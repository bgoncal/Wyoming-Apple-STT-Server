import AVFoundation
import Foundation
import Speech

enum WyomingSpeechTranscriberError: LocalizedError {
    case engineUnavailable
    case noSupportedLocales

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            return "Apple's local speech engine is unavailable on this Mac."
        case .noSupportedLocales:
            return "No compatible Apple speech locale is installed."
        }
    }
}

actor WyomingSpeechTranscriber {
    struct Response: Sendable {
        var text: String
        var language: String
    }

    func availableLocaleIdentifiers() async -> [String] {
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
        if !installed.isEmpty {
            return installed.sorted()
        }

        return await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    }

    func transcribe(
        audioData: Data,
        format: WyomingAudioFormat,
        languageHint: String?,
        preferredLocaleIdentifier: String
    ) async throws -> Response {
        guard SpeechTranscriber.isAvailable else {
            throw WyomingSpeechTranscriberError.engineUnavailable
        }

        let locale = try await resolveLocale(languageHint: languageHint, preferredLocaleIdentifier: preferredLocaleIdentifier)
        guard !audioData.isEmpty else {
            return Response(text: "", language: locale.identifier)
        }

        let wavURL = try WAVFileWriter.makeLinearPCMFile(audio: audioData, format: format)
        defer {
            try? FileManager.default.removeItem(at: wavURL)
        }

        let audioFile = try AVAudioFile(forReading: wavURL)
        let speechModule = SpeechTranscriber(locale: locale, preset: .transcription)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [speechModule], options: options)

        let resultCollector = Task {
            var latestResult = ""
            for try await result in speechModule.results {
                let candidate = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    latestResult = candidate
                }
            }
            return latestResult
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            let text = try await resultCollector.value
            return Response(text: text, language: locale.identifier)
        } catch {
            resultCollector.cancel()
            throw error
        }
    }

    private func resolveLocale(languageHint: String?, preferredLocaleIdentifier: String) async throws -> Locale {
        let preferredIdentifiers = [
            normalizeLanguageIdentifier(languageHint),
            normalizeLanguageIdentifier(preferredLocaleIdentifier),
            Optional(Locale.current.identifier),
        ]

        var preferredCandidates: [Locale] = []
        for candidate in preferredIdentifiers {
            guard let candidate, !candidate.isEmpty else { continue }
            preferredCandidates.append(Locale(identifier: candidate))
        }

        for candidate in preferredCandidates {
            if let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                return resolved
            }
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        if let first = supportedLocales.first {
            return first
        }

        throw WyomingSpeechTranscriberError.noSupportedLocales
    }

    private func normalizeLanguageIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        return identifier.replacingOccurrences(of: "_", with: "-")
    }
}
