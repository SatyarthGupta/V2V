import AVFAudio
import Foundation

nonisolated enum MicPermission: Equatable, Sendable {
    case undetermined
    case granted
    case denied
}

nonisolated protocol PermissionProviding: Sendable {
    func micStatus() -> MicPermission
    /// Shows the system prompt if undetermined; returns whether access is granted.
    func requestMic() async -> Bool
}

/// Microphone permission via `AVAudioApplication` (PRD E3).
/// Without permission iOS records silence instead of failing, so we must check explicitly.
nonisolated struct PermissionService: PermissionProviding {
    func micStatus() -> MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    func requestMic() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
