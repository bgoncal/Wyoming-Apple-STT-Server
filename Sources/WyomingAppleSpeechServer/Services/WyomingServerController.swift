import Foundation
import Network

@MainActor
final class WyomingServerController {
    var onLog: ((String) -> Void)?
    var onPhaseChange: ((AppModel.ServerPhase) -> Void)?
    var onClientCountChange: ((Int) -> Void)?
    var onTranscript: ((TranscriptRecord) -> Void)?

    private let configuration: ServerConfiguration
    private let transcriber: WyomingSpeechTranscriber
    private var listener: NWListener?
    private var sessions: [UUID: WyomingClientSession] = [:]

    init(configuration: ServerConfiguration, transcriber: WyomingSpeechTranscriber) {
        self.configuration = configuration
        self.transcriber = transcriber
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: configuration.port)!)
        listener.service = NWListener.Service(name: configuration.serviceName, type: "_wyoming._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handleNewConnection(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleListenerState(state)
            }
        }

        self.listener = listener
        onPhaseChange?(.starting)
        listener.start(queue: .main)
    }

    func stop() {
        for session in sessions.values {
            session.cancel()
        }
        sessions.removeAll()
        onClientCountChange?(0)
        listener?.cancel()
        listener = nil
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let session = WyomingClientSession(
            connection: connection,
            configuration: configuration,
            transcriber: transcriber
        )

        session.onLog = { [weak self] message in
            self?.onLog?(message)
        }
        session.onTranscript = { [weak self] record in
            self?.onTranscript?(record)
        }
        session.onClose = { [weak self] sessionID in
            self?.sessions.removeValue(forKey: sessionID)
            self?.onClientCountChange?(self?.sessions.count ?? 0)
        }

        sessions[session.id] = session
        onClientCountChange?(sessions.count)
        session.start()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            onLog?("Listening on tcp://0.0.0.0:\(configuration.port) and advertising \(configuration.serviceName) via _wyoming._tcp.local.")
            onPhaseChange?(.running)
        case let .failed(error):
            onLog?("Listener failed: \(error.localizedDescription)")
            onPhaseChange?(.failed(error.localizedDescription))
            listener?.cancel()
            listener = nil
        case let .waiting(error):
            onLog?("Listener waiting: \(error.localizedDescription)")
        case .cancelled:
            onPhaseChange?(.stopped)
        default:
            break
        }
    }
}

@MainActor
private final class WyomingClientSession {
    let id = UUID()

    var onLog: ((String) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onTranscript: ((TranscriptRecord) -> Void)?

    private let connection: NWConnection
    private let configuration: ServerConfiguration
    private let transcriber: WyomingSpeechTranscriber
    private let parser = WyomingEventParser()

    private var transcribeRequest = WyomingTranscribeRequest()
    private var activeAudioFormat: WyomingAudioFormat?
    private var activeAudio = Data()
    private var hasClosed = false

    init(connection: NWConnection, configuration: ServerConfiguration, transcriber: WyomingSpeechTranscriber) {
        self.connection = connection
        self.configuration = configuration
        self.transcriber = transcriber
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(state)
            }
        }
        connection.start(queue: .main)
    }

    func cancel() {
        connection.cancel()
        closeIfNeeded()
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onLog?("Client connected from \(clientLabel).")
            receiveNextChunk()
        case let .failed(error):
            onLog?("Connection to \(clientLabel) failed: \(error.localizedDescription)")
            closeIfNeeded()
        case .cancelled:
            closeIfNeeded()
        default:
            break
        }
    }

    private func receiveNextChunk() {
        guard !hasClosed else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.onLog?("Receive error from \(self.clientLabel): \(error.localizedDescription)")
                    self.closeIfNeeded()
                    return
                }

                if let data, !data.isEmpty {
                    do {
                        let events = try self.parser.append(data)
                        for event in events {
                            await self.handle(event)
                        }
                    } catch {
                        self.onLog?("Protocol error from \(self.clientLabel): \(error.localizedDescription)")
                        self.closeIfNeeded()
                        return
                    }
                }

                if isComplete {
                    self.closeIfNeeded()
                } else {
                    self.receiveNextChunk()
                }
            }
        }
    }

    private func handle(_ event: WyomingEvent) async {
        switch event.type {
        case "describe":
            let locales = await transcriber.availableLocaleIdentifiers()
            send(.info(serviceName: configuration.serviceName, languages: locales, port: configuration.port))

        case "transcribe":
            transcribeRequest = WyomingTranscribeRequest(
                name: event.data["name"]?.stringValue,
                language: event.data["language"]?.stringValue,
                context: event.data["context"]?.objectValue
            )

        case "audio-start":
            activeAudioFormat = WyomingAudioFormat.from(event.data)
            activeAudio.removeAll(keepingCapacity: true)

        case "audio-chunk":
            if activeAudioFormat == nil {
                activeAudioFormat = WyomingAudioFormat.from(event.data)
            }
            activeAudio.append(event.payload ?? Data())

        case "audio-stop":
            guard let format = activeAudioFormat else {
                onLog?("Ignoring audio-stop from \(clientLabel) because no audio-start was received.")
                return
            }

            let audio = activeAudio
            let request = transcribeRequest
            activeAudioFormat = nil
            activeAudio.removeAll(keepingCapacity: false)
            transcribeRequest = WyomingTranscribeRequest()

            do {
                let result = try await transcriber.transcribe(
                    audioData: audio,
                    format: format,
                    languageHint: request.language,
                    preferredLocaleIdentifier: configuration.preferredLocaleIdentifier
                )
                send(.transcript(text: result.text, language: result.language))
                onTranscript?(
                    TranscriptRecord(
                        timestamp: .now,
                        text: result.text.isEmpty ? "[No speech detected]" : result.text,
                        language: result.language,
                        client: clientLabel
                    )
                )
                onLog?(
                    result.text.isEmpty
                    ? "Transcribed \(clientLabel): <empty>"
                    : "Transcribed \(clientLabel): \(result.text)"
                )
            } catch {
                send(.transcript(text: "", language: request.language ?? configuration.preferredLocaleIdentifier))
                onLog?("Transcription failed for \(clientLabel): \(error.localizedDescription)")
            }

        case "ping":
            send(WyomingEvent(type: "pong"))

        default:
            onLog?("Ignoring unsupported Wyoming event '\(event.type)' from \(clientLabel).")
        }
    }

    private func send(_ event: WyomingEvent) {
        do {
            let content = try event.serialized()
            connection.send(content: content, completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                Task { @MainActor [weak self] in
                    self?.onLog?("Send error to \(self?.clientLabel ?? "client"): \(error.localizedDescription)")
                }
            })
        } catch {
            onLog?("Failed to encode '\(event.type)' for \(clientLabel): \(error.localizedDescription)")
        }
    }

    private func closeIfNeeded() {
        guard !hasClosed else { return }
        hasClosed = true
        connection.cancel()
        onLog?("Client disconnected from \(clientLabel).")
        onClose?(id)
    }

    private var clientLabel: String {
        switch connection.endpoint {
        case let .hostPort(host, port):
            return "\(host):\(port.rawValue)"
        default:
            return "\(connection.endpoint)"
        }
    }
}
