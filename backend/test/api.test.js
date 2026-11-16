import assert from 'node:assert/strict';
import test from 'node:test';
import { Readable } from 'node:stream';
import sharp from 'sharp';
import { createTestApp } from './helpers.js';
import { loadSettings } from '../src/config.js';
import { coarseMapArea, kmBetween } from '../src/utils.js';

// These are the deliberately public local fixture identities, never real provider credentials.
const donor = 'demo-donor', seeker = 'demo-seeker', admin = 'demo-admin';
const headers = (token = seeker, extra = {}) => ({ host: '127.0.0.1', authorization: `Bearer ${token}`, 'x-country': 'BD', ...extra });
const location = (extra = {}) => ({ country: 'BD', city: 'Dhaka', latitude: 23.82, longitude: 90.42, mode: 'automatic', ...extra });
const move = { country: 'AU', city: 'Sydney', latitude: -33.8688, longitude: 151.2093, mode: 'automatic' };
const profileBody = profile => Object.fromEntries(['display_name', 'blood_type', 'height_cm', 'weight_kg', 'city', 'latitude', 'longitude', 'available'].map(key => [key, profile[key]]));

/** Assert against real HTTP behavior while keeping failure messages inside the local test runner. */
function body(response, status = 200) {
  assert.equal(response.statusCode, status, response.body);
  return response.json();
}
/** Close each application pool before the next test resets the dedicated test database. */
async function fixture(t, overrides) {
  const f = await createTestApp(overrides);
  t.after(() => f.app.close());
  return f;
}
/** Exercise actual query-string parsing and validation instead of calling the search SQL directly. */
function search(f, overrides = {}, token = seeker, country = 'BD') {
  const query = new URLSearchParams({ blood_type: 'O+', radius_km: '39', latitude: '23.811', longitude: '90.413', ...overrides });
  return f.request('GET', `/donors?${query}`, undefined, token, country);
}

test('configuration rejects secret browser keys, unsafe origins and non-loopback demos', () => {
  const settings = { databaseUrl: 'postgresql://example@127.0.0.1/example', demo: false };
  const encoded = `${Buffer.from('{"alg":"HS256"}').toString('base64url')}.${Buffer.from('{"role":"service_role"}').toString('base64url')}.invalid-signature`;
  for (const supabaseKey of ['sb_secret_never-public', encoded]) assert.throws(() => loadSettings({ ...settings, supabaseKey }), /public|service-role/);
  for (const supabaseUrl of ['http://auth.example.invalid', 'https://user:pass@auth.example.invalid', 'https://auth.example.invalid/path']) assert.throws(() => loadSettings({ ...settings, supabaseUrl }));
  assert.throws(() => loadSettings({ ...settings, origins: ['*'] }));
  assert.throws(() => loadSettings({ ...settings, demo: true, host: '0.0.0.0' }));
  assert.throws(() => loadSettings({ ...settings, livekitUrl: 'ws://media.example.invalid' }));
});

test('public configuration and admin assets use security headers without credentials', async t => {
  const f = await fixture(t, { supabaseUrl: 'https://auth.example.invalid', supabaseKey: 'public-anon-key' });
  const config = await f.request('GET', '/auth/config', undefined, '');
  assert.equal(body(config).supabase_anon_key, 'public-anon-key');
  assert.match(config.headers['content-security-policy'], /connect-src 'self' https:\/\/auth.example.invalid/);
  assert.equal(config.headers['cache-control'], 'no-store');
  assert.equal(config.headers['x-content-type-options'], 'nosniff');
  const root = await f.app.inject({ method: 'GET', url: '/', headers: { host: '127.0.0.1' } });
  assert.equal(root.statusCode, 307);
  assert.equal(root.headers.location, '/admin/');
  const asset = await f.app.inject({ method: 'GET', url: '/admin/mark.png', headers: { host: '127.0.0.1' } });
  assert.equal(asset.statusCode, 200);
  assert.match(asset.headers['content-type'], /^image\/png/);
  assert.equal(body(await f.request('GET', '/health', undefined, '')).demo, true);
  const countries = body(await f.request('GET', '/countries', undefined, '')).items;
  assert.ok(countries.some(c => c.code === 'BD') && countries.some(c => c.code === 'AU'));
});

test('demo validates peer and Host, and request limits cover buffered and streamed input', async t => {
  const f = await fixture(t);
  body(await f.app.inject({ method: 'GET', url: '/api/v1/health', remoteAddress: '192.0.2.1', headers: { host: '127.0.0.1', 'x-forwarded-for': '127.0.0.1' } }), 403);
  body(await f.app.inject({ method: 'GET', url: '/api/v1/health', headers: { host: 'public.example.invalid' } }), 403);
  const base = { method: 'POST', url: '/api/v1/reports', headers: headers(seeker, { 'content-type': 'application/json' }) };
  body(await f.app.inject({ ...base, payload: Buffer.alloc(33_000, 120) }), 413);
  body(await f.app.inject({ ...base, payload: Readable.from([Buffer.alloc(16_000, 120), Buffer.alloc(17_000, 120)]) }), 413);
  body(await f.request('GET', '/me', undefined, ''), 401);
  // Object prototype names are not demo tokens; they previously slipped through a plain-object lookup.
  for (const token of ['not-a-demo-token', 'constructor', 'toString', '__proto__']) body(await f.request('GET', '/me', undefined, token), 401);
});

test('production tokens require the approved provider and cannot self-assign administrator privileges', async t => {
  const f = await fixture(t, { demo: false, countries: new Set(['BD', 'AU']), supabaseUrl: 'https://auth.example.invalid', supabaseKey: 'public-key' });
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  let status = 401, identity;
  globalThis.fetch = async (url, options) => {
    assert.equal(url, 'https://auth.example.invalid/auth/v1/user');
    assert.equal(options.redirect, 'manual');
    assert.equal(options.headers.apikey, 'public-key');
    return new Response(JSON.stringify(identity || {}), { status, headers: { 'content-type': 'application/json' } });
  };
  body(await f.request('GET', '/me'), 401);
  status = 200;
  identity = { id: 'unapproved-member', app_metadata: { provider: 'email' }, user_metadata: { role: 'admin', provider: 'google' } };
  body(await f.request('GET', '/me'), 403);
  identity = { id: 'real-member', app_metadata: { provider: 'google' }, user_metadata: { role: 'admin' } };
  assert.equal(body(await f.request('GET', '/me')).role, 'member');
  body(await f.request('GET', '/admin/reports'), 403);
  assert.equal(body(await f.request('GET', '/me', undefined, seeker, 'AU')).country, 'BD');
  body(await f.request('GET', '/conversations', undefined, seeker, 'AU'), 409);
  globalThis.fetch = async () => { throw new Error('Service unavailable'); };
  body(await f.request('GET', '/me'), 503);
});

test('new member bootstrap requires location and administrator bootstrap uses an enabled country', async t => {
  const f = await fixture(t, { demo: false, countries: new Set(['AU', 'BD']), admins: new Set(['admin-id']), supabaseUrl: 'https://auth.example.invalid', supabaseKey: 'public-key' });
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  let identity = 'new-user';
  globalThis.fetch = async () => new Response(JSON.stringify({ id: identity, app_metadata: { provider: 'apple' } }), { status: 200 });
  body(await f.request('GET', '/me', undefined, 'test-token', ''), 409);
  assert.equal(await f.store.transaction(null, db => db.one("SELECT id FROM accounts WHERE id='new-user'")), undefined);
  const created = body(await f.request('POST', '/location', move, 'test-token', 'AU'));
  assert.equal(created.country, 'AU');
  assert.equal(created.blood_type, null);
  assert.equal(body(await f.request('GET', '/me', undefined, 'test-token', '')).country, 'AU');
  identity = 'admin-id';
  const bootstrapped = body(await f.app.inject({ method: 'GET', url: '/api/v1/me', headers: { host: '127.0.0.1', authorization: 'Bearer test-token', origin: 'http://127.0.0.1:8080' } }));
  assert.equal(bootstrapped.role, 'admin');
  assert.equal(bootstrapped.country, 'AU');
});

test('browser member access is blocked while native and browser administrators keep authorized access', async t => {
  const f = await fixture(t);
  for (const browser of [{ origin: 'http://127.0.0.1:8080' }, { 'sec-fetch-site': 'same-origin' }, { 'sec-fetch-mode': 'cors', 'x-client': 'native' }]) {
    for (const path of ['/me', '/conversations', '/admin/reports']) {
      body(await f.app.inject({ method: 'GET', url: `/api/v1${path}`, headers: headers(seeker, browser) }), 403);
    }
    body(await f.app.inject({ method: 'GET', url: '/api/v1/me', headers: headers(admin, browser) }));
    body(await f.app.inject({ method: 'GET', url: '/api/v1/admin/reports', headers: headers(admin, browser) }));
  }
  body(await f.request('GET', '/me'));
  body(await f.request('GET', '/admin/reports', undefined, admin));
});

test('profile input cannot set privileges, bypass limits or overwrite newer location', async t => {
  const f = await fixture(t);
  const original = body(await f.request('GET', '/me'));
  const data = profileBody(original);
  for (const extra of [{ role: 'admin' }, { banned: false }, { height_cm: 99 }, { weight_kg: 301 }, { blood_type: 'unknown' }, { available: 'true' }, { display_name: ' ' }]) body(await f.request('PUT', '/me', { ...data, ...extra }), 422);
  for (const extra of [{ city: ' ' }, { latitude: 91 }, { mode: 'gps-verified' }, { role: 'admin' }]) body(await f.request('POST', '/location', location(extra)), 422);
  body(await f.request('POST', '/location', location({ country: 'ZZ' })), 400);
  for (const mode of ['automatic', 'manual']) {
    body(await f.request('POST', '/location', location({ mode })));
    body(await f.request('PUT', '/me', data), 409);
  }
  const saved = body(await f.request('PUT', '/me', { ...data, city: 'Dhaka', latitude: 23.82, longitude: 90.42, height_cm: 167.64, weight_kg: 68.0388555 }));
  assert.equal(saved.bmi, 24.2);
  assert.equal(saved.role, 'member');
  assert.ok(!Object.hasOwn(saved, 'location'));
});

test('country movement preserves incomplete profile and global cooldown while replacing stale destination data', async t => {
  const f = await fixture(t);
  const cooldown = new Date(Date.now() + 86_400_000).toISOString();
  await f.store.transaction('BD', async db => {
    await db.run("UPDATE profiles SET blood_type=NULL,height_cm=NULL,weight_kg=NULL WHERE id='donor'");
    await db.run("UPDATE accounts SET available=0,eligible_after_utc=$1 WHERE id='donor'", [cooldown]);
    await db.run(`INSERT INTO ${db.schema('AU')}.profiles(id,display_name,blood_type,height_cm,weight_kg,city,latitude,longitude) VALUES('donor','Stale name','AB-',190,100,'Old city',0,0)`);
  });
  const moved = body(await f.request('POST', '/location', move, donor));
  assert.equal(moved.country, 'AU');
  assert.equal(moved.display_name, 'Nadia (demo)');
  assert.equal(moved.blood_type, null);
  assert.equal(moved.bmi, null);
  assert.equal(moved.available, false);
  assert.equal(moved.eligible_after_utc, cooldown);
  assert.equal(body(await f.request('GET', '/me', undefined, donor, '')).country, 'AU');
  await f.store.transaction('BD', async db => {
    assert.equal(await db.one("SELECT id FROM profiles WHERE id='donor'"), undefined);
    assert.ok(await db.one("SELECT id FROM messages WHERE id='demo-message'"));
  });
  const returned = body(await f.request('POST', '/location', location({ mode: 'manual' }), donor, 'BD'));
  assert.equal(returned.country, 'BD');
  assert.equal(returned.location_mode, 'manual');
  assert.equal(returned.eligible_after_utc, cooldown);
});

test('a failing move rolls back source, stale destination and registry together', async t => {
  const f = await fixture(t);
  await f.store.transaction('AU', db => db.run("INSERT INTO profiles(id,display_name,blood_type,height_cm,weight_kg,city,latitude,longitude) VALUES('seeker','Old copy','AB-',190,100,'Old city',0,0)"));
  const original = f.app.ctx.endMatchingCalls;
  f.app.ctx.endMatchingCalls = async () => { throw new Error('Simulated transfer failure'); };
  try { body(await f.request('POST', '/location', move), 500); }
  finally { f.app.ctx.endMatchingCalls = original; }
  const profile = body(await f.request('GET', '/me'));
  assert.equal(profile.country, 'BD');
  assert.equal(profile.location_mode, 'automatic');
  assert.equal((await f.store.transaction('AU', db => db.one("SELECT display_name FROM profiles WHERE id='seeker'"))).display_name, 'Old copy');
});

test('unchanged location readings do not rewrite the profile or consume shared rate limits', async t => {
  const f = await fixture(t);
  const data = location();
  body(await f.request('POST', '/location', data));
  const before = await f.store.transaction('BD', db => db.one("SELECT xmin::text AS version FROM profiles WHERE id='seeker'"));
  for (let i = 0; i < 65; i += 1) body(await f.request('POST', '/location', data));
  const after = await f.store.transaction('BD', db => db.one("SELECT xmin::text AS version FROM profiles WHERE id='seeker'"));
  assert.equal(after.version, before.version);
  for (let i = 1; i < 60; i += 1) body(await f.request('POST', '/location', { ...data, latitude: 23.82 + i / 10_000 }));
  const limited = await f.request('POST', '/location', { ...data, latitude: 23.84 });
  body(limited, 429);
  assert.ok(limited.headers['retry-after']);
  assert.equal(body(await f.request('POST', '/location', { ...data, latitude: 23.82 + 59 / 10_000, mode: 'manual' })).location_mode, 'manual');
});

test('search applies private PostGIS radius and returns only the approved coarse projection', async t => {
  const f = await fixture(t);
  const result = body(await search(f));
  assert.equal(result.items.length, 2);
  for (const candidate of result.items) {
    assert.deepEqual(Object.keys(candidate).sort(), ['id', 'display_name', 'blood_type', 'city', 'distance_band', 'map_area'].sort());
    assert.deepEqual(Object.keys(candidate.map_area).sort(), ['id', 'latitude', 'longitude'].sort());
  }
  for (const radius_km of [0, 39.1, 100]) body(await search(f, { radius_km }), 422);
  body(await search(f, { latitude: -33.86 }), 409);
  body(await search(f, { blood_type: 'universal' }), 422);
  body(await search(f, { latitude: 'nan' }), 422);
  body(await search(f, { latitude: 'Infinity' }), 422);
  assert.ok(body(await search(f, { radius_km: 1 })).items.some(item => item.id === 'donor'));
  await f.store.transaction(null, db => db.run("UPDATE accounts SET available=0 WHERE id='donor'"));
  assert.ok(!body(await search(f)).items.some(item => item.id === 'donor'));
  await f.store.transaction(null, db => db.run("UPDATE accounts SET banned=1 WHERE id='donor-two'"));
  assert.deepEqual(body(await search(f)).items, []);
});

test('map markers are stable across searches and preserve polar and date-line cells', async t => {
  const f = await fixture(t);
  const first = Object.fromEntries(body(await search(f)).items.map(row => [row.id, row.map_area]));
  const moved = Object.fromEntries(body(await search(f, { latitude: 23.812, longitude: 90.414, radius_km: 10 })).items.map(row => [row.id, row.map_area]));
  assert.deepEqual(first, moved);
  assert.deepEqual(first.donor, coarseMapArea(23.8103, 90.4125));
  assert.deepEqual(coarseMapArea(23.8103, 90.4125), coarseMapArea(23.8113, 90.4135));
  assert.notEqual(coarseMapArea(23.8103, 90.4125).id, coarseMapArea(23.91, 90.4125).id);
  assert.deepEqual(coarseMapArea(10.01, 180), coarseMapArea(10.01, -180));
  assert.deepEqual(coarseMapArea(10.01, 179.999), coarseMapArea(10.01, -179.999));
  assert.deepEqual(coarseMapArea(89.99, -179), coarseMapArea(90, 120));
  assert.deepEqual(coarseMapArea(-89.99, -170), coarseMapArea(-90, 70));
  for (const latitude of [-90, -89.975, -89.925, -80, -45, 0, 45, 80, 89.925, 89.975, 90]) {
    for (const longitude of [-180, -179.999, 0, 179.999, 180]) {
      const area = coarseMapArea(latitude, longitude);
      assert.ok(area.latitude >= -90 && area.latitude <= 90 && area.longitude >= -180 && area.longitude < 180);
      assert.deepEqual(area, coarseMapArea(area.latitude, area.longitude));
    }
    if (Math.abs(latitude) < 89.95) {
      const area = coarseMapArea(latitude, 0), poleward = Math.max(Math.abs(area.latitude - 0.025), Math.abs(area.latitude + 0.025));
      let step = 0.001, neighbor;
      do { step *= 2; neighbor = coarseMapArea(latitude, step); } while (neighbor.id === area.id);
      assert.ok(kmBetween(area.latitude - 0.025, 0, area.latitude + 0.025, 0) >= 5);
      assert.ok(kmBetween(poleward, area.longitude, poleward, neighbor.longitude) >= 5);
    }
  }
});

test('photo bytes are sanitized and private before acceptance and after revocation', async t => {
  const f = await fixture(t);
  const image = await sharp({ create: { width: 1000, height: 500, channels: 3, background: '#aa1234' } }).jpeg().withMetadata({ orientation: 6 }).toBuffer();
  const uploaded = await f.app.inject({ method: 'PUT', url: '/api/v1/me/photo', headers: headers(donor, { 'content-type': 'image/jpeg' }), payload: image });
  assert.equal(body(uploaded).has_photo, true);
  body(await f.request('GET', '/profiles/donor/photo'), 404);
  body(await f.request('GET', '/profiles/donor/photo', undefined, admin), 404);
  const own = await f.request('GET', '/profiles/donor/photo', undefined, donor);
  assert.equal(own.statusCode, 200);
  assert.equal(own.headers['cache-control'], 'no-store');
  const metadata = await sharp(own.rawPayload).metadata();
  assert.equal(metadata.format, 'jpeg');
  assert.equal(metadata.exif, undefined);
  assert.equal(metadata.orientation, undefined);
  assert.ok(metadata.width <= 512 && metadata.height <= 512);
  const created = body(await f.request('POST', '/requests', { blood_type: 'O+', radius_km: 39, destination_name: 'Demo Hospital', destination_latitude: 23.8, destination_longitude: 90.4, donor_ids: ['donor'] }));
  body(await f.request('POST', `/requests/${created.id}/accept`, {}, donor));
  assert.equal((await f.request('GET', '/profiles/donor/photo')).statusCode, 200);
  body(await f.request('POST', `/requests/${created.id}/cancel`, {}));
  body(await f.request('GET', '/profiles/donor/photo'), 404);
  body(await f.request('DELETE', '/me/photo', undefined, donor));
  body(await f.request('GET', '/profiles/donor/photo', undefined, donor), 404);
});

test('photo upload rejects wrong MIME, oversized bodies and non-image bytes', async t => {
  const f = await fixture(t);
  body(await f.app.inject({ method: 'PUT', url: '/api/v1/me/photo', headers: headers(donor, { 'content-type': 'text/plain' }), payload: 'not an image' }), 415);
  body(await f.app.inject({ method: 'PUT', url: '/api/v1/me/photo', headers: headers(donor, { 'content-type': 'image/png' }), payload: Buffer.from('not an image') }), 422);
  body(await f.app.inject({ method: 'PUT', url: '/api/v1/me/photo', headers: headers(donor, { 'content-type': 'image/png' }), payload: Buffer.alloc(5 * 1024 * 1024 + 1) }), 413);
  const tooLarge = await sharp({ create: { width: 4000, height: 4000, channels: 3, background: '#ffffff' } }).png().toBuffer();
  body(await f.app.inject({ method: 'PUT', url: '/api/v1/me/photo', headers: headers(donor, { 'content-type': 'image/png' }), payload: tooLarge }), 422);
});
