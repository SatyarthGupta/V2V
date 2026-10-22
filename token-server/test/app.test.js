import { describe, expect, it } from 'vitest';
import request from 'supertest';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';

const testConfig = loadConfig({ OPENAI_API_KEY: 'sk-test', APP_SHARED_SECRET: 'secret' });

describe('GET /healthz', () => {
  it('S-10: returns 200', async () => {
    const res = await request(buildApp({ config: testConfig })).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });
});

describe('loadConfig', () => {
  it('S-11: throws a clear error when OPENAI_API_KEY is missing', () => {
    expect(() => loadConfig({ APP_SHARED_SECRET: 'secret' })).toThrow(/OPENAI_API_KEY/);
  });

  it('S-11: throws when APP_SHARED_SECRET is missing', () => {
    expect(() => loadConfig({ OPENAI_API_KEY: 'sk-test' })).toThrow(/APP_SHARED_SECRET/);
  });

  it('defaults PORT to 8787', () => {
    expect(testConfig.port).toBe(8787);
  });
});
