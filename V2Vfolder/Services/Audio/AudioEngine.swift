import AVFAudio
import Foundation
import OSLog

nonisolated protocol AudioEngineProtocol: AnyObject, Sendable {
    /// Mic audio as Realtime PCM16 24 kHz mono chunks.
    var micChunks: AsyncStream<Data> { get }
    /// Fires when all scheduled AI audio has finished playing.
    var playbackDrained: AsyncStream<Void> { get }
    /// Fires when the hardware configuration changed and the engine stopped itself (D-010).
    var configurationChanges: AsyncStream<Void> { get }
    /// True while AI audio is scheduled or playing.
    var isPlaying: Bool { get }

    func start() throws
    func stop()
    /// Rebuilds the graph for the current route (AirPods ↔ speaker). Drops queued playback;
    /// call `flushPlayback()` first if you need the cut point.
    func rebuildForCurrentRoute() throws
    func enqueue(pcm16: Data, itemID: String)
    /// Stops AI audio immediately (barge-in, D-004) and reports how much of the current item was heard.
    func flushPlayback() -> PlaybackCut?
    func setMicMuted(_ muted: Bool)
}

/// One AVAudioEngine for capture *and* playback, so Apple's voice processing can cancel
/// the AI's own voice from the mic (D-003). Create one per conversation.
nonisolated final class AudioEngine: AudioEngineProtocol, @unchecked Sendable {
    let micChunks: AsyncStream<Data>
    let playbackDrained: AsyncStream<Void>
    let configurationChanges: AsyncStream<Void>

    private let micContinuation: AsyncStream<Data>.Continuation
    private let drainedContinuation: AsyncStream<Void>.Continuation
    private let configContinuation: AsyncStream<Void>.Continuation

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configObserver: NSObjectProtocol?

    // State below is shared with audio callbacks; guarded by `lock`.
    private let lock = NSLock()
    private var clock = PlaybackClock(sampleRate: RealtimeAudioFormat.sampleRate)
    /// Bumped on every flush/stop so completion callbacks from discarded buffers are ignored.
    private var generation = 0
    /// Player timeline position (24 kHz frames) where the buffer now playing started.
    private var headStartFrame: Double = 0
    private var converter: PCMConverter?
    private var isMuted = false
    private var isRunning = false
    private var micChunkCount = 0
    private var micDropCount = 0

    init() {
        (micChunks, micContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(50))
        (playbackDrained, drainedContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        (configurationChanges, configContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        engine.attach(player)

        let configContinuation = configContinuation
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            // iOS stops the engine itself here (e.g. right after voice processing reconfigures the hardware).
            Log.audio.info("engine configuration changed → needs rebuild")
            configContinuation.yield()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        micContinuation.finish()
        drainedContinuation.finish()
        configContinuation.finish()
    }

    var isPlaying: Bool {
        lock.withLock { !clock.isDrained }
    }

    // MARK: - Lifecycle

    func start() throws {
        #if !targetEnvironment(simulator)
        // Echo cancellation + noise suppression for the engine's own I/O pair (D-003).
        // Must be enabled while the engine is stopped and before reading the input format.
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            throw SessionError.audioEngineFailed("voice processing: \(error.localizedDescription)")
        }
        engine.inputNode.isVoiceProcessingAGCEnabled = true
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            .init(enableAdvancedDucking: true, duckingLevel: .min)
        #endif

        try configureGraph()
        try startEngine()
    }

    func stop() {
        lock.withLock {
            generation += 1
            clock.reset()
            isRunning = false
        }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func rebuildForCurrentRoute() throws {
        lock.withLock {
            generation += 1
            clock.reset()
            headStartFrame = 0
        }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try configureGraph()
        try startEngine()
    }

    private func startEngine() throws {
        engine.prepare()
        do {
            try engine.start()
            try player.playAudio()
        } catch {
            throw SessionError.audioEngineFailed("engine start: \(error.localizedDescription)")
        }
        lock.withLock {
            isRunning = true
            headStartFrame = 0
        }
        Log.audio.info("engine started: running=\(self.engine.isRunning, privacy: .public) playerPlaying=\(self.player.isPlaying, privacy: .public)")
    }

    /// (Re)connects the player and installs the mic tap for the current hardware format.
    private func configureGraph() throws {
        let playbackFormat = try RealtimeAudioFormat.playback()
        do {
            try engine.connectNode(player, to: engine.mainMixerNode, format: playbackFormat)
        } catch {
            throw SessionError.audioEngineFailed("connect player: \(error.localizedDescription)")
        }

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 1) else {
            throw SessionError.audioEngineFailed("no usable input (\(hardwareFormat))")
        }

        // Voice processing can report several input channels; we only send channel 0.
        let converter = try PCMConverter(inputFormat: monoFormat)
        lock.withLock {
            self.converter = converter
            micChunkCount = 0
            micDropCount = 0
        }
        Log.audio.info("""
            graph configured: input \(hardwareFormat.sampleRate, privacy: .public) Hz \
            \(hardwareFormat.channelCount, privacy: .public) ch \
            commonFormat=\(hardwareFormat.commonFormat.rawValue, privacy: .public) \
            interleaved=\(hardwareFormat.isInterleaved, privacy: .public) \
            voiceProcessing=\(input.isVoiceProcessingEnabled, privacy: .public)
            """)

        input.removeTap(onBus: 0)
        // 100 ms chunks: the smallest tap size the system honours.
        let frames = AVAudioFrameCount(hardwareFormat.sampleRate * 0.1)
        do {
            try input.installAudioTap(onBus: 0, bufferSize: frames, format: hardwareFormat) { [weak self] buffer, _ in
                self?.handleMic(buffer)
            }
        } catch {
            throw SessionError.audioEngineFailed("mic tap: \(error.localizedDescription)")
        }
    }

    // MARK: - Mic

    private func handleMic(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let (converter, muted) = lock.withLock { (self.converter, isMuted) }
        guard !muted, let converter else { return }
        guard let mono = Self.firstChannel(of: buffer, as: converter.inputFormat),
              let data = try? converter.convert(mono), !data.isEmpty else {
            let drops = lock.withLock { micDropCount += 1; return micDropCount }
            if drops == 1 || drops.isMultiple(of: 50) {
                Log.audio.error("mic buffer dropped (\(drops, privacy: .public) so far): format \(buffer.format, privacy: .public)")
            }
            return
        }
        let count = lock.withLock { micChunkCount += 1; return micChunkCount }
        if count == 1 || count.isMultiple(of: 50) {
            Log.audio.info("mic chunks sent: \(count, privacy: .public) (\(data.count, privacy: .public) bytes each)")
        }
        micContinuation.yield(data)
    }

    func setMicMuted(_ muted: Bool) {
        lock.withLock { isMuted = muted }
        #if !targetEnvironment(simulator)
        engine.inputNode.isVoiceProcessingInputMuted = muted
        #endif
    }

    /// Copies channel 0 of the read-only tap buffer into a mono Float32 buffer for the converter.
    /// Voice processing may deliver Float32, Int16 or Int32 samples depending on the device and route.
    private static func firstChannel(of buffer: AVReadOnlyAudioPCMBuffer, as monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channel = buffer.channelData(0)
        let count: Int = switch channel {
        case .float(let samples): samples.count
        case .int16(let samples): samples.count
        case .int32(let samples): samples.count
        @unknown default: 0
        }
        guard count > 0,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(count)),
              let destination = mono.floatChannelData?[0] else { return nil }

        switch channel {
        case .float(let samples):
            for index in 0..<count { destination[index] = samples[index] }
        case .int16(let samples):
            for index in 0..<count { destination[index] = Float(samples[index]) / 32_768 }
        case .int32(let samples):
            for index in 0..<count { destination[index] = Float(samples[index]) / 2_147_483_648 }
        @unknown default:
            return nil
        }
        mono.frameLength = AVAudioFrameCount(count)
        return mono
    }

    // MARK: - Playback

    func enqueue(pcm16: Data, itemID: String) {
        guard let buffer = try? PCMConverter.playbackBuffer(fromPCM16: pcm16) else { return }
        let scheduledGeneration: Int = lock.withLock {
            // Starting from an empty queue (first delta or an underrun): this buffer starts now.
            if clock.isDrained { headStartFrame = currentFrame() }
            clock.scheduled(itemID: itemID, frames: Int(buffer.frameLength))
            return generation
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferFinished(generation: scheduledGeneration)
        }
        if !player.isPlaying { try? player.playAudio() }
    }

    func flushPlayback() -> PlaybackCut? {
        let cut: PlaybackCut? = lock.withLock {
            let framesIntoHead = Int((currentFrame() - headStartFrame).rounded())
            let cut = clock.cut(framesIntoCurrentBuffer: framesIntoHead)
            clock.reset()
            generation += 1
            return cut
        }
        // Outside the lock: stop() may call completion handlers, which take the lock.
        // stop() discards every scheduled buffer at once; that's the instant barge-in.
        player.stop()
        let running = lock.withLock {
            headStartFrame = 0
            return isRunning
        }
        if running { try? player.playAudio() }
        return cut
    }

    private func bufferFinished(generation finishedGeneration: Int) {
        let drained: Bool = lock.withLock {
            guard finishedGeneration == generation else { return false }
            clock.completedOldestBuffer()
            headStartFrame = currentFrame()
            return clock.isDrained
        }
        if drained {
            Log.audio.info("playback drained")
            drainedContinuation.yield()
        }
    }

    /// Player timeline position in 24 kHz frames. Call with `lock` held.
    private func currentFrame() -> Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return 0 }
        return Double(playerTime.sampleTime) * RealtimeAudioFormat.sampleRate / playerTime.sampleRate
    }
}
