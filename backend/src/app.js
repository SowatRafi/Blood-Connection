import Fastify from 'fastify';
import helmet from '@fastify/helmet';
import cors from '@fastify/cors';
import staticFiles from '@fastify/static';
import swagger from '@fastify/swagger';
import { fileURLToPath } from 'node:url';
import { loadSettings } from './config.js';
import { Store } from './store.js';
import { authContext } from './auth.js';
import * as shared from './shared.js';
import * as utils from './utils.js';
import { HttpError } from './errors.js';
import { registerProfileRoutes } from './profiles.js';
import { registerDonationRoutes, expireRequests } from './donations.js';
import { registerSafetyRoutes, scrubDeletedAccounts } from './safety.js';
import { registerNotificationRoutes, processPush } from './notifications.js';
import { registerCallRoutes, cleanupMedia } from './calls.js';

/** Factory separates tests from the listener and keeps the mobile/admin API stable during migration. */
export async function createApp(overrides = {}, options = {}) {
  const settings = loadSettings(overrides);
  const store = options.store || new Store(settings);
  await store.initialize();
  if (settings.demo) await store.seed();
  const app = Fastify({ bodyLimit: 32768, trustProxy: false, logger: false,
    ajv: { customOptions: { removeAdditional: false, coerceTypes: false, useDefaults: true } } });
  const ctx = { store, settings, ...utils, ...shared, ...authContext(store, settings) };
  ctx.expireRequests = (db, country) => expireRequests(db, country, ctx);
  app.decorate('ctx', ctx);
  app.decorate('store', store);
  app.decorate('settings', settings);
  app.decorateRequest('user', null);

  // Never trust forwarded IPs or Host headers to make public demo credentials safe on a network listener.
  app.addHook('onRequest', async request => {
    if (!settings.demo) return;
    const host = request.headers.host || '';
    const validHost = /^(localhost|127\.0\.0\.1|\[::1\])(?::\d+)?$/i.test(host);
    if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(request.ip) || !validHost) throw new HttpError(403, 'Demo mode is only available over loopback');
  });
  await app.register(helmet, { contentSecurityPolicy: { directives: {
    defaultSrc: ["'self'"], scriptSrc: ["'self'"], styleSrc: ["'self'"],
    connectSrc: ["'self'", ...(settings.supabaseUrl ? [settings.supabaseUrl] : [])], imgSrc: ["'self'", 'data:', 'blob:'],
    frameAncestors: ["'none'"], baseUri: ["'self'"], formAction: ["'self'"], upgradeInsecureRequests: settings.demo ? null : [],
  } }, referrerPolicy: { policy: 'no-referrer' }, hsts: !settings.demo });
  await app.register(cors, { origin: settings.origins, methods: ['GET', 'POST', 'PUT', 'DELETE'], allowedHeaders: ['Authorization', 'Content-Type', 'X-Country'] });
  // Generate the contract from the same route schemas used for validation, avoiding a second manual API spec.
  await app.register(swagger, { openapi: { info: { title: 'Blood Connection', version: '0.1.0' } } });
  app.addHook('onSend', async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    reply.header('Permissions-Policy', 'camera=(), geolocation=(self), microphone=(self)');
  });
  // Only image routes have a larger body limit; Fastify enforces it on streamed bodies as well.
  app.addContentTypeParser(['image/jpeg', 'image/png'], { parseAs: 'buffer' }, (request, body, done) => done(null, body));
  app.addHook('preValidation', async request => {
    const trim = value => typeof value === 'string' ? value.trim() : Array.isArray(value) ? value.map(trim)
      : value && typeof value === 'object' && !Buffer.isBuffer(value) ? Object.fromEntries(Object.entries(value).map(([k, v]) => [k, trim(v)])) : value;
    request.body = trim(request.body);
    // HTTP query values are strings; body values remain strictly typed, especially UTC offsets/booleans.
    for (const key of ['radius_km', 'latitude', 'longitude', 'after']) {
      if (typeof request.query?.[key] === 'string' && request.query[key].trim() !== '' && Number.isFinite(Number(request.query[key]))) request.query[key] = Number(request.query[key]);
    }
  });
  app.setErrorHandler((error, request, reply) => {
    if (error.validation) return reply.code(422).send({ detail: 'Check the information you entered' });
    if (error instanceof HttpError || (error.statusCode >= 400 && error.statusCode < 500 && !error.code)) {
      if (error.statusCode === 429) reply.header('Retry-After', '60');
      return reply.code(error.statusCode).send({ detail: error.message });
    }
    if (error.code === '23505' || ['40001', '40P01'].includes(error.code)) return reply.code(409).send({ detail: 'This information changed. Refresh and try again' });
    if (error.code === 'FST_ERR_CTP_BODY_TOO_LARGE') return reply.code(413).send({ detail: 'Request body is too large' });
    if (error.code === 'FST_ERR_CTP_INVALID_MEDIA_TYPE') return reply.code(415).send({ detail: 'Use JSON, JPEG or PNG as required by this action' });
    if (error.statusCode === 400) return reply.code(400).send({ detail: 'Invalid request' });
    // No tokens, SQL values, health records or rejected payloads enter errors or logs.
    app.log.error({ code: error.code || 'internal' }, 'Request failed');
    return reply.code(500).send({ detail: 'Something went wrong. Please try again' });
  });
  app.setNotFoundHandler((request, reply) => reply.code(404).send({ detail: 'Not found' }));
  app.get('/api/v1/health', () => ({ status: 'ok', demo: settings.demo, calling_enabled: settings.callingEnabled }));
  app.get('/api/v1/auth/config', () => ({ supabase_url: settings.supabaseUrl || null, supabase_anon_key: settings.supabaseKey || null }));
  app.get('/openapi.json', { schema: { hide: true } }, () => app.swagger());
  app.get('/api/v1/countries', () => ({ items: Object.entries(utils.COUNTRIES).filter(([code]) => (settings.demo || settings.countries.has(code)) && store.countries().includes(code)).map(([code, name]) => ({ code, name })).sort((a, b) => a.name.localeCompare(b.name)) }));
  app.get('/', (request, reply) => reply.redirect('/admin/', 307));
  registerProfileRoutes(app, ctx);
  registerDonationRoutes(app, ctx);
  registerSafetyRoutes(app, ctx);
  registerNotificationRoutes(app, ctx);
  registerCallRoutes(app, ctx);
  await app.register(staticFiles, { root: fileURLToPath(new URL('../../admin/', import.meta.url)), prefix: '/admin/', index: ['index.html'], redirect: true });

  let timer, running;
  const work = async () => {
    if (running) return;
    running = (async () => {
      try {
        await scrubDeletedAccounts(store, ctx);
        await cleanupMedia(store, settings, ctx);
        await processPush(store, settings, ctx);
        await store.transaction(null, db => db.run('DELETE FROM rate_limits WHERE window_start<$1', [Date.now() - 86400000]));
      } catch (error) { app.log.error({ code: error.code || 'worker' }, 'Background work will retry'); }
    })();
    await running;
    running = null;
  };
  app.addHook('onReady', async () => { if (settings.workers) { timer = setInterval(work, 15000); timer.unref(); } });
  app.addHook('onClose', async () => { clearInterval(timer); await running; await store.close(); });
  await app.ready();
  return app;
}
