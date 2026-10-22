import Foundation
import OSLog
import SwiftData

/// A conversation as the controller hands it over when a session ends.
struct FinishedConversation: Equatable {
    let turns: [TranscriptTurn]
    let persona: Persona
    let startedAt: Date
    let endedAt: Date
}

/// Saves and deletes history (docs/LLD.md §8). Reading is done by `@Query` in the views.
final class ConversationStore {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer) {
        self.container = container
    }

    /// On-disk store for the app; in-memory for tests and previews.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: ConversationRecord.self, TurnRecord.self, configurations: configuration)
    }

    /// Saves the non-empty turns. Conversations with nothing said aren't saved.
    @discardableResult
    func save(_ finished: FinishedConversation) -> ConversationRecord? {
        let spoken = finished.turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !spoken.isEmpty else { return nil }

        let record = ConversationRecord(startedAt: finished.startedAt, endedAt: finished.endedAt,
                                        personaID: finished.persona.rawValue)
        context.insert(record)
        for (index, turn) in spoken.enumerated() {
            let turnRecord = TurnRecord(index: index, role: turn.role.rawValue, text: turn.text,
                                        wasInterrupted: turn.wasInterrupted)
            turnRecord.conversation = record
            context.insert(turnRecord)
        }
        do {
            try context.save()
        } catch {
            Log.session.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
        return record
    }

    func delete(_ record: ConversationRecord) {
        context.delete(record)
        try? context.save()
    }

    func allConversations() throws -> [ConversationRecord] {
        try context.fetch(FetchDescriptor<ConversationRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
    }
}
