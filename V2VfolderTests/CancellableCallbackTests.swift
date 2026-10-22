import Foundation
import Testing
@testable import V2Vfolder

struct CancellableCallbackTests {
    @Test("Resumes when the callback fires")
    func callbackSucceeds() async throws {
        try await cancellableCallback { resume in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { resume(nil) }
        }
    }

    @Test("Propagates the callback's error")
    func callbackFails() async {
        await #expect(throws: URLError(.networkConnectionLost)) {
            try await cancellableCallback { resume in resume(URLError(.networkConnectionLost)) }
        }
    }

    @Test("A callback that never fires still times out promptly (ping with no pong)")
    func neverCalledBackTimesOut() async {
        let started = ContinuousClock.now
        await #expect(throws: TimeoutError(duration: .milliseconds(50))) {
            try await withTimeout(.milliseconds(50)) {
                try await cancellableCallback { _ in /* never calls back */ }
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("Late callback after cancellation is ignored (no double resume crash)")
    func lateCallbackIgnored() async {
        let task = Task {
            try await cancellableCallback { resume in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { resume(nil) }
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try? await Task.sleep(for: .milliseconds(100)) // let the late callback fire
    }
}
