import AVFoundation
import Foundation
import Speech

enum WyomingSpeechTranscriberError: LocalizedError {
    case engineUnavailable
    case noSupportedLocales
    case unsupportedLocale(String)
    case assetInstallationIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            return "Apple's local speech engine is unavailable on this Mac."
        case .noSupportedLocales:
            return "No compatible Apple speech locale is installed."
        case let .unsupportedLocale(identifier):
            return "Apple Speech does not support the locale \(identifier)."
        case let .assetInstallationIncomplete(identifier):
            return "Speech assets for \(identifier) were not fully installed."
        }
    }
}

actor WyomingSpeechTranscriber {
    struct Response: Sendable {
        var text: String
        var language: String
    }

    func availableLocaleIdentifiers() async -> [String] {
        return await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    }

    func localeOptions() async -> [SpeechLocaleOption] {
        let installedIdentifiers = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        let supportedLocales = await SpeechTranscriber.supportedLocales

        return supportedLocales
            .map { locale in
                SpeechLocaleOption(
                    identifier: locale.identifier,
                    displayName: localizedDisplayName(for: locale.identifier),
                    availability: installedIdentifiers.contains(locale.identifier) ? .installed : .downloadable
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func ensureLocaleInstalled(
        identifier: String,
        progressHandler: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> String {
        let locale = try await canonicalSupportedLocale(for: identifier)
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let currentStatus = await AssetInventory.status(forModules: [module])

        if currentStatus == .installed {
            if let progressHandler {
                await progressHandler(1)
            }
            return locale.identifier
        }

        if let progressHandler {
            await progressHandler(0)
        }

        let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        let progressTask: Task<Void, Never>?

        if let request {
            progressTask = Task {
                while !Task.isCancelled {
                    if let progressHandler {
                        await progressHandler(request.progress.fractionCompleted)
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }

            do {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await request.downloadAndInstall()
                    try Task.checkCancellation()
                } onCancel: {
                    request.progress.cancel()
                }
            } catch {
                progressTask?.cancel()
                throw error
            }
        } else {
            progressTask = nil
        }

        progressTask?.cancel()
        try Task.checkCancellation()

        let finalStatus = await AssetInventory.status(forModules: [module])
        guard finalStatus == .installed else {
            throw WyomingSpeechTranscriberError.assetInstallationIncomplete(locale.identifier)
        }

        if let progressHandler {
            await progressHandler(1)
        }

        return locale.identifier
    }

    func releaseLocaleReservation(identifier: String) async throws -> Bool {
        let locale = try await canonicalSupportedLocale(for: identifier)
        return await AssetInventory.release(reservedLocale: locale)
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
        _ = try await ensureLocaleInstalled(identifier: locale.identifier)
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

    private func canonicalSupportedLocale(for identifier: String) async throws -> Locale {
        let locale = Locale(identifier: normalizeLanguageIdentifier(identifier) ?? identifier)
        if let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return resolved
        }

        throw WyomingSpeechTranscriberError.unsupportedLocale(identifier)
    }

    private func normalizeLanguageIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        return identifier.replacingOccurrences(of: "_", with: "-")
    }

    private func localizedDisplayName(for identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        return locale.localizedString(forIdentifier: identifier) ?? identifier
    }
}
