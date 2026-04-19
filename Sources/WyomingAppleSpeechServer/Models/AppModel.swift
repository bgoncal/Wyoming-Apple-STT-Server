import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum ServerPhase: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    var serviceName: String
    var portText: String
    var preferredLocaleIdentifier: String
    var autoStart: Bool
    var serverPhase: ServerPhase = .stopped
    var availableLocaleIdentifiers: [String] = []
    var activeClientCount = 0
    var advertisedServiceType = "_wyoming._tcp.local."
    var recentTranscripts: [TranscriptRecord] = []
    var logs: [LogEntry] = []

    private let transcriber = WyomingSpeechTranscriber()
    private var serverController: WyomingServerController?

    init() {
        let defaults = UserDefaults.standard
        self.serviceName = defaults.string(forKey: Defaults.serviceName) ?? Host.current().localizedName ?? "Wyoming Apple Speech"

        let savedPort = defaults.integer(forKey: Defaults.port)
        self.portText = String(savedPort == 0 ? 10_300 : savedPort)
        self.preferredLocaleIdentifier = defaults.string(forKey: Defaults.localeIdentifier) ?? Locale.current.identifier
        self.autoStart = defaults.object(forKey: Defaults.autoStart) as? Bool ?? true

        appendLog("Ready to host a Wyoming STT endpoint backed by Apple Speech.")

        Task { @MainActor [weak self] in
            await self?.bootstrap()
        }
    }

    var canStart: Bool {
        serverController == nil
    }

    var canStop: Bool {
        serverController != nil
    }

    func startServer() async {
        guard serverController == nil else {
            appendLog("Server is already running.")
            return
        }

        guard let port = UInt16(portText), port > 0 else {
            serverPhase = .failed("Choose a valid TCP port.")
            appendLog("Invalid port: \(portText).")
            return
        }

        serverPhase = .starting
        persistCurrentDraft(port: port)

        let authorizationStatus = await SpeechAuthorization.requestIfNeeded()
        guard authorizationStatus == .authorized else {
            let explanation = SpeechAuthorization.failureDescription(for: authorizationStatus)
            serverPhase = .failed(explanation)
            appendLog("Speech authorization failed: \(explanation)")
            return
        }

        let trimmedName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = ServerConfiguration(
            serviceName: trimmedName.isEmpty ? "Wyoming Apple Speech" : trimmedName,
            port: port,
            preferredLocaleIdentifier: preferredLocaleIdentifier,
            autoStart: autoStart
        )

        let controller = WyomingServerController(configuration: configuration, transcriber: transcriber)
        controller.onLog = { [weak self] message in
            self?.appendLog(message)
        }
        controller.onTranscript = { [weak self] record in
            self?.recentTranscripts.insert(record, at: 0)
            self?.recentTranscripts = Array(self?.recentTranscripts.prefix(20) ?? [])
        }
        controller.onClientCountChange = { [weak self] count in
            self?.activeClientCount = count
        }
        controller.onPhaseChange = { [weak self] phase in
            self?.serverPhase = phase
            if case .stopped = phase {
                self?.serverController = nil
            }
            if case .failed = phase {
                self?.serverController = nil
            }
        }

        do {
            try controller.start()
            serverController = controller
        } catch {
            serverPhase = .failed(error.localizedDescription)
            appendLog("Unable to start listener: \(error.localizedDescription)")
        }
    }

    func stopServer() {
        serverController?.stop()
        serverController = nil
        activeClientCount = 0
        serverPhase = .stopped
        appendLog("Server stopped.")
    }

    func restartServer() async {
        stopServer()
        await startServer()
    }

    func refreshAvailableLocales() async {
        let locales = await transcriber.availableLocaleIdentifiers()
        let current = preferredLocaleIdentifier
        let merged = Array(Set(locales + [current])).sorted()
        availableLocaleIdentifiers = merged
    }

    func localeDisplayName(for identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        let languageName = locale.localizedString(forIdentifier: identifier) ?? identifier
        return "\(languageName) (\(identifier))"
    }

    private func bootstrap() async {
        await refreshAvailableLocales()
        if autoStart {
            await startServer()
        }
    }

    private func appendLog(_ message: String) {
        logs.insert(LogEntry(timestamp: .now, message: message), at: 0)
        logs = Array(logs.prefix(200))
    }

    private func persistCurrentDraft(port: UInt16) {
        let defaults = UserDefaults.standard
        defaults.set(serviceName, forKey: Defaults.serviceName)
        defaults.set(Int(port), forKey: Defaults.port)
        defaults.set(preferredLocaleIdentifier, forKey: Defaults.localeIdentifier)
        defaults.set(autoStart, forKey: Defaults.autoStart)
    }
}

private enum Defaults {
    static let serviceName = "serviceName"
    static let port = "port"
    static let localeIdentifier = "preferredLocaleIdentifier"
    static let autoStart = "autoStart"
}
