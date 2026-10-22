import Foundation

/// Every state the voice session can be in (docs/HLD.md §3).
/// `VoiceSessionController` owns the transitions; ViewModels only map these to UI.
nonisolated enum SessionState: Equatable, Sendable {
    case idle
    case checkingPermission
    case permissionDenied
    case connecting
    case listening
    case userSpeaking
    case thinking
    case aiSpeaking
    case paused(PauseReason)
    case reconnecting(attempt: Int)
    case failed(SessionError)

    /// True while a session is live: audio and/or network resources are held.
    var isActive: Bool {
        switch self {
        case .idle, .permissionDenied, .failed:
            false
        case .checkingPermission, .connecting, .listening, .userSpeaking,
             .thinking, .aiSpeaking, .paused, .reconnecting:
            true
        }
    }
}

nonisolated enum PauseReason: Equatable, Sendable {
    /// A phone call, Siri or an alarm took the audio session (PRD E5).
    /// `canAutoResume` mirrors the system's `shouldResume` hint.
    case interruption(canAutoResume: Bool)
    case userMuted
}

nonisolated enum SessionError: Error, Equatable, Sendable {
    /// The internet is reachable but the Mac's token server isn't (D-021, PRD E10).
    case tokenServerUnreachable
    case noInternet
    case tokenRejected(status: Int)
    case socketFailed(String)
    case serverError(code: String, message: String)
    case audioEngineFailed(String)
    case reconnectExhausted
}
