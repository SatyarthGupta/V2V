# LLD — V2V Speech-to-Speech App

Related: [HLD](HLD.md) · [Test Cases](TEST_CASES.md) · [Decisions](DECISIONS.md)

> Verify Realtime event names against the OpenAI Realtime reference when implementing. Names here follow the GA API (`response.output_audio.delta`, `session.audio.output.voice`, …).

## 1. iOS module layout

```
V2Vfolder/
├── App/
│   ├── V2VApp.swift                 // @main, ModelContainer, DI composition root
│   └── AppDependencies.swift        // builds live services; tests build fakes
├── Models/
│   ├── SessionState.swift
│   ├── TranscriptTurn.swift         // value type for live UI
│   ├── Persona.swift                // enum quick/storyteller/coach: name, subtitle, voice (no prompts)
│   └── Persistence/Conversation.swift, Turn.swift   // SwiftData @Model
├── Domain/
│   ├── VoiceSessionController.swift // state machine (actor-isolated @MainActor class)
│   ├── ReconnectPolicy.swift        // backoff schedule, pure
│   └── PlaybackClock.swift          // played-ms accounting, pure
├── Services/
│   ├── Realtime/
│   │   ├── RealtimeClient.swift     // protocol + URLSessionWebSocketTask impl (actor)
│   │   ├── RealtimeEvents.swift     // Codable client/server events
│   │   └── SessionConfig.swift      // session.update payload builder
│   ├── Audio/
│   │   ├── AudioEngine.swift        // protocol + AVAudioEngine impl
│   │   ├── PCMConverter.swift       // hw format ⇄ PCM16 24 kHz mono
│   │   └── AudioSessionManager.swift// category, routes, interruptions
│   ├── TokenService.swift
│   ├── PermissionService.swift
│   ├── NetworkMonitor.swift         // NWPathMonitor → AsyncStream<Bool>
│   └── ConversationStore.swift      // SwiftData wrapper
├── ViewModels/
│   ├── ConversationViewModel.swift
│   ├── SettingsViewModel.swift
│   └── HistoryViewModel.swift
├── Views/
│   ├── ConversationView.swift, OrbView.swift, TranscriptView.swift
│   ├── PermissionDeniedView.swift, ErrorBanner.swift
│   ├── SettingsView.swift, HistoryView.swift, ConversationDetailView.swift
└── Config/
    ├── Secrets.xcconfig (git-ignored) // TOKEN_SERVER_URL, APP_SHARED_SECRET
    └── Info.plist keys: NSMicrophoneUsageDescription, UIBackgroundModes=[audio]
```

## 2. Core types

```swift
enum SessionState: Equatable, Sendable {
    case idle
    case checkingPermission
    case permissionDenied
    case connecting
    case listening
    case userSpeaking
    case thinking
    case aiSpeaking
    case paused(PauseReason)            // .interruption(canAutoResume: Bool) | .userMuted
    case reconnecting(attempt: Int)
    case failed(SessionError)
}

enum SessionError: Error, Equatable, Sendable {
    case tokenServerUnreachable          // internet OK but Mac server unreachable (D-021)
    case noInternet, tokenRejected(status: Int)
    case socketFailed(String), serverError(code: String, message: String)
    case audioEngineFailed(String), reconnectExhausted
}

struct TranscriptTurn: Identifiable, Equatable, Sendable {
    enum Role: Sendable { case user, assistant }
    let id: String          // Realtime item_id
    let role: Role
    var text: String
    var isFinal: Bool
    var wasInterrupted: Bool
}

enum Persona: String, CaseIterable, Identifiable, Codable, Sendable {
    case quick, storyteller, coach            // default: .quick (stored in UserDefaults)
    var id: String { rawValue }
    var displayName: String                   // "Quick", "Storyteller", "Coach"
    var subtitle: String                      // "Short, fast answers" …
    var voice: String                         // marin / cedar / coral (for display; server is the source of truth)
}
```
Prompts are **not** in the app. See [PERSONAS.md](PERSONAS.md).

## 3. Service protocols (all injectable)

```swift
protocol TokenProviding: Sendable {
    func fetchToken(persona: Persona) async throws -> EphemeralToken // value, expiresAt, instructions, voice
}

protocol RealtimeClienting: Sendable {
    func connect(token: EphemeralToken, model: String) async throws
    func send(_ event: ClientEvent) async throws
    var events: AsyncThrowingStream<ServerEvent, Error> { get }  // finishes/throws on close
    func ping(timeout: Duration) async throws
    func disconnect() async
}

protocol AudioEngineProtocol: AnyObject, Sendable {
    func start() throws                         // voice processing ON
    func stop()
    var micChunks: AsyncStream<Data> { get }    // PCM16 LE 24 kHz mono, ~40 ms chunks
    func enqueue(pcm16 data: Data, responseID: String, itemID: String)
    func flushPlayback() -> PlaybackCut?        // returns (itemID, playedMs) of cut item
    var playbackDrained: AsyncStream<String> { get } // itemID finished playing
    func setMicMuted(_ muted: Bool)
    func rebuildForCurrentRoute() throws
}

protocol AudioSessionManaging: Sendable {
    func configureAndActivate() throws
    func deactivate()
    var interruptions: AsyncStream<AudioInterruption> { get }  // .began(reason) | .ended(shouldResume)
    var routeChanges: AsyncStream<RouteChange> { get }        // reason + new output port type
    var mediaServicesReset: AsyncStream<Void> { get }
}

protocol PermissionProviding: Sendable {
    func micStatus() -> MicPermission           // .undetermined | .granted | .denied
    func requestMic() async -> Bool
}

protocol NetworkMonitoring: Sendable { var isReachable: AsyncStream<Bool> { get } }
```

## 4. VoiceSessionController (the heart)

`@MainActor @Observable final class VoiceSessionController`
- Published: `state`, `turns: [TranscriptTurn]`, `inputLevel`, `outputLevel`, `currentRoute`.
- Owns one `TaskGroup`-like set of child tasks per session: **mic pump**, **event loop**, **ping loop**, **notification loop**. All are cancelled on `end()`, `reconnect`, or `pause`.

### 4.1 Start
1. `state = .checkingPermission`. `micStatus()`: `.denied` → `.permissionDenied`, return. `.undetermined` → `requestMic()`.
2. `state = .connecting`. `audioSession.configureAndActivate()`:
   `setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])`, `setPreferredIOBufferDuration(0.02)`.
3. `token = try await withTimeout(8s) { tokenService.fetchToken(persona) }`
4. `try await withTimeout(8s) { realtime.connect(token, model: "gpt-realtime-2.1") }`. The URL is `wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1`, header `Authorization: Bearer <ek_…>`.
5. Send `session.update` (see §6). Wait for `session.updated` (timeout 5 s).
6. `audioEngine.start()`. Start the mic pump: `for await chunk in micChunks { send(.inputAudioAppend(base64)) }`.
7. **New session only** (not on reconnect): send `response.create` so the AI greets the user (PRD F10).
8. `state = .listening`.

### 4.2 Event loop (server → app)
| Server event | Action |
|---|---|
| `input_audio_buffer.speech_started` | **Barge-in**: `if let cut = audioEngine.flushPlayback() { send(.truncate(itemID: cut.itemID, contentIndex: 0, audioEndMs: cut.playedMs)); mark turn interrupted }`. Add the active `response_id` to `cancelledResponses`. `state = .userSpeaking` |
| `input_audio_buffer.speech_stopped` | `state = .thinking` |
| `conversation.item.input_audio_transcription.delta/.completed` | upsert the user turn |
| `response.created` | `activeResponseID = id` |
| `response.output_audio.delta` | drop if `response_id ∈ cancelledResponses`, else `enqueue(...)`; `state = .aiSpeaking` |
| `response.output_audio_transcript.delta/.done` | upsert the assistant turn (drop if cancelled) |
| `response.done` | clear active id; if `status == cancelled` keep the turn marked interrupted |
| playback drained (local) | if nothing queued → `state = .listening` |
| `error` | log; fatal codes (`session_expired`, auth) → reconnect; otherwise banner |
| stream finished/thrown | → `reconnect()` |

### 4.3 Barge-in latency guarantee
- `flushPlayback()` calls `playerNode.stop()` synchronously, which discards all scheduled buffers immediately. No fade longer than 10 ms.
- `playedMs` = `PlaybackClock`: sum of the durations of fully played buffers for the item + `playerNode.playerTime(forNodeTime: lastRenderTime).sampleTime / 24_000` for the current buffer. A pure struct, unit-tested.
- Local playback stops before any network round-trip, so perceived stop is ~1 audio buffer (≤ 40 ms) after the server event arrives.

### 4.4 Interruption (call / Siri / alarm)
- `.began(reason)`: cancel the mic pump, `flushPlayback()` (+ truncate), `audioEngine.stop()`, `state = .paused(.interruption(canAutoResume: false))`. **Keep the socket open**; the ping loop keeps running.
- `.ended(shouldResume: true)`: `configureAndActivate()` → `rebuildForCurrentRoute()` → `start()` → restart the pump → `.listening`. If the socket died meanwhile, run `reconnect()`.
- `.ended(shouldResume: false)`: `state = .paused(.interruption(canAutoResume: false))`; the UI shows **Resume**.
- Reason `.routeDisconnected` is treated like a route change, not a pause.

### 4.5 Route change (AirPods)
| Reason | Action |
|---|---|
| `.oldDeviceUnavailable` | `flushPlayback()` + truncate (the user didn't hear the rest), `rebuildForCurrentRoute()`, keep listening. The AI doesn't keep talking into thin air |
| `.newDeviceAvailable`, `.override`, `.categoryChange` | `rebuildForCurrentRoute()` (restart the engine; the hardware sample rate may change between 16k HFP and 48k) |
| `AVAudioEngineConfigurationChange` | same rebuild; the engine has already stopped |

`rebuildForCurrentRoute()`: `engine.stop()` → remove the tap → re-read `inputNode.outputFormat(forBus:0)` → recreate `PCMConverter` → reinstall the tap → reconnect `playerNode → mainMixer` with the 24 kHz format → `engine.prepare(); engine.start()`.

### 4.6 Reconnect
```
ReconnectPolicy.delays = [0.5, 1, 2, 4, 8, 8, 8]  // ≈31.5 s total budget
```
1. `state = .reconnecting(attempt: n)`. Cancel the pump, event and ping tasks, `realtime.disconnect()`, `flushPlayback()`.
2. If `NetworkMonitor` reports unreachable, wait for reachable *or* the next delay, whichever comes first.
3. **New token** (the old one may have expired) → connect → `session.update`.
4. **Seed context**: for the last 10 final turns send `conversation.item.create` (user turns as `input_text`, assistant turns as `output_text`, i.e. text, not audio).
5. Restart the engine/pump → `.listening`. On exhaustion → `.failed(.reconnectExhausted)` and stop the engine (mic indicator off).

Triggers: event stream ends/throws, `ping` fails (every 10 s, 5 s timeout), path unsatisfied for > 3 s, server `error` with a session-fatal code.

### 4.7 Timeouts (nothing hangs)
Each external await is wrapped in `withTimeout(_:)` (a task-group race). Token 8 s, connect 8 s, session.updated 5 s, ping 5 s. A UI watchdog: if `connecting` lasts > 20 s → `.failed`.

## 5. AudioEngine implementation details
- One `AVAudioEngine`. `inputNode.setVoiceProcessingEnabled(true)` **before** `engine.prepare()`. This enables AEC + noise suppression + AGC for the engine's I/O pair.
- `inputNode.isVoiceProcessingAGCEnabled = true`. `voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)`.
- Capture: `installTap(onBus: 0, bufferSize: 960, format: hwFormat)` → `PCMConverter` (`AVAudioConverter` to Int16, 24 kHz, mono) → `Data` → `AsyncStream.Continuation.yield` (`bufferingNewest(50)`, so the realtime thread never blocks).
- Playback: `AVAudioPlayerNode` connected to `mainMixerNode` with format Float32 24 kHz mono. Each delta: base64 → Int16 → Float32 `AVAudioPCMBuffer` → `scheduleBuffer(_:completionCallbackType: .dataPlayedBack)`, which updates `PlaybackClock` and emits `playbackDrained` when the queue for the item is empty.
- Mute: `inputNode.isVoiceProcessingInputMuted = true` (plus skip sending).
- Levels: RMS of each buffer → `inputLevel` / `outputLevel`, throttled to 30 Hz for the orb.

## 6. session.update payload
```json
{
  "type": "session.update",
  "session": {
    "type": "realtime",
    "model": "gpt-realtime-2.1",
    "instructions": "<token response .instructions (persona prompt from server)>",
    "output_modalities": ["audio"],
    "audio": {
      "input": {
        "format": { "type": "audio/pcm", "rate": 24000 },
        "noise_reduction": { "type": "near_field" },
        "transcription": { "model": "gpt-4o-mini-transcribe" },
        "turn_detection": { "type": "semantic_vad", "eagerness": "auto",
                            "interrupt_response": true, "create_response": true }
      },
      "output": { "format": { "type": "audio/pcm", "rate": 24000 }, "voice": "<token response .voice>" }
    }
  }
}
```
`noise_reduction` switches to `far_field` when the output route is the built-in speaker.
The token server sends the same config when minting, so the session is correct even before `session.update`.

## 7. ViewModels
```swift
@MainActor @Observable final class ConversationViewModel {
    private(set) var orb: OrbState            // idle/listening/userSpeaking/thinking/aiSpeaking/paused/reconnecting/error
    private(set) var turns: [TranscriptTurn]
    private(set) var banner: BannerModel?     // network/server errors with Retry
    private(set) var showPermissionDenied: Bool
    var isMuted: Bool
    func startTapped() async; func endTapped() async; func resumeTapped() async
    func retryTapped() async; func openSettingsTapped(); func scenePhaseChanged(_:)
}
```
- On `end`/`failed`: persist `turns` via `ConversationStore.save(turns:voice:startedAt:)`.
- `SettingsViewModel`: picker over `Persona.allCases` (name + subtitle), stored in `UserDefaults` (default `.quick`). A footnote says "applies to next conversation". No free-text prompt editing.
- `HistoryViewModel`: `@Query`-backed list in the view; delete via the store.

## 8. Persistence (SwiftData)
```swift
@Model final class Conversation { var id: UUID; var startedAt: Date; var endedAt: Date?; var voice: String
                                  @Relationship(deleteRule: .cascade) var turns: [Turn] }
@Model final class Turn { var index: Int; var role: String; var text: String; var wasInterrupted: Bool }
```
Audio is never stored.

## 9. Token server (Node + Express)

```
token-server/
├── package.json         // express, express-rate-limit, helmet, dotenv; dev: vitest, supertest
├── src/app.js           // buildApp({ fetchImpl, env }) for testability
├── src/personas.js      // SHARED_VOICE_RULES + quick/storyteller/coach prompts + voices (docs/PERSONAS.md)
├── src/server.js        // listen(PORT)
├── test/app.test.js
└── .env.example         // OPENAI_API_KEY=, APP_SHARED_SECRET=, PORT=8787
```

`POST /session`
- Headers: `x-app-secret` (timing-safe compare) → else **401**.
- Rate limit 10/min/IP → **429**.
- Body `{ personaId?: "quick" | "storyteller" | "coach" }`. Missing → `quick`; any other value → **400**. Any other body fields (e.g. `instructions`, `voice`) are **ignored**.
- Calls `POST https://api.openai.com/v1/realtime/client_secrets` with `Authorization: Bearer ${OPENAI_API_KEY}` and body `{ expires_after: { anchor: "created_at", seconds: 600 }, session: { type: "realtime", model: "gpt-realtime-2.1", instructions: <persona prompt>, audio: { output: { voice: <persona voice> }, input: { turn_detection: { type: "semantic_vad" } } } } }`.
- Returns `{ value, expires_at, personaId, voice, instructions }`. The app echoes `instructions`/`voice` back in `session.update` (and on reconnect), so the persona survives a full session reset. OpenAI failure → **502** with a generic message (no upstream details leaked). Timeout 8 s.
- `GET /healthz` → 200.
- Logs never contain the key or the token value.

## 10. Info.plist / capabilities
| Key | Value |
|---|---|
| `NSMicrophoneUsageDescription` | "V2V uses the microphone so you can talk with the AI assistant." |
| `UIBackgroundModes` | `audio` |
| `NSAppTransportSecurity` | Debug only: `NSAllowsLocalNetworking = YES` |
| `NSLocalNetworkUsageDescription` | Debug only, for reaching the Mac token server over LAN |
