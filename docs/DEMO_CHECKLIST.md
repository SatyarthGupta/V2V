# Demo Checklist: V2V

Run through this before every live demo. Related: [D-019](DECISIONS.md) (local server), [D-021](DECISIONS.md) (`.local` host), [D-022](DECISIONS.md) (debug overlay), [D-027](DECISIONS.md) (MVP scope).

## The day before

- [ ] **OpenAI spending cap**: platform.openai.com → Settings → Limits → set a monthly budget (e.g. $10). A bug that loops requests then can't run up a bill.
- [ ] **Rotate the API key after the demo.** It was pasted in a chat while building. Create a new key, put it in `token-server/.env`, and delete the old one.
- [ ] **Record a backup video**: screen-record (Control Centre → Screen Recording, with the **microphone on**) a full run of the script below. If anything fails live, play the video.
- [ ] **Charge** the iPhone and the earbuds.

## 30 minutes before

- [ ] **Same Wi-Fi**: Mac and iPhone on the *same* network. Conference/office Wi-Fi often blocks phone↔Mac traffic, so see Plan B.
- [ ] **Start the token server and keep the Mac awake:**
  ```bash
  cd ~/Developer/Appdev_day1/V2Vfolder/token-server
  caffeinate -dims npm run dev
  ```
  `caffeinate` stops the Mac sleeping while the server runs. Leave this Terminal window open.
- [ ] **Server health**: from the Mac, `curl http://$(scutil --get LocalHostName).local:8787/healthz` → `{"ok":true}`.
- [ ] **Build fresh**: in Xcode choose **Satyarth Iphone 16** → ⌘R.
- [ ] **Permissions** (Settings → V2V): **Microphone ON** and **Local Network ON**.
- [ ] **Volume up**, ring/silent switch doesn't matter, **Do Not Disturb ON** (calls aren't handled in the MVP, D-027).
- [ ] **Persona**: set to the one you'll open with (Quick is the default).
- [ ] **Smoke test**: Start → hear the greeting → ask one question → End.

## Plan B: Wi-Fi blocks the phone from reaching the Mac

Symptom: *"Can't reach the token server on your Mac…"* even though the server is running.

1. iPhone: Settings → **Personal Hotspot** → on.
2. Mac: join the iPhone's hotspot Wi-Fi.
3. Restart the server (`caffeinate -dims npm run dev`) and tap **Retry** in the app.

The Mac's `.local` name keeps working, and the internet goes over cellular. Test this once **before** the demo day.

## Live demo script (about 3 minutes)

| # | Say / do | Shows |
|---|---|---|
| 1 | Tap **Start** | Greeting in one sentence; orb goes **Listening** |
| 2 | "What's the capital of Japan?" | Short answer (Quick persona), live transcript |
| 3 | **End** → persona **Storyteller** → **Start** → "Tell me a long story about a dragon who learns to cook" | Long, vivid reply |
| 4 | Talk over it mid-sentence: "Wait, make it a cat instead" | **Barge-in**: it stops instantly; bubble shows *Interrupted*; continues with the cat |
| 5 | Phone on the table, speaker loud, stay silent for a bit | **Echo cancellation**: it doesn't interrupt itself |
| 6 | Put earbuds in mid-reply, then switch Bluetooth off mid-reply | Audio moves to the earbuds; on removal the AI stops and goes back to the speaker |
| 7 | **Triple-tap the orb** | Debug overlay: state, route, **reply latency**, events |
| 8 | **End** → tap the **clock** icon | Conversation saved in **History**; open it to show the transcript |
| 9 | (Optional) Settings → V2V → Microphone **off** → Start | Clear "Microphone access is off" card + **Open Settings**; no crash |

Turn the microphone back on after step 9.

## If something goes wrong live

| Symptom | Likely cause | Fix |
|---|---|---|
| "Can't reach the token server…" | Server stopped / Mac asleep / different Wi-Fi / Local Network off | Check the Terminal window, then Wi-Fi, then Settings → V2V → Local Network; then Plan B |
| "No internet connection" | Phone offline | Wi-Fi/cellular, then **Retry** |
| "The token server rejected the app" | Shared secret mismatch | `APP_SHARED_SECRET` in `token-server/.env` must equal `Secrets.swift` |
| "Lost the connection to OpenAI" | Network blip, or the 60-min session limit (no auto-reconnect in MVP) | Tap **Retry** |
| Silence, orb stuck | Audio engine issue | Triple-tap the orb: check *State* and *Route*; End → Start |
| Quiet audio | Output on the earpiece | Should auto-switch to the speaker; End → Start; check the volume |

## Known MVP limitations (say them before anyone asks)

- Phone calls / Siri mid-conversation aren't handled. Tap End → Start afterwards (D-027).
- No automatic reconnect after a network drop. The app shows an error + Retry and never hangs (D-027).
- Works only with the Mac's token server on the same network (no cloud hosting, D-019).
