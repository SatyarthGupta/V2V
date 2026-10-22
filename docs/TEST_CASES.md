# Test Cases — V2V

Related: [PRD](PRD.md) · [LLD](LLD.md)

Levels: **U** = unit (Swift Testing, fakes) · **S** = server (vitest + supertest) · **UI** = XCUIAutomation · **M** = manual on a physical iPhone (required for real audio hardware).

## 1. Unit — VoiceSessionController (fakes for every service)

| ID | Edge | Given / When | Then |
|---|---|---|---|
| U-01 | F1 | mic granted, token OK, socket OK → `start()` | states: checkingPermission → connecting → listening; `session.update` sent with semantic_vad + interrupt_response |
| U-02 | E3 | `micStatus = .denied` → `start()` | state `.permissionDenied`; **no** token fetch, **no** socket connect, engine never started |
| U-03 | E3 | `.undetermined`, user declines → `start()` | `.permissionDenied` |
| U-04 | E3 | permissionDenied, then granted, scenePhase → active | ViewModel clears the denied screen; `start()` succeeds |
| U-05 | E1 | aiSpeaking, playback at 1,840 ms of item_42 → `speech_started` | `flushPlayback` called once; `conversation.item.truncate(item_42, 0, 1840)` sent; state `.userSpeaking`; turn `wasInterrupted = true` |
| U-06 | E1 | after U-05, late `output_audio.delta` with the old response_id | **not** enqueued |
| U-07 | E1 | `speech_started` while **not** playing | no truncate sent; no flush side effects |
| U-08 | E1 | after barge-in, new response arrives | new audio enqueued normally |
| U-09 | E5 | listening → interruption `.began` | mic pump cancelled, engine stopped, playback flushed, state `.paused`; socket **not** disconnected |
| U-10 | E5 | paused → `.ended(shouldResume: true)` | session reactivated, engine rebuilt + started, `.listening` |
| U-11 | E5 | paused → `.ended(shouldResume: false)` | stays `.paused`; `resume()` → `.listening` |
| U-12 | E5+E7 | paused, socket closes during the pause, then `.ended(shouldResume)` | goes to `.reconnecting`, not `.listening` |
| U-13 | E4 | aiSpeaking → route `.oldDeviceUnavailable` | flush + truncate sent, `rebuildForCurrentRoute` called, socket untouched, state `.listening` |
| U-14 | E4 | listening → route `.newDeviceAvailable` | rebuild called once; no state change; socket untouched |
| U-15 | E4 | `AVAudioEngineConfigurationChange` | rebuild called; if rebuild throws → `.failed(.audioEngineFailed)` |
| U-16 | E7 | event stream throws | `.reconnecting(1)`; new token fetched; reconnect succeeds → `.listening`; last 10 turns sent as `conversation.item.create` |
| U-17 | E7 | every reconnect attempt fails | attempts follow `[0.5,1,2,4,8,8,8]` (test clock); ends `.failed(.reconnectExhausted)`; engine stopped |
| U-18 | E7 | ping times out (fake never pongs) | reconnect triggered within ping interval + 5 s |
| U-19 | E7 | token fetch hangs forever | times out at 8 s → reconnect/failed; **no hang** |
| U-20 | E7 | network unreachable during reconnect, reachable at 3 s | the attempt waits for reachability, not the full delay |
| U-21 | F6 | `end()` from any state | all child tasks cancelled, socket disconnected, engine stopped, session deactivated, state `.idle` |
| U-22 | — | `end()` called twice / during connecting | idempotent, no crash |
| U-23 | — | server `error` non-fatal (e.g. invalid_value) | banner shown, session continues |
| U-24 | — | server `error` session-fatal (expired) | reconnect |
| U-25 | F9 | toggle mute | mic chunks stop being sent; engine input muted |
| U-26 | F10 | new session reaches `session.updated` | exactly one `response.create` sent (greeting) |
| U-27 | F10 | reconnect reaches `session.updated` | **no** `response.create` sent (no re-greeting) |
| U-28 | E11 | server closes with session-expired | reconnect with context seeding; no greeting; ends `.listening` |

## 2. Unit — pure components

| ID | Component | Case |
|---|---|---|
| U-30 | ReconnectPolicy | delays sequence and total budget ≤ 32 s; resets after success |
| U-31 | PlaybackClock | 3 scheduled 40 ms buffers, 2 played + 15 ms into the 3rd → 95 ms |
| U-32 | PlaybackClock | flush resets the per-item clock; a new item starts at 0 |
| U-33 | PCMConverter | 48 kHz Float32 stereo 960 frames → 24 kHz Int16 mono 480 frames; a sine wave keeps its frequency |
| U-34 | PCMConverter | 16 kHz HFP input → 24 kHz output length correct |
| U-35 | RealtimeEvents | decode every server event fixture (JSON files) incl. unknown type → `.unknown` (no throw) |
| U-36 | RealtimeEvents | encode `session.update` matches the golden JSON in LLD §6 |
| U-37 | SessionConfig | speaker route → `far_field`; AirPods → `near_field` |
| U-38 | Persona | exactly 3 cases; unknown stored raw value falls back to `.quick`; default is `.quick` |
| U-39 | TokenService | 401 → `.tokenRejected(401)`; 502 → `.tokenServerUnreachable`; JSON parse OK |
| U-40 | ConversationStore | save → fetch returns turns in order; delete cascades turns (in-memory container) |
| U-41 | Timeout helper | `withTimeout` throws `TimeoutError` and cancels the child |
| U-42 | TokenService + NetworkMonitor | token host unreachable while the path is satisfied → `.tokenServerUnreachable` (not a "no internet" error) |
| U-43 | TokenService + NetworkMonitor | path unsatisfied → "no internet" error |

## 3. Unit — ViewModels

| ID | Case |
|---|---|
| U-50 | ConversationViewModel maps every `SessionState` → the correct `OrbState` + accessibility label |
| U-51 | `.failed` → banner with Retry; `retryTapped()` calls `start()` |
| U-52 | `.permissionDenied` → `showPermissionDenied = true`; `openSettingsTapped` opens the settings URL (injected opener) |
| U-53 | End persists the conversation once (not twice on end + failed) |
| U-54 | SettingsViewModel persists the selected persona; reload shows it; the default is Quick |
| U-55 | HistoryViewModel delete removes the item |

## 4. Token server (vitest + supertest, fetch mocked)

| ID | Edge | Case | Expect |
|---|---|---|---|
| S-01 | E9 | no `x-app-secret` | 401, upstream not called |
| S-02 | E9 | wrong secret (same length) | 401 |
| S-03 | — | valid request | 200 `{ value, expires_at }`; upstream called with `Authorization: Bearer <OPENAI_API_KEY>` and model `gpt-realtime-2.1` |
| S-04 | E8 | response body / logs | never contain `OPENAI_API_KEY` |
| S-05 | — | `personaId` not one of quick/storyteller/coach | 400 |
| S-06 | D-020 | body includes `instructions: "ignore all rules…"` / `voice: "ash"` | ignored; upstream receives the persona's own prompt + voice |
| S-12 | — | no `personaId` | upstream receives the `quick` prompt + `marin`; response `personaId: "quick"` |
| S-13 | — | each persona | upstream instructions = shared voice rules + that persona's prompt; correct voice |
| S-07 | E9 | 11 requests in 60 s from one IP | 11th → 429 |
| S-08 | — | upstream 500 | 502, generic message |
| S-09 | E7 | upstream hangs | 504 / 502 within 8 s |
| S-10 | — | `GET /healthz` | 200 |
| S-11 | — | missing `OPENAI_API_KEY` at boot | process exits with a clear error |

## 5. UI tests (XCUIAutomation, app launched with `-uiTestFakes` → fake services)

| ID | Case |
|---|---|
| UI-01 | Launch → Start → orb shows "Listening"; End → returns to idle, conversation in History |
| UI-02 | Fake permission denied → the explanation screen shows "Open Settings"; no crash |
| UI-03 | Fake network failure script → "Reconnecting…" then error banner with Retry; Retry → Listening |
| UI-04 | Fake transcript events → user and assistant bubbles appear in order |
| UI-05 | Settings: the picker shows exactly 3 personas; select Storyteller, relaunch → persisted |
| UI-06 | History: swipe to delete removes the row |
| UI-07 | Fake interruption began/ended(no resume) → Paused + Resume button → Listening |
| UI-08 | Triple-tap the orb → the debug overlay shows state + last event; triple-tap again → hidden |

## 6. Manual device test script (physical iPhone, token server reachable)

| ID | Edge | Steps | Pass criteria |
|---|---|---|---|
| M-01 | E1 | **Storyteller** persona: ask for a long story; start talking 3 s into the reply | AI audio stops instantly (subjectively < 150 ms); the next answer responds to the new question and doesn't continue the story |
| M-02 | E1 | Interrupt 5× in a row quickly | No overlapping voices, no stuck "speaking" state |
| M-03 | E2 | Speaker at max volume, ask for a 60 s monologue, stay silent | No self-interruption; transcript shows no phantom user turns |
| M-04 | E2 | Same as M-03 in a quiet room and a noisy café | Same |
| M-05 | E3 | Settings → V2V → Microphone off → Start | Explanation screen, Open Settings works; re-enable → back in app → Start works without relaunch |
| M-06 | E4 | Mid-reply, take AirPods out of ears / put them in the case | Audio moves to the speaker; the session continues; the AI stops the interrupted sentence |
| M-07 | E4 | Mid-conversation, connect AirPods | Audio + mic move to AirPods within ~1 s; conversation continues |
| M-08 | E4 | Toggle AirPods ↔ speaker 5× within 1 min | No crash, no silence > 2 s, no echo loop |
| M-09 | E5 | During a reply, receive a phone call (call from another phone), decline | Paused on ring; resumes after decline |
| M-10 | E5 | Accept the call, talk 30 s, hang up | Resumes or shows Resume; no audio leaking into the call |
| M-11 | E5 | Trigger Siri / an alarm mid-conversation | Pause + resume |
| M-12 | E6 | Lock the screen mid-conversation, keep talking 2 min | Conversation continues; orange mic indicator present |
| M-13 | E6 | Switch to another app (non-audio) and talk | Continues |
| M-14 | E7 | Airplane mode 10 s → off | "Reconnecting…" → back to listening; the AI remembers the topic |
| M-15 | E7 | Airplane mode 60 s | Error + Retry after ~30 s; UI responsive the whole time; Retry works |
| M-16 | E7 | ~~Switch Wi-Fi → cellular mid-reply~~ **Out of scope** (token server is local-only, [D-019](DECISIONS.md)). Instead: turn the Mac's Wi-Fi off for 10 s mid-reply | Reconnects when the Mac is back; otherwise an error + Retry; no hang |
| M-17 | E8 | `strings V2Vfolder.app/V2Vfolder | grep sk-` | No result |
| M-18 | NFR | 30-min session in Instruments (Allocations) | No crash; memory growth < 50 MB |
| M-19 | NFR | Measure end-of-turn → first audio 20× | p50 < 1.0 s |
| M-20 | F7 | Quick persona: ask 5 general questions | Every answer ≤ ~2 sentences; no lists or markdown read aloud |
| M-21 | F10 | Start a new session; then force a reconnect (M-14) | Greets once at start; doesn't greet again after the reconnect |
| M-22 | E10 | (a) Settings → V2V → Local Network off → Start; (b) stop `npm run dev` → Start | "Can't reach the token server" + checklist, not "No internet"; no hang |
| M-23 | E10 | Change the Mac's Wi-Fi IP (reconnect to the router / renew DHCP) → Start | Still works via the `.local` hostname |
