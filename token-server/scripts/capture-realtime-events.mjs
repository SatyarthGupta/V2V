// Records real Realtime API events to use as Swift test fixtures (v2v-9sr.2).
//
// Usage (token server must be running: `npm run dev`):
//   node --env-file=.env scripts/capture-realtime-events.mjs <speech.pcm> <out-dir>
//
// <speech.pcm> is raw PCM16 LE 24 kHz mono. It's streamed twice: once to get a reply,
// then again mid-reply to capture a barge-in. Audio deltas are shortened and anything
// that looks like a token is redacted before saving.

import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [pcmPath, outDir] = process.argv.slice(2);
if (!pcmPath || !outDir) {
  console.error('usage: capture-realtime-events.mjs <speech.pcm> <out-dir>');
  process.exit(1);
}

const speech = readFileSync(pcmPath);
const silence = Buffer.alloc(24_000 * 2 * 1.5); // 1.5 s of silence ends the turn for VAD
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// 1. Token from our own server (same path the app uses).
const tokenRes = await fetch('http://localhost:8787/session', {
  method: 'POST',
  headers: { 'x-app-secret': process.env.APP_SHARED_SECRET, 'Content-Type': 'application/json' },
  body: JSON.stringify({ personaId: 'storyteller' }),
});
if (!tokenRes.ok) throw new Error(`token server returned ${tokenRes.status}`);
const token = await tokenRes.json();

// 2. Connect with the ephemeral key as a Bearer header (the same way URLSessionWebSocketTask will).
const ws = new WebSocket('wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1', {
  headers: { Authorization: `Bearer ${token.value}` },
});

const firstByType = new Map();
const order = [];
let audioDeltas = 0;
let bargedIn = false;

const redact = (event) => JSON.parse(JSON.stringify(event, (key, value) => {
  if (typeof value === 'string' && /^ek_/.test(value)) return 'ek_REDACTED';
  if (key === 'delta' && event.type === 'response.output_audio.delta') return value.slice(0, 64);
  if (key === 'instructions' && typeof value === 'string') return value.slice(0, 80) + '…';
  return value;
}));

async function streamAudio(buffer) {
  const chunk = 24_000 * 2 * 0.04; // 40 ms
  for (let offset = 0; offset < buffer.length; offset += chunk) {
    ws.send(JSON.stringify({ type: 'input_audio_buffer.append', audio: buffer.subarray(offset, offset + chunk).toString('base64') }));
    await sleep(40);
  }
}

const done = new Promise((resolve, reject) => {
  ws.addEventListener('error', (e) => reject(new Error(`socket error: ${e.message ?? e.type}`)));
  ws.addEventListener('close', (e) => { console.log(`closed ${e.code} ${e.reason}`); resolve(); });

  ws.addEventListener('message', async (message) => {
    const event = JSON.parse(message.data);
    order.push(event.type);
    if (!firstByType.has(event.type)) firstByType.set(event.type, redact(event));

    if (event.type === 'session.created') {
      ws.send(JSON.stringify({
        type: 'session.update',
        session: {
          type: 'realtime',
          output_modalities: ['audio'],
          instructions: token.instructions,
          audio: {
            input: {
              format: { type: 'audio/pcm', rate: 24000 },
              noise_reduction: { type: 'near_field' },
              transcription: { model: 'gpt-4o-mini-transcribe' },
              turn_detection: { type: 'semantic_vad', eagerness: 'auto', interrupt_response: true, create_response: true },
            },
            output: { format: { type: 'audio/pcm', rate: 24000 }, voice: token.voice },
          },
        },
      }));
    }

    if (event.type === 'session.updated') {
      await streamAudio(Buffer.concat([speech, silence]));
    }

    // Barge in once the reply has been talking for a bit.
    if (event.type === 'response.output_audio.delta' && ++audioDeltas === 15 && !bargedIn) {
      bargedIn = true;
      ws.send(JSON.stringify({ type: 'conversation.item.truncate', item_id: event.item_id, content_index: 0, audio_end_ms: 600 }));
      await streamAudio(Buffer.concat([speech, silence]));
    }

    if (event.type === 'error') console.error('server error event:', JSON.stringify(event));
  });
});

// Stop after 45 s regardless, so the script can't hang.
setTimeout(() => ws.close(1000, 'capture finished'), 45_000);
await done;

mkdirSync(outDir, { recursive: true });
for (const [type, event] of firstByType) {
  writeFileSync(join(outDir, `${type}.json`), JSON.stringify(event, null, 2) + '\n');
}
console.log(`saved ${firstByType.size} event types to ${outDir}`);
console.log('event order (deltas collapsed):');
console.log(order.filter((t, i) => t !== order[i - 1]).join('\n'));
