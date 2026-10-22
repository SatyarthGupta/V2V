import Foundation
import Observation

/// What the orb shows. A UI-level simplification of `SessionState` (PRD F5).
enum OrbState: Equatable {
    case idle, connecting, listening, userSpeaking, thinking, aiSpeaking, paused, reconnecting, error

    init(_ state: SessionState) {
        switch state {
        case .idle: self = .idle
        case .checkingPermission, .connecting: self = .connecting
        case .listening: self = .listening
        case .userSpeaking: self = .userSpeaking
        case .thinking: self = .thinking
        case .aiSpeaking: self = .aiSpeaking
        case .paused: self = .paused
        case .reconnecting: self = .reconnecting
        case .permissionDenied, .failed: self = .error
        }
    }

    /// Shown under the orb and read by VoiceOver.
    var label: String {
        switch self {
        case .idle: "Tap Start to talk"
        case .connecting: "Connecting…"
        case .listening: "Listening"
        case .userSpeaking: "You're speaking"
        case .thinking: "Thinking…"
        case .aiSpeaking: "Speaking"
        case .paused: "Paused"
        case .reconnecting: "Reconnecting…"
        case .error: "Something went wrong"
        }
    }
}

struct DebugInfo: Equatable {
    let state: String
    let route: String
    let events: [String]
    let lastError: String?
    let latency: String
}

@Observable
final class ConversationViewModel {
    static let personaKey = "selectedPersona"

    private let controller: VoiceSessionController
    private let defaults: UserDefaults

    /// Applies to the next conversation; voice can't change mid-session (D-020).
    var persona: Persona {
        didSet { defaults.set(persona.rawValue, forKey: Self.personaKey) }
    }

    init(controller: VoiceSessionController, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
        self.persona = Persona(storedValue: defaults.string(forKey: Self.personaKey))
    }

    var orb: OrbState { OrbState(controller.state) }
    var turns: [TranscriptTurn] { controller.turns }
    var isSessionActive: Bool { controller.state.isActive }
    var isMuted: Bool { controller.isMuted }
    var showPermissionDenied: Bool { controller.state == .permissionDenied }

    /// Banner text: a fatal failure, otherwise the last non-fatal server error.
    var errorMessage: String? {
        if case .failed(let error) = controller.state { return Self.message(for: error) }
        return controller.lastServerError?.message
    }

    /// Snapshot for the hidden debug overlay (D-022). No tokens, audio or transcript text.
    var debug: DebugInfo {
        let route = controller.currentRoute
        let error: String? = if case .failed(let error) = controller.state {
            String(describing: error)
        } else {
            controller.lastServerError.map { "\($0.code ?? $0.type): \($0.message)" }
        }
        return DebugInfo(
            state: String(describing: controller.state),
            route: "\(route.outputName)\(route.isBluetooth ? " (Bluetooth)" : "")",
            events: controller.recentEvents,
            lastError: error,
            latency: controller.lastReplyLatency.map(Self.milliseconds) ?? "–"
        )
    }

    nonisolated static func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return "\(Int(ms.rounded())) ms"
    }

    var canRetry: Bool {
        if case .failed = controller.state { return true }
        return false
    }

    func startTapped() async {
        await controller.start(persona: persona)
    }

    func endTapped() async {
        await controller.end()
    }

    func toggleMute() {
        controller.setMuted(!controller.isMuted)
    }

    /// Plain-language, actionable error text (PRD E3, E7, E10).
    static func message(for error: SessionError) -> String {
        switch error {
        case .tokenServerUnreachable:
            "Can't reach the token server on your Mac. Check that your iPhone is on the same Wi-Fi, the server is running (npm run dev), and Local Network access is allowed for V2V in Settings."
        case .noInternet:
            "No internet connection. Check Wi-Fi and try again."
        case .tokenRejected(let status) where status == 401:
            "The token server rejected the app. Check that the shared secret matches."
        case .tokenRejected(let status) where status == 429:
            "Too many attempts. Wait a minute and try again."
        case .tokenRejected(let status):
            "The token server couldn't start a session (error \(status))."
        case .socketFailed:
            "Lost the connection to OpenAI."
        case .serverError(_, let message):
            message
        case .audioEngineFailed(let detail):
            "Audio problem: \(detail)"
        case .reconnectExhausted:
            "Couldn't reconnect. Check your connection and try again."
        }
    }
}
