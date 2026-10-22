import Foundation

/// Backoff schedule for reconnecting after a network drop (D-011, PRD E7).
/// Stateless: the controller tracks the attempt number and resets it after a successful reconnect.
nonisolated struct ReconnectPolicy: Equatable, Sendable {
    /// `delays[n]` is the wait before attempt `n + 1`.
    let delays: [Duration]

    static let standard = ReconnectPolicy(delays: [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8), .seconds(8),
    ])

    var maxAttempts: Int { delays.count }

    /// Sum of all delays: the longest the user waits before seeing an error.
    var totalBudget: Duration { delays.reduce(.zero, +) }

    /// The wait before a 1-based `attempt`, or `nil` when attempts are exhausted.
    func delay(beforeAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}
