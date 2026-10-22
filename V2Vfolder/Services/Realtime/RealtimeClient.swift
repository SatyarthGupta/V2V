import Foundation

nonisolated protocol RealtimeClienting: AnyObject, Sendable {
    /// Opens the socket and waits for `session.created`. The returned stream yields every
    /// server event (starting with `session.created`) and finishes or throws when the socket closes.
    func connect(token: EphemeralToken) async throws -> AsyncThrowingStream<ServerEvent, Error>
    func send(_ event: ClientEvent) async throws
    /// Round-trip ping; throws if no pong arrives within `timeout` (D-011).
    func ping(timeout: Duration) async throws
    func disconnect() async
}

/// WebSocket connection to `gpt-realtime-2.1`, authenticated with the ephemeral key (D-002, D-013).
actor RealtimeClient: RealtimeClienting {
    static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?model=\(RealtimeSessionConfig.model)")
    static let connectTimeout: Duration = .seconds(8)

    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<ServerEvent, Error>.Continuation?

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func connect(token: EphemeralToken) async throws -> AsyncThrowingStream<ServerEvent, Error> {
        await disconnect()
        guard let endpoint = Self.endpoint else { throw SessionError.socketFailed("bad endpoint") }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        let socket = urlSession.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        // The first message must be session.created; otherwise auth or the handshake failed.
        let first: ServerEvent
        do {
            first = try await withTimeout(Self.connectTimeout) {
                try ServerEvent.decode(try await Self.payload(of: socket.receive()))
            }
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            self.socket = nil
            throw SessionError.socketFailed(String(describing: error))
        }
        guard case .sessionCreated = first else {
            socket.cancel(with: .goingAway, reason: nil)
            self.socket = nil
            if case .error(let serverError) = first {
                throw SessionError.serverError(code: serverError.code ?? serverError.type, message: serverError.message)
            }
            throw SessionError.socketFailed("expected session.created, got \(first)")
        }

        let (stream, continuation) = AsyncThrowingStream<ServerEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        continuation.yield(first)

        receiveLoop = Task { [socket] in
            do {
                while !Task.isCancelled {
                    let data = try await Self.payload(of: socket.receive())
                    // A malformed event shouldn't kill the session; skip it.
                    if let event = try? ServerEvent.decode(data) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: SessionError.socketFailed(String(describing: error)))
            }
        }
        return stream
    }

    func send(_ event: ClientEvent) async throws {
        guard let socket else { throw SessionError.socketFailed("not connected") }
        let data = try event.jsonData()
        guard let text = String(data: data, encoding: .utf8) else { throw SessionError.socketFailed("encoding") }
        do {
            try await socket.send(.string(text))
        } catch {
            throw SessionError.socketFailed(String(describing: error))
        }
    }

    func ping(timeout: Duration) async throws {
        guard let socket else { throw SessionError.socketFailed("not connected") }
        try await withTimeout(timeout) {
            try await cancellableCallback { resume in
                socket.sendPing { error in resume(error) }
            }
        }
    }

    func disconnect() async {
        receiveLoop?.cancel()
        receiveLoop = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation?.finish()
        continuation = nil
    }

    private static func payload(of message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .string(let text): Data(text.utf8)
        case .data(let data): data
        @unknown default: throw SessionError.socketFailed("unknown message type")
        }
    }
}

/// Bridges a one-shot callback API into async code that also returns promptly when cancelled.
/// Whichever happens first (callback or cancellation) resumes the continuation; the other is ignored.
nonisolated func cancellableCallback(_ start: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    let once = ResumeOnce()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.install(continuation)
            start { error in once.resume(error) }
        }
    } onCancel: {
        once.resume(CancellationError())
    }
}

/// Resumes a continuation at most once, from any thread.
nonisolated private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let result: Result<Void, Error>? = lock.withLock {
            if let pendingResult {
                finished = true
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func resume(_ error: Error?) {
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !finished else { return nil }
            guard let continuation = self.continuation else {
                // Cancelled or called back before install: remember it for install().
                pendingResult = pendingResult ?? result
                return nil
            }
            finished = true
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
