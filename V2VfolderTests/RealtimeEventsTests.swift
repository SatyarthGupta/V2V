import Foundation
import Testing
@testable import V2Vfolder

/// Loads JSON captured from the live Realtime API (token-server/scripts/capture-realtime-events.mjs).
private enum Fixture {
    private final class BundleToken {}

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"),
                               "Missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    static func event(_ name: String) throws -> ServerEvent {
        try ServerEvent.decode(data(name))
    }

    static let all = [
        "conversation.item.added", "conversation.item.done",
        "conversation.item.input_audio_transcription.completed", "conversation.item.input_audio_transcription.delta",
        "conversation.item.truncated", "error", "input_audio_buffer.committed",
        "input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "rate_limits.updated",
        "response.content_part.added", "response.content_part.done", "response.created", "response.done",
        "response.output_audio.delta", "response.output_audio.done",
        "response.output_audio_transcript.delta", "response.output_audio_transcript.done",
        "response.output_item.added", "response.output_item.done", "session.created", "session.updated",
    ]
}

/// Parses encoded JSON back into a plain object for structural comparison.
private func jsonObject(_ event: ClientEvent) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: event.jsonData()) as? NSDictionary)
}

struct ServerEventDecodingTests {
    @Test("U-35: every live fixture decodes without throwing", arguments: Fixture.all)
    func everyFixtureDecodes(name: String) throws {
        _ = try Fixture.event(name)
    }

    @Test("U-35: speech started/stopped carry the user item id")
    func speechEvents() throws {
        #expect(try Fixture.event("input_audio_buffer.speech_started")
                == .speechStarted(itemID: "item_EbXTql9s6TeSAfdkdpJG7", audioStartMs: 0))
        #expect(try Fixture.event("input_audio_buffer.speech_stopped")
                == .speechStopped(itemID: "item_EbXTql9s6TeSAfdkdpJG7"))
    }

    @Test("U-35: user transcription delta and completed")
    func inputTranscription() throws {
        #expect(try Fixture.event("conversation.item.input_audio_transcription.delta")
                == .inputTranscriptionDelta(itemID: "item_EbXTql9s6TeSAfdkdpJG7", delta: "Tell"))
        #expect(try Fixture.event("conversation.item.input_audio_transcription.completed")
                == .inputTranscriptionCompleted(itemID: "item_EbXTql9s6TeSAfdkdpJG7",
                                                transcript: "Tell me a long story about a dragon who learns to cook."))
    }

    @Test("U-35: response lifecycle with assistant audio + transcript")
    func responseLifecycle() throws {
        let response = "resp_EbXTtmgAUuOqZdsHdMk95"
        let item = "item_EbXTtxO9b5ERWTkn5CHfO"

        #expect(try Fixture.event("response.created") == .responseCreated(responseID: response))

        guard case .outputAudioDelta(let r, let i, let audio) = try Fixture.event("response.output_audio.delta") else {
            Issue.record("expected outputAudioDelta"); return
        }
        #expect(r == response && i == item)
        #expect(Data(base64Encoded: audio) != nil)

        #expect(try Fixture.event("response.output_audio.done") == .outputAudioDone(responseID: response, itemID: item))
        #expect(try Fixture.event("response.output_audio_transcript.delta")
                == .outputTranscriptDelta(responseID: response, itemID: item, delta: "Alright"))
        guard case .outputTranscriptDone(_, _, let transcript) = try Fixture.event("response.output_audio_transcript.done") else {
            Issue.record("expected outputTranscriptDone"); return
        }
        #expect(transcript.hasPrefix("Alright"))
    }

    @Test("U-35: barge-in → response.done cancelled with reason turn_detected")
    func cancelledByBargeIn() throws {
        #expect(try Fixture.event("response.done")
                == .responseDone(responseID: "resp_EbXTtmgAUuOqZdsHdMk95", status: .cancelled, reason: "turn_detected"))
    }

    @Test("U-35: conversation.item.truncated echoes the cut point")
    func truncated() throws {
        #expect(try Fixture.event("conversation.item.truncated")
                == .itemTruncated(itemID: "item_EbXTtxO9b5ERWTkn5CHfO", audioEndMs: 600))
    }

    @Test("U-35: error is nested under \"error\" and keeps the client event id")
    func errorEvent() throws {
        #expect(try Fixture.event("error") == .error(RealtimeServerError(
            type: "invalid_request_error",
            code: "item_truncate_invalid_item_id",
            message: "Item with item_id not found: item_does_not_exist",
            clientEventID: "evt_client_1")))
    }

    @Test("session.created exposes expires_at (for E11 max session length)")
    func sessionCreatedExpiry() throws {
        guard case .sessionCreated(let expiresAt) = try Fixture.event("session.created") else {
            Issue.record("expected sessionCreated"); return
        }
        #expect((expiresAt ?? 0) > 1_700_000_000)
        #expect(try Fixture.event("session.updated") == .sessionUpdated)
    }

    @Test("U-35: events the app ignores decode as .unknown", arguments: [
        "rate_limits.updated", "response.output_item.added", "conversation.item.added", "input_audio_buffer.committed",
    ])
    func ignoredEventsAreUnknown(name: String) throws {
        #expect(try Fixture.event(name) == .unknown(type: name))
    }

    @Test("U-35: a brand-new event type decodes as .unknown instead of throwing")
    func futureEventType() throws {
        let data = Data(#"{"type":"response.something_new","event_id":"e1","foo":1}"#.utf8)
        #expect(try ServerEvent.decode(data) == .unknown(type: "response.something_new"))
    }

    @Test("Unknown response status is preserved")
    func unknownStatus() {
        #expect(ResponseStatus("paused") == .other("paused"))
        #expect(ResponseStatus("completed") == .completed)
    }
}

struct ClientEventEncodingTests {
    @Test("U-36: session.update matches docs/LLD.md §6 exactly")
    func sessionUpdateGolden() throws {
        let config = RealtimeSessionConfig(instructions: "Be brief.", voice: "marin", outputIsBuiltInSpeaker: false)
        let expected: NSDictionary = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": "gpt-realtime-2.1",
                "instructions": "Be brief.",
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "noise_reduction": ["type": "near_field"],
                        "transcription": ["model": "gpt-4o-mini-transcribe"],
                        "turn_detection": ["type": "semantic_vad", "eagerness": "auto",
                                           "interrupt_response": true, "create_response": true],
                    ],
                    "output": ["format": ["type": "audio/pcm", "rate": 24000], "voice": "marin"],
                ],
            ],
        ]
        #expect(try jsonObject(.sessionUpdate(config)) == expected)
    }

    @Test("U-37: built-in speaker → far_field, otherwise near_field")
    func noiseReductionByRoute() {
        #expect(RealtimeSessionConfig(instructions: "", voice: "marin", outputIsBuiltInSpeaker: true).noiseReduction == .farField)
        #expect(RealtimeSessionConfig(instructions: "", voice: "marin", outputIsBuiltInSpeaker: false).noiseReduction == .nearField)
    }

    @Test("input_audio_buffer.append carries base64 audio")
    func append() throws {
        #expect(try jsonObject(.inputAudioAppend(audio: "AAAA")) == ["type": "input_audio_buffer.append", "audio": "AAAA"])
    }

    @Test("conversation.item.truncate uses snake_case fields")
    func truncate() throws {
        #expect(try jsonObject(.truncate(itemID: "item_1", contentIndex: 0, audioEndMs: 1840)) == [
            "type": "conversation.item.truncate", "item_id": "item_1", "content_index": 0, "audio_end_ms": 1840,
        ])
    }

    @Test("response.create and response.cancel have no payload")
    func bareEvents() throws {
        #expect(try jsonObject(.responseCreate) == ["type": "response.create"])
        #expect(try jsonObject(.responseCancel) == ["type": "response.cancel"])
    }

    @Test("Seeded turns: user → input_text, assistant → output_text")
    func seedItems() throws {
        #expect(try jsonObject(.conversationItemCreate(role: .user, text: "hi")) == [
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
        ])
        #expect(try jsonObject(.conversationItemCreate(role: .assistant, text: "hello")) == [
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "hello"]]],
        ])
    }
}
