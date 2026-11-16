/** Real local relay verification with fictional accounts in the guarded *_test PostgreSQL database. */
import assert from 'node:assert/strict';
import { createECDH, randomBytes, randomUUID } from 'node:crypto';
import ece from 'http_ece';
import { createTestApp } from '../test/helpers.js';
import { processPush } from '../src/notifications.js';

// Do not expose response bodies, device endpoints or key material when a diagnostic fails.
function success(response, action) {
  assert.equal(response.statusCode, 200, `${action} failed with HTTP ${response.statusCode}`);
  return response.json();
}

// Read only this random loopback topic and decrypt with the receiver's private key, as a device would.
async function readRelay(origin, topic, receiver, auth) {
  const response = await fetch(`${origin}/${topic}/json?poll=1`, { redirect: 'manual', signal: AbortSignal.timeout(8000) });
  assert.equal(response.status, 200, 'Local relay polling failed');
  const messages = (await response.text()).split('\n').filter(Boolean).map(line => JSON.parse(line)).filter(entry => entry.event === 'message');
  return messages.map(entry => {
    assert.equal(entry.encoding, 'base64', 'The relay must contain opaque encrypted bytes');
    return JSON.parse(ece.decrypt(Buffer.from(entry.message, 'base64'), { version: 'aes128gcm', privateKey: receiver, authSecret: auth }).toString());
  });
}

// This uses the actual API, durable outbox, local ntfy and cryptography; it never registers a real phone.
async function main() {
  const origin = 'http://127.0.0.1:8090';
  const topic = `upbloodcheck${randomUUID().replaceAll('-', '')}`;
  const receiver = createECDH('prime256v1');
  const publicKey = receiver.generateKeys().toString('base64url');
  const auth = randomBytes(16).toString('base64url');
  const { app, store, ctx, request } = await createTestApp({ pushOrigins: new Set([origin]) });
  try {
    success(await request('POST', '/devices', { provider: 'unifiedpush', token: `${origin}/${topic}?up=1`, pub_key: publicKey, auth }, 'demo-donor'), 'Device enrollment');
    const donation = success(await request('POST', '/requests', { blood_type: 'O+', radius_km: 39, donor_ids: ['donor'], destination_name: 'Fictional test hospital', destination_latitude: 23.8, destination_longitude: 90.4 }), 'Donation request');
    await processPush(store, app.settings, ctx);
    const messages = await readRelay(origin, topic, receiver, auth);
    const delivered = messages.find(message => message.request_id === donation.id);
    assert.ok(delivered, 'The encrypted donation invitation did not reach the relay');
    assert.deepEqual(Object.keys(delivered).sort(), ['country', 'event_id', 'kind', 'request_id']);
    const status = await store.transaction('BD', db => db.one('SELECT status FROM push_outbox'));
    assert.equal(status.status, 'sent');

    // A report-review target must remain authorized after its reporter moves and enters cooldown.
    const report = success(await request('POST', '/reports', { conversation_id: 'demo-conversation', reason: 'other', details: 'Fictional local relay verification.' }, 'demo-donor'), 'Report submission');
    success(await request('POST', '/location', { country: 'AU', city: 'Sydney', latitude: -33.86, longitude: 151.2, mode: 'manual' }, 'demo-donor'), 'Travel');
    await store.transaction(null, db => db.run("UPDATE accounts SET available=0,eligible_after_utc='2099-01-01T00:00:00.000Z' WHERE id='donor'"));
    success(await request('POST', `/admin/reports/${report.id}/resolve`, { decision: 'dismiss', note: 'Private local diagnostic review note' }, 'demo-admin'), 'Report review');
    await processPush(store, app.settings, ctx);
    const reviewed = (await readRelay(origin, topic, receiver, auth)).find(message => message.kind === 'report_reviewed');
    assert.ok(reviewed, 'The encrypted report review did not reach the relay');
    assert.deepEqual(Object.keys(reviewed).sort(), ['country', 'event_id', 'kind', 'report_country', 'report_id']);
    assert.equal(reviewed.report_id, report.id);
    assert.equal(reviewed.report_country, 'BD');
    const inbox = success(await request('GET', '/events', undefined, 'demo-donor', 'AU'), 'Cross-country inbox');
    assert.ok(inbox.items.some(item => item.report_id === report.id));
    console.log('PASS: request and cross-travel/cooldown report review -> PostgreSQL outbox -> local ntfy -> authenticated decryption; no personal content in relay payload.');
  } finally { await app.close(); }
}

await main();
