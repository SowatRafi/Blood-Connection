import assert from 'node:assert/strict';
import test from 'node:test';
import { jwtVerify } from 'jose';
import { createTestApp } from './helpers.js';
import { cleanupMedia } from '../src/calls.js';

const settings = { livekitUrl: 'wss://media.example.invalid', livekitKey: 'local-test-key', livekitSecret: 'fictional-test-secret-only-never-use-in-production' };

test('calling exposes credentials only after the invited participant accepts and revokes on block', async t => {
  const { app, request, store, ctx } = await createTestApp(settings);
  t.after(() => app.close());
  const started = await request('POST', '/conversations/demo-conversation/calls', {});
  assert.equal(started.statusCode, 200, started.body);
  const id = started.json().id;
  const ringing = await request('GET', `/calls/${id}`);
  assert.equal(ringing.json().status, 'ringing');
  assert.equal('token' in ringing.json(), false);
  assert.equal((await request('GET', '/calls', undefined, 'demo-donor')).json().items[0].id, id);
  assert.equal((await request('GET', `/calls/${id}`, undefined, 'demo-admin')).statusCode, 404);
  assert.equal((await request('POST', `/calls/${id}/accept`, {})).statusCode, 403);
  const accepted = await request('POST', `/calls/${id}/accept`, {}, 'demo-donor');
  assert.equal(accepted.statusCode, 200, accepted.body);
  const { payload } = await jwtVerify(accepted.json().token, Buffer.from(settings.livekitSecret), { issuer: settings.livekitKey, subject: 'donor', algorithms: ['HS256'] });
  assert.equal(payload.video.room, `blood-${id}`);
  assert.deepEqual(payload.video.canPublishSources, ['microphone']);
  assert.equal(payload.video.canPublishData, false);
  assert.equal(typeof (await request('GET', `/calls/${id}`)).json().token, 'string');
  assert.equal((await request('POST', '/blocks', { user_id: 'donor' })).statusCode, 200);
  assert.equal((await request('GET', `/calls/${id}`)).statusCode, 403);
  assert.equal((await store.transaction(null, db => db.one('SELECT COUNT(*)::int AS count FROM media_cleanup'))).count, 1);
  const network = t.mock.method(globalThis, 'fetch', async () => new Response(null, { status: 200 }));
  await cleanupMedia(store, app.settings, ctx);
  assert.equal(network.mock.callCount(), 3);
  assert.equal((await store.transaction(null, db => db.one('SELECT COUNT(*)::int AS count FROM media_cleanup'))).count, 0);
});

test('concurrent starts allow one live call and failed media cleanup survives until retry', async t => {
  const { app, request, store, ctx } = await createTestApp(settings);
  t.after(() => app.close());
  const responses = await Promise.all([
    request('POST', '/conversations/demo-conversation/calls', {}),
    request('POST', '/conversations/demo-conversation/calls', {}),
  ]);
  assert.deepEqual(responses.map(r => r.statusCode).sort(), [200, 409]);
  const id = responses.find(r => r.statusCode === 200).json().id;
  assert.equal((await request('POST', `/calls/${id}/accept`, {}, 'demo-donor')).statusCode, 200);
  let status = 503;
  t.mock.method(globalThis, 'fetch', async () => new Response(null, { status }));
  assert.equal((await request('POST', `/calls/${id}/end`, {})).statusCode, 200);
  assert.equal((await request('GET', `/calls/${id}`)).json().status, 'ended');
  assert.equal((await store.transaction(null, db => db.one('SELECT COUNT(*)::int AS count FROM media_cleanup'))).count, 1);
  status = 200;
  await cleanupMedia(store, app.settings, ctx);
  assert.equal((await store.transaction(null, db => db.one('SELECT COUNT(*)::int AS count FROM media_cleanup'))).count, 0);
});

test('ringing expiry and donor cooldown prevent stale call acceptance', async t => {
  const { app, request, store } = await createTestApp(settings);
  t.after(() => app.close());
  const started = await request('POST', '/conversations/demo-conversation/calls', {});
  assert.equal(started.statusCode, 200, started.body);
  const id = started.json().id;
  await store.transaction(null, db => db.run("UPDATE accounts SET eligible_after_utc='2099-01-01T00:00:00.000Z' WHERE id='donor'"));
  assert.equal((await request('GET', '/calls', undefined, 'demo-donor')).json().items.length, 0);
  assert.equal((await request('POST', `/calls/${id}/accept`, {}, 'demo-donor')).statusCode, 409);
  await store.transaction('BD', db => db.run("UPDATE calls SET expires_at='2000-01-01T00:00:00.000Z' WHERE id=$1", [id]));
  assert.equal((await request('GET', `/calls/${id}`)).json().status, 'ended');
  assert.equal((await request('POST', `/calls/${id}/accept`, {}, 'demo-donor')).statusCode, 409);
});

test('unconfigured calls return an explicit error without creating a fictional connection', async t => {
  const { app, request, store } = await createTestApp();
  t.after(() => app.close());
  const response = await request('POST', '/conversations/demo-conversation/calls', {});
  assert.equal(response.statusCode, 503);
  assert.equal((await store.transaction('BD', db => db.one('SELECT COUNT(*)::int AS count FROM calls'))).count, 0);
});
