import Foundation
import OSLog
import SwiftData

/// Composition root: builds the services and hands them to the ViewModels.
///
/// `live()` wires the real implementations. UI tests launch with `-uiTestFakes`
/// to get fakes instead (v2v-5lp.1).
final class AppDependencies {
    let conversation: ConversationViewModel
    let history: HistoryViewModel
    let modelContainer: ModelContainer

    init(conversation: ConversationViewModel, history: HistoryViewModel, modelContainer: ModelContainer) {
        self.conversation = conversation
        self.history = history
        self.modelContainer = modelContainer
    }

    static func live() -> AppDependencies {
        let session = VoiceSessionDependencies(
            permissions: PermissionService(),
            tokens: TokenService(config: .current, network: NetworkMonitor()),
            audioSession: AudioSessionManager(),
            makeRealtimeClient: { RealtimeClient() },
            makeAudioEngine: { AudioEngine() }
        )
        return assemble(session: session, container: makeContainer(inMemory: false))
    }

    static func assemble(session: VoiceSessionDependencies, container: ModelContainer) -> AppDependencies {
        let store = ConversationStore(container: container)
        let controller = VoiceSessionController(dependencies: session)
        controller.onSessionEnded = { finished in store.save(finished) }
        return AppDependencies(conversation: ConversationViewModel(controller: controller),
                               history: HistoryViewModel(store: store),
                               modelContainer: container)
    }

    /// Falls back to an in-memory store so a corrupt database can't stop the app from launching.
    static func makeContainer(inMemory: Bool) -> ModelContainer {
        do {
            return try ConversationStore.makeContainer(inMemory: inMemory)
        } catch {
            Log.session.error("history store unavailable, using memory: \(error.localizedDescription, privacy: .public)")
            // An in-memory container with these two models can only fail on programmer error.
            return try! ConversationStore.makeContainer(inMemory: true)
        }
    }
}
