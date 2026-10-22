import Foundation

// Realtime API (GA) events used by the app. Field names were verified against live
// `gpt-realtime-2.1` traffic; fixtures are in V2VfolderTests/Fixtures/Realtime.

// MARK: - Client → server

nonisolated enum ClientEvent: Encodable, Equatable, Sendable {
    case sessionUpdate(RealtimeSessionConfig)
    /// Base64 PCM16 24 kHz mono.
    case inputAudioAppend(audio: String)
    /// Trims the unheard part of an assistant item after a barge-in (D-004).
    case truncate(itemID: String, contentIndex: Int, audioEndMs: Int)
    /// Asks the model to speak now (used for the greeting, PRD F10).
    case responseCreate
    case responseCancel
    /// Replays a transcript turn as text into a fresh session after reconnect (D-011).
    case conversationItemCreate(role: TranscriptTurn.Role, text: String)

    var type: String {
        switch self {
        case .sessionUpdate: "session.update"
        case .inputAudioAppend: "input_audio_buffer.append"
        case .truncate: "conversation.item.truncate"
        case .responseCreate: "response.create"
        case .responseCancel: "response.cancel"
        case .conversationItemCreate: "conversation.item.create"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, session, audio, item
        case itemID = "item_id"
        case contentIndex = "content_index"
        case audioEndMs = "audio_end_ms"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .sessionUpdate(let session):
            try container.encode(session, forKey: .session)
        case .inputAudioAppend(let audio):
            try container.encode(audio, forKey: .audio)
        case .truncate(let itemID, let contentIndex, let audioEndMs):
            try container.encode(itemID, forKey: .itemID)
            try container.encode(contentIndex, forKey: .contentIndex)
            try container.encode(audioEndMs, forKey: .audioEndMs)
        case .responseCreate, .responseCancel:
            break
        case .conversationItemCreate(let role, let text):
            try container.encode(ConversationItem(role: role, text: text), forKey: .item)
        }
    }

    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// `conversation.item.create` payload: a text message. User text is `input_text`, assistant text is `output_text`.
nonisolated private struct ConversationItem: Encodable {
    struct Content: Encodable {
        let type: String
        let text: String
    }

    let type = "message"
    let role: String
    let content: [Content]

    init(role: TranscriptTurn.Role, text: String) {
        self.role = role.rawValue
        self.content = [Content(type: role == .user ? "input_text" : "output_text", text: text)]
    }
}

// MARK: - Server → client

nonisolated enum ResponseStatus: Equatable, Sendable {
    case completed, cancelled, failed, incomplete, inProgress
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "completed": self = .completed
        case "cancelled": self = .cancelled
        case "failed": self = .failed
        case "incomplete": self = .incomplete
        case "in_progress": self = .inProgress
        default: self = .other(raw)
        }
    }
}

nonisolated struct RealtimeServerError: Equatable, Sendable {
    let type: String
    let code: String?
    let message: String
    /// The client `event_id` that caused the error, if we sent one.
    let clientEventID: String?
}

nonisolated enum ServerEvent: Equatable, Sendable {
    case sessionCreated(expiresAt: Int?)
    case sessionUpdated
    case speechStarted(itemID: String, audioStartMs: Int)
    case speechStopped(itemID: String)
    case inputTranscriptionDelta(itemID: String, delta: String)
    case inputTranscriptionCompleted(itemID: String, transcript: String)
    case responseCreated(responseID: String)
    /// Base64 PCM16 24 kHz mono.
    case outputAudioDelta(responseID: String, itemID: String, audio: String)
    case outputAudioDone(responseID: String, itemID: String)
    case outputTranscriptDelta(responseID: String, itemID: String, delta: String)
    case outputTranscriptDone(responseID: String, itemID: String, transcript: String)
    /// `reason` is e.g. "turn_detected" when cancelled by a barge-in.
    case responseDone(responseID: String, status: ResponseStatus, reason: String?)
    case itemTruncated(itemID: String, audioEndMs: Int)
    case error(RealtimeServerError)
    /// Any event the app doesn't act on (rate_limits.updated, output_item.added, …).
    case unknown(type: String)
}

extension ServerEvent: Decodable {
    private enum Keys: String, CodingKey {
        case type, delta, transcript, response, session, error
        case itemID = "item_id"
        case responseID = "response_id"
        case audioStartMs = "audio_start_ms"
        case audioEndMs = "audio_end_ms"
    }

    private struct ResponsePayload: Decodable {
        struct StatusDetails: Decodable { let reason: String? }
        let id: String
        let status: String
        let status_details: StatusDetails?
    }

    private struct SessionPayload: Decodable {
        let expires_at: Int?
    }

    private struct ErrorPayload: Decodable {
        let type: String
        let code: String?
        let message: String
        let event_id: String?
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)

        switch type {
        case "session.created":
            let session = try c.decodeIfPresent(SessionPayload.self, forKey: .session)
            self = .sessionCreated(expiresAt: session?.expires_at)
        case "session.updated":
            self = .sessionUpdated
        case "input_audio_buffer.speech_started":
            self = .speechStarted(itemID: try c.decode(String.self, forKey: .itemID),
                                  audioStartMs: try c.decode(Int.self, forKey: .audioStartMs))
        case "input_audio_buffer.speech_stopped":
            self = .speechStopped(itemID: try c.decode(String.self, forKey: .itemID))
        case "conversation.item.input_audio_transcription.delta":
            self = .inputTranscriptionDelta(itemID: try c.decode(String.self, forKey: .itemID),
                                            delta: try c.decode(String.self, forKey: .delta))
        case "conversation.item.input_audio_transcription.completed":
            self = .inputTranscriptionCompleted(itemID: try c.decode(String.self, forKey: .itemID),
                                                transcript: try c.decode(String.self, forKey: .transcript))
        case "response.created":
            self = .responseCreated(responseID: try c.decode(ResponsePayload.self, forKey: .response).id)
        case "response.output_audio.delta":
            self = .outputAudioDelta(responseID: try c.decode(String.self, forKey: .responseID),
                                     itemID: try c.decode(String.self, forKey: .itemID),
                                     audio: try c.decode(String.self, forKey: .delta))
        case "response.output_audio.done":
            self = .outputAudioDone(responseID: try c.decode(String.self, forKey: .responseID),
                                    itemID: try c.decode(String.self, forKey: .itemID))
        case "response.output_audio_transcript.delta":
            self = .outputTranscriptDelta(responseID: try c.decode(String.self, forKey: .responseID),
                                          itemID: try c.decode(String.self, forKey: .itemID),
                                          delta: try c.decode(String.self, forKey: .delta))
        case "response.output_audio_transcript.done":
            self = .outputTranscriptDone(responseID: try c.decode(String.self, forKey: .responseID),
                                         itemID: try c.decode(String.self, forKey: .itemID),
                                         transcript: try c.decode(String.self, forKey: .transcript))
        case "response.done":
            let response = try c.decode(ResponsePayload.self, forKey: .response)
            self = .responseDone(responseID: response.id, status: ResponseStatus(response.status),
                                 reason: response.status_details?.reason)
        case "conversation.item.truncated":
            self = .itemTruncated(itemID: try c.decode(String.self, forKey: .itemID),
                                  audioEndMs: try c.decode(Int.self, forKey: .audioEndMs))
        case "error":
            let error = try c.decode(ErrorPayload.self, forKey: .error)
            self = .error(RealtimeServerError(type: error.type, code: error.code,
                                              message: error.message, clientEventID: error.event_id))
        default:
            self = .unknown(type: type)
        }
    }

    nonisolated static func decode(_ data: Data) throws -> ServerEvent {
        try JSONDecoder().decode(ServerEvent.self, from: data)
    }
}
