import Foundation

typealias WyomingObject = [String: WyomingValue]

enum WyomingProtocolError: LocalizedError {
    case invalidJSON
    case missingEventType
    case invalidEventData

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Received invalid Wyoming JSON framing."
        case .missingEventType:
            return "Received a Wyoming event without a type."
        case .invalidEventData:
            return "Received Wyoming event data in an unsupported shape."
        }
    }
}

enum WyomingValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object(WyomingObject)
    case array([WyomingValue])
    case null

    init(any value: Any) throws {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .number(Double(int))
        case let uint as UInt:
            self = .number(Double(uint))
        case let double as Double:
            self = .number(double)
        case let float as Float:
            self = .number(Double(float))
        case let array as [Any]:
            self = .array(try array.map(Self.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(try dictionary.mapValues(Self.init(any:)))
        case _ as NSNull:
            self = .null
        default:
            throw WyomingProtocolError.invalidEventData
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case let .number(value):
            return Int(value)
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }

    var objectValue: WyomingObject? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    func asFoundationObject() -> Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            if value.rounded() == value {
                return Int(value)
            }
            return value
        case let .bool(value):
            return value
        case let .object(value):
            return value.mapValues { $0.asFoundationObject() }
        case let .array(value):
            return value.map { $0.asFoundationObject() }
        case .null:
            return NSNull()
        }
    }
}

struct WyomingAudioFormat: Sendable, Equatable {
    let rate: Int
    let width: Int
    let channels: Int

    static let homeAssistantFallback = WyomingAudioFormat(rate: 16_000, width: 2, channels: 1)

    static func from(_ object: WyomingObject) -> WyomingAudioFormat? {
        if let nestedAudio = object["audio"]?.objectValue,
           let format = WyomingAudioFormat.fromFields(in: nestedAudio) {
            return format
        }

        return WyomingAudioFormat.fromFields(in: object)
    }

    private static func fromFields(in object: WyomingObject) -> WyomingAudioFormat? {
        guard
            let rate = object["rate"]?.intValue,
            let width = object["width"]?.intValue,
            let channels = object["channels"]?.intValue
        else {
            return nil
        }

        return WyomingAudioFormat(rate: rate, width: width, channels: channels)
    }
}

struct WyomingTranscribeRequest: Sendable, Equatable {
    var name: String?
    var language: String?
    var context: WyomingObject?
}

struct WyomingSynthesizeVoice: Sendable, Equatable {
    var name: String?
    var language: String?
    var speaker: String?

    static func from(_ object: WyomingObject?) -> WyomingSynthesizeVoice? {
        guard let object else { return nil }

        return WyomingSynthesizeVoice(
            name: object["name"]?.stringValue,
            language: object["language"]?.stringValue,
            speaker: object["speaker"]?.stringValue
        )
    }
}

struct WyomingSynthesizeRequest: Sendable, Equatable {
    var text: String
    var voice: WyomingSynthesizeVoice?
    var context: WyomingObject?

    static func from(_ event: WyomingEvent) -> WyomingSynthesizeRequest? {
        guard let text = event.data["text"]?.stringValue else {
            return nil
        }

        return WyomingSynthesizeRequest(
            text: text,
            voice: WyomingSynthesizeVoice.from(event.data["voice"]?.objectValue),
            context: event.data["context"]?.objectValue
        )
    }
}

struct WyomingTTSVoice: Sendable, Equatable {
    var name: String
    var language: String
    var displayName: String
}

struct WyomingEvent: Sendable, Equatable {
    var type: String
    var data: WyomingObject = [:]
    var payload: Data? = nil

    func serialized(protocolVersion: String = "swift-0.1.0") throws -> Data {
        var header: WyomingObject = [
            "type": .string(type),
            "version": .string(protocolVersion),
        ]

        let dataBytes: Data?
        if data.isEmpty {
            dataBytes = nil
        } else {
            dataBytes = try JSONSerialization.data(withJSONObject: data.mapValues { $0.asFoundationObject() })
            header["data_length"] = .number(Double(dataBytes?.count ?? 0))
        }

        if let payload {
            header["payload_length"] = .number(Double(payload.count))
        }

        let headerBytes = try JSONSerialization.data(withJSONObject: header.mapValues { $0.asFoundationObject() })

        var framed = Data()
        framed.append(headerBytes)
        framed.append(0x0A)
        if let dataBytes {
            framed.append(dataBytes)
        }
        if let payload {
            framed.append(payload)
        }

        return framed
    }

    static func info(
        serviceName: String,
        asrLanguages: [String],
        ttsVoices: [WyomingTTSVoice] = [],
        port: UInt16
    ) -> WyomingEvent {
        let speechAttribution: WyomingObject = [
            "name": .string("Apple Speech"),
            "url": .string("https://developer.apple.com/documentation/speech"),
        ]

        let asrModel: WyomingObject = [
            "name": .string("apple-local-stt"),
            "languages": .array(asrLanguages.map(WyomingValue.string)),
            "attribution": .object(speechAttribution),
            "installed": .bool(true),
            "description": .string("On-device speech-to-text powered by Apple's Speech framework."),
            "version": .string("macOS 26"),
        ]

        let asrProgram: WyomingObject = [
            "name": .string(serviceName),
            "attribution": .object(speechAttribution),
            "installed": .bool(true),
            "description": .string("Local Wyoming speech server on TCP port \(port)."),
            "version": .string("0.1.0"),
            "models": .array([.object(asrModel)]),
            "supports_transcript_streaming": .bool(false),
        ]

        let avFoundationAttribution: WyomingObject = [
            "name": .string("Apple AVFoundation"),
            "url": .string("https://developer.apple.com/documentation/avfoundation/speech_synthesis"),
        ]

        let ttsVoiceObjects: [WyomingValue] = ttsVoices
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .map { voice in
                .object([
                    "name": .string(voice.name),
                    "languages": .array([.string(voice.language)]),
                    "attribution": .object(avFoundationAttribution),
                    "installed": .bool(true),
                    "description": .string("\(voice.displayName) (\(voice.language))"),
                    "version": .string("macOS 26"),
                ])
            }

        let ttsProgram: WyomingObject = [
            "name": .string(serviceName),
            "attribution": .object(avFoundationAttribution),
            "installed": .bool(true),
            "description": .string("Local Wyoming text-to-speech server on TCP port \(port)."),
            "version": .string("0.1.0"),
            "voices": .array(ttsVoiceObjects),
            "supports_synthesize_streaming": .bool(false),
        ]

        return WyomingEvent(
            type: "info",
            data: [
                "asr": .array([.object(asrProgram)]),
                "tts": .array(ttsVoices.isEmpty ? [] : [.object(ttsProgram)]),
                "handle": .array([]),
                "intent": .array([]),
                "wake": .array([]),
                "mic": .array([]),
                "snd": .array([]),
            ]
        )
    }

    static func transcript(text: String, language: String?) -> WyomingEvent {
        var data: WyomingObject = ["text": .string(text)]
        if let language, !language.isEmpty {
            data["language"] = .string(language)
        }

        return WyomingEvent(type: "transcript", data: data)
    }

    static func audioStart(format: WyomingAudioFormat) -> WyomingEvent {
        WyomingEvent(type: "audio-start", data: format.eventData)
    }

    static func audioChunk(_ payload: Data, format: WyomingAudioFormat) -> WyomingEvent {
        WyomingEvent(type: "audio-chunk", data: format.eventData, payload: payload)
    }

    static func audioStop() -> WyomingEvent {
        WyomingEvent(type: "audio-stop")
    }

    static func error(message: String) -> WyomingEvent {
        WyomingEvent(type: "error", data: ["message": .string(message)])
    }
}

private extension WyomingAudioFormat {
    var eventData: WyomingObject {
        [
            "rate": .number(Double(rate)),
            "width": .number(Double(width)),
            "channels": .number(Double(channels)),
        ]
    }
}

final class WyomingEventParser {
    private var buffer = Data()

    func append(_ data: Data) throws -> [WyomingEvent] {
        buffer.append(data)

        var events: [WyomingEvent] = []
        while let event = try nextEventIfAvailable() {
            events.append(event)
        }

        return events
    }

    private func nextEventIfAvailable() throws -> WyomingEvent? {
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
            return nil
        }

        let headerBytes = Data(buffer[..<newlineIndex])
        guard !headerBytes.isEmpty else {
            throw WyomingProtocolError.invalidJSON
        }

        let headerObject = try parseObject(from: headerBytes)
        guard let type = headerObject["type"]?.stringValue else {
            throw WyomingProtocolError.missingEventType
        }

        let dataLength = headerObject["data_length"]?.intValue ?? 0
        let payloadLength = headerObject["payload_length"]?.intValue ?? 0
        let messageLength = headerBytes.count + 1 + dataLength + payloadLength

        guard buffer.count >= messageLength else {
            return nil
        }

        let dataStart = newlineIndex + 1
        let dataEnd = dataStart + dataLength
        let payloadEnd = dataEnd + payloadLength

        var mergedData = headerObject["data"]?.objectValue ?? [:]
        if dataLength > 0 {
            let extraBytes = Data(buffer[dataStart..<dataEnd])
            let extraData = try parseObject(from: extraBytes)
            mergedData.merge(extraData) { _, newValue in newValue }
        }

        let payload: Data?
        if payloadLength > 0 {
            payload = Data(buffer[dataEnd..<payloadEnd])
        } else {
            payload = nil
        }

        buffer.removeSubrange(..<payloadEnd)

        return WyomingEvent(type: type, data: mergedData, payload: payload)
    }

    private func parseObject(from data: Data) throws -> WyomingObject {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw WyomingProtocolError.invalidJSON
        }

        return try dictionary.mapValues(WyomingValue.init(any:))
    }
}
