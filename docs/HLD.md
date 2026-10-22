# HLD — V2V Speech-to-Speech App

Related: [PRD](PRD.md) · [LLD](LLD.md) · [Decisions](DECISIONS.md)

## 1. System context

```mermaid
flowchart LR
    U((User)) -- voice --> App[iOS App<br/>SwiftUI + MVVM]
    App -- "1. POST /session<br/>x-app-secret" --> TS[Token Server<br/>Node + Express]
    TS -- "2. POST /v1/realtime/client_secrets<br/>Bearer sk-…" --> OAI[(OpenAI Realtime API<br/>gpt-realtime-2.1)]
    TS -- "3. ephemeral key ek_… (≈10 min)" --> App
    App <-- "4. wss://api.openai.com/v1/realtime<br/>PCM16 24 kHz audio + JSON events" --> OAI
    App -- transcripts --> DB[(SwiftData<br/>on device)]
```

- The **OpenAI API key lives only on the token server** (env var). The app gets a short-lived client secret per session. (PRD E8)
- After the handshake, audio goes **directly app ↔ OpenAI** over WebSocket. The token server isn't in the audio path, so it adds no latency.

## 2. Architecture (MVVM)

```mermaid
flowchart TB
    subgraph View["View layer (SwiftUI)"]
        CV[ConversationView]
        OV[OrbView]
        TV[TranscriptView]
        SV[SettingsView]
        HV[HistoryView]
        PV[PermissionDeniedView]
    end
    subgraph VM["ViewModel layer (@Observable, @MainActor)"]
        CVM[ConversationViewModel]
        SVM[SettingsViewModel]
        HVM[HistoryViewModel]
    end
    subgraph Domain["Domain / Services (protocols, actors)"]
        VSC[VoiceSessionController<br/>state machine]
        RC[RealtimeClient<br/>WebSocket actor]
        AE[AudioEngine<br/>capture + playback + AEC]
        ASM[AudioSessionManager<br/>routes + interruptions]
        NM[NetworkMonitor]
        TKS[TokenService]
        PS[PermissionService]
        ST[ConversationStore<br/>SwiftData]
    end
    CV & OV & TV & PV --> CVM
    SV --> SVM
    HV --> HVM
    CVM --> VSC
    CVM --> ST
    HVM --> ST
    SVM --> Settings[(UserDefaults)]
    VSC --> RC & AE & ASM & NM & TKS & PS
```

**Rules**
- Views only render ViewModel state and send intents (`start()`, `end()`, `toggleMute()`).
- ViewModels are `@MainActor @Observable`. They map domain state to UI state; no audio or network code.
- `VoiceSessionController` owns the **session state machine** and coordinates the services. All edge-case logic lives here, so it's unit-testable with fakes.
- Every service sits behind a protocol, so tests inject fakes.
- Swift Concurrency throughout: `actor`s, `AsyncStream`, and `NotificationCenter.notifications(named:)`. No Combine.

## 3. Session state machine

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> CheckingPermission: start()
    CheckingPermission --> PermissionDenied: denied
    CheckingPermission --> Connecting: granted
    PermissionDenied --> CheckingPermission: app returns to foreground
    Connecting --> Listening: session.updated
    Connecting --> Failed: token/socket error
    Listening --> UserSpeaking: speech_started
    UserSpeaking --> Thinking: speech_stopped
    Thinking --> AISpeaking: first audio delta
    AISpeaking --> UserSpeaking: speech_started (BARGE-IN)
    AISpeaking --> Listening: playback drained
    Listening --> Paused: interruption began
    AISpeaking --> Paused: interruption began
    Paused --> Listening: interruption ended (+shouldResume) / resume()
    Listening --> Reconnecting: socket closed / ping timeout / path unsatisfied
    AISpeaking --> Reconnecting: socket closed / ping timeout
    Reconnecting --> Listening: new session ready
    Reconnecting --> Failed: retries exhausted (~30 s)
    Failed --> Connecting: retry()
    Listening --> Idle: end()
    Failed --> Idle: end()
```

(Any active state → `Idle` on `end()`. Any active state → `Paused`/`Reconnecting` on the matching events. Only the main edges are drawn.)

## 4. How each edge case is handled

| # | Edge case | Mechanism |
|---|---|---|
| E1 | **Barge-in** | Server `semantic_vad` with `interrupt_response: true` auto-cancels the response. On `input_audio_buffer.speech_started` the app **immediately flushes the local player** (`AVAudioPlayerNode.stop()`), computes the ms actually played, and sends `conversation.item.truncate(item_id, audio_end_ms)` so the model's memory matches what the user heard. Late `output_audio.delta`s for the cancelled response are dropped by `response_id` |
| E2 | **Echo** | Apple **voice processing I/O** (`setVoiceProcessingEnabled(true)` on the engine's input node). The hardware AEC uses the engine's own output as the reference, so the mic signal sent to OpenAI has the AI voice removed. Audio session `mode = .voiceChat`. Server `noise_reduction` adds a second layer. Capture and playback **must share one `AVAudioEngine`** so AEC has the reference |
| E3 | **Mic denied** | `AVAudioApplication.requestRecordPermission()` before connecting. `.denied` → `PermissionDenied` state → explanation view + `UIApplication.openSettingsURLString`. Re-check on `scenePhase == .active` |
| E4 | **AirPods / route change** | Observe `AVAudioSession.routeChangeNotification` and `AVAudioEngineConfigurationChange`. On `.oldDeviceUnavailable` (AirPods removed): pause playback ~300 ms, rebuild/restart the engine on the new route, continue. On `.newDeviceAvailable`: restart the engine on the new route. The session (socket) is never torn down for a route change |
| E5 | **Calls / Siri / alarms** | `AVAudioSession.interruptionNotification`. `.began` → stop capture + flush playback, `Paused`, socket kept alive. `.ended` + `.shouldResume` → reactivate session, restart engine, `Listening`; otherwise show "Tap to resume". If the socket died during the pause → `Reconnecting` |
| E6 | **Background** | `UIBackgroundModes: audio`. The active `.playAndRecord` session keeps the app alive while the mic is live. Media-services reset (`mediaServicesWereResetNotification`) → full audio rebuild |
| E7 | **Network drop** | Three detectors: (a) WebSocket receive error/close, (b) app-level ping every 10 s with a 5 s timeout, (c) `NWPathMonitor` unsatisfied. → `Reconnecting`: exponential backoff 0.5, 1, 2, 4, 8, 8 s (~30 s cap), **fresh token each attempt**, new session seeded with the last ~10 transcript turns as `conversation.item.create`. Every await has a timeout, so nothing can hang. Exhausted → `Failed` + Retry |
| E8 | **No key in app** | The app has only `TOKEN_SERVER_URL` + `APP_SHARED_SECRET` (xcconfig, not committed). The server calls `/v1/realtime/client_secrets` with the session config (model, voice, instructions, VAD) and returns `{ value, expires_at }` |
| E9 | **Server abuse** | `x-app-secret` header check (constant-time compare) + `express-rate-limit` (e.g. 10 req/min/IP) + CORS off + session config built on the server (the client only sends a `personaId`; prompts and voices live on the server, [D-020](DECISIONS.md)) |

## 5. Key flows

### 5.1 Start session
```mermaid
sequenceDiagram
    participant V as ConversationView
    participant VM as ConversationViewModel
    participant C as VoiceSessionController
    participant P as PermissionService
    participant T as TokenService
    participant R as RealtimeClient
    participant A as AudioEngine
    V->>VM: start()
    VM->>C: start(settings)
    C->>P: ensureMicPermission()
    P-->>C: granted
    C->>T: fetchToken(voice, instructions)
    T-->>C: ek_… (expires_at)
    C->>R: connect(token)
    R-->>C: session.created
    C->>R: session.update (pcm 24k, semantic_vad, transcription)
    C->>A: start() (voice processing on)
    A-->>C: mic PCM chunks (AsyncStream)
    C->>R: input_audio_buffer.append …
    C-->>VM: state = .listening
```

### 5.2 Barge-in
```mermaid
sequenceDiagram
    participant A as AudioEngine
    participant C as VoiceSessionController
    participant R as RealtimeClient
    Note over A: AI speaking (item_42)
    R-->>C: input_audio_buffer.speech_started
    C->>A: flushPlayback() → playedMs = 1840
    C->>R: conversation.item.truncate(item_42, 0, 1840)
    Note over R: server already cancelled response (interrupt_response)
    R-->>C: late response.output_audio.delta (old response_id)
    C--xA: dropped (cancelled response id)
    C-->>C: state = .userSpeaking
```

## 6. Deployment
| Piece | Dev | Device testing / demo |
|---|---|---|
| Token server | `npm run dev` on Mac; Simulator uses `http://localhost:8787` | Same Mac server; the iPhone on the **same Wi-Fi** uses `http://<mac-lan-ip>:8787` (ATS local-networking exception). **No cloud hosting** ([D-019](DECISIONS.md)) |
| iOS app | Simulator (no AEC/AirPods realism) | **Physical iPhone required** for E2, E4, E5, E6 |

## 7. Repo layout
```
V2Vfolder/
├── V2Vfolder/              # iOS app (MVVM)
│   ├── App/  Views/  ViewModels/  Domain/  Services/  Models/  Config/
├── V2VfolderTests/         # Swift Testing unit tests
├── V2VfolderUITests/       # XCUIAutomation UI tests
├── token-server/           # Node + Express
└── docs/                   # PRD, HLD, LLD, TEST_CASES, DECISIONS
```
