import Foundation

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    var timestamp: Date
    let message: String
    var repetitionCount: Int = 1
}
