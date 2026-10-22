# Design Decisions Log (ADR-lite)

Every significant design decision, with the reasoning and the alternatives rejected. Append new entries; don't rewrite old ones. To reverse one, add a new entry that supersedes it.

Format: **Context → Decision → Why → Alternatives rejected → Consequences**

---

### D-001 · Platform: iPhone only, iOS 26+
- **Date**: 2026-10-22 · **Status**: Accepted (user choice)
- **Context**: Need a working voice app with robust audio edge cases; one developer.
- **Decision**: iPhone-only target, iOS 26 minimum.
- **Why**: Smallest test surface for the hardest part (audio routing/interruptions behave differently on iPad/macOS). iOS 26 gives current SwiftUI, Observation, `AVAudioApplication` permission APIs and `allowBluetoothHFP`.
- **Rejected**: iPhone + iPad (extra layout + multitasking audio cases); iOS + macOS (different audio session model, ~30% more work).
- **Consequences**: No iPad layout; can add later since MVVM keeps views thin.

### D-002 · Transport: WebSocket + AVAudioEngine (not WebRTC)
- **Status**: Accepted (user choice)
- **Context**: Realtime API supports WebRTC, WebSocket and SIP. We need instant barge-in and reliable AEC on iOS.
- **Decision**: `URLSessionWebSocketTask` to `wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1`; audio captured/played with our own `AVAudioEngine`.
- **Why**: No third-party binary. We own the playback buffer, so barge-in can flush locally *before* any network round-trip. Apple's voice-processing I/O gives hardware-grade echo cancellation. Full control of `AVAudioSession` for AirPods and call handling (WebRTC's iOS audio unit tends to fight the app over the session).
- **Rejected**: WebRTC (Google WebRTC SPM; opaque audio session handling; harder to unit-test).
- **Consequences**: We must base64-encode PCM, handle jitter ourselves and implement `conversation.item.truncate`. Slightly more bandwidth than Opus over WebRTC (~48 KB/s each way). That's acceptable.

### D-003 · Echo control: Apple voice processing on a single shared AVAudioEngine
- **Status**: Accepted
- **Context**: On the speaker, the mic hears the AI, and server VAD would treat that as the user speaking and interrupt the AI (self-interrupt loop).
- **Decision**: `inputNode.setVoiceProcessingEnabled(true)` on the same engine that plays the AI audio. Session mode `.voiceChat`. Server `noise_reduction` (`far_field` on speaker, `near_field` on headsets) as a second layer.
- **Why**: AEC needs the playback signal as a reference. That only works if playback goes through the same voice-processing I/O unit. Removing echo at the source means server VAD stays accurate and barge-in remains possible.
- **Rejected**: Muting the mic while the AI speaks (kills barge-in); client-side energy gating (fragile, volume-dependent); relying on server noise reduction alone (not true AEC).
- **Consequences**: Never play AI audio through a separate `AVAudioPlayer`/engine. Voice processing changes the input format, so always read the format after enabling it.

### D-004 · Barge-in: server semantic VAD + immediate local flush + truncate
- **Status**: Accepted
- **Context**: "Talking over it stops it immediately."
- **Decision**: `turn_detection: semantic_vad, interrupt_response: true`. On `speech_started` the client synchronously stops `AVAudioPlayerNode`, computes played ms and sends `conversation.item.truncate`. Late deltas from cancelled responses are dropped by `response_id`.
- **Why**: The server cancels generation, but audio already buffered on the device would keep playing for seconds, so a local flush is what makes it *feel* instant. Truncate keeps the model's memory consistent with what the user actually heard (no "as I was saying…" about unheard content).
- **Rejected**: Waiting for `response.done(cancelled)` before stopping (adds RTT latency); an on-device VAD for barge-in (duplicated logic, more false triggers; reconsider if server latency proves too high).
- **Consequences**: `PlaybackClock` must be accurate, so it's unit-tested.

### D-005 · Turn detection: semantic VAD (hands-free)
- **Status**: Accepted (user choice)
- **Decision**: `semantic_vad`, eagerness `auto`.
- **Why**: Ends the turn based on meaning, so it cuts users off less mid-thought than silence VAD. Still supports `interrupt_response` for barge-in.
- **Rejected**: `server_vad` (more false cutoffs on pauses); push-to-talk (not conversational, though it solves echo trivially).

### D-006 · Architecture: MVVM + a domain state machine
- **Status**: Accepted (user choice: MVVM)
- **Decision**: Views → `@Observable @MainActor` ViewModels → `VoiceSessionController` (explicit `SessionState` machine) → protocol-backed services.
- **Why**: Every edge case is a state transition, so a central state machine makes them explicit and testable with fakes. Keeps ViewModels thin (UI mapping only) and Views dumb.
- **Rejected**: Logic inside the ViewModel (bloated, hard to test); TCA (third-party, learning curve).
- **Consequences**: All service APIs are protocols; `AppDependencies` is the composition root and also builds fakes for UI tests (`-uiTestFakes`).

### D-007 · Concurrency: Swift Concurrency only (no Combine)
- **Status**: Accepted (project guideline)
- **Decision**: `actor` for `RealtimeClient`, `AsyncStream` for mic chunks/events, `NotificationCenter.notifications(named:)` for audio session notifications, `withTimeout` task-group races.
- **Why**: Matches the project style guide; structured cancellation makes "end/reconnect cancels everything" reliable.
- **Consequences**: The audio tap runs on a realtime thread, so it only yields to an `AsyncStream` with `bufferingNewest`. No locks or awaits on that thread.

### D-008 · Background: keep the conversation alive (audio background mode)
- **Status**: Accepted (user choice)
- **Decision**: `UIBackgroundModes = audio`; pause only on real interruptions (calls, Siri, alarms) and auto-resume on `shouldResume`.
- **Why**: Hands-free use (walking, cooking) needs it to work with the screen locked, like a phone call.
- **Rejected**: Pause on background (simpler, but breaks the main use case).
- **Consequences**: The App Store review note must explain live voice conversation. The mic indicator is visible to the user in the background (good for privacy).

### D-009 · Interruptions: keep the socket during a pause
- **Status**: Accepted
- **Decision**: On interruption `.began`, stop audio only; keep the WebSocket and ping loop alive. Reconnect only if the socket actually died.
- **Why**: Most interruptions are short (Siri, a declined call), so resuming on the same session preserves full context with zero reconnect latency.
- **Consequences**: A long call may outlive the session. That's handled by the normal reconnect path with transcript seeding.

### D-010 · Route changes: rebuild the engine, never the session
- **Status**: Accepted
- **Decision**: On route change / engine configuration change, rebuild the audio graph for the new hardware format. On `.oldDeviceUnavailable`, also flush + truncate the current AI utterance.
- **Why**: AirPods (HFP 16 kHz) ↔ speaker (48 kHz) changes the hardware format, so the engine must be reconfigured. The network session is unrelated. Flushing on removal matches iOS conventions (audio stops when headphones are pulled) and keeps the model's memory honest.
- **Consequences**: `PCMConverter` is recreated per route; tested at 16 k and 48 k.

### D-011 · Network resilience: triple detection + bounded backoff + fresh token + context seeding
- **Status**: Accepted
- **Decision**: Detect via socket error, a 10 s ping with a 5 s timeout, and `NWPathMonitor`. Backoff `[0.5,1,2,4,8,8,8]` s (~30 s), a new ephemeral token per attempt, and the last 10 transcript turns replayed as text items into the new session.
- **Why**: A socket can silently stall (no error), so the ping catches it. The ephemeral token may have expired. A new Realtime session has no memory, so seeding keeps the conversation coherent. The bounded budget guarantees an error state instead of hanging.
- **Rejected**: Infinite retries (hangs from the user's perspective); reconnecting without context (the AI forgets mid-conversation).
- **Consequences**: Seeded turns are text, so the AI's tone may shift slightly after a reconnect. Acceptable.

### D-012 · Every external await has a timeout
- **Status**: Accepted
- **Decision**: Token 8 s, connect 8 s, `session.updated` 5 s, ping 5 s, plus a 20 s connecting watchdog.
- **Why**: The PRD says "doesn't hang". Unbounded awaits on network are the main cause of hangs.

### D-013 · Secrets: ephemeral client secrets from our own token server
- **Status**: Accepted
- **Decision**: The server calls `POST /v1/realtime/client_secrets` (600 s expiry) with the session config; the app only ever sees `ek_…`.
- **Why**: Any key in the app binary can be extracted. Ephemeral keys limit the blast radius to one short session. Building the session config server-side means a stolen token can't be used for a different model.
- **Rejected**: Embedding the key (insecure); proxying all audio through our server (adds latency + bandwidth cost).

### D-014 · Token server: Node + Express, shared app secret + rate limit
- **Status**: Accepted (user choice)
- **Decision**: Express, `express-rate-limit` (10/min/IP), timing-safe `x-app-secret` check, voice allowlist, instructions length cap, `helmet`, and no CORS.
- **Why**: Simplest stack and closest to OpenAI's examples. The shared secret + rate limit stops casual abuse of the OpenAI bill without needing user accounts.
- **Rejected**: No auth (anyone can spend credits); Sign in with Apple (too heavy for an MVP); Vapor/Workers/FastAPI (fine, but no advantage here).
- **Consequences**: The shared secret is extractable from the app, so it's speed-bump security only. Upgrade path: App Attest or Sign in with Apple.

### D-015 · Persistence: SwiftData, transcripts only
- **Status**: Accepted (user choice: history in scope)
- **Decision**: `Conversation` + `Turn` models; audio is never stored.
- **Why**: Native, minimal code, works with `@Query`. Not storing audio keeps privacy simple.

### D-016 · Audio format: PCM16 24 kHz mono both ways
- **Status**: Accepted
- **Why**: The Realtime API's native format; no codec dependency. `AVAudioConverter` handles hardware rates.
- **Consequences**: ~48 KB/s upstream + base64 overhead. Fine on Wi-Fi/LTE.

### D-017 · Testing strategy
- **Status**: Accepted (project guideline)
- **Decision**: Swift Testing for unit tests (state machine with fakes + pure components), XCUIAutomation for UI tests with fake services, vitest + supertest for the server, and a **manual device script** for real audio hardware (AEC, AirPods, calls).
- **Why**: Echo, Bluetooth and phone calls can't be faithfully simulated, so the risky logic (state transitions) is unit-tested and the hardware behaviour is verified manually against explicit pass criteria.

### D-018 · Task tracking: beads (`bd`)
- **Status**: Accepted (user choice)
- **Decision**: The implementation plan lives in beads epics/issues with dependencies; `bd ready` drives the order of work.
- **Why**: Dependency-aware, git-backed and agent-friendly. It survives across sessions.

### D-019 · Token server runs locally only; no cloud hosting
- **Date**: 2026-10-22 · **Status**: Accepted (user choice) · Amends D-014 and HLD §6
- **Context**: Device testing over cellular would need the token server hosted on the internet (Render/Fly/Railway).
- **Decision**: Don't host it. The token server runs only on the developer's Mac (`npm run dev`). The iPhone reaches it over the local Wi-Fi network (`http://<mac-lan-ip>:8787`).
- **Why**: Hosting a server costs money, which is out of scope for this project. Running locally still meets E8: the OpenAI key stays on the Mac and the app only gets short-lived tokens.
- **Rejected**: Paid hosting (cost); free tiers (cold starts and sleep would distort the reconnect and latency tests, and they can still need a card); putting the key in the app (breaks E8).
- **Consequences**:
  - The iPhone must be on the same Wi-Fi as the Mac, and the Mac must be running the server.
  - Cellular-only use and the Wi-Fi → cellular test (M-16) are out of scope. Reconnect needs a fresh token from the server, so it can only succeed once the phone is back on that Wi-Fi.
  - Network-drop tests (M-14, M-15) are run on Wi-Fi only.
  - Task `v2v-293.4` (deploy) is closed as won't-do. Revisit only if the project needs public distribution.

### D-020 · Three preset personas with server-side prompts (no free-form prompt editing)
- **Date**: 2026-10-22 · **Status**: Accepted (user choice) · Supersedes the "voice picker + edit instructions" part of PRD F7, and the voice allowlist / instructions cap in D-014
- **Context**: This is a demo. Ten voices plus a free-text prompt editor is more UI and more risk than it needs. The user wants 2–3 personas, with one that keeps answers short.
- **Decision**: Three fixed personas, each with its own voice: **Quick** (default, 1–2 sentence answers, `marin`), **Storyteller** (long answers, to show off barge-in, `cedar`) and **Coach** (explains, then asks a follow-up question, `coral`). Prompts live in `token-server/src/personas.js`, and the app sends only `personaId`. All personas share a "voice rules" preamble (no markdown, speak numbers naturally, handle interruptions, greet once). Specs are in [PERSONAS.md](PERSONAS.md).
- **Why**:
  - Short default answers make the demo feel fast, and give more turns in less time.
  - Storyteller exists so barge-in is easy to demonstrate. Interrupting a two-sentence answer is hard.
  - Prompts on the server mean a leaked shared secret can't be used to run arbitrary prompts on our bill, and prompts can be tuned without rebuilding the app.
  - A single persona picker is a much smaller settings UI and fewer tests than a voice list plus a text editor.
- **Rejected**: Free-text prompt editor (scope + abuse); voice picker independent of persona (more UI, little demo value); prompts bundled in the app (would need an app rebuild to tune, and the client could send anything).
- **Consequences**: `/session` takes `{ personaId }` and ignores client-sent `instructions`/`voice`. Its response includes the resolved `instructions` + `voice`, so the app can re-send them in `session.update` after a reconnect. The greeting is triggered by the app sending `response.create` on new sessions only.

### D-021 · Reach the Mac by `.local` hostname; infer Local Network denial
- **Date**: 2026-10-22 · **Status**: Accepted · Follows from D-019
- **Context**: With a local-only server, the phone must find the Mac on Wi-Fi. LAN IPs change, and iOS asks for Local Network permission on first contact. iOS gives no API to read that permission's state.
- **Decision**: `TOKEN_SERVER_URL = http://<ComputerName>.local:8787` (Bonjour/mDNS). If the token fetch fails while `NWPathMonitor` reports the internet is reachable → `SessionError.tokenServerUnreachable`, shown as "Can't reach the token server" with a checklist (same Wi-Fi · server running · Local Network allowed) and an Open Settings button.
- **Why**: The `.local` name survives DHCP changes without rebuilding the app. Telling "can't reach Mac" apart from "no internet" points the user straight at the fix during a demo.
- **Rejected**: Hard-coded IP (breaks on DHCP renew); Bonjour service browsing with `NWBrowser` (more code, little gain over a hostname).
- **Consequences**: Some networks block mDNS. The DEMO_CHECKLIST plan B (iPhone Personal Hotspot) covers that.

### D-022 · Hidden debug overlay for the live demo
- **Date**: 2026-10-22 · **Status**: Accepted
- **Decision**: Triple-tap the orb to toggle an overlay showing `SessionState`, input/output route, the last 20 server event types, the last error and end-of-turn→first-audio latency.
- **Why**: When something goes wrong live, you need to see in seconds whether it's the network, the audio route or the server. It also makes edge-case handling visible to the audience ("watch the route switch to AirPods").
- **Consequences**: The overlay reads from `VoiceSessionController`'s published state plus a small ring buffer of event names; it never shows tokens or transcripts' raw payloads.

### D-023 · Minimum iOS raised to 27.0
- **Date**: 2026-10-22 · **Status**: Accepted (user choice) · Supersedes the "iOS 26 minimum" in D-001 (iPhone-only still stands)
- **Decision**: `IPHONEOS_DEPLOYMENT_TARGET = 27.0` for the app and both test targets.
- **Why**: iOS 27 is the latest release, and the demo device already runs iOS 27.0.1. There's no audience on older versions to support for a demo, and targeting the latest OS lets us use iOS 27 APIs without availability checks.
- **Consequences**: The app won't install on iOS 26 devices. Simulators must use the iOS 27 runtime.

### D-024 · App secrets in a git-ignored Swift file (not xcconfig); no ATS exception
- **Date**: 2026-10-22 · **Status**: Accepted · Amends LLD §1/§10 (`Secrets.xcconfig`, Debug ATS key)
- **Decision**: The token server host, port and shared secret live in `V2Vfolder/Config/Secrets.swift` (git-ignored). The committed template is `config-templates/Secrets.swift.template`. `AppConfig` builds the URL with `URLComponents`. No `NSAppTransportSecurity` key is added.
- **Why**:
  - **Swift file, not xcconfig**: `//` starts a comment in xcconfig, so URLs need escaping hacks. Wiring an xcconfig also needs a manual project-configuration step, while a Swift file is picked up automatically by the synced folder.
  - **No ATS exception**: Apple's docs say ATS allows `.local` hosts by default on current iOS, and our server URL is a `.local` name, not an IP (D-021).
- **Consequences**: A fresh clone won't build until `Secrets.swift` is created from the template. That's intentional, and it fails loudly. The secret is in the app binary either way (it's speed-bump security, D-014).

### D-025 · Adopt the iOS 27 audio APIs (no deprecated calls)
- **Date**: 2026-10-22 · **Status**: Accepted · Follows from D-023 (iOS 27 minimum)
- **Context**: The iOS 27 SDK deprecates the APIs the LLD was written against.
- **Decision**:
  - **Interruptions**: `AVAudioSession.interruptionNotification` is replaced by `didBecomeInactiveNotification` (a `DeactivationContext` with `source` `.system` vs `.app`, plus the interruption reason) and `resumptionRecommendationNotification` (`.shouldResume` / `.shouldNotResume`). Our own deactivation (`source == .app`) is ignored.
  - **Engine**: `player.playAudio()`, `engine.connectNode(_:to:format:)` and `installAudioTap(onBus:…)` replace their non-throwing predecessors. The new tap gives a `Sendable` `AVReadOnlyAudioPCMBuffer`, and we read channel 0 via `channelData(0)` → `.float(Span<Float>)`.
  - **Tap size**: 100 ms, the documented minimum the system honours.
- **Why**: Deprecated APIs may behave differently or stop working in later releases. The new calls *throw* instead of failing silently, which maps cleanly onto `SessionError.audioEngineFailed`. The API shapes were confirmed by compiling probes, because the docs were incomplete.
- **Consequences**: The parsing logic stays pure and unit-tested (`interruptionBegan`, `interruptionEnded`). Real interruption behaviour is verified on the device (M-09…M-11).

### D-026 · Restart the engine on configuration change; force the loudspeaker after voice processing starts
- **Date**: 2026-10-22 · **Status**: Accepted · Found in the first device test · Extends D-003, D-010
- **Context**: On the iPhone, the first run produced no audio out, no mic audio in, and an orb stuck on "Speaking". Device logs showed iOS posting `AVAudioEngineConfigurationChange` about **100 ms after `engine.start()`**: enabling voice processing reconfigures the hardware, and iOS stops the engine itself. Output had also landed on the **earpiece** despite `.defaultToSpeaker`.
- **Decision**:
  - The controller listens to `configurationChanges` from the moment audio starts (not only for AirPods). It calls `rebuildForCurrentRoute()`, re-applies the speaker override and mute, and returns `aiSpeaking` → `listening`, because queued audio is lost.
  - Loop guard: more than 5 rebuilds in 10 s → `.failed(.audioEngineFailed)`.
  - After every engine start or rebuild, if the output is `.builtInReceiver`, the app calls `overrideOutputAudioPort(.speaker)`. AirPods and headphones are left alone.
  - Unified logging (`Log.audio` / `Log.session`) records state transitions, lifecycle events, mic chunk counts, the route and engine status. Tokens, audio and transcripts are never logged in clear.
- **Why**: This is an iOS behaviour, not a bug we can avoid; every voice-processing app has to handle it. Without the logs we would have been guessing (the first hypothesis, the mic sample format, was wrong).
- **Verified on device (iPhone 16, iOS 27.0.1)**: config change → rebuild → about 700 mic chunks sent, playback drains → listening, 7 barge-ins handled, no self-interruption on the loudspeaker. Covers M-01 and M-03, informally.
