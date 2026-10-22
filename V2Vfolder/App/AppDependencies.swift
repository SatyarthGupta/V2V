import Foundation

/// Composition root: builds the services and hands them to the ViewModels.
///
/// `live()` wires the real implementations. UI tests launch with `-uiTestFakes`
/// to get fakes instead (v2v-5lp.1).
final class AppDependencies {
    let conversation: ConversationViewModel

    init(conversation: ConversationViewModel) {
        self.conversation = conversation
    }

    static func live() -> AppDependencies {
        let session = VoiceSessionDependencies(
            permissions: PermissionService(),
            tokens: TokenService(config: .current),
            audioSession: AudioSessionManager(),
            makeRealtimeClient: { RealtimeClient() },
            makeAudioEngine: { AudioEngine() }
        )
        let controller = VoiceSessionController(dependencies: session)
        return AppDependencies(conversation: ConversationViewModel(controller: controller))
    }
}
