import Foundation

enum WAVFileWriter {
    static func makeLinearPCMFile(audio: Data, format: WyomingAudioFormat) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try write(audio: audio, format: format, to: url)
        return url
    }

    static func write(audio: Data, format: WyomingAudioFormat, to url: URL) throws {
        guard format.rate > 0, format.width > 0, format.channels > 0 else {
            throw WAVFileWriterError.invalidFormat
        }

        let bitsPerSample = UInt16(format.width * 8)
        let blockAlign = UInt16(format.channels * format.width)
        let byteRate = UInt32(format.rate * Int(blockAlign))
        let riffChunkSize = UInt32(36 + audio.count)

        var data = Data()
        data.append(ascii: "RIFF")
        data.append(littleEndian: riffChunkSize)
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(format.channels))
        data.append(littleEndian: UInt32(format.rate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(ascii: "data")
        data.append(littleEndian: UInt32(audio.count))
        data.append(audio)

        try data.write(to: url, options: .atomic)
    }
}

enum WAVFileWriterError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "The incoming PCM stream has an invalid audio format."
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func append(ascii string: String) {
        append(contentsOf: string.utf8)
    }
}
