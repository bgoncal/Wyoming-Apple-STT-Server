import Foundation
import Testing
@testable import WyomingAppleSpeechServer

@Test
func protocolRoundTripPreservesTypeAndData() throws {
    let event = WyomingEvent(
        type: "transcript",
        data: [
            "text": .string("turn on the kitchen lights"),
            "language": .string("en-US"),
        ]
    )

    let parser = WyomingEventParser()
    let parsedEvents = try parser.append(event.serialized(protocolVersion: "test-suite"))

    #expect(parsedEvents.count == 1)
    #expect(parsedEvents[0].type == "transcript")
    #expect(parsedEvents[0].data["text"]?.stringValue == "turn on the kitchen lights")
    #expect(parsedEvents[0].data["language"]?.stringValue == "en-US")
}

@Test
func wavWriterProducesRIFFFile() throws {
    let audio = Data(repeating: 0x55, count: 64)
    let format = WyomingAudioFormat(rate: 16_000, width: 2, channels: 1)
    let url = try WAVFileWriter.makeLinearPCMFile(audio: audio, format: format)
    defer {
        try? FileManager.default.removeItem(at: url)
    }

    let fileData = try Data(contentsOf: url)

    #expect(String(decoding: fileData.prefix(4), as: UTF8.self) == "RIFF")
    #expect(String(decoding: fileData[8..<12], as: UTF8.self) == "WAVE")
    #expect(fileData.count == audio.count + 44)
}

@Test
func audioFormatSupportsNestedAudioObject() {
    let format = WyomingAudioFormat.from([
        "audio": .object([
            "rate": .number(16_000),
            "width": .number(2),
            "channels": .number(1),
        ]),
    ])

    #expect(format == WyomingAudioFormat(rate: 16_000, width: 2, channels: 1))
}

@Test
func homeAssistantFallbackAudioFormatMatchesAssistPCM() {
    #expect(WyomingAudioFormat.homeAssistantFallback == WyomingAudioFormat(rate: 16_000, width: 2, channels: 1))
}

@Test
func infoAdvertisesTextToSpeechWhenVoicesAreAvailable() {
    let event = WyomingEvent.info(
        serviceName: "Test Server",
        asrLanguages: ["en-US"],
        ttsVoices: [
            WyomingTTSVoice(name: "com.apple.voice.test", language: "en-US", displayName: "Test Voice"),
        ],
        port: 10_300
    )

    guard case let .array(ttsPrograms) = event.data["tts"] else {
        Issue.record("Expected tts program list.")
        return
    }

    #expect(ttsPrograms.count == 1)
    #expect(ttsPrograms.first?.objectValue?["supports_synthesize_streaming"] == .bool(false))

    guard case let .array(voices)? = ttsPrograms.first?.objectValue?["voices"] else {
        Issue.record("Expected tts voice list.")
        return
    }

    #expect(voices.count == 1)
    #expect(voices.first?.objectValue?["name"] == .string("com.apple.voice.test"))
    #expect(voices.first?.objectValue?["languages"] == .array([.string("en-US")]))
}

@Test
func synthesizeRequestParsesTextAndVoice() {
    let event = WyomingEvent(
        type: "synthesize",
        data: [
            "text": .string("Hello from Apple voices"),
            "voice": .object([
                "name": .string("com.apple.voice.compact.en-US.Samantha"),
                "language": .string("en-US"),
                "speaker": .string("Samantha"),
            ]),
        ]
    )

    let request = WyomingSynthesizeRequest.from(event)

    #expect(request?.text == "Hello from Apple voices")
    #expect(request?.voice?.name == "com.apple.voice.compact.en-US.Samantha")
    #expect(request?.voice?.language == "en-US")
    #expect(request?.voice?.speaker == "Samantha")
}

@Test
func audioChunkSerializesPayloadAndFormat() throws {
    let payload = Data([0x01, 0x02, 0x03, 0x04])
    let event = WyomingEvent.audioChunk(
        payload,
        format: WyomingAudioFormat(rate: 22_050, width: 2, channels: 1)
    )
    #expect(WyomingAudioFormat.from(event.data) == WyomingAudioFormat(rate: 22_050, width: 2, channels: 1))

    let parser = WyomingEventParser()
    let parsedEvents = try parser.append(event.serialized(protocolVersion: "test-suite"))

    #expect(parsedEvents.count == 1)
    #expect(parsedEvents[0].type == "audio-chunk")
    #expect(parsedEvents[0].payload == payload)
    #expect(WyomingAudioFormat.from(parsedEvents[0].data) == WyomingAudioFormat(rate: 22_050, width: 2, channels: 1))
}
