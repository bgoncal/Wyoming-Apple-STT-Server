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
