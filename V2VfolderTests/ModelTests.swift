import Testing
@testable import V2Vfolder

struct PersonaTests {
    @Test("U-38: exactly three personas, Quick is the default")
    func threePersonasWithQuickDefault() {
        #expect(Persona.allCases == [.quick, .storyteller, .coach])
        #expect(Persona.default == .quick)
    }

    @Test("U-38: unknown or missing stored values fall back to Quick", arguments: [nil, "", "pirate", "QUICK"])
    func unknownStoredValueFallsBack(stored: String?) {
        #expect(Persona(storedValue: stored) == .quick)
    }

    @Test("Stored raw values round-trip", arguments: Persona.allCases)
    func storedValueRoundTrips(persona: Persona) {
        #expect(Persona(storedValue: persona.rawValue) == persona)
    }

    @Test("Voices match docs/PERSONAS.md and the token server")
    func voicesMatchServer() {
        #expect(Persona.quick.voice == "marin")
        #expect(Persona.storyteller.voice == "cedar")
        #expect(Persona.coach.voice == "coral")
    }
}

struct SessionStateTests {
    @Test("Only idle, permissionDenied and failed release session resources")
    func activeStates() {
        let inactive: [SessionState] = [.idle, .permissionDenied, .failed(.reconnectExhausted)]
        let active: [SessionState] = [
            .checkingPermission, .connecting, .listening, .userSpeaking, .thinking, .aiSpeaking,
            .paused(.interruption(canAutoResume: true)), .paused(.userMuted), .reconnecting(attempt: 1),
        ]
        #expect(inactive.allSatisfy { !$0.isActive })
        #expect(active.allSatisfy { $0.isActive })
    }
}

struct TranscriptTurnTests {
    @Test("A new turn starts empty, not final and not interrupted")
    func defaults() {
        let turn = TranscriptTurn(id: "item_1", role: .assistant)
        #expect(turn.text.isEmpty)
        #expect(!turn.isFinal)
        #expect(!turn.wasInterrupted)
    }
}
