# PRD — V2V: Speech-to-Speech Voice Assistant

| Field | Value |
|---|---|
| Status | Draft v1 |
| Date | 2026-10-22 |
| Model | OpenAI `gpt-realtime-2.1` (Realtime API, GA) |
| Platform | iPhone, iOS 27+ ([D-023](DECISIONS.md)) |
| Related | [HLD](HLD.md) · [LLD](LLD.md) · [Test Cases](TEST_CASES.md) · [Decisions](DECISIONS.md) |

## 1. Problem
Typing to an AI is slow and awkward on a phone. People want a hands-free, natural conversation: talk, get a spoken answer, and cut in at any time, like talking to a person. Most voice demos break the moment real life happens: AirPods disconnect, a call comes in, the network flickers, or the AI hears itself through the speaker.

## 2. Goal
An iPhone app where the user taps once and has a spoken conversation with GPT Realtime. It stays robust through the real-world audio and network edge cases listed in §5.

### Non-goals (v1)
- iPad, macOS, watchOS
- User accounts / cloud sync
- Tool calling / function calling, image input
- Push-to-talk mode
- Multi-language UI localization (the model may still reply in any language)
- **Deferred to after the MVP ([D-027](DECISIONS.md))**: phone-call / Siri / background pause and resume (E5, E6), automatic network reconnect (E7 reconnect part), and silent reconnect at the 60-min session limit (E11)

## 3. Users
| Persona | Need |
|---|---|
| Hands-busy user (cooking, walking) | Talk without looking at the screen; works with AirPods and in the background |
| Curious learner | Fast back-and-forth Q&A; interrupt long answers |
| Developer / demo owner | Doesn't leak the API key; doesn't run up the OpenAI bill from abuse |

## 4. Functional requirements

| ID | Requirement | Priority |
|---|---|---|
| F1 | Tap **Start** to begin a session. The app fetches a short-lived token from the token server and connects to `gpt-realtime-2.1` | P0 |
| F2 | Hands-free conversation with **semantic VAD**: the server decides when the user's turn ends | P0 |
| F3 | Stream the model's audio reply with low latency (first audio < 1.0 s after end of user turn, p50) | P0 |
| F4 | **Live transcript** of user and assistant turns, updating while speaking | P0 |
| F5 | **State indicator (orb)**: idle, connecting, listening, user speaking, thinking, AI speaking, paused, reconnecting, error | P0 |
| F6 | Tap **End** to stop the session; the conversation is saved | P0 |
| F7 | **Persona picker**: 3 preset personas (Quick *(default, short answers)*, Storyteller, Coach), each with a fixed voice. No free-form prompt editing. See [PERSONAS.md](PERSONAS.md) | P1 |
| F10 | AI greets the user in one short sentence when a new session starts | P1 |
| F8 | **History**: past conversations saved on device (SwiftData); list, open, delete | P1 |
| F9 | Mute mic toggle during a session | P1 |

## 5. Voice edge-case requirements (must-have)

| ID | Scenario | Required behaviour | Acceptance |
|---|---|---|---|
| E1 | **Barge-in**: user talks over the AI | AI audio stops **immediately** (< 150 ms locally). The server response is cancelled and the conversation is truncated to what was actually heard | Speaking mid-reply stops playback; the next reply doesn't repeat unheard content |
| E2 | **Echo**: AI hears itself on speaker | No self-interruption when playing through the built-in speaker at max volume | A 60 s monologue on speaker produces 0 false `speech_started` events |
| E3 | **Mic permission denied** | Clear explanation screen with an **Open Settings** button; no crash, no silent failure | Deny permission, then Start → explanation screen; granting in Settings and returning works without relaunch |
| E4 | **AirPods / route change** mid-conversation | Audio moves to the new route (AirPods ↔ speaker ↔ wired/CarPlay) without dropping the session. On disconnect, playback pauses briefly then continues on speaker | Connect/disconnect AirPods 5× mid-reply; session survives, audio comes from the correct device |
| E5 | ⏸ **Deferred (D-027)**. **Phone call / Siri / alarm interruption** | Session pauses (mic off, playback stopped, state = Paused). When the interruption ends, it resumes automatically if the system says `shouldResume`, otherwise shows a "Tap to resume" control | Receive call → paused; hang up → resumes or offers resume; no zombie audio |
| E6 | ⏸ **Deferred (D-027)**; best-effort only (audio background mode is on, untested). **Background** | Conversation continues in the background (audio background mode), including with the screen locked | Lock the phone mid-conversation; keep talking; replies continue |
| E7 | 🟡 **MVP: error + Retry, never hang. Auto-reconnect deferred (D-027)**. **Network drop** | **MVP**: on socket close/error, show "Lost the connection to OpenAI" with **Retry**; release audio; never hang. **Deferred**: Detect within 5 s. Show "Reconnecting…" and retry with backoff (max ~30 s total). On success, start a new session seeded with recent transcript context. On failure, show an error with **Retry**. Never hang | Airplane mode on 10 s then off → reconnects. On for 60 s → error + Retry; UI stays responsive |
| E8 | **API key never ships** | The app holds only a short-lived client secret minted by our token server. The OpenAI key exists only on the server | `strings` on the app binary shows no `sk-` key; the token expires within ~10 min |
| E9 | **Token server abuse** | The server requires a shared app secret and rate-limits per IP | Request without the secret → 401; > N requests/min → 429 |
| E10 | **Token server unreachable / Local Network denied** | If the Mac server can't be reached but the internet works, show "Can't reach the token server" with a checklist (same Wi-Fi, server running, Local Network allowed) + Open Settings. This must be distinct from "No internet" | Deny Local Network, or stop the server → that specific message, no hang |
| E11 | ⏸ **Deferred (D-027)**; needs reconnect. MVP: the 60-min close shows the same error + Retry as E7. **Max session length** | When OpenAI ends the session for its duration limit, reconnect silently with context and no re-greeting | Forced session-expired close → back to Listening, conversation continues |

## 6. Non-functional requirements
| Area | Target |
|---|---|
| Latency | End-of-turn → first audio p50 < 1.0 s, p95 < 2.0 s on good Wi-Fi |
| Barge-in stop | Local playback stops < 150 ms after `speech_started` |
| Stability | 30-min continuous session without crash or memory growth > 50 MB |
| Privacy | Audio is not stored; only transcripts are saved locally. Mic usage string explains why |
| Accessibility | Orb states have VoiceOver labels; transcript supports Dynamic Type |
| Architecture | MVVM, Swift Concurrency (no Combine), Swift Testing for unit tests, XCUIAutomation for UI tests |

## 7. Success metrics (demo / MVP)
- All E1–E9 acceptance checks pass on a physical iPhone
- ≥ 90% of sessions in a test week end without an unrecoverable error
- Barge-in feels instant in manual testing (5/5 testers)

## 8. Out-of-scope risks / open questions
- Voice selection is locked once the model has spoken in a session (API constraint). A voice change applies to the next session.
- Background-audio use must be justified in App Store review (it's a live voice conversation, which is acceptable).
- The token server runs **locally on the dev Mac only**. Paid hosting is out of scope ([D-019](DECISIONS.md)). The iPhone must be on the same Wi-Fi; cellular use isn't supported.
