import { createApp } from '../src/app.js';
import { loadSettings } from '../src/config.js';
import { Store } from '../src/store.js';

/** Tests can reset only the dedicated *_test database; no interactive demo or production data is touched. */
export async function createTestApp(overrides = {}) {
  const settings = loadSettings({ demo: true, workers: false,
    databaseUrl: process.env.TEST_DATABASE_URL || 'postgresql://blood_connection_app:local-development-runtime-only@127.0.0.1:5436/blood_connection_test',
    migrationDatabaseUrl: process.env.TEST_MIGRATION_DATABASE_URL || 'postgresql://blood_connection_migrator:local-development-migration-only@127.0.0.1:5436/blood_connection_test',
    ...overrides });
  const store = new Store(settings);
  await store.migrate(['BD', 'AU']);
  await store.resetForTests();
  const app = await createApp(settings, { store });
  const request = (method, path, payload, token = 'demo-seeker', country = 'BD') => app.inject({ method,
    url: path.startsWith('/api/') ? path : `/api/v1${path}`, payload,
    headers: { host: '127.0.0.1', ...(token ? { authorization: `Bearer ${token}` } : {}), ...(country ? { 'x-country': country } : {}) } });
  return { app, store, ctx: app.ctx, request };
}
