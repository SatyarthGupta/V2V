import AVFAudio
import Testing
@testable import V2Vfolder

struct AudioSessionParsingTests {
    @Test("System deactivation (phone call, Siri) → .began(.system)")
    func callBegan() {
        #expect(AudioSessionManager.interruptionBegan(source: .system, reason: nil) == .began(.system))
        #expect(AudioSessionManager.interruptionBegan(source: .system, reason: .default) == .began(.system))
    }

    @Test("Our own setActive(false) is not an interruption")
    func appDeactivationIgnored() {
        #expect(AudioSessionManager.interruptionBegan(source: .app, reason: nil) == nil)
        #expect(AudioSessionManager.interruptionBegan(source: .app, reason: .default) == nil)
    }

    @Test("Special interruption reasons are preserved")
    func reasons() {
        #expect(AudioSessionManager.interruptionBegan(source: .system, reason: .routeDisconnected) == .began(.routeDisconnected))
        #expect(AudioSessionManager.interruptionBegan(source: .system, reason: .builtInMicMuted) == .began(.builtInMicMuted))
    }

    @Test("Resumption recommendation → ended(shouldResume:)")
    func ended() {
        #expect(AudioSessionManager.interruptionEnded(recommendation: .shouldResume) == .ended(shouldResume: true))
        #expect(AudioSessionManager.interruptionEnded(recommendation: .shouldNotResume) == .ended(shouldResume: false))
    }

    @Test("Route change reasons map; unknown → .other", arguments: [
        (AVAudioSession.RouteChangeReason.newDeviceAvailable, RouteChange.Reason.newDeviceAvailable),
        (.oldDeviceUnavailable, .oldDeviceUnavailable),
        (.categoryChange, .categoryChange),
        (.override, .override),
        (.wakeFromSleep, .other),
        (.routeConfigurationChange, .other),
    ])
    func routeReasons(raw: AVAudioSession.RouteChangeReason, expected: RouteChange.Reason) {
        #expect(AudioSessionManager.parseRouteChangeReason([AVAudioSessionRouteChangeReasonKey: raw.rawValue]) == expected)
    }

    @Test("Missing or malformed route reason → .other")
    func missingRouteReason() {
        #expect(AudioSessionManager.parseRouteChangeReason(nil) == .other)
        #expect(AudioSessionManager.parseRouteChangeReason([AVAudioSessionRouteChangeReasonKey: "x"]) == .other)
    }
}
