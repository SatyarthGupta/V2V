import Foundation
import Testing
@testable import V2Vfolder

struct TimeoutTests {
    @Test("Returns the result when the operation finishes in time")
    func returnsResult() async throws {
        let value = try await withTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test("U-41: throws TimeoutError and cancels the operation")
    func timesOutAndCancels() async {
        let wasCancelled = CancellationFlag()
        let started = ContinuousClock.now

        await #expect(throws: TimeoutError(duration: .milliseconds(50))) {
            try await withTimeout(.milliseconds(50)) {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch is CancellationError {
                    wasCancelled.set()
                    throw CancellationError()
                }
            }
        }

        #expect(wasCancelled.value)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("Propagates the operation's own error")
    func propagatesError() async {
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom()) {
            try await withTimeout(.seconds(5)) { throw Boom() }
        }
    }
}

/// Thread-safe flag for observing cancellation from inside a child task.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

struct ReconnectPolicyTests {
    @Test("U-30: standard schedule is 0.5, 1, 2, 4, 8, 8, 8 seconds")
    func standardSchedule() {
        let policy = ReconnectPolicy.standard
        let expected: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8), .seconds(8)]
        #expect(policy.maxAttempts == 7)
        #expect((1...7).compactMap(policy.delay(beforeAttempt:)) == expected)
    }

    @Test("U-30: total budget stays within 32 seconds")
    func budget() {
        #expect(ReconnectPolicy.standard.totalBudget == .milliseconds(31_500))
        #expect(ReconnectPolicy.standard.totalBudget <= .seconds(32))
    }

    @Test("U-30: no delay outside the attempt range", arguments: [0, -1, 8, 100])
    func outOfRange(attempt: Int) {
        #expect(ReconnectPolicy.standard.delay(beforeAttempt: attempt) == nil)
    }
}

struct PlaybackClockTests {
    /// 40 ms at 24 kHz.
    private let buffer40ms = 960

    @Test("U-31: 2 buffers played + 15 ms into the 3rd → 95 ms")
    func cutMidThirdBuffer() {
        var clock = PlaybackClock()
        for _ in 0..<3 { clock.scheduled(itemID: "item_42", frames: buffer40ms) }
        clock.completedOldestBuffer()
        clock.completedOldestBuffer()

        #expect(clock.cut(framesIntoCurrentBuffer: 360) == PlaybackCut(itemID: "item_42", playedMs: 95))
    }

    @Test("U-32: reset clears everything; a new item starts at 0")
    func resetStartsFresh() {
        var clock = PlaybackClock()
        clock.scheduled(itemID: "a", frames: buffer40ms)
        clock.scheduled(itemID: "a", frames: buffer40ms)
        clock.completedOldestBuffer()
        clock.reset()

        #expect(clock.isDrained)
        #expect(clock.cut(framesIntoCurrentBuffer: 0) == nil)

        clock.scheduled(itemID: "b", frames: buffer40ms)
        #expect(clock.cut(framesIntoCurrentBuffer: 240) == PlaybackCut(itemID: "b", playedMs: 10))
    }

    @Test("Frames from a previous item don't count toward the next one")
    func itemsAreIndependent() {
        var clock = PlaybackClock()
        clock.scheduled(itemID: "a", frames: buffer40ms)
        clock.scheduled(itemID: "b", frames: buffer40ms)
        clock.scheduled(itemID: "b", frames: buffer40ms)
        clock.completedOldestBuffer() // a done
        clock.completedOldestBuffer() // first b done

        #expect(clock.cut(framesIntoCurrentBuffer: 0) == PlaybackCut(itemID: "b", playedMs: 40))
    }

    @Test("Queue underrun mid-item keeps the item's played time")
    func survivesUnderrun() {
        var clock = PlaybackClock()
        clock.scheduled(itemID: "a", frames: buffer40ms)
        clock.completedOldestBuffer()
        #expect(clock.isDrained)

        // The next delta for the same item arrives late.
        clock.scheduled(itemID: "a", frames: buffer40ms)
        #expect(clock.cut(framesIntoCurrentBuffer: 480) == PlaybackCut(itemID: "a", playedMs: 60))
    }

    @Test("Frames into the current buffer are clamped to the buffer length")
    func clampsProgress() {
        var clock = PlaybackClock()
        clock.scheduled(itemID: "a", frames: buffer40ms)
        #expect(clock.cut(framesIntoCurrentBuffer: 99_999)?.playedMs == 40)
        #expect(clock.cut(framesIntoCurrentBuffer: -5)?.playedMs == 0)
    }
}
