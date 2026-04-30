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
    private let synthesizer: WyomingSpeechSynthesizer
    private var listener: NWListener?
    private var sessions: [UUID: WyomingClientSession] = [:]

    init(
        configuration: ServerConfiguration,
        transcriber: WyomingSpeechTranscriber,
        synthesizer: WyomingSpeechSynthesizer
    ) {
        self.configuration = configuration
        self.transcriber = transcriber
        self.synthesizer = synthesizer
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
            transcriber: transcriber,
            synthesizer: synthesizer
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
    private let synthesizer: WyomingSpeechSynthesizer
    private let parser = WyomingEventParser()

    private var transcribeRequest = WyomingTranscribeRequest()
    private var synthesizeStreamRequest: WyomingSynthesizeRequest?
    private var synthesizeTextChunks: [String] = []
    private var activeAudioFormat: WyomingAudioFormat?
    private var activeAudio = Data()
    private var receivedAudioChunkCount = 0
    private var firstAudioChunkSize = 0
    private var hasClosed = false

    init(
        connection: NWConnection,
        configuration: ServerConfiguration,
        transcriber: WyomingSpeechTranscriber,
        synthesizer: WyomingSpeechSynthesizer
    ) {
        self.connection = connection
        self.configuration = configuration
        self.transcriber = transcriber
        self.synthesizer = synthesizer
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
        onLog?(eventSummary(for: event))

        switch event.type {
        case "describe":
            let locales = await transcriber.availableLocaleIdentifiers()
            let voices = synthesizer.availableVoices()
            send(.info(serviceName: configuration.serviceName, asrLanguages: locales, ttsVoices: voices, port: configuration.port))

        case "transcribe":
            transcribeRequest = WyomingTranscribeRequest(
                name: event.data["name"]?.stringValue,
                language: event.data["language"]?.stringValue,
                context: event.data["context"]?.objectValue
            )
            onLog?(
                "Received transcribe from \(clientLabel)"
                + " language=\(transcribeRequest.language ?? "<none>")"
                + " model=\(transcribeRequest.name ?? "<default>")"
            )

        case "audio-start":
            activeAudioFormat = WyomingAudioFormat.from(event.data)
            activeAudio.removeAll(keepingCapacity: true)
            receivedAudioChunkCount = 0
            firstAudioChunkSize = 0
            if let format = activeAudioFormat {
                onLog?(
                    "Received audio-start from \(clientLabel)"
                    + " rate=\(format.rate)"
                    + " width=\(format.width)"
                    + " channels=\(format.channels)"
                )
            } else {
                onLog?("Received audio-start from \(clientLabel) without a usable audio format.")
            }

        case "audio-chunk":
            if activeAudioFormat == nil {
                activeAudioFormat = WyomingAudioFormat.from(event.data)
            }
            let payload = event.payload ?? Data()
            activeAudio.append(payload)
            receivedAudioChunkCount += 1
            if receivedAudioChunkCount == 1 {
                firstAudioChunkSize = payload.count
            }
            if receivedAudioChunkCount == 1 {
                if let format = activeAudioFormat {
                    onLog?(
                        "Received first audio-chunk from \(clientLabel)"
                        + " bytes=\(payload.count)"
                        + " rate=\(format.rate)"
                        + " width=\(format.width)"
                        + " channels=\(format.channels)"
                    )
                } else {
                    onLog?("Received first audio-chunk from \(clientLabel) with \(payload.count) bytes but no usable audio format.")
                }
            }

        case "audio-stop":
            let format = resolvedAudioFormatForBufferedStream()
            guard let format else {
                onLog?(
                    "Ignoring audio-stop from \(clientLabel)"
                    + " because no usable audio format was established."
                    + " chunks=\(receivedAudioChunkCount)"
                    + " buffered_bytes=\(activeAudio.count)"
                )
                return
            }

            let audio = activeAudio
            let request = transcribeRequest
            let chunkCount = receivedAudioChunkCount
            activeAudioFormat = nil
            activeAudio.removeAll(keepingCapacity: false)
            receivedAudioChunkCount = 0
            firstAudioChunkSize = 0
            transcribeRequest = WyomingTranscribeRequest()
            onLog?(
                "Received audio-stop from \(clientLabel)"
                + " chunks=\(chunkCount)"
                + " buffered_bytes=\(audio.count)"
            )

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

        case "synthesize-start":
            synthesizeStreamRequest = WyomingSynthesizeRequest(
                text: "",
                voice: WyomingSynthesizeVoice.from(event.data["voice"]?.objectValue),
                language: event.data["language"]?.stringValue,
                context: event.data["context"]?.objectValue
            )
            synthesizeTextChunks.removeAll(keepingCapacity: true)
            onLog?("Received synthesize-start from \(clientLabel).")

        case "synthesize-chunk":
            let text = event.data["text"]?.stringValue ?? ""
            synthesizeTextChunks.append(text)
            onLog?("Received synthesize-chunk from \(clientLabel) characters=\(text.count).")

        case "synthesize":
            guard let request = WyomingSynthesizeRequest.from(event) else {
                let message = "Received synthesize from \(clientLabel) without text."
                onLog?(message)
                send(.error(message: message))
                return
            }

            if synthesizeStreamRequest != nil {
                synthesizeStreamRequest = request
                onLog?("Received compatibility synthesize from \(clientLabel) characters=\(request.text.count).")
                return
            }

            await synthesizeAndSendAudio(request: request, sendStoppedEvent: false)

        case "synthesize-stop":
            let fallbackRequest = synthesizeStreamRequest
            let text = synthesizeTextChunks.joined()
            synthesizeStreamRequest = nil
            synthesizeTextChunks.removeAll(keepingCapacity: false)

            guard var request = fallbackRequest else {
                let message = "Received synthesize-stop from \(clientLabel) without synthesize-start."
                onLog?(message)
                send(.error(message: message))
                return
            }

            if !text.isEmpty {
                request.text = text
            }

            await synthesizeAndSendAudio(request: request, sendStoppedEvent: true)

        case "ping":
            send(WyomingEvent(type: "pong"))

        default:
            onLog?("Ignoring unsupported Wyoming event '\(event.type)' from \(clientLabel).")
        }
    }

    private func eventSummary(for event: WyomingEvent) -> String {
        var details = [
            "Received \(event.type) from \(clientLabel)",
        ]

        if let payload = event.payload, !payload.isEmpty {
            details.append("payload_bytes=\(payload.count)")
        }

        if let format = WyomingAudioFormat.from(event.data) {
            details.append("rate=\(format.rate)")
            details.append("width=\(format.width)")
            details.append("channels=\(format.channels)")
        }

        if let language = event.data["language"]?.stringValue, !language.isEmpty {
            details.append("language=\(language)")
        }

        if let name = event.data["name"]?.stringValue, !name.isEmpty {
            details.append("name=\(name)")
        }

        return details.joined(separator: " ")
    }

    private func synthesizeAndSendAudio(request: WyomingSynthesizeRequest, sendStoppedEvent: Bool) async {
        onLog?(
            "Synthesizing speech for \(clientLabel)"
            + " characters=\(request.text.count)"
            + " voice=\(request.voice?.name ?? request.voice?.speaker ?? "<default>")"
            + " language=\(request.language ?? request.voice?.language ?? configuration.preferredLocaleIdentifier)"
        )

        do {
            let response = try await synthesizer.synthesize(
                text: request.text,
                requestedVoice: request.voice,
                preferredLanguage: request.language ?? request.voice?.language ?? configuration.preferredLocaleIdentifier
            )
            send(.audioStart(format: response.format))
            sendAudioChunks(response.audioData, format: response.format)
            send(.audioStop())

            if sendStoppedEvent {
                send(WyomingEvent(type: "synthesize-stopped"))
            }

            onLog?(
                "Synthesized speech for \(clientLabel)"
                + " bytes=\(response.audioData.count)"
                + " rate=\(response.format.rate)"
                + " channels=\(response.format.channels)"
                + " voice=\(response.voiceIdentifier ?? "<system-default>")"
            )
        } catch {
            let message = "Synthesis failed for \(clientLabel): \(error.localizedDescription)"
            send(.error(message: message))
            if sendStoppedEvent {
                send(WyomingEvent(type: "synthesize-stopped"))
            }
            onLog?(message)
        }
    }

    private func sendAudioChunks(_ audioData: Data, format: WyomingAudioFormat) {
        let chunkSize = 16_384
        var offset = 0

        while offset < audioData.count {
            let end = min(offset + chunkSize, audioData.count)
            send(.audioChunk(Data(audioData[offset..<end]), format: format))
            offset = end
        }
    }

    private func resolvedAudioFormatForBufferedStream() -> WyomingAudioFormat? {
        if let activeAudioFormat {
            return activeAudioFormat
        }

        guard receivedAudioChunkCount > 0, !activeAudio.isEmpty else {
            return nil
        }

        let fallback = WyomingAudioFormat.homeAssistantFallback
        onLog?(
            "Assuming Home Assistant PCM format for \(clientLabel)"
            + " rate=\(fallback.rate)"
            + " width=\(fallback.width)"
            + " channels=\(fallback.channels)"
            + " first_chunk_bytes=\(firstAudioChunkSize)"
            + " buffered_bytes=\(activeAudio.count)"
        )
        return fallback
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
