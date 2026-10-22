import Foundation

nonisolated struct TimeoutError: Error, Equatable, Sendable {
    let duration: Duration
}

/// Runs `operation`, throwing `TimeoutError` if it takes longer than `duration` (D-012).
///
/// The operation is cancelled on timeout. It must respond to cancellation
/// (URLSession and our clients do), because a task group can't return until
/// all of its child tasks have finished.
nonisolated func withTimeout<T: Sendable, C: Clock<Duration>>(
    _ duration: Duration,
    clock: C = ContinuousClock(),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(for: duration)
            throw TimeoutError(duration: duration)
        }
        defer { group.cancelAll() }
        // The first child to finish wins: either the result or the timeout error.
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        return result
    }
}
