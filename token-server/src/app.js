import { createHash, timingSafeEqual } from 'node:crypto';
import express from 'express';
import helmet from 'helmet';
import { rateLimit } from 'express-rate-limit';
import { resolvePersona } from './personas.js';

export const REALTIME_MODEL = 'gpt-realtime-2.1';
const CLIENT_SECRETS_URL = 'https://api.openai.com/v1/realtime/client_secrets';
const TOKEN_TTL_SECONDS = 600;

// Builds the Express app. Dependencies are injected so tests can pass a fake
// `fetchImpl` instead of calling OpenAI (docs/LLD.md §9).
export function buildApp({
  config,
  fetchImpl = fetch,
  upstreamTimeoutMs = 8000,
  rateLimitPerMinute = 10,
  logger = console,
} = {}) {
  if (!config) {
    throw new Error('buildApp requires a config (see loadConfig)');
  }

  const app = express();
  app.disable('x-powered-by');
  app.use(helmet());
  app.use(express.json({ limit: '4kb' }));

  app.get('/healthz', (_req, res) => {
    res.json({ ok: true });
  });

  const sessionLimiter = rateLimit({
    windowMs: 60_000,
    limit: rateLimitPerMinute,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    message: { error: 'rate_limited' },
  });

  app.post('/session', sessionLimiter, requireAppSecret(config.appSharedSecret), async (req, res) => {
    // Only personaId is read from the body; client-sent instructions/voice are ignored (D-020).
    const persona = resolvePersona(req.body?.personaId);
    if (!persona) {
      return res.status(400).json({ error: 'invalid_persona' });
    }

    const upstreamBody = {
      expires_after: { anchor: 'created_at', seconds: TOKEN_TTL_SECONDS },
      session: {
        type: 'realtime',
        model: REALTIME_MODEL,
        instructions: persona.instructions,
        audio: {
          input: { turn_detection: { type: 'semantic_vad' } },
          output: { voice: persona.voice },
        },
      },
    };

    let upstream;
    try {
      upstream = await fetchImpl(CLIENT_SECRETS_URL, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${config.openaiApiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(upstreamBody),
        signal: AbortSignal.timeout(upstreamTimeoutMs),
      });
    } catch (error) {
      const timedOut = error?.name === 'TimeoutError' || error?.name === 'AbortError';
      logger.error(`client_secrets request failed: ${timedOut ? 'timeout' : error?.name ?? 'error'}`);
      return res.status(timedOut ? 504 : 502).json({ error: 'upstream_unavailable' });
    }

    if (!upstream.ok) {
      // Don't forward upstream details to the client; log only the status.
      logger.error(`client_secrets returned HTTP ${upstream.status}`);
      return res.status(502).json({ error: 'upstream_error' });
    }

    let data;
    try {
      data = await upstream.json();
    } catch {
      logger.error('client_secrets returned invalid JSON');
      return res.status(502).json({ error: 'upstream_error' });
    }

    if (typeof data?.value !== 'string') {
      logger.error('client_secrets response missing value');
      return res.status(502).json({ error: 'upstream_error' });
    }

    return res.json({
      value: data.value,
      expires_at: data.expires_at,
      personaId: persona.id,
      voice: persona.voice,
      instructions: persona.instructions,
    });
  });

  return app;
}

// Rejects requests without the correct x-app-secret header (PRD E9).
// Both values are hashed first so timingSafeEqual always compares equal lengths.
function requireAppSecret(expectedSecret) {
  const expectedDigest = sha256(expectedSecret);
  return (req, res, next) => {
    const provided = req.get('x-app-secret');
    if (!provided || !timingSafeEqual(sha256(provided), expectedDigest)) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    return next();
  };
}

function sha256(value) {
  return createHash('sha256').update(value).digest();
}
