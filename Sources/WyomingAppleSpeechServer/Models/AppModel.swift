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
    var localeOptions: [SpeechLocaleOption] = []
    var localeDownloadState: LocaleDownloadState?
    var localeInstallErrorMessage: String?
    var localeRemovalIdentifier: String?
    var activeClientCount = 0
    var advertisedServiceType = "_wyoming._tcp.local."
    var recentTranscripts: [TranscriptRecord] = []
    var logs: [LogEntry] = []

    private let transcriber = WyomingSpeechTranscriber()
    private var serverController: WyomingServerController?
    private var localeInstallTask: Task<String, Error>?
    private var pendingRemovalLocaleIdentifiers: Set<String> = []

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
        serverController == nil && localeDownloadState == nil
    }

    var canStop: Bool {
        serverController != nil
    }

    var isInstallingLocale: Bool {
        localeDownloadState != nil
    }

    var installedLocaleOptions: [SpeechLocaleOption] {
        localeOptions.filter { option in
            switch localeAvailability(for: option) {
            case .installed, .removalRequested:
                return true
            default:
                return false
            }
        }
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
        localeInstallErrorMessage = nil

        let authorizationStatus = await SpeechAuthorization.requestIfNeeded()
        guard authorizationStatus == .authorized else {
            let explanation = SpeechAuthorization.failureDescription(for: authorizationStatus)
            serverPhase = .failed(explanation)
            appendLog("Speech authorization failed: \(explanation)")
            return
        }

        do {
            try await ensurePreferredLocaleIsReady(trigger: "Starting server")
        } catch is CancellationError {
            serverPhase = .stopped
            appendLog("Server start canceled because locale asset download was canceled.")
        } catch {
            serverPhase = .failed(error.localizedDescription)
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
        var options = await transcriber.localeOptions()
        if !options.contains(where: { $0.identifier == preferredLocaleIdentifier }) {
            options.append(
                SpeechLocaleOption(
                    identifier: preferredLocaleIdentifier,
                    displayName: localeDisplayName(for: preferredLocaleIdentifier),
                    availability: .unsupported
                )
            )
            options.sort { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
        localeOptions = options
    }

    func handlePreferredLocaleSelectionChange() async {
        localeInstallErrorMessage = nil
        persistCurrentDraft(port: UInt16(portText) ?? 10_300)
        await refreshAvailableLocales()

        do {
            try await ensurePreferredLocaleIsReady(trigger: "Selected locale")
        } catch is CancellationError {
            localeInstallErrorMessage = "Locale download canceled."
        } catch {
            localeInstallErrorMessage = error.localizedDescription
        }
    }

    func cancelLocaleInstallation() {
        guard let task = localeInstallTask, let currentDownload = localeDownloadState else {
            return
        }

        task.cancel()
        localeInstallTask = nil
        localeDownloadState = nil
        localeInstallErrorMessage = "Locale download canceled."
        appendLog("Canceled Apple Speech asset download for \(currentDownload.identifier).")

        Task { @MainActor [weak self] in
            await self?.refreshAvailableLocales()
        }
    }

    func removeLocale(identifier: String) async {
        guard localeRemovalIdentifier == nil else {
            return
        }

        guard !(serverController != nil && preferredLocaleIdentifier == identifier) else {
            localeInstallErrorMessage = "Stop the server before removing the currently selected locale."
            return
        }

        localeInstallErrorMessage = nil
        localeRemovalIdentifier = identifier
        appendLog("Releasing Apple Speech assets for \(identifier).")

        do {
            let released = try await transcriber.releaseLocaleReservation(identifier: identifier)
            localeRemovalIdentifier = nil

            if released {
                pendingRemovalLocaleIdentifiers.insert(identifier)
                appendLog("Release requested for \(identifier). macOS may remove the downloaded speech assets later.")
            } else {
                localeInstallErrorMessage = "This locale is not currently reserved by the app, so there was nothing to remove."
                appendLog("No removable reservation found for \(identifier).")
            }

            await refreshAvailableLocales()
        } catch {
            localeRemovalIdentifier = nil
            localeInstallErrorMessage = error.localizedDescription
            appendLog("Failed to release speech assets for \(identifier): \(error.localizedDescription)")
        }
    }

    func localeDisplayName(for identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        let languageName = locale.localizedString(forIdentifier: identifier) ?? identifier
        return "\(languageName) (\(identifier))"
    }

    func localePickerLabel(for option: SpeechLocaleOption) -> String {
        "\(option.displayName) (\(option.identifier)) - \(localeAvailability(for: option).label)"
    }

    func localeAvailability(for option: SpeechLocaleOption) -> SpeechLocaleOption.Availability {
        if localeDownloadState?.identifier == option.identifier {
            return .downloading
        }

        if pendingRemovalLocaleIdentifiers.contains(option.identifier) {
            return .removalRequested
        }

        return option.availability
    }

    func canRemoveLocale(_ identifier: String) -> Bool {
        if isInstallingLocale || localeRemovalIdentifier != nil {
            return false
        }

        if serverController != nil && preferredLocaleIdentifier == identifier {
            return false
        }

        return true
    }

    var selectedLocaleAvailabilityLabel: String {
        guard let option = localeOptions.first(where: { $0.identifier == preferredLocaleIdentifier }) else {
            return "Unavailable"
        }

        return localeAvailability(for: option).label
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

    private func ensurePreferredLocaleIsReady(trigger: String) async throws {
        guard let option = localeOptions.first(where: { $0.identifier == preferredLocaleIdentifier }) else {
            throw WyomingSpeechTranscriberError.unsupportedLocale(preferredLocaleIdentifier)
        }

        guard localeAvailability(for: option) != .installed else {
            return
        }

        let displayName = localeDisplayName(for: preferredLocaleIdentifier)
        localeDownloadState = LocaleDownloadState(identifier: preferredLocaleIdentifier, displayName: displayName, progress: 0)
        appendLog("\(trigger): downloading Apple Speech assets for \(preferredLocaleIdentifier).")
        let identifierToInstall = preferredLocaleIdentifier
        let task = Task<String, Error> { [transcriber] in
            try await transcriber.ensureLocaleInstalled(identifier: identifierToInstall) { [weak self] progress in
                await MainActor.run {
                    guard let self else { return }
                    if self.localeDownloadState?.identifier == identifierToInstall {
                        self.localeDownloadState?.progress = progress
                    }
                }
            }
        }
        localeInstallTask = task

        do {
            let canonicalIdentifier = try await task.value
            localeInstallTask = nil

            preferredLocaleIdentifier = canonicalIdentifier
            pendingRemovalLocaleIdentifiers.remove(canonicalIdentifier)
            localeDownloadState?.progress = 1
            await refreshAvailableLocales()
            localeDownloadState = nil
            appendLog("Apple Speech assets ready for \(canonicalIdentifier).")
        } catch is CancellationError {
            localeInstallTask = nil
            localeDownloadState = nil
            await refreshAvailableLocales()
            throw CancellationError()
        } catch {
            localeInstallTask = nil
            localeDownloadState = nil
            localeInstallErrorMessage = error.localizedDescription
            appendLog("Failed to install speech assets for \(preferredLocaleIdentifier): \(error.localizedDescription)")
            throw error
        }
    }
}

private enum Defaults {
    static let serviceName = "serviceName"
    static let port = "port"
    static let localeIdentifier = "preferredLocaleIdentifier"
    static let autoStart = "autoStart"
}
