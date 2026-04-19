import Foundation

struct ServerConfiguration: Sendable, Equatable {
    var serviceName: String
    var port: UInt16
    var preferredLocaleIdentifier: String
    var autoStart: Bool
}
