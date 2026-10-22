import Foundation
import Observation

/// Actions for the history screen. Reading is done by `@Query` in `HistoryView` (docs/LLD.md §7).
@Observable
final class HistoryViewModel {
    private let store: ConversationStore

    init(store: ConversationStore) {
        self.store = store
    }

    func delete(_ conversation: ConversationRecord) {
        store.delete(conversation)
    }
}
