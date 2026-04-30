import AVFoundation
import Foundation

enum WyomingSpeechSynthesizerError: LocalizedError {
    case emptyText
    case unsupportedAudioBuffer
    case synthesisFailed

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text was provided for speech synthesis."
        case .unsupportedAudioBuffer:
            return "Apple Speech Synthesis returned an unsupported audio buffer format."
        case .synthesisFailed:
            return "Apple Speech Synthesis did not produce audio."
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
        AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                WyomingTTSVoice(name: voice.identifier, language: voice.language, displayName: voice.name)
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

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolveVoice(requestedVoice: requestedVoice, preferredLanguage: preferredLanguage)

        let job = SpeechSynthesisJob(voiceIdentifier: utterance.voice?.identifier)
        return try await job.run(utterance: utterance)
    }

    private func resolveVoice(
        requestedVoice: WyomingSynthesizeVoice?,
        preferredLanguage: String
    ) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()

        if let requestedName = requestedVoice?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedName.isEmpty,
           let voice = voice(matching: requestedName, in: voices) {
            return voice
        }

        if let requestedSpeaker = requestedVoice?.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedSpeaker.isEmpty,
           let voice = voice(matching: requestedSpeaker, in: voices) {
            return voice
        }

        if let requestedLanguage = normalizedLanguageIdentifier(requestedVoice?.language),
           let voice = AVSpeechSynthesisVoice(language: requestedLanguage) {
            return voice
        }

        if let voice = AVSpeechSynthesisVoice(language: normalizedLanguageIdentifier(preferredLanguage) ?? preferredLanguage) {
            return voice
        }

        return AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    private func voice(matching requestedName: String, in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        voices.first { voice in
            voice.identifier.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || voice.name.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func normalizedLanguageIdentifier(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return identifier.replacingOccurrences(of: "_", with: "-")
    }
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
                audioData.append(try Self.int16PCMData(from: pcmBuffer))
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

    private static func int16PCMData(from buffer: AVAudioPCMBuffer) throws -> Data {
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
