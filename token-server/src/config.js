// Reads and validates server configuration from environment variables.
// Throws on missing secrets so the server fails fast at boot (test S-11).

export function loadConfig(env = process.env) {
  const missing = ['OPENAI_API_KEY', 'APP_SHARED_SECRET'].filter((name) => !env[name]);
  if (missing.length > 0) {
    throw new Error(`Missing required environment variable(s): ${missing.join(', ')}. Copy .env.example to .env and fill them in.`);
  }

  return {
    openaiApiKey: env.OPENAI_API_KEY,
    appSharedSecret: env.APP_SHARED_SECRET,
    port: Number(env.PORT ?? 8787),
  };
}
