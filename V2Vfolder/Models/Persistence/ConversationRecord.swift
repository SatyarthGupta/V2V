import Foundation
import SwiftData

/// A finished conversation saved on device (PRD F8, D-015). Transcripts only; audio is never stored.
@Model
final class ConversationRecord {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var personaID: String
    @Relationship(deleteRule: .cascade, inverse: \TurnRecord.conversation)
    var turns: [TurnRecord] = []

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date, personaID: String) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.personaID = personaID
    }

    var persona: Persona { Persona(storedValue: personaID) }

    /// Turns in conversation order (SwiftData doesn't preserve array order).
    var orderedTurns: [TurnRecord] { turns.sorted { $0.index < $1.index } }

    /// First thing the user said, for the history list.
    var title: String {
        orderedTurns.first { $0.role == TranscriptTurn.Role.user.rawValue }?.text ?? "Conversation"
    }
}

@Model
final class TurnRecord {
    var index: Int
    var role: String
    var text: String
    var wasInterrupted: Bool
    var conversation: ConversationRecord?

    init(index: Int, role: String, text: String, wasInterrupted: Bool) {
        self.index = index
        self.role = role
        self.text = text
        self.wasInterrupted = wasInterrupted
    }

    var transcriptTurn: TranscriptTurn {
        TranscriptTurn(id: "\(index)", role: TranscriptTurn.Role(rawValue: role) ?? .assistant,
                       text: text, isFinal: true, wasInterrupted: wasInterrupted)
    }
}
