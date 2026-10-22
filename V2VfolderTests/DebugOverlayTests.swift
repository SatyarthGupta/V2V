import Foundation
import Testing
@testable import V2Vfolder

@MainActor
struct DebugOverlayTests {
    private func listening() async throws -> (VoiceSessionController, FakeRealtimeClient) {
        let client = FakeRealtimeClient()
        let controller = VoiceSessionController(dependencies: VoiceSessionDependencies(
            permissions: FakePermissionService(), tokens: FakeTokenService(), audioSession: FakeAudioSessionManager(),
            makeRealtimeClient: { client }, makeAudioEngine: { FakeAudioEngine() }))
        await controller.start(persona: .quick)
        for _ in 0..<400 where controller.state != .listening { try await Task.sleep(for: .milliseconds(5)) }
        return (controller, client)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }

    @Test("Reply latency = end of user turn → first AI audio")
    func measuresLatency() async throws {
        let (controller, client) = try await listening()
        client.emit(.speechStopped(itemID: "u1"))
        try await Task.sleep(for: .milliseconds(120))
        client.emit(.responseCreated(responseID: "r1"))
        client.emit(.outputAudioDelta(responseID: "r1", itemID: "a1", audio: Data([1, 0]).base64EncodedString()))
        try await settle()

        let latency = try #require(controller.lastReplyLatency)
        #expect(latency >= .milliseconds(100))
        #expect(latency < .seconds(2))
    }

    @Test("Only the first audio after a turn counts toward latency")
    func latencyOnlyOnFirstDelta() async throws {
        let (controller, client) = try await listening()
        client.emit(.speechStopped(itemID: "u1"))
        client.emit(.outputAudioDelta(responseID: "r1", itemID: "a1", audio: Data([1, 0]).base64EncodedString()))
        try await settle()
        let first = controller.lastReplyLatency

        try await Task.sleep(for: .milliseconds(100))
        client.emit(.outputAudioDelta(responseID: "r1", itemID: "a1", audio: Data([1, 0]).base64EncodedString()))
        try await settle()
        #expect(controller.lastReplyLatency == first)
    }

    @Test("Event list keeps names only, skips deltas, and is capped at 20")
    func eventRingBuffer() async throws {
        let (controller, client) = try await listening()
        client.emit(.outputTranscriptDelta(responseID: "r", itemID: "a", delta: "secret words"))
        for index in 0..<30 {
            client.emit(.responseCreated(responseID: "r\(index)"))
        }
        try await settle()

        #expect(controller.recentEvents.count == VoiceSessionController.debugEventLimit)
        #expect(controller.recentEvents.allSatisfy { !$0.contains("secret") })
        #expect(controller.recentEvents.last == "response.created")
    }

    @Test("ViewModel debug snapshot exposes state, route and latency text")
    func viewModelSnapshot() async throws {
        let (controller, _) = try await listening()
        let viewModel = ConversationViewModel(controller: controller,
                                              defaults: UserDefaults(suiteName: "DebugOverlayTests-\(UUID())")!)
        let info = viewModel.debug
        #expect(info.state == "listening")
        #expect(info.route == "Speaker")
        #expect(info.latency == "–")
        #expect(info.lastError == nil)
        #expect(info.events.contains("session.updated"))
    }

    @Test("Durations format as whole milliseconds")
    func formatsMilliseconds() {
        #expect(ConversationViewModel.milliseconds(.milliseconds(812)) == "812 ms")
        #expect(ConversationViewModel.milliseconds(.seconds(1.5)) == "1500 ms")
    }

    @Test("Event names never include payload text")
    func eventNames() {
        #expect(ServerEvent.inputTranscriptionCompleted(itemID: "u", transcript: "my password").name == "input_transcription.completed")
        #expect(ServerEvent.responseDone(responseID: "r", status: .cancelled, reason: "turn_detected").name == "response.done (cancelled)")
    }
}
