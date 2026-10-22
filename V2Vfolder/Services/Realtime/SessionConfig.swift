import Foundation

/// The `session` object of `session.update` (docs/LLD.md §6).
/// Verified against live `session.updated`: the server echoes these values back.
nonisolated struct RealtimeSessionConfig: Encodable, Equatable, Sendable {
    nonisolated enum NoiseReduction: String, Sendable {
        /// AirPods, wired headsets, receiver.
        case nearField = "near_field"
        /// Built-in speaker: the mic is farther from the mouth and hears the room (D-003).
        case farField = "far_field"
    }

    static let model = "gpt-realtime-2.1"
    static let transcriptionModel = "gpt-4o-mini-transcribe"

    let instructions: String
    let voice: String
    let noiseReduction: NoiseReduction

    /// `instructions` and `voice` come from the token server's response (D-020).
    init(instructions: String, voice: String, outputIsBuiltInSpeaker: Bool) {
        self.instructions = instructions
        self.voice = voice
        self.noiseReduction = outputIsBuiltInSpeaker ? .farField : .nearField
    }

    func encode(to encoder: Encoder) throws {
        let pcm = Format(type: "audio/pcm", rate: Int(RealtimeAudioFormat.sampleRate))
        let session = Session(
            type: "realtime",
            model: Self.model,
            instructions: instructions,
            output_modalities: ["audio"],
            audio: .init(
                input: .init(
                    format: pcm,
                    noise_reduction: .init(type: noiseReduction.rawValue),
                    transcription: .init(model: Self.transcriptionModel),
                    turn_detection: .init(type: "semantic_vad", eagerness: "auto",
                                          interrupt_response: true, create_response: true)
                ),
                output: .init(format: pcm, voice: voice)
            )
        )
        try session.encode(to: encoder)
    }

    // Wire shapes; property names match the API's snake_case keys exactly.
    private struct Format: Encodable { let type: String; let rate: Int }
    private struct TypeOnly: Encodable { let type: String }
    private struct Transcription: Encodable { let model: String }
    private struct TurnDetection: Encodable {
        let type: String
        let eagerness: String
        let interrupt_response: Bool
        let create_response: Bool
    }
    private struct Input: Encodable {
        let format: Format
        let noise_reduction: TypeOnly
        let transcription: Transcription
        let turn_detection: TurnDetection
    }
    private struct Output: Encodable { let format: Format; let voice: String }
    private struct Audio: Encodable { let input: Input; let output: Output }
    private struct Session: Encodable {
        let type: String
        let model: String
        let instructions: String
        let output_modalities: [String]
        let audio: Audio
    }
}
