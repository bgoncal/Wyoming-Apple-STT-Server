import Foundation

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
}
