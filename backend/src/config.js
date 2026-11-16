import { decodeJwt } from 'jose';

/** Parse deployment settings once; secrets never enter public health or log output. */
export function loadSettings(overrides = {}) {
  const list = name => (process.env[name] || '').split(',').map(v => v.trim()).filter(Boolean);
  const settings = {
    demo: process.env.DEMO_MODE === '1',
    host: process.env.HOST || '127.0.0.1', port: Number(process.env.PORT || 8000),
    databaseUrl: process.env.DATABASE_URL || '', migrationDatabaseUrl: process.env.MIGRATION_DATABASE_URL || '',
    supabaseUrl: (process.env.SUPABASE_URL || '').replace(/\/$/, ''), supabaseKey: process.env.SUPABASE_ANON_KEY || '',
    countries: new Set(list('ENABLED_COUNTRIES').map(s => s.toUpperCase())), admins: new Set(list('ADMIN_USER_IDS')),
    origins: list('CORS_ORIGINS').length ? list('CORS_ORIGINS') : ['http://localhost:8080', 'http://127.0.0.1:8080'],
    livekitUrl: process.env.LIVEKIT_URL || '', livekitKey: process.env.LIVEKIT_API_KEY || '', livekitSecret: process.env.LIVEKIT_API_SECRET || '',
    pushOrigins: new Set(list('PUSH_ALLOWED_ORIGINS').map(s => s.replace(/\/$/, ''))),
    apnsKeyPath: process.env.APNS_KEY_PATH || '', apnsKeyId: process.env.APNS_KEY_ID || '',
    apnsTeamId: process.env.APNS_TEAM_ID || '', apnsTopic: process.env.APNS_TOPIC || '', apnsSandbox: process.env.APNS_SANDBOX === '1',
    workers: true, ...overrides,
  };
  if (!settings.databaseUrl) throw new Error('DATABASE_URL is required; see backend/README.md');
  if (settings.demo && !['127.0.0.1', 'localhost', '::1'].includes(settings.host)) throw new Error('Demo mode must bind to loopback');
  if (settings.origins.includes('*')) throw new Error('CORS origins must be explicit');
  for (const origin of settings.origins) {
    const url = new URL(origin);
    if (!['http:', 'https:'].includes(url.protocol) || url.origin !== origin || url.username || url.password) throw new Error('Invalid CORS origin');
  }
  if (settings.supabaseKey.startsWith('sb_secret_')) throw new Error('Use a public Supabase publishable/anon key');
  // This decodes deployment configuration to reject a known privileged key format;
  // it does not authenticate users. auth.js validates sessions with the auth server.
  if (settings.supabaseKey.split('.').length === 3 && decodeJwt(settings.supabaseKey).role === 'service_role') throw new Error('Supabase service-role keys cannot be public client configuration');
  if (settings.supabaseUrl) {
    const url = new URL(settings.supabaseUrl);
    if (url.protocol !== 'https:' || url.origin !== settings.supabaseUrl || url.username || url.password) throw new Error('SUPABASE_URL must be an HTTPS origin');
  }
  if (settings.livekitUrl) {
    const url = new URL(settings.livekitUrl);
    if (!(settings.demo ? ['ws:', 'wss:'] : ['wss:']).includes(url.protocol) || url.username || url.password || url.search || url.hash || !['', '/'].includes(url.pathname)) throw new Error('Invalid LiveKit WebSocket origin');
  }
  settings.callingEnabled = Boolean(settings.livekitUrl && settings.livekitKey && settings.livekitSecret);
  return settings;
}
