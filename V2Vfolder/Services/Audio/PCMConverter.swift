import AVFAudio
import Foundation

nonisolated enum PCMConverterError: Error, Equatable {
    case unsupportedFormat
    case bufferAllocationFailed
    case conversionFailed(String)
}

/// The Realtime API's audio format both ways: PCM16 little-endian, 24 kHz, mono (D-016).
nonisolated enum RealtimeAudioFormat {
    static let sampleRate: Double = 24_000

    /// Wire format for `input_audio_buffer.append` / `response.output_audio.delta`.
    static func wire() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw PCMConverterError.unsupportedFormat
        }
        return format
    }

    /// Float format for scheduling on `AVAudioPlayerNode`.
    static func playback() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw PCMConverterError.unsupportedFormat
        }
        return format
    }
}

/// Converts microphone buffers (hardware format: 48 kHz speaker, 16 kHz AirPods HFP, …)
/// into Realtime wire PCM16. Recreate it on every route change (D-010).
///
/// Not thread-safe: use from the single audio tap callback only.
nonisolated final class PCMConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(inputFormat: AVAudioFormat) throws {
        let outputFormat = try RealtimeAudioFormat.wire()
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PCMConverterError.unsupportedFormat
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// Converts one tap buffer to PCM16 bytes. The converter keeps resampler state between
    /// calls (it's fed with `.noDataNow`, not end-of-stream), so a continuous stream stays seamless.
    func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw PCMConverterError.bufferAllocationFailed
        }

        var inputConsumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputConsumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error {
            throw PCMConverterError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        }
        guard let samples = output.int16ChannelData else {
            throw PCMConverterError.conversionFailed("missing int16 channel data")
        }
        return Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    /// Decodes Realtime PCM16 bytes into a Float32 buffer ready for `AVAudioPlayerNode`.
    /// Returns `nil` for a delta with no samples (there's nothing to schedule).
    static func playbackBuffer(fromPCM16 data: Data) throws -> AVAudioPCMBuffer? {
        let format = try RealtimeAudioFormat.playback()
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else {
            throw PCMConverterError.bufferAllocationFailed
        }
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frameCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}
