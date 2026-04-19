import Speech

enum SpeechAuthorization {
    static func requestIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func failureDescription(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Authorized"
        case .denied:
            return "Speech recognition permission was denied in System Settings."
        case .restricted:
            return "Speech recognition is restricted on this Mac."
        case .notDetermined:
            return "Speech recognition permission is still pending."
        @unknown default:
            return "Speech recognition returned an unknown authorization status."
        }
    }
}
