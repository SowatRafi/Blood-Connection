import assert from 'node:assert/strict';
import { createECDH, randomBytes } from 'node:crypto';
import test from 'node:test';
import ece from 'http_ece';
import { createTestApp } from './helpers.js';
import { processPush } from '../src/notifications.js';

const settings = { pushOrigins: new Set(['http://127.0.0.1:8090']) };
const donationRequest = { blood_type: 'O+', radius_km: 10, destination_name: 'Demo Hospital', destination_latitude: 23.811, destination_longitude: 90.413, donor_ids: ['donor'] };

// Each test enrolls a disposable key pair rather than depending on a real phone or push subscription.
function subscription(suffix = 'test') {
  const receiver = createECDH('prime256v1');
  const publicKey = receiver.generateKeys().toString('base64url');
  const auth = randomBytes(16).toString('base64url');
  return { receiver, body: { provider: 'unifiedpush', token: `http://127.0.0.1:8090/up-${suffix}`, pub_key: publicKey, auth } };
}

test('device registration preserves ownership and enforces a five-device cap', async t => {
  const { app, request, store } = await createTestApp(settings);
  t.after(() => app.close());
  const { body } = subscription();
  const first = await request('POST', '/devices', body);
  assert.equal(first.statusCode, 200, first.body);
  assert.equal((await request('POST', '/devices', body)).json().id, first.json().id);
  assert.equal((await request('POST', '/devices', body, 'demo-donor')).statusCode, 409);
  assert.equal((await request('DELETE', '/devices', { token: body.token }, 'demo-donor')).statusCode, 200);
  assert.equal((await store.transaction(null, db => db.one('SELECT COUNT(*)::int AS count FROM devices'))).count, 1);
  for (let i = 1; i < 5; i += 1) assert.equal((await request('POST', '/devices', { ...body, token: `${body.token}-${i}` })).statusCode, 200);
  assert.equal((await request('POST', '/devices', { ...body, token: `${body.token}-sixth` })).statusCode, 409);
  assert.equal((await request('POST', '/devices', { ...body, token: 'https://unapproved.example/push' })).statusCode, 422);
  assert.equal((await request('POST', '/devices', { ...body, auth: 'bad' })).statusCode, 422);
});

test('review notifications remain owner-only after travel, cooldown and blocking', async t => {
  const { app, request, store, ctx } = await createTestApp(settings);
  t.after(() => app.close());
  const { body, receiver } = subscription('review');
  assert.equal((await request('POST', '/devices', body)).statusCode, 200);
  const review = await request('POST', '/admin/reports/demo-report/resolve', { decision: 'dismiss', note: 'Internal review note not for notification delivery' }, 'demo-admin');
  assert.equal(review.statusCode, 200, review.body);
  const moved = await request('POST', '/location', { country: 'AU', city: 'Sydney', latitude: -33.8688, longitude: 151.2093, mode: 'automatic' });
  assert.equal(moved.statusCode, 200, moved.body);
  await store.transaction(null, async db => {
    await db.run("UPDATE accounts SET available=0,eligible_after_utc='2099-01-01T00:00:00.000Z' WHERE id='seeker'");
    await db.run("INSERT INTO blocks(blocker,blocked,created_at) VALUES('seeker','reported',$1)", [ctx.stamp()]);
  });
  const inbox = await request('GET', '/events', undefined, 'demo-seeker', 'AU');
  assert.equal(inbox.statusCode, 200, inbox.body);
  const event = inbox.json().items.find(item => item.report_id === 'demo-report');
  assert.ok(event);
  assert.equal(event.country, 'BD');
  assert.equal(event.request_id, null);
  assert.equal(JSON.stringify(event).includes('Internal review note'), false);
  assert.equal((await request('POST', `/events/${event.id}/read?country=BD`, {}, 'demo-seeker', 'AU')).statusCode, 200);
  assert.equal((await request('POST', `/events/${event.id}/read?country=BD`, {}, 'demo-donor')).statusCode, 404);
  assert.equal((await request('GET', '/events', undefined, 'demo-donor')).json().items.some(item => item.report_id === 'demo-report'), false);
  const sent = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => { sent.push(options); return new Response(null, { status: 201 }); });
  await processPush(store, app.settings, ctx);
  assert.equal(sent.length, 1);
  const payload = JSON.parse(ece.decrypt(sent[0].body, { version: 'aes128gcm', privateKey: receiver, authSecret: body.auth }).toString());
  assert.equal(payload.report_id, 'demo-report');
  assert.equal(payload.report_country, 'BD');
  assert.equal(payload.country, 'BD');
  assert.equal('body' in payload, false);
});

test('donation invitation delivery rechecks cooldown and suppresses ineligible inbox items', async t => {
  const { app, request, store, ctx } = await createTestApp(settings);
  t.after(() => app.close());
  assert.equal((await request('POST', '/devices', subscription('cooldown').body, 'demo-donor')).statusCode, 200);
  const created = await request('POST', '/requests', donationRequest);
  assert.equal(created.statusCode, 200, created.body);
  await store.transaction(null, db => db.run("UPDATE accounts SET eligible_after_utc='2099-01-01T00:00:00.000Z' WHERE id='donor'"));
  const network = t.mock.method(globalThis, 'fetch', async () => new Response(null, { status: 201 }));
  await processPush(store, app.settings, ctx);
  assert.equal(network.mock.callCount(), 0);
  assert.equal((await request('GET', '/events', undefined, 'demo-donor')).json().items.length, 0);
  const job = await store.transaction('BD', db => db.one('SELECT status FROM push_outbox'));
  assert.equal(job.status, 'suppressed');
});

test('outbox retries outages and leases concurrent workers without duplicate delivery', async t => {
  const { app, request, store, ctx } = await createTestApp(settings);
  t.after(() => app.close());
  assert.equal((await request('POST', '/devices', subscription('lease').body, 'demo-donor')).statusCode, 200);
  assert.equal((await request('POST', '/requests', donationRequest)).statusCode, 200);
  let responseStatus = 503;
  const network = t.mock.method(globalThis, 'fetch', async () => {
    await new Promise(resolve => setTimeout(resolve, 15));
    return new Response(null, { status: responseStatus });
  });
  await processPush(store, app.settings, ctx);
  const pending = await store.transaction('BD', db => db.one('SELECT * FROM push_outbox'));
  assert.equal(pending.status, 'pending');
  assert.equal(pending.attempts, 1);
  await store.transaction('BD', db => db.run("UPDATE push_outbox SET next_attempt='2000-01-01T00:00:00.000Z'"));
  responseStatus = 201;
  await Promise.all([processPush(store, app.settings, ctx), processPush(store, app.settings, ctx)]);
  assert.equal(network.mock.callCount(), 2);
  assert.equal((await store.transaction('BD', db => db.one('SELECT status FROM push_outbox'))).status, 'sent');
});

test('sign-out removes pending delivery, and a gone distributor endpoint removes its registration', async t => {
  const { app, request, store, ctx } = await createTestApp(settings);
  t.after(() => app.close());
  const { body } = subscription('removed');
  await request('POST', '/devices', body, 'demo-donor');
  await request('POST', '/requests', donationRequest);
  await request('DELETE', '/devices', { token: body.token }, 'demo-donor');
  const network = t.mock.method(globalThis, 'fetch', async () => new Response(null, { status: 410 }));
  await processPush(store, app.settings, ctx);
  assert.equal(network.mock.callCount(), 0);
  await request('POST', '/devices', body, 'demo-donor');
  await store.transaction('BD', async db => {
    const original = await db.one("SELECT * FROM events WHERE kind='donation_request'");
    await ctx.emitEvent(db, 'donor', 'donation_request', original.title, original.body, original.request_id);
  });
  await processPush(store, app.settings, ctx);
  assert.equal(network.mock.callCount(), 1);
  assert.equal((await store.transaction(null, db => db.one('SELECT COUNT(*)::int AS count FROM devices'))).count, 0);
});

test('regional cursors scan past obsolete events and validate notification IDs', async t => {
  const { app, request, store, ctx } = await createTestApp(settings);
  t.after(() => app.close());
  await store.transaction('BD', async db => {
    await db.run("INSERT INTO events(user_id,kind,title,body,request_id,created_at) SELECT 'seeker','donation_request','Old request','Expired','missing-'||n,$1 FROM generate_series(1,105) n", [ctx.stamp()]);
    await db.run("UPDATE reports SET status='dismissed' WHERE id='demo-report'");
    await ctx.emitEvent(db, 'seeker', 'report_reviewed', 'Reviewed', 'A safe result', null, { report_id: 'demo-report', report_country: 'BD' });
  });
  const response = await request('GET', '/events?country=BD&after=0');
  assert.equal(response.statusCode, 200, response.body);
  assert.equal(response.json().items.length, 1);
  assert.equal(response.json().next_after, '106');
  assert.equal(response.json().cursor_country, 'BD');
  assert.equal((await request('GET', '/events?country=BD&after=106')).json().items.length, 0);
  assert.equal((await request('POST', '/events/106/read', {})).statusCode, 200);
  assert.equal((await request('POST', '/events/not-an-id/read', {})).statusCode, 422);
  assert.equal((await request('GET', '/events?country=ZZ')).statusCode, 404);
  assert.equal((await request('GET', '/events?after=-1')).statusCode, 422);
});
