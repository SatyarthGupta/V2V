import AVFAudio
import Foundation
import Testing
@testable import V2Vfolder

struct PCMConverterTests {
    /// Builds a Float32 deinterleaved buffer holding a sine wave in every channel.
    private func sineBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: Int, frequency: Double, startFrame: Int) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                data[channel][frame] = Float(0.5 * sin(2 * .pi * frequency * Double(startFrame + frame) / sampleRate))
            }
        }
        return buffer
    }

    /// Streams `chunks` buffers of `framesPerChunk` through one converter; returns all output samples.
    private func convertStream(sampleRate: Double, channels: AVAudioChannelCount, framesPerChunk: Int, chunks: Int, frequency: Double) throws -> [Int16] {
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let converter = try PCMConverter(inputFormat: inputFormat)
        var output = Data()
        for chunk in 0..<chunks {
            let input = try sineBuffer(sampleRate: sampleRate, channels: channels, frames: framesPerChunk, frequency: frequency, startFrame: chunk * framesPerChunk)
            output.append(try converter.convert(input))
        }
        return output.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private func zeroCrossings(_ samples: [Int16]) -> Int {
        zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }

    @Test("U-33: 48 kHz stereo → 24 kHz mono, frame count halves, frequency preserved")
    func downsamplesSpeakerFormat() throws {
        // 50 chunks × 960 frames at 48 kHz = 1 second.
        let samples = try convertStream(sampleRate: 48_000, channels: 2, framesPerChunk: 960, chunks: 50, frequency: 1_000)

        // Resampler priming may hold back a few frames; allow a small tolerance.
        #expect(abs(samples.count - 24_000) <= 64)
        // A 1 kHz sine crosses zero ~2,000 times per second.
        #expect(abs(zeroCrossings(samples) - 2_000) <= 40)
        #expect(samples.contains { $0 > 10_000 }) // Amplitude survived (0.5 full-scale ≈ 16,384).
    }

    @Test("U-34: 16 kHz AirPods HFP → 24 kHz, frame count × 1.5")
    func upsamplesHFPFormat() throws {
        // 50 chunks × 320 frames at 16 kHz = 1 second.
        let samples = try convertStream(sampleRate: 16_000, channels: 1, framesPerChunk: 320, chunks: 50, frequency: 500)
        #expect(abs(samples.count - 24_000) <= 64)
        #expect(abs(zeroCrossings(samples) - 1_000) <= 30)
    }

    @Test("Playback decode maps PCM16 to Float32 at 24 kHz mono")
    func decodesPCM16() throws {
        let values: [Int16] = [0, 16_384, -32_768, 32_767]
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }

        let buffer = try #require(try PCMConverter.playbackBuffer(fromPCM16: data))
        #expect(buffer.format.sampleRate == 24_000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.frameLength == 4)

        let samples = try #require(buffer.floatChannelData)[0]
        #expect(samples[0] == 0)
        #expect(samples[1] == 0.5)
        #expect(samples[2] == -1)
        #expect(abs(samples[3] - 1) < 0.0001)
    }

    @Test("Empty or single-byte delta yields nothing to schedule", arguments: [Data(), Data([0x01])])
    func decodesEmpty(data: Data) throws {
        #expect(try PCMConverter.playbackBuffer(fromPCM16: data) == nil)
    }
}
