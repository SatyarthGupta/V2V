import AVFAudio
import Foundation
import OSLog

/// Where audio is going right now (shown in the debug overlay, D-022).
nonisolated struct AudioRoute: Equatable, Sendable {
    let outputName: String
    let isBuiltInSpeaker: Bool
    let isBluetooth: Bool
    /// Audio leaves the phone (Bluetooth, wired headphones, CarPlay…), not the built-in speaker or earpiece.
    let isExternal: Bool

    init(outputName: String, isBuiltInSpeaker: Bool, isBluetooth: Bool, isExternal: Bool? = nil) {
        self.outputName = outputName
        self.isBuiltInSpeaker = isBuiltInSpeaker
        self.isBluetooth = isBluetooth
        self.isExternal = isExternal ?? (isBluetooth || !isBuiltInSpeaker)
    }

    static let unknown = AudioRoute(outputName: "Unknown", isBuiltInSpeaker: false, isBluetooth: false, isExternal: false)
}

/// A phone call, Siri or an alarm taking over the audio session (PRD E5).
nonisolated enum AudioInterruption: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case system
        case routeDisconnected
        case builtInMicMuted
    }

    case began(Kind)
    case ended(shouldResume: Bool)
}

/// AirPods connected/disconnected and similar (PRD E4).
nonisolated struct RouteChange: Equatable, Sendable {
    nonisolated enum Reason: Equatable, Sendable {
        case newDeviceAvailable
        case oldDeviceUnavailable
        case categoryChange
        case override
        case other
    }

    let reason: Reason
    let route: AudioRoute
}

nonisolated protocol AudioSessionManaging: Sendable {
    func configureAndActivate() throws
    func deactivate()
    func currentRoute() -> AudioRoute
    /// Moves output from the quiet earpiece to the loudspeaker. Voice processing can switch
    /// the route to the receiver even with `.defaultToSpeaker`. Headphones and AirPods are left alone.
    func routeToSpeakerIfOnReceiver()
    func interruptions() -> AsyncStream<AudioInterruption>
    func routeChanges() -> AsyncStream<RouteChange>
    func mediaServicesWereReset() -> AsyncStream<Void>
}

/// Wraps `AVAudioSession` for a two-way voice conversation (docs/LLD.md §4.1, D-003, D-008).
nonisolated struct AudioSessionManager: AudioSessionManaging {
    private var session: AVAudioSession { .sharedInstance() }

    func configureAndActivate() throws {
        // .voiceChat pairs with voice processing for echo cancellation (D-003).
        // HFP lets AirPods act as the mic; defaultToSpeaker avoids the quiet earpiece.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func currentRoute() -> AudioRoute {
        Self.route(from: session.currentRoute)
    }

    func routeToSpeakerIfOnReceiver() {
        let outputs = session.currentRoute.outputs.map(\.portType)
        guard outputs.contains(.builtInReceiver) else {
            Log.audio.info("output route: \(outputs.map(\.rawValue), privacy: .public)")
            return
        }
        do {
            try session.overrideOutputAudioPort(.speaker)
            Log.audio.info("output was on the earpiece → switched to the loudspeaker")
        } catch {
            Log.audio.error("speaker override failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// iOS 27 interruption API: the session going inactive (began) and the system's
    /// resumption recommendation (ended). Replaces the deprecated interruptionNotification.
    func interruptions() -> AsyncStream<AudioInterruption> {
        let began = Self.stream(of: AVAudioSession.didBecomeInactiveNotification) { notification -> AudioInterruption? in
            guard let context = notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext else {
                return nil
            }
            return Self.interruptionBegan(source: context.source, reason: context.interruptionContext?.reason)
        }
        let ended = Self.stream(of: AVAudioSession.resumptionRecommendationNotification) { notification -> AudioInterruption? in
            guard let context = notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else {
                return nil
            }
            return Self.interruptionEnded(recommendation: context.recommendation)
        }
        return Self.merge(began, ended)
    }

    func routeChanges() -> AsyncStream<RouteChange> {
        Self.stream(of: AVAudioSession.routeChangeNotification) { notification in
            let reason = Self.parseRouteChangeReason(notification.userInfo)
            return RouteChange(reason: reason, route: Self.route(from: AVAudioSession.sharedInstance().currentRoute))
        }
    }

    func mediaServicesWereReset() -> AsyncStream<Void> {
        Self.stream(of: AVAudioSession.mediaServicesWereResetNotification) { _ in () }
    }

    // MARK: - Parsing (pure, unit-tested)

    /// The session went inactive. Our own `setActive(false)` (source `.app`) isn't an interruption.
    static func interruptionBegan(source: AVAudioSession.DeactivationSource,
                                  reason: AVAudioSession.InterruptionReason?) -> AudioInterruption? {
        guard source == .system else { return nil }
        let kind: AudioInterruption.Kind = switch reason {
        case .routeDisconnected: .routeDisconnected
        case .builtInMicMuted: .builtInMicMuted
        default: .system
        }
        return .began(kind)
    }

    static func interruptionEnded(recommendation: AVAudioSession.ResumptionRecommendation) -> AudioInterruption {
        .ended(shouldResume: recommendation == .shouldResume)
    }

    static func parseRouteChangeReason(_ userInfo: [AnyHashable: Any]?) -> RouteChange.Reason {
        guard let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return .other }
        switch reason {
        case .newDeviceAvailable: return .newDeviceAvailable
        case .oldDeviceUnavailable: return .oldDeviceUnavailable
        case .categoryChange: return .categoryChange
        case .override: return .override
        default: return .other
        }
    }

    static func route(from description: AVAudioSessionRouteDescription) -> AudioRoute {
        guard let output = description.outputs.first else { return .unknown }
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
        let builtIn: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver]
        return AudioRoute(outputName: output.portName,
                          isBuiltInSpeaker: output.portType == .builtInSpeaker,
                          isBluetooth: bluetooth.contains(output.portType),
                          isExternal: !builtIn.contains(output.portType))
    }

    /// Interleaves two streams into one; finishes when both finish or the consumer stops.
    private static func merge<T: Sendable>(_ first: AsyncStream<T>, _ second: AsyncStream<T>) -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await value in first { continuation.yield(value) } }
                    group.addTask { for await value in second { continuation.yield(value) } }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Turns a notification into an AsyncStream of parsed, Sendable values. Ends when the consumer stops.
    private static func stream<T: Sendable>(of name: Notification.Name, parse: @escaping @Sendable (Notification) -> T?) -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task {
                for await notification in NotificationCenter.default.notifications(named: name) {
                    if let value = parse(notification) { continuation.yield(value) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
