import Foundation

/// One turn in the live transcript (PRD F4). `id` is the Realtime `item_id`,
/// so streaming deltas for the same item update the same turn.
nonisolated struct TranscriptTurn: Identifiable, Equatable, Sendable {
    nonisolated enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    var text: String
    var isFinal: Bool
    /// Set when the user barged in before this assistant turn finished playing (PRD E1).
    var wasInterrupted: Bool

    init(id: String, role: Role, text: String = "", isFinal: Bool = false, wasInterrupted: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isFinal = isFinal
        self.wasInterrupted = wasInterrupted
    }
}
