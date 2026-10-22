import Foundation
import Observation
import OSLog

/// Everything the controller talks to, injected so tests can use fakes (D-006).
struct VoiceSessionDependencies {
    let permissions: PermissionProviding
    let tokens: TokenProviding
    let audioSession: AudioSessionManaging
    /// One client and one engine per conversation.
    let makeRealtimeClient: () -> RealtimeClienting
    let makeAudioEngine: () -> AudioEngineProtocol
}

/// The session state machine (docs/HLD.md §3, docs/LLD.md §4). All edge-case logic lives here.
@Observable
final class VoiceSessionController {
    static let connectWatchdog: Duration = .seconds(20)
    static let rebuildWindow: Duration = .seconds(10)
    static let maxRebuildsPerWindow = 5

    private(set) var state: SessionState = .idle {
        didSet {
            if state != oldValue { Log.session.info("state → \(String(describing: self.state), privacy: .public)") }
        }
    }
    private(set) var turns: [TranscriptTurn] = []
    /// Non-fatal server error to show in a banner; cleared on the next start.
    private(set) var lastServerError: RealtimeServerError?
    private(set) var isMuted = false
    /// Where audio is going (debug overlay, D-022).
    private(set) var currentRoute: AudioRoute = .unknown
    /// Last lifecycle event names, newest last (debug overlay).
    private(set) var recentEvents: [String] = []
    /// Time from the user's end of turn to the AI's first audio (PRD NFR latency).
    private(set) var lastReplyLatency: Duration?
    static let debugEventLimit = 20
    private var speechStoppedAt: ContinuousClock.Instant?

    private let deps: VoiceSessionDependencies

    // Per-session resources. `sessionID` guards every async callback so work from an
    // ended session can never mutate a newer one.
    private var sessionID = UUID()
    private var client: RealtimeClienting?
    private var engine: AudioEngineProtocol?
    private var tasks: [Task<Void, Never>] = []
    private var token: EphemeralToken?
    private var activeResponseID: String?
    private var cancelledResponseIDs: Set<String> = []
    private var isNewConversation = true
    private var recentRebuilds: [ContinuousClock.Instant] = []
    private var startedAt: Date?
    private var currentPersona: Persona?
    private var hasReportedFinish = false

    /// Called once when a conversation with at least one turn ends or fails (saves history, F8).
    var onSessionEnded: ((FinishedConversation) -> Void)?

    init(dependencies: VoiceSessionDependencies) {
        self.deps = dependencies
    }

    // MARK: - Intents

    func start(persona: Persona) async {
        guard !state.isActive else { return }
        let id = UUID()
        sessionID = id
        turns = []
        lastServerError = nil
        isNewConversation = true
        recentRebuilds = []
        startedAt = .now
        currentPersona = persona
        hasReportedFinish = false
        recentEvents = []
        lastReplyLatency = nil
        speechStoppedAt = nil

        state = .checkingPermission
        switch deps.permissions.micStatus() {
        case .denied:
            state = .permissionDenied
            return
        case .undetermined:
            let granted = await deps.permissions.requestMic()
            guard id == sessionID else { return }
            guard granted else {
                state = .permissionDenied
                return
            }
        case .granted:
            break
        }

        state = .connecting
        startWatchdog(for: id)
        do {
            try deps.audioSession.configureAndActivate()
            let token = try await deps.tokens.fetchToken(persona: persona)
            guard id == sessionID else { return }
            self.token = token

            let client = deps.makeRealtimeClient()
            self.client = client
            let events = try await client.connect(token: token)
            guard id == sessionID else { await client.disconnect(); return }

            listen(to: events, session: id)
            let route = deps.audioSession.currentRoute()
            try await client.send(.sessionUpdate(RealtimeSessionConfig(
                instructions: token.instructions, voice: token.voice, outputIsBuiltInSpeaker: route.isBuiltInSpeaker)))
            // Audio starts when the server confirms with session.updated (see handle(_:)).
        } catch {
            guard id == sessionID else { return }
            await fail(Self.sessionError(from: error))
        }
    }

    /// Ends the conversation from any state. Safe to call repeatedly.
    func end() async {
        sessionID = UUID()
        reportFinished()
        await tearDown()
        state = .idle
    }

    /// Hands the transcript to history exactly once per conversation (end *or* failure, U-53).
    private func reportFinished() {
        guard !hasReportedFinish, !turns.isEmpty, let startedAt, let persona = currentPersona else { return }
        hasReportedFinish = true
        onSessionEnded?(FinishedConversation(turns: turns, persona: persona, startedAt: startedAt, endedAt: .now))
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        engine?.setMicMuted(muted)
    }

    // MARK: - Session lifecycle

    private func startWatchdog(for id: UUID) {
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: Self.connectWatchdog)
            guard let self, id == self.sessionID, self.state == .connecting else { return }
            await self.fail(.socketFailed("connect timed out"))
        })
    }

    private func listen(to events: AsyncThrowingStream<ServerEvent, Error>, session id: UUID) {
        tasks.append(Task { [weak self] in
            do {
                for try await event in events {
                    guard let self, id == self.sessionID else { return }
                    await self.handle(event)
                }
                guard let self, id == self.sessionID else { return }
                await self.fail(.socketFailed("connection closed"))
            } catch {
                guard let self, id == self.sessionID else { return }
                await self.fail(Self.sessionError(from: error))
            }
        })
    }

    /// Called once the server has applied our session config.
    private func beginAudio() async {
        guard state == .connecting, let client else { return }
        let id = sessionID
        let engine = deps.makeAudioEngine()
        self.engine = engine
        do {
            try engine.start()
        } catch {
            await fail(Self.sessionError(from: error))
            return
        }
        // Must run after the engine starts: enabling voice processing can move output to the earpiece.
        deps.audioSession.routeToSpeakerIfOnReceiver()
        engine.setMicMuted(isMuted)

        // Mic pump: stream every chunk to the server.
        tasks.append(Task { [weak self] in
            for await chunk in engine.micChunks {
                guard let self, id == self.sessionID else { return }
                try? await client.send(.inputAudioAppend(audio: chunk.base64EncodedString()))
            }
        })
        // AI finished talking out loud → back to listening.
        tasks.append(Task { [weak self] in
            for await _ in engine.playbackDrained {
                guard let self, id == self.sessionID else { return }
                if self.state == .aiSpeaking { self.state = .listening }
            }
        })
        // iOS stopped the engine (hardware reconfigured, e.g. voice processing or a route change): restart it (D-010).
        tasks.append(Task { [weak self] in
            for await _ in engine.configurationChanges {
                guard let self, id == self.sessionID else { return }
                await self.recoverEngine(engine)
            }
        })
        // Headphones / earbuds connected or removed (PRD E4).
        let routeChanges = deps.audioSession.routeChanges()
        tasks.append(Task { [weak self] in
            for await change in routeChanges {
                guard let self, id == self.sessionID else { return }
                await self.handleRouteChange(change)
            }
        })
        currentRoute = deps.audioSession.currentRoute()

        state = .listening
        if isNewConversation {
            isNewConversation = false
            try? await client.send(.responseCreate) // Greeting (PRD F10).
        }
    }

    /// Audio moved to a different device (D-010, PRD E4). The session is never torn down for this.
    /// The engine itself is rebuilt only via `configurationChanges`, which iOS posts when the
    /// hardware format actually changes, so a route switch isn't counted twice against the loop guard.
    private func handleRouteChange(_ change: RouteChange) async {
        Log.audio.info("route change \(String(describing: change.reason), privacy: .public) → \(change.route.outputName, privacy: .public)")
        let previous = currentRoute
        currentRoute = change.route

        // iOS doesn't always say `.oldDeviceUnavailable`: switching Bluetooth off arrived as `.override`
        // on device. So compare routes: external (earbuds/headphones) → built-in means the headset was lost.
        let headsetLost = change.reason == .oldDeviceUnavailable || (previous.isExternal && !change.route.isExternal)
        if headsetLost {
            // The user didn't hear the rest, so stop the AI rather than let it talk out of the speaker.
            await silenceAI(cancelOnServer: true)
            if state == .aiSpeaking || state == .thinking { state = .listening }
        }

        // Falling back from earbuds often lands on the quiet earpiece.
        deps.audioSession.routeToSpeakerIfOnReceiver()
        currentRoute = deps.audioSession.currentRoute()

        // Speaker hears the room → far-field noise reduction; headset → near-field (D-003).
        if currentRoute.isBuiltInSpeaker != previous.isBuiltInSpeaker, let token, let client {
            try? await client.send(.sessionUpdate(RealtimeSessionConfig(
                instructions: token.instructions, voice: token.voice, outputIsBuiltInSpeaker: currentRoute.isBuiltInSpeaker)))
        }
    }

    /// Rebuilds the engine after iOS stopped it. Gives up if it keeps happening, so we can't loop forever.
    private func recoverEngine(_ engine: AudioEngineProtocol) async {
        let now = ContinuousClock.now
        recentRebuilds = recentRebuilds.filter { now - $0 < Self.rebuildWindow } + [now]
        guard recentRebuilds.count <= Self.maxRebuildsPerWindow else {
            await fail(.audioEngineFailed("audio hardware kept resetting"))
            return
        }
        do {
            try engine.rebuildForCurrentRoute()
        } catch {
            await fail(Self.sessionError(from: error))
            return
        }
        deps.audioSession.routeToSpeakerIfOnReceiver()
        engine.setMicMuted(isMuted)
        // Any queued AI audio was dropped by the rebuild.
        if state == .aiSpeaking { state = .listening }
    }

    private func fail(_ error: SessionError) async {
        sessionID = UUID()
        reportFinished()
        await tearDown()
        state = .failed(error)
    }

    private func tearDown() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        engine?.stop()
        engine = nil
        if let client {
            self.client = nil
            await client.disconnect()
        }
        deps.audioSession.deactivate()
        activeResponseID = nil
        cancelledResponseIDs.removeAll()
        token = nil
    }

    // MARK: - Server events

    private func handle(_ event: ServerEvent) async {
        Self.logEvent(event)
        recordForDebug(event)
        switch event {
        case .sessionUpdated:
            await beginAudio()

        case .speechStarted(let userItemID, _):
            await bargeIn()
            upsertTurn(id: userItemID, role: .user) { _ in }
            if state.isConversing { state = .userSpeaking }

        case .speechStopped:
            if state == .userSpeaking { state = .thinking }

        case .inputTranscriptionDelta(let itemID, let delta):
            upsertTurn(id: itemID, role: .user) { $0.text += delta }

        case .inputTranscriptionCompleted(let itemID, let transcript):
            upsertTurn(id: itemID, role: .user) {
                $0.text = transcript
                $0.isFinal = true
            }

        case .responseCreated(let responseID):
            activeResponseID = responseID

        case .outputAudioDelta(let responseID, let itemID, let audio):
            guard !cancelledResponseIDs.contains(responseID), let pcm = Data(base64Encoded: audio) else { return }
            engine?.enqueue(pcm16: pcm, itemID: itemID)
            if state == .listening || state == .thinking { state = .aiSpeaking }

        case .outputTranscriptDelta(let responseID, let itemID, let delta):
            guard !cancelledResponseIDs.contains(responseID) else { return }
            upsertTurn(id: itemID, role: .assistant) { $0.text += delta }

        case .outputTranscriptDone(_, let itemID, let transcript):
            // Also arrives for cancelled responses, already trimmed to what was heard.
            upsertTurn(id: itemID, role: .assistant) {
                $0.text = transcript
                $0.isFinal = true
            }

        case .responseDone(let responseID, _, _):
            if responseID == activeResponseID { activeResponseID = nil }
            if state == .thinking, engine?.isPlaying != true { state = .listening }

        case .error(let error):
            lastServerError = error

        case .sessionCreated, .outputAudioDone, .itemTruncated, .unknown:
            break
        }
    }

    /// Feeds the debug overlay (D-022): event names only (never payloads or transcripts),
    /// plus end-of-turn → first-audio latency.
    private func recordForDebug(_ event: ServerEvent) {
        switch event {
        case .speechStopped:
            speechStoppedAt = .now
        case .outputAudioDelta(let responseID, _, _):
            if let stoppedAt = speechStoppedAt, !cancelledResponseIDs.contains(responseID) {
                lastReplyLatency = ContinuousClock.now - stoppedAt
                speechStoppedAt = nil
            }
        default:
            break
        }
        // Per-chunk deltas would flood the list; only lifecycle events are kept.
        switch event {
        case .outputAudioDelta, .outputTranscriptDelta, .inputTranscriptionDelta:
            return
        default:
            recentEvents.append(event.name)
            if recentEvents.count > Self.debugEventLimit {
                recentEvents.removeFirst(recentEvents.count - Self.debugEventLimit)
            }
        }
    }

    /// The user started talking: silence the AI now, then tell the server what was heard (D-004).
    /// The server cancels the response itself (`interrupt_response`), so no cancel is sent.
    private func bargeIn() async {
        await silenceAI(cancelOnServer: false)
    }

    /// Stops AI audio immediately, drops the rest of the current response, and trims the
    /// model's memory to what was actually heard.
    private func silenceAI(cancelOnServer: Bool) async {
        let responseID = activeResponseID
        if let responseID {
            cancelledResponseIDs.insert(responseID)
        }
        if cancelOnServer, responseID != nil {
            try? await client?.send(.responseCancel)
        }
        guard let cut = engine?.flushPlayback() else { return }
        upsertTurn(id: cut.itemID, role: .assistant) { $0.wasInterrupted = true }
        try? await client?.send(.truncate(itemID: cut.itemID, contentIndex: 0, audioEndMs: cut.playedMs))
    }

    private func upsertTurn(id: String, role: TranscriptTurn.Role, update: (inout TranscriptTurn) -> Void) {
        if let index = turns.firstIndex(where: { $0.id == id }) {
            update(&turns[index])
        } else {
            var turn = TranscriptTurn(id: id, role: role)
            update(&turn)
            turns.append(turn)
        }
    }

    /// Logs lifecycle events; skips per-chunk deltas to keep the console readable.
    private static func logEvent(_ event: ServerEvent) {
        switch event {
        case .outputAudioDelta, .outputTranscriptDelta, .inputTranscriptionDelta, .unknown:
            return
        case .error(let error):
            Log.session.error("server error \(error.code ?? error.type, privacy: .public): \(error.message, privacy: .public)")
        case .inputTranscriptionCompleted(_, let transcript):
            Log.session.info("heard user: \(transcript, privacy: .private)")
        default:
            Log.session.info("event: \(String(describing: event), privacy: .public)")
        }
    }

    private static func sessionError(from error: Error) -> SessionError {
        if let error = error as? SessionError { return error }
        if error is TimeoutError { return .socketFailed("timed out") }
        return .socketFailed(String(describing: error))
    }
}

private extension SessionState {
    /// States in which speech events should drive the orb.
    var isConversing: Bool {
        switch self {
        case .listening, .userSpeaking, .thinking, .aiSpeaking: true
        default: false
        }
    }
}
