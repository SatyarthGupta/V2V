import Foundation

/// The three demo personas (docs/PERSONAS.md, D-020).
/// Prompts live on the token server; the app only knows ids and display info.
nonisolated enum Persona: String, CaseIterable, Identifiable, Codable, Sendable {
    case quick
    case storyteller
    case coach

    static let `default`: Persona = .quick

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick: "Quick"
        case .storyteller: "Storyteller"
        case .coach: "Coach"
        }
    }

    var subtitle: String {
        switch self {
        case .quick: "Short, fast answers"
        case .storyteller: "Long, vivid answers. Great for interrupting"
        case .coach: "Explains, then asks you a question"
        }
    }

    /// For display only; the token server is the source of truth for the voice.
    var voice: String {
        switch self {
        case .quick: "marin"
        case .storyteller: "cedar"
        case .coach: "coral"
        }
    }

    /// Restores a persona saved in UserDefaults; unknown or missing values fall back to `.quick`.
    init(storedValue: String?) {
        self = storedValue.flatMap(Persona.init(rawValue:)) ?? .default
    }
}
