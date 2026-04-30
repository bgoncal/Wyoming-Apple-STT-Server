import AVFoundation
import AppKit
import Foundation

enum WyomingSpeechSynthesizerError: LocalizedError {
    case emptyText
    case unsupportedAudioBuffer
    case synthesisFailed
    case unavailableVoice(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text was provided for speech synthesis."
        case .unsupportedAudioBuffer:
            return "Apple Speech Synthesis returned an unsupported audio buffer format."
        case .synthesisFailed:
            return "Apple Speech Synthesis did not produce audio."
        case let .unavailableVoice(voice):
            return "Apple Speech Synthesis could not load voice '\(voice)'."
        }
    }
}

final class WyomingSpeechSynthesizer: @unchecked Sendable {
    struct Response: Sendable {
        var audioData: Data
        var format: WyomingAudioFormat
        var voiceIdentifier: String?
    }

    func availableVoices() -> [WyomingTTSVoice] {
        appleVoiceDescriptors()
            .map { descriptor in
                WyomingTTSVoice(
                    name: descriptor.identifier,
                    language: descriptor.language,
                    displayName: descriptor.name,
                    variantDescription: descriptor.variantDescription
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func synthesize(
        text rawText: String,
        requestedVoice: WyomingSynthesizeVoice?,
        preferredLanguage: String
    ) async throws -> Response {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw WyomingSpeechSynthesizerError.emptyText
        }

        switch resolveVoice(requestedVoice: requestedVoice, preferredLanguage: preferredLanguage) {
        case let .avFoundation(voice):
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice

            let job = SpeechSynthesisJob(voiceIdentifier: utterance.voice?.identifier)
            return try await job.run(utterance: utterance)

        case let .appKit(identifier):
            let job = FileSpeechSynthesisJob(voiceIdentifier: identifier)
            return try await job.run(text: text)
        }
    }

    private func resolveVoice(
        requestedVoice: WyomingSynthesizeVoice?,
        preferredLanguage: String
    ) -> ResolvedSpeechVoice {
        let voices = AVSpeechSynthesisVoice.speechVoices()

        if let requestedName = requestedVoice?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedName.isEmpty {
            if let voice = AVSpeechSynthesisVoice(identifier: requestedName) ?? voice(matching: requestedName, in: voices) {
                return .avFoundation(voice)
            }

            if let appKitVoiceIdentifier = appKitVoiceIdentifier(matching: requestedName) {
                return .appKit(appKitVoiceIdentifier)
            }

            if let fallback = fallbackVoice(for: requestedName, in: voices) {
                return fallback
            }
        }

        if let requestedSpeaker = requestedVoice?.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedSpeaker.isEmpty {
            if let voice = AVSpeechSynthesisVoice(identifier: requestedSpeaker) ?? voice(matching: requestedSpeaker, in: voices) {
                return .avFoundation(voice)
            }

            if let appKitVoiceIdentifier = appKitVoiceIdentifier(matching: requestedSpeaker) {
                return .appKit(appKitVoiceIdentifier)
            }
        }

        if let requestedLanguage = normalizedLanguageIdentifier(requestedVoice?.language),
           let voice = AVSpeechSynthesisVoice(language: requestedLanguage) {
            return .avFoundation(voice)
        }

        if let voice = AVSpeechSynthesisVoice(language: normalizedLanguageIdentifier(preferredLanguage) ?? preferredLanguage) {
            return .avFoundation(voice)
        }

        return .avFoundation(AVSpeechSynthesisVoice(language: Locale.current.identifier))
    }

    private func voice(matching requestedName: String, in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        voices.first { voice in
            voice.identifier.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || voice.name.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func appKitVoiceIdentifier(matching requestedName: String) -> String? {
        appleVoiceDescriptors().first { descriptor in
            descriptor.identifier.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || descriptor.name.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }?.identifier
    }

    private func fallbackVoice(for requestedIdentifier: String, in voices: [AVSpeechSynthesisVoice]) -> ResolvedSpeechVoice? {
        guard let descriptor = mobileAssetVoiceDescriptor(for: requestedIdentifier) else {
            if let languageVoice = AVSpeechSynthesisVoice(language: normalizedLanguageIdentifier(requestedIdentifier) ?? requestedIdentifier) {
                return .avFoundation(languageVoice)
            }
            return nil
        }

        let fallbackIdentifiers = [
            "com.apple.voice.compact.\(descriptor.language).\(descriptor.name)",
            "com.apple.voice.super-compact.\(descriptor.language).\(descriptor.name)",
        ]

        for identifier in fallbackIdentifiers {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                return .avFoundation(voice)
            }
            if mobileAssetVoiceDescriptor(for: identifier) != nil {
                return .appKit(identifier)
            }
        }

        if let voice = voices.first(where: { voice in
            voice.language == descriptor.language
            && voice.name.compare(descriptor.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return .avFoundation(voice)
        }

        if let languageVoice = AVSpeechSynthesisVoice(language: descriptor.language) {
            return .avFoundation(languageVoice)
        }

        return nil
    }

    private func normalizedLanguageIdentifier(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return identifier.replacingOccurrences(of: "_", with: "-")
    }

    private func appleVoiceDescriptors() -> [AppleVoiceDescriptor] {
        var descriptorsByIdentifier: [String: AppleVoiceDescriptor] = [:]

        for descriptor in appKitVoiceDescriptors() {
            descriptorsByIdentifier[descriptor.identifier] = descriptor
        }

        return Array(descriptorsByIdentifier.values)
    }

    private func appKitVoiceDescriptors() -> [AppleVoiceDescriptor] {
        NSSpeechSynthesizer.availableVoices.compactMap { voice in
            let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
            let identifier = voice.rawValue
            let name = attributes[.name] as? String ?? identifier
            let language = (attributes[.localeIdentifier] as? String)
                ?? (attributes[NSSpeechSynthesizer.VoiceAttributeKey(rawValue: "VoiceLanguage")] as? String)
                ?? Locale.current.identifier

            return AppleVoiceDescriptor(
                identifier: identifier,
                name: name,
                language: normalizedLanguageIdentifier(language) ?? language,
                variantDescription: variantDescription(for: identifier)
            )
        }
    }

    private func mobileAssetVoiceDescriptor(for identifier: String) -> AppleVoiceDescriptor? {
        let prefix = "com.apple.voice."
        guard identifier.hasPrefix(prefix) else { return nil }

        let components = identifier.dropFirst(prefix.count).split(separator: ".")
        guard components.count >= 3 else { return nil }

        let quality = String(components[0])
        let name = String(components[components.count - 1])
        let language = components[1..<(components.count - 1)].joined(separator: ".")
        let variant = variantDescription(for: identifier) ?? quality.capitalized

        return AppleVoiceDescriptor(
            identifier: identifier,
            name: name,
            language: normalizedLanguageIdentifier(language) ?? language,
            variantDescription: variant
        )
    }

    private func variantDescription(for identifier: String) -> String? {
        if identifier.localizedCaseInsensitiveContains(".premium.") {
            return "Premium"
        }
        if identifier.localizedCaseInsensitiveContains(".enhanced.") {
            return "Enhanced"
        }
        if identifier.localizedCaseInsensitiveContains(".compact.")
            || identifier.localizedCaseInsensitiveContains(".super-compact.") {
            return "Compact"
        }
        return nil
    }
}

private struct AppleVoiceDescriptor {
    var identifier: String
    var name: String
    var language: String
    var variantDescription: String?
}

private enum ResolvedSpeechVoice {
    case avFoundation(AVSpeechSynthesisVoice?)
    case appKit(String)
}

private final class SpeechSynthesisJob: @unchecked Sendable {
    private let lock = NSLock()
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: String?
    private var continuation: CheckedContinuation<WyomingSpeechSynthesizer.Response, Error>?
    private var audioData = Data()
    private var audioFormat: WyomingAudioFormat?
    private var didResume = false

    init(voiceIdentifier: String?) {
        self.voiceIdentifier = voiceIdentifier
    }

    func run(utterance: AVSpeechUtterance) async throws -> WyomingSpeechSynthesizer.Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                }

                synthesizer.write(utterance) { [self] buffer in
                    handle(buffer: buffer)
                }
            }
        } onCancel: {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func handle(buffer: AVAudioBuffer) {
        lock.withLock {
            guard !didResume else { return }

            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                resume(throwing: WyomingSpeechSynthesizerError.unsupportedAudioBuffer)
                return
            }

            guard pcmBuffer.frameLength > 0 else {
                finish()
                return
            }

            do {
                audioData.append(try PCMBufferConverter.int16PCMData(from: pcmBuffer))
                audioFormat = WyomingAudioFormat(
                    rate: Int(pcmBuffer.format.sampleRate.rounded()),
                    width: 2,
                    channels: Int(pcmBuffer.format.channelCount)
                )
            } catch {
                resume(throwing: error)
            }
        }
    }

    private func finish() {
        guard let audioFormat, !audioData.isEmpty else {
            resume(throwing: WyomingSpeechSynthesizerError.synthesisFailed)
            return
        }

        resume(
            returning: WyomingSpeechSynthesizer.Response(
                audioData: audioData,
                format: audioFormat,
                voiceIdentifier: voiceIdentifier
            )
        )
    }

    private func resume(returning response: WyomingSpeechSynthesizer.Response) {
        guard !didResume else { return }
        didResume = true
        continuation?.resume(returning: response)
        continuation = nil
    }

    private func resume(throwing error: Error) {
        guard !didResume else { return }
        didResume = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private final class FileSpeechSynthesisJob: NSObject, NSSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let voiceIdentifier: String
    private let outputURL: URL
    private var synthesizer: NSSpeechSynthesizer?
    private var continuation: CheckedContinuation<WyomingSpeechSynthesizer.Response, Error>?
    private var didResume = false

    init(voiceIdentifier: String) {
        self.voiceIdentifier = voiceIdentifier
        self.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyoming-tts-\(UUID().uuidString)")
            .appendingPathExtension("aiff")
    }

    func run(text: String) async throws -> WyomingSpeechSynthesizer.Response {
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                }

                DispatchQueue.main.async {
                    self.start(text: text)
                }
            }
        } onCancel: {
            synthesizer?.stopSpeaking()
        }
    }

    private func start(text: String) {
        guard let synthesizer = NSSpeechSynthesizer(
            voice: NSSpeechSynthesizer.VoiceName(rawValue: voiceIdentifier)
        ) else {
            resume(throwing: WyomingSpeechSynthesizerError.unavailableVoice(voiceIdentifier))
            return
        }

        self.synthesizer = synthesizer
        synthesizer.delegate = self

        guard synthesizer.startSpeaking(text, to: outputURL) else {
            resume(throwing: WyomingSpeechSynthesizerError.synthesisFailed)
            return
        }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        guard finishedSpeaking else {
            resume(throwing: WyomingSpeechSynthesizerError.synthesisFailed)
            return
        }

        do {
            let file = try AVAudioFile(forReading: outputURL)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else {
                throw WyomingSpeechSynthesizerError.unsupportedAudioBuffer
            }

            try file.read(into: buffer)
            let audioData = try PCMBufferConverter.int16PCMData(from: buffer)
            let format = WyomingAudioFormat(
                rate: Int(buffer.format.sampleRate.rounded()),
                width: 2,
                channels: Int(buffer.format.channelCount)
            )

            resume(
                returning: WyomingSpeechSynthesizer.Response(
                    audioData: audioData,
                    format: format,
                    voiceIdentifier: voiceIdentifier
                )
            )
        } catch {
            resume(throwing: error)
        }
    }

    private func resume(returning response: WyomingSpeechSynthesizer.Response) {
        lock.withLock {
            guard !didResume else { return }
            didResume = true
            continuation?.resume(returning: response)
            continuation = nil
            synthesizer = nil
        }
    }

    private func resume(throwing error: Error) {
        lock.withLock {
            guard !didResume else { return }
            didResume = true
            continuation?.resume(throwing: error)
            continuation = nil
            synthesizer = nil
        }
    }
}

private enum PCMBufferConverter {
    static func int16PCMData(from buffer: AVAudioPCMBuffer) throws -> Data {
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            return try int16PCMDataFromFloat32(buffer)
        case .pcmFormatInt16:
            return try int16PCMDataFromInt16(buffer)
        default:
            throw WyomingSpeechSynthesizerError.unsupportedAudioBuffer
        }
    }

    private static func int16PCMDataFromFloat32(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard let channelData = buffer.floatChannelData else {
            throw WyomingSpeechSynthesizerError.unsupportedAudioBuffer
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var data = Data(capacity: frameCount * channelCount * MemoryLayout<Int16>.size)

        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<channelCount {
                let sample = max(-1, min(1, channelData[channelIndex][frameIndex]))
                let intSample = Int16((sample * Float(Int16.max)).rounded())
                appendLittleEndian(intSample, to: &data)
            }
        }

        return data
    }

    private static func int16PCMDataFromInt16(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard let channelData = buffer.int16ChannelData else {
            throw WyomingSpeechSynthesizerError.unsupportedAudioBuffer
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        if buffer.format.isInterleaved {
            let byteCount = frameCount * channelCount * MemoryLayout<Int16>.size
            return Data(bytes: channelData[0], count: byteCount)
        }

        var data = Data(capacity: frameCount * channelCount * MemoryLayout<Int16>.size)
        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<channelCount {
                appendLittleEndian(channelData[channelIndex][frameIndex], to: &data)
            }
        }

        return data
    }

    private static func appendLittleEndian(_ sample: Int16, to data: inout Data) {
        var littleEndianSample = sample.littleEndian
        withUnsafeBytes(of: &littleEndianSample) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
