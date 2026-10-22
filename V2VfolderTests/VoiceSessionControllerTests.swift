import Foundation
import Testing
@testable import V2Vfolder

/// Wires a controller to scriptable fakes.
@MainActor
private final class Harness {
    let permissions: FakePermissionService
    let tokens = FakeTokenService()
    let audioSession = FakeAudioSessionManager()
    let client = FakeRealtimeClient()
    let engine = FakeAudioEngine()
    lazy var controller = VoiceSessionController(dependencies: VoiceSessionDependencies(
        permissions: permissions,
        tokens: tokens,
        audioSession: audioSession,
        makeRealtimeClient: { [client] in client },
        makeAudioEngine: { [engine] in engine }
    ))

    init(mic: MicPermission = .granted, grantOnRequest: Bool = true) {
        permissions = FakePermissionService(status: mic, grantOnRequest: grantOnRequest)
    }

    /// Starts a session and waits until the controller is listening.
    func startListening(_ persona: Persona = .quick) async throws {
        await controller.start(persona: persona)
        try await expectEventually { self.controller.state == .listening }
    }

    func count(_ event: ClientEvent) -> Int {
        client.sent.filter { $0 == event }.count
    }

    /// Simulates the AI speaking `itemID` in response `responseID`.
    func aiSpeaks(response responseID: String, item itemID: String) async throws {
        client.emit(.responseCreated(responseID: responseID))
        client.emit(.outputAudioDelta(responseID: responseID, itemID: itemID, audio: Data([1, 0, 2, 0]).base64EncodedString()))
        try await expectEventually { self.controller.state == .aiSpeaking }
    }
}

/// Polls until `condition` holds (async events are delivered on later turns of the run loop).
@MainActor
private func expectEventually(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Lets in-flight tasks run, for asserting that something did *not* happen.
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(50))
}

@MainActor
struct VoiceSessionStartTests {
    @Test("U-01: start → listening; session.update carries the persona config")
    func startHappyPath() async throws {
        let h = Harness()
        try await h.startListening(.coach)

        guard case .sessionUpdate(let config) = h.client.sent.first else {
            Issue.record("first event should be session.update"); return
        }
        #expect(config.voice == "coral")
        #expect(config.instructions == "Fake coach")
        #expect(config.noiseReduction == .farField) // fake route is the built-in speaker
        #expect(h.audioSession.activateCount == 1)
        #expect(h.engine.startCount == 1)
    }

    @Test("U-26: a new conversation greets exactly once")
    func greetsOnce() async throws {
        let h = Harness()
        try await h.startListening()
        try await expectEventually { h.count(.responseCreate) == 1 }
        try await settle()
        #expect(h.count(.responseCreate) == 1)
    }

    @Test("Mic chunks are streamed to the server as base64")
    func micPump() async throws {
        let h = Harness()
        try await h.startListening()
        h.engine.emitMic(Data([1, 2]))
        try await expectEventually { h.count(.inputAudioAppend(audio: "AQI=")) == 1 }
    }

    @Test("U-02: denied mic → permissionDenied; nothing else happens")
    func micDenied() async throws {
        let h = Harness(mic: .denied)
        await h.controller.start(persona: .quick)

        #expect(h.controller.state == .permissionDenied)
        #expect(h.tokens.fetchCount == 0)
        #expect(h.client.connectCount == 0)
        #expect(h.engine.startCount == 0)
        #expect(h.audioSession.activateCount == 0)
    }

    @Test("U-03: user declines the prompt → permissionDenied")
    func micDeclined() async throws {
        let h = Harness(mic: .undetermined, grantOnRequest: false)
        await h.controller.start(persona: .quick)
        #expect(h.permissions.requestCount == 1)
        #expect(h.controller.state == .permissionDenied)
        #expect(h.tokens.fetchCount == 0)
    }

    @Test("U-04: user grants the prompt → session starts")
    func micGrantedOnPrompt() async throws {
        let h = Harness(mic: .undetermined, grantOnRequest: true)
        try await h.startListening()
        #expect(h.permissions.requestCount == 1)
    }

    @Test("U-04: after a denial, starting again once granted works without relaunch")
    func retryAfterGrantingInSettings() async throws {
        let h = Harness(mic: .denied)
        await h.controller.start(persona: .quick)
        #expect(h.controller.state == .permissionDenied)

        h.permissions.status = .granted // user flipped the switch in Settings
        try await h.startListening()
    }

    @Test("Token server unreachable → failed, audio released")
    func tokenFailure() async throws {
        let h = Harness()
        h.tokens.error = SessionError.tokenServerUnreachable
        await h.controller.start(persona: .quick)

        #expect(h.controller.state == .failed(.tokenServerUnreachable))
        #expect(h.engine.startCount == 0)
        #expect(h.audioSession.deactivateCount >= 1)
    }

    @Test("Socket connect failure → failed")
    func connectFailure() async throws {
        let h = Harness()
        let client = FakeRealtimeClient(connectError: SessionError.socketFailed("handshake"))
        let controller = VoiceSessionController(dependencies: VoiceSessionDependencies(
            permissions: h.permissions, tokens: h.tokens, audioSession: h.audioSession,
            makeRealtimeClient: { client }, makeAudioEngine: { h.engine }))
        await controller.start(persona: .quick)
        #expect(controller.state == .failed(.socketFailed("handshake")))
    }

    @Test("Audio engine failure → failed and the socket is closed")
    func engineFailure() async throws {
        let h = Harness()
        h.engine.startError = SessionError.audioEngineFailed("no input")
        await h.controller.start(persona: .quick)
        try await expectEventually { h.controller.state == .failed(.audioEngineFailed("no input")) }
        #expect(h.client.disconnectCount == 1)
    }

    @Test("Socket drop mid-conversation → failed (reconnect arrives in v2v-tto.5)")
    func socketDrop() async throws {
        let h = Harness()
        try await h.startListening()
        h.client.drop()
        try await expectEventually {
            if case .failed(.socketFailed) = h.controller.state { return true }
            return false
        }
        #expect(h.engine.stopCount == 1)
    }
}

@MainActor
struct VoiceSessionBargeInTests {
    @Test("U-05: user talks over the AI → playback flushed, truncate sent, turn marked interrupted")
    func bargeIn() async throws {
        let h = Harness()
        try await h.startListening()
        try await h.aiSpeaks(response: "r1", item: "item_42")

        h.engine.nextCut = PlaybackCut(itemID: "item_42", playedMs: 1840)
        h.client.emit(.speechStarted(itemID: "user_2", audioStartMs: 0))

        try await expectEventually { h.count(.truncate(itemID: "item_42", contentIndex: 0, audioEndMs: 1840)) == 1 }
        #expect(h.engine.flushCount == 1)
        #expect(h.controller.state == .userSpeaking)
        #expect(h.controller.turns.first { $0.id == "item_42" }?.wasInterrupted == true)
    }

    @Test("U-06: late audio from the cancelled response is dropped")
    func lateDeltasDropped() async throws {
        let h = Harness()
        try await h.startListening()
        try await h.aiSpeaks(response: "r1", item: "item_42")
        h.engine.nextCut = PlaybackCut(itemID: "item_42", playedMs: 500)
        h.client.emit(.speechStarted(itemID: "user_2", audioStartMs: 0))
        try await expectEventually { h.controller.state == .userSpeaking }

        h.client.emit(.outputAudioDelta(responseID: "r1", itemID: "item_42", audio: Data([9, 9]).base64EncodedString()))
        h.client.emit(.outputTranscriptDelta(responseID: "r1", itemID: "item_42", delta: " unheard words"))
        try await settle()

        #expect(h.engine.enqueued.count == 1)
        #expect(h.controller.turns.first { $0.id == "item_42" }?.text.contains("unheard") != true)
    }

    @Test("U-07: speech while the AI is silent → no flush cut, no truncate")
    func speechWhileSilent() async throws {
        let h = Harness()
        try await h.startListening()
        h.client.emit(.speechStarted(itemID: "user_1", audioStartMs: 0))
        try await expectEventually { h.controller.state == .userSpeaking }
        try await settle()
        #expect(!h.client.sent.contains { if case .truncate = $0 { true } else { false } })
    }

    @Test("U-08: after a barge-in, the next response plays normally")
    func nextResponsePlays() async throws {
        let h = Harness()
        try await h.startListening()
        try await h.aiSpeaks(response: "r1", item: "item_42")
        h.engine.nextCut = PlaybackCut(itemID: "item_42", playedMs: 300)
        h.client.emit(.speechStarted(itemID: "user_2", audioStartMs: 0))
        h.client.emit(.speechStopped(itemID: "user_2"))
        try await expectEventually { h.controller.state == .thinking }

        try await h.aiSpeaks(response: "r2", item: "item_43")
        #expect(h.engine.enqueued.map(\.itemID) == ["item_42", "item_43"])
    }

    @Test("Playback drained → back to listening")
    func drainedReturnsToListening() async throws {
        let h = Harness()
        try await h.startListening()
        try await h.aiSpeaks(response: "r1", item: "item_1")
        h.client.emit(.responseDone(responseID: "r1", status: .completed, reason: nil))
        try await settle()
        #expect(h.controller.state == .aiSpeaking) // still playing buffered audio

        h.engine.finishPlayback()
        try await expectEventually { h.controller.state == .listening }
    }
}

@MainActor
struct VoiceSessionEngineRecoveryTests {
    @Test("U-15: iOS stopped the engine (configuration change) → rebuilt, speaker re-applied, session continues")
    func rebuildsOnConfigurationChange() async throws {
        let h = Harness()
        try await h.startListening()
        let overridesBefore = h.audioSession.speakerOverrideCount

        h.engine.emitConfigurationChange()
        try await expectEventually { h.engine.rebuildCount == 1 }
        #expect(h.audioSession.speakerOverrideCount == overridesBefore + 1)
        #expect(h.controller.state == .listening)
        #expect(h.client.disconnectCount == 0)
    }

    @Test("Rebuild while the AI is speaking → back to listening (queued audio was dropped)")
    func rebuildWhileSpeaking() async throws {
        let h = Harness()
        try await h.startListening()
        try await h.aiSpeaks(response: "r1", item: "item_1")

        h.engine.emitConfigurationChange()
        try await expectEventually { h.controller.state == .listening }
    }

    @Test("Engine that keeps resetting → fails instead of looping forever")
    func rebuildLoopGuard() async throws {
        let h = Harness()
        try await h.startListening()
        for _ in 0...VoiceSessionController.maxRebuildsPerWindow {
            h.engine.emitConfigurationChange()
            try await Task.sleep(for: .milliseconds(10))
        }
        try await expectEventually { h.controller.state == .failed(.audioEngineFailed("audio hardware kept resetting")) }
    }

    @Test("Speaker override is applied when audio starts")
    func speakerOverrideOnStart() async throws {
        let h = Harness()
        try await h.startListening()
        #expect(h.audioSession.speakerOverrideCount == 1)
    }
}

@MainActor
struct VoiceSessionTranscriptTests {
    @Test("User and assistant turns stream in order and finalise")
    func transcript() async throws {
        let h = Harness()
        try await h.startListening()

        h.client.emit(.speechStarted(itemID: "u1", audioStartMs: 0))
        h.client.emit(.inputTranscriptionDelta(itemID: "u1", delta: "Hel"))
        h.client.emit(.inputTranscriptionDelta(itemID: "u1", delta: "lo"))
        h.client.emit(.speechStopped(itemID: "u1"))
        h.client.emit(.inputTranscriptionCompleted(itemID: "u1", transcript: "Hello."))
        h.client.emit(.responseCreated(responseID: "r1"))
        h.client.emit(.outputTranscriptDelta(responseID: "r1", itemID: "a1", delta: "Hi "))
        h.client.emit(.outputTranscriptDone(responseID: "r1", itemID: "a1", transcript: "Hi there!"))

        try await expectEventually { h.controller.turns.count == 2 && h.controller.turns[1].isFinal }
        #expect(h.controller.turns.map(\.role) == [.user, .assistant])
        #expect(h.controller.turns[0] == TranscriptTurn(id: "u1", role: .user, text: "Hello.", isFinal: true))
        #expect(h.controller.turns[1].text == "Hi there!")
    }

    @Test("U-23: a non-fatal server error is surfaced but the session continues")
    func nonFatalError() async throws {
        let h = Harness()
        try await h.startListening()
        let error = RealtimeServerError(type: "invalid_request_error", code: "x", message: "bad", clientEventID: nil)
        h.client.emit(.error(error))
        try await expectEventually { h.controller.lastServerError == error }
        #expect(h.controller.state == .listening)
    }
}

@MainActor
struct VoiceSessionEndTests {
    @Test("U-21: end() releases everything and returns to idle")
    func endReleases() async throws {
        let h = Harness()
        try await h.startListening()
        await h.controller.end()

        #expect(h.controller.state == .idle)
        #expect(h.client.disconnectCount == 1)
        #expect(h.engine.stopCount == 1)
        #expect(h.audioSession.deactivateCount >= 1)

        let sentBefore = h.client.sent.count
        h.engine.emitMic(Data([1, 2, 3]))
        try await settle()
        #expect(h.client.sent.count == sentBefore) // mic pump stopped
    }

    @Test("U-22: end() twice is harmless")
    func endTwice() async throws {
        let h = Harness()
        try await h.startListening()
        await h.controller.end()
        await h.controller.end()
        #expect(h.controller.state == .idle)
    }

    @Test("U-22: end() while connecting wins over a late session.updated")
    func endWhileConnecting() async throws {
        let h = Harness()
        h.client.autoConfirmSession = false
        await h.controller.start(persona: .quick)
        #expect(h.controller.state == .connecting)

        await h.controller.end()
        h.client.emit(.sessionUpdated)
        try await settle()

        #expect(h.controller.state == .idle)
        #expect(h.engine.startCount == 0)
    }

    @Test("start() while a session is active is ignored")
    func doubleStart() async throws {
        let h = Harness()
        try await h.startListening()
        await h.controller.start(persona: .quick)
        #expect(h.tokens.fetchCount == 1)
    }

    @Test("U-25: mute is forwarded to the engine")
    func mute() async throws {
        let h = Harness()
        try await h.startListening()
        h.controller.setMuted(true)
        #expect(h.engine.isMicMuted)
        #expect(h.controller.isMuted)
    }
}
