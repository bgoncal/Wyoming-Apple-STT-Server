import Foundation

struct SpeechLocaleOption: Identifiable, Sendable, Equatable {
    enum Availability: Sendable, Equatable {
        case installed
        case downloading
        case downloadable
        case removalRequested
        case unsupported

        var label: String {
            switch self {
            case .installed:
                return "Installed"
            case .downloading:
                return "Downloading"
            case .downloadable:
                return "Download required"
            case .removalRequested:
                return "Removal requested"
            case .unsupported:
                return "Unavailable"
            }
        }
    }

    let identifier: String
    let displayName: String
    let availability: Availability

    var id: String {
        identifier
    }
}

struct LocaleDownloadState: Sendable, Equatable {
    let identifier: String
    let displayName: String
    var progress: Double
}
