import Foundation

// Scriptable fakes for unit tests and `-uiTestFakes` UI tests (v2v-h28.9).
// Each records what it was asked to do, so tests can assert on side effects.

nonisolated final class FakePermissionService: PermissionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: MicPermission
    private var _grantOnRequest: Bool
    private(set) var requestCount = 0

    init(status: MicPermission = .granted, grantOnRequest: Bool = true) {
        _status = status
        _grantOnRequest = grantOnRequest
    }

    var status: MicPermission {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }

    func micStatus() -> MicPermission { status }

    func requestMic() async -> Bool {
        lock.withLock {
            requestCount += 1
            _status = _grantOnRequest ? .granted : .denied
            return _grantOnRequest
        }
    }
}

nonisolated final class FakeTokenService: TokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    private(set) var fetchCount = 0

    init(error: Error? = nil) { _error = error }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    func fetchToken(persona: Persona) async throws -> EphemeralToken {
        let error = lock.withLock { () -> Error? in
            fetchCount += 1
            return _error
        }
        if let error { throw error }
        return EphemeralToken(value: "ek_fake", expiresAt: .now.addingTimeInterval(600),
                              personaID: persona.rawValue, voice: persona.voice, instructions: "Fake \(persona.rawValue)")
    }
}

nonisolated final class FakeRealtimeClient: RealtimeClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ServerEvent, Error>.Continuation?
    private var _sent: [ClientEvent] = []
    private var _connectError: Error?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    /// Sends `session.created` then `session.updated` automatically after `session.update`.
    var autoConfirmSession = true

    init(connectError: Error? = nil) { _connectError = connectError }

    var sent: [ClientEvent] { lock.withLock { _sent } }

    func connect(token: EphemeralToken) async throws -> AsyncThrowingStream<ServerEvent, Error> {
        let error = lock.withLock { () -> Error? in
            connectCount += 1
            return _connectError
        }
        if let error { throw error }
        let (stream, continuation) = AsyncThrowingStream<ServerEvent, Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        continuation.yield(.sessionCreated(expiresAt: nil))
        return stream
    }

    func send(_ event: ClientEvent) async throws {
        let confirm = lock.withLock { () -> Bool in
            _sent.append(event)
            if case .sessionUpdate = event { return autoConfirmSession }
            return false
        }
        if confirm { emit(.sessionUpdated) }
    }

    func ping(timeout: Duration) async throws {}

    func disconnect() async {
        lock.withLock {
            disconnectCount += 1
            continuation?.finish()
            continuation = nil
        }
    }

    /// Test hook: deliver a server event.
    func emit(_ event: ServerEvent) {
        _ = lock.withLock { continuation }?.yield(event)
    }

    /// Test hook: simulate the socket dropping.
    func drop(_ error: Error = URLError(.networkConnectionLost)) {
        lock.withLock {
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }
}

nonisolated final class FakeAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    let micChunks: AsyncStream<Data>
    let playbackDrained: AsyncStream<Void>
    let configurationChanges: AsyncStream<Void>
    private let micContinuation: AsyncStream<Data>.Continuation
    private let drainedContinuation: AsyncStream<Void>.Continuation
    private let configContinuation: AsyncStream<Void>.Continuation

    private let lock = NSLock()
    private var _isPlaying = false
    private var _nextCut: PlaybackCut?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var rebuildCount = 0
    private(set) var flushCount = 0
    private(set) var enqueued: [(itemID: String, bytes: Int)] = []
    private(set) var isMicMuted = false
    var startError: Error?

    init() {
        (micChunks, micContinuation) = AsyncStream.makeStream()
        (playbackDrained, drainedContinuation) = AsyncStream.makeStream()
        (configurationChanges, configContinuation) = AsyncStream.makeStream()
    }

    var isPlaying: Bool {
        get { lock.withLock { _isPlaying } }
        set { lock.withLock { _isPlaying = newValue } }
    }

    /// What the next `flushPlayback()` reports (simulates audio mid-playback).
    var nextCut: PlaybackCut? {
        get { lock.withLock { _nextCut } }
        set { lock.withLock { _nextCut = newValue } }
    }

    func start() throws {
        lock.withLock { startCount += 1 }
        if let startError { throw startError }
    }

    func stop() { lock.withLock { stopCount += 1; _isPlaying = false } }

    func rebuildForCurrentRoute() throws { lock.withLock { rebuildCount += 1 } }

    func enqueue(pcm16: Data, itemID: String) {
        lock.withLock {
            enqueued.append((itemID, pcm16.count))
            _isPlaying = true
        }
    }

    func flushPlayback() -> PlaybackCut? {
        lock.withLock {
            flushCount += 1
            let cut = _isPlaying ? _nextCut : nil
            _isPlaying = false
            _nextCut = nil
            return cut
        }
    }

    func setMicMuted(_ muted: Bool) { lock.withLock { isMicMuted = muted } }

    // Test hooks
    func emitMic(_ data: Data) { micContinuation.yield(data) }
    func finishPlayback() {
        lock.withLock { _isPlaying = false }
        drainedContinuation.yield()
    }
    func emitConfigurationChange() { configContinuation.yield() }
}

nonisolated final class FakeAudioSessionManager: AudioSessionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var interruptionContinuation: AsyncStream<AudioInterruption>.Continuation?
    private var routeContinuation: AsyncStream<RouteChange>.Continuation?
    private var resetContinuation: AsyncStream<Void>.Continuation?
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    var route = AudioRoute(outputName: "Speaker", isBuiltInSpeaker: true, isBluetooth: false)
    var activateError: Error?

    func configureAndActivate() throws {
        lock.withLock { activateCount += 1 }
        if let activateError { throw activateError }
    }

    func deactivate() { lock.withLock { deactivateCount += 1 } }
    func currentRoute() -> AudioRoute { lock.withLock { route } }
    private(set) var speakerOverrideCount = 0
    func routeToSpeakerIfOnReceiver() { lock.withLock { speakerOverrideCount += 1 } }

    func interruptions() -> AsyncStream<AudioInterruption> {
        let (stream, continuation) = AsyncStream<AudioInterruption>.makeStream()
        lock.withLock { interruptionContinuation = continuation }
        return stream
    }

    func routeChanges() -> AsyncStream<RouteChange> {
        let (stream, continuation) = AsyncStream<RouteChange>.makeStream()
        lock.withLock { routeContinuation = continuation }
        return stream
    }

    func mediaServicesWereReset() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lock.withLock { resetContinuation = continuation }
        return stream
    }

    // Test hooks
    func emit(_ interruption: AudioInterruption) { _ = lock.withLock { interruptionContinuation }?.yield(interruption) }
    func emit(_ change: RouteChange) { _ = lock.withLock { routeContinuation }?.yield(change) }
}
