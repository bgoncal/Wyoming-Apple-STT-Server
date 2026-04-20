import Foundation

struct TranscriptRecord: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let language: String?
    let client: String
}
