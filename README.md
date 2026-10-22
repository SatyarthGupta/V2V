# V2V: talk to GPT, hands-free, on your iPhone

A speech-to-speech iPhone app built on OpenAI's **`gpt-realtime-2.1`**. Tap **Start** and just talk. You can interrupt the AI mid-sentence, it doesn't hear itself on the loudspeaker, and it handles Bluetooth earbuds coming and going.

Your OpenAI API key **never goes into the app**. A small token server on your Mac holds it and gives the iPhone short-lived (10-minute) session tokens.

```
iPhone app ──(Wi-Fi, x-app-secret)──▶ token server on your Mac ──(your API key)──▶ OpenAI
     ▲                                         │
     └───────────── short-lived token ◀────────┘
iPhone app ◀═══════ voice (WebSocket) ═══════▶ OpenAI Realtime
```

## Features

- **Hands-free conversation** with server-side semantic turn detection
- **Barge-in**: talk over the AI and it stops instantly; it remembers only what you actually heard
- **Echo cancellation** (Apple voice processing): no self-interruption on the loudspeaker
- **Earbuds in or out mid-reply**: audio switches; on removal the AI stops and moves to the loudspeaker
- **3 personas**: *Quick* (short answers, default), *Storyteller* (long answers, good for showing barge-in), *Coach*
- **Live transcript**, **history** of past conversations (on device), **clear errors** with Retry
- **Hidden debug panel**: triple-tap the orb for state, audio route, reply latency and recent events

**Known limitations (MVP):** phone calls / Siri mid-conversation and automatic network reconnect aren't handled. After a call or a network drop, tap **Retry** or **End → Start**. The iPhone must be on the **same Wi-Fi** as the Mac running the token server. See [`docs/DECISIONS.md`](docs/DECISIONS.md) (D-019, D-027).

---

## What you need

| | Requirement |
|---|---|
| Mac | **Xcode 27** or newer (iOS 27 SDK) |
| iPhone | **iOS 27** or newer, connected to the Mac by cable (or paired for wireless debugging) |
| Network | Mac and iPhone on the **same Wi-Fi** |
| Node.js | **22.9 or newer**: check with `node --version`; install with `brew install node` |
| OpenAI | An **API key** from an account with billing enabled and access to the Realtime API (`gpt-realtime-2.1`) |
| Apple | Any Apple ID (a free one works) to sign the app for your own iPhone |

> A real iPhone is required for voice. The iOS Simulator can build the app and run the tests, but it has no echo cancellation or Bluetooth audio.

> **Older iOS versions:** the app can also be built for iPhones on earlier iOS versions (roughly iOS 17+). Lower **Minimum Deployments** on all 3 targets, then add `if #available(iOS 27, *)` fallbacks for the few iOS 27-only audio APIs it uses. In `AudioEngine.swift`, `installAudioTap`/`AVReadOnlyAudioPCMBuffer`, `connectNode` and `playAudio()` fall back to `installTap`, `connect` and `play()`. In `AudioSessionManager.swift`, the `didBecomeInactive`/`resumptionRecommendation` notifications fall back to `interruptionNotification`, and `.allowBluetoothHFP` falls back to `.allowBluetooth` on versions that predate it. The iOS 17 floor comes from SwiftData, `@Observable` and `AVAudioApplication`. See [D-025](docs/DECISIONS.md).

---

## Setup (about 10 minutes)

### 1. Get the code

```bash
git clone git@github.com:SatyarthGupta/V2V.git
cd V2V
```

### 2. Start the token server on your Mac

```bash
cd token-server
npm install
cp .env.example .env
```

Generate a shared secret (the app sends it so strangers can't use your server):

```bash
openssl rand -hex 32
```

Open `token-server/.env` and fill in:

```ini
OPENAI_API_KEY=sk-...your key...
APP_SHARED_SECRET=...the value from openssl...
PORT=8787
```

`.env` is git-ignored, so your key stays on your Mac. Then start the server and keep this Terminal window open:

```bash
npm run dev
```

You should see `V2V token server listening on port 8787`.

Check it from the Mac:

```bash
curl http://$(scutil --get LocalHostName).local:8787/healthz
# → {"ok":true}
```

### 3. Point the app at your Mac

The app finds your Mac by its Bonjour name, which survives Wi-Fi IP changes. Get the name:

```bash
scutil --get LocalHostName
# e.g. Alexs-MacBook-Pro   →   use  Alexs-MacBook-Pro.local
```

Create the app's secrets file from the template (it's git-ignored):

```bash
cd ..   # back to the repo root
cp config-templates/Secrets.swift.template V2Vfolder/Config/Secrets.swift
```

Edit `V2Vfolder/Config/Secrets.swift`:

```swift
nonisolated enum Secrets {
    static let tokenServerHost = "Alexs-MacBook-Pro.local"   // your name + ".local"
    static let tokenServerPort = 8787
    static let appSharedSecret = "PASTE_THE_SAME_APP_SHARED_SECRET_AS_IN_.env"
}
```

The **shared secret must be identical** in `.env` and `Secrets.swift`.

### 4. Sign the app with your Apple ID

1. Open **`V2Vfolder.xcodeproj`** in Xcode.
2. Xcode → **Settings → Accounts** → add your Apple ID if it isn't there.
3. Select the project in the navigator, then for **each of the 3 targets** (`V2Vfolder`, `V2VfolderTests`, `V2VfolderUITests`) open **Signing & Capabilities** and:
   - set **Team** to your Apple ID / team
   - change **Bundle Identifier** to something unique to you, e.g. `com.yourname.V2V` (and `com.yourname.V2V.Tests`, `com.yourname.V2V.UITests`). The original IDs belong to the author's team and won't sign for you.

### 5. Prepare your iPhone (first time only)

1. Connect the iPhone to the Mac and tap **Trust** if asked.
2. iPhone: **Settings → Privacy & Security → Developer Mode → On**, then restart when prompted.
3. Make sure the iPhone is on the **same Wi-Fi** as the Mac.

### 6. Run it

1. In Xcode's toolbar, pick **your iPhone** as the run destination.
2. Press **⌘R**.
3. *Free Apple ID only:* if iOS says "Untrusted Developer", go to iPhone **Settings → General → VPN & Device Management**, tap your Apple ID, then **Trust**. Run again.
4. In the app, tap **Start** and **Allow** both prompts: **Microphone** and **Local Network**.
5. You should hear a one-sentence greeting. Start talking.

**Try this:** switch the persona (top right) to **Storyteller**, ask for a long story, and talk over it mid-sentence. It stops right away and the bubble shows *Interrupted*.

---

## Troubleshooting

| You see | Fix |
|---|---|
| **"Can't reach the token server on your Mac…"** | Is `npm run dev` still running? Same Wi-Fi? iPhone **Settings → V2V → Local Network** on? Is `tokenServerHost` in `Secrets.swift` exactly `<LocalHostName>.local`? Test from the iPhone: open `http://<LocalHostName>.local:8787/healthz` in Safari. You should see `{"ok":true}`. |
| **"The token server rejected the app…"** | `APP_SHARED_SECRET` in `.env` and `appSharedSecret` in `Secrets.swift` don't match. |
| **"The token server couldn't start a session (error 502)"** | OpenAI rejected the key: check it, billing, and Realtime access. The server's Terminal shows the HTTP status. |
| **"Microphone access is off"** | Tap **Open Settings** and turn the microphone on. |
| **"No internet connection"** | The iPhone itself is offline. |
| Build error: `cannot find 'Secrets' in scope` | You skipped step 3: create `V2Vfolder/Config/Secrets.swift` from the template. |
| Signing errors | Step 4: set your Team and a unique Bundle Identifier on all 3 targets. |
| Office or conference Wi-Fi blocks the phone ↔ Mac connection | Turn on the iPhone's **Personal Hotspot**, connect the Mac to it, restart `npm run dev`, tap **Retry**. |
| Anything else | Triple-tap the orb for the debug panel; the Xcode console also logs every state change. |

More demo tips: [`docs/DEMO_CHECKLIST.md`](docs/DEMO_CHECKLIST.md).

---

## Running the tests

- **App (unit + UI tests):** in Xcode pick an **iPhone simulator** as the destination and press **⌘U**. The UI tests use fake services (`-uiTestFakes`), so they don't need a key, a microphone or the server.
- **Token server:** `cd token-server && npm test`

## Cost and security

- Every conversation uses **your** OpenAI account. Set a monthly budget under OpenAI dashboard → **Settings → Limits**.
- The API key lives only in `token-server/.env` on your Mac. The app only ever gets short-lived `ek_…` tokens.
- The shared secret is a speed bump, not real authentication (it ships inside the app). Don't expose the token server to the internet.
- Never commit `token-server/.env` or `V2Vfolder/Config/Secrets.swift`; both are git-ignored.

## Project layout

```
V2Vfolder/              iOS app (SwiftUI, MVVM, Swift Concurrency)
  App/ Views/ ViewModels/ Domain/ Services/ Models/ Config/
V2VfolderTests/         Swift Testing unit tests (+ live API event fixtures)
V2VfolderUITests/       XCUIAutomation UI tests (fake services)
token-server/           Node + Express token server
config-templates/       Secrets.swift.template
docs/                   PRD, HLD, LLD, test cases, personas, decisions, demo checklist
```

## Docs

[PRD](docs/PRD.md) · [High-level design](docs/HLD.md) · [Low-level design](docs/LLD.md) · [Test cases](docs/TEST_CASES.md) · [Personas](docs/PERSONAS.md) · [Design decisions](docs/DECISIONS.md) · [Demo checklist](docs/DEMO_CHECKLIST.md)
