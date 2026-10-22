import Foundation
import SwiftData
import Testing
@testable import V2Vfolder

@MainActor
struct ConversationStoreTests {
    private func makeStore() throws -> ConversationStore {
        ConversationStore(container: try ConversationStore.makeContainer(inMemory: true))
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func finished(_ turns: [TranscriptTurn], persona: Persona = .coach, startedAt: Date? = nil) -> FinishedConversation {
        FinishedConversation(turns: turns, persona: persona, startedAt: startedAt ?? start, endedAt: (startedAt ?? start) + 60)
    }

    @Test("U-40: save → fetch returns turns in order with persona and interruption flag")
    func saveAndFetch() throws {
        let store = try makeStore()
        store.save(finished([
            TranscriptTurn(id: "u1", role: .user, text: "Tell me a story", isFinal: true),
            TranscriptTurn(id: "a1", role: .assistant, text: "Once upon a time", isFinal: true, wasInterrupted: true),
            TranscriptTurn(id: "u2", role: .user, text: "Shorter please", isFinal: true),
        ]))

        let all = try store.allConversations()
        #expect(all.count == 1)
        let record = try #require(all.first)
        #expect(record.persona == .coach)
        #expect(record.title == "Tell me a story")
        #expect(record.orderedTurns.map(\.text) == ["Tell me a story", "Once upon a time", "Shorter please"])
        #expect(record.orderedTurns.map(\.role) == ["user", "assistant", "user"])
        #expect(record.orderedTurns[1].wasInterrupted)
    }

    @Test("Empty and whitespace-only turns are skipped; nothing said → nothing saved")
    func skipsEmpty() throws {
        let store = try makeStore()
        #expect(store.save(finished([TranscriptTurn(id: "u1", role: .user, text: "  ")])) == nil)
        #expect(try store.allConversations().isEmpty)

        store.save(finished([
            TranscriptTurn(id: "a0", role: .assistant, text: ""),
            TranscriptTurn(id: "u1", role: .user, text: "Hi", isFinal: true),
        ]))
        #expect(try store.allConversations().first?.turns.count == 1)
    }

    @Test("Newest conversation first")
    func newestFirst() throws {
        let store = try makeStore()
        store.save(finished([TranscriptTurn(id: "1", role: .user, text: "old")], startedAt: start))
        store.save(finished([TranscriptTurn(id: "1", role: .user, text: "new")], startedAt: start + 3600))
        #expect(try store.allConversations().map(\.title) == ["new", "old"])
    }

    @Test("U-40 / U-55: delete removes the conversation and cascades its turns")
    func deleteCascades() throws {
        let store = try makeStore()
        let record = try #require(store.save(finished([
            TranscriptTurn(id: "u1", role: .user, text: "a"), TranscriptTurn(id: "a1", role: .assistant, text: "b"),
        ])))
        HistoryViewModel(store: store).delete(record)

        #expect(try store.allConversations().isEmpty)
        #expect(try store.container.mainContext.fetch(FetchDescriptor<TurnRecord>()).isEmpty)
    }

    @Test("A title falls back when the user never spoke")
    func titleFallback() throws {
        let store = try makeStore()
        let record = try #require(store.save(finished([TranscriptTurn(id: "a1", role: .assistant, text: "Hello!")])))
        #expect(record.title == "Conversation")
    }
}

@MainActor
struct SessionEndedReportingTests {
    private final class Box { var reports: [FinishedConversation] = [] }

    private func makeController(client: FakeRealtimeClient, box: Box) -> VoiceSessionController {
        let controller = VoiceSessionController(dependencies: VoiceSessionDependencies(
            permissions: FakePermissionService(), tokens: FakeTokenService(), audioSession: FakeAudioSessionManager(),
            makeRealtimeClient: { client }, makeAudioEngine: { FakeAudioEngine() }))
        controller.onSessionEnded = { box.reports.append($0) }
        return controller
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("U-53: End reports the conversation once, with persona and turns")
    func reportsOnEnd() async throws {
        let client = FakeRealtimeClient()
        let box = Box()
        let controller = makeController(client: client, box: box)
        await controller.start(persona: .storyteller)
        try await waitUntil { controller.state == .listening }
        client.emit(.inputTranscriptionCompleted(itemID: "u1", transcript: "Hi"))
        try await waitUntil { controller.turns.count == 1 }

        await controller.end()
        await controller.end()

        #expect(box.reports.count == 1)
        #expect(box.reports.first?.persona == .storyteller)
        #expect(box.reports.first?.turns.map(\.text) == ["Hi"])
    }

    @Test("U-53: a failure reports once; the following End doesn't report again")
    func reportsOnceOnFailureThenEnd() async throws {
        let client = FakeRealtimeClient()
        let box = Box()
        let controller = makeController(client: client, box: box)
        await controller.start(persona: .quick)
        try await waitUntil { controller.state == .listening }
        client.emit(.inputTranscriptionCompleted(itemID: "u1", transcript: "Hello"))
        try await waitUntil { controller.turns.count == 1 }

        client.drop()
        try await waitUntil { if case .failed = controller.state { true } else { false } }
        await controller.end()

        #expect(box.reports.count == 1)
    }

    @Test("Nothing said → nothing reported")
    func silentSessionNotReported() async throws {
        let client = FakeRealtimeClient()
        let box = Box()
        let controller = makeController(client: client, box: box)
        await controller.start(persona: .quick)
        try await waitUntil { controller.state == .listening }
        await controller.end()
        #expect(box.reports.isEmpty)
    }
}
