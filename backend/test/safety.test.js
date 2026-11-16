import assert from 'node:assert/strict';
import { beforeEach, afterEach, test } from 'node:test';
import sharp from 'sharp';
import { createTestApp } from './helpers.js';

let fixture;
beforeEach(async () => { fixture = await createTestApp(); });
afterEach(async () => { await fixture?.app.close(); });
const reportBody = { conversation_id: 'demo-conversation', reason: 'harassment', details: 'Fictional concern for testing', idempotency_key: 'safety-report-idempotency' };

// Binary uploads use the real Fastify parser and the same authorization headers as the phone.
function imageRequest(method, path, payload, token = 'demo-seeker', country = 'BD', contentType = 'image/png') {
  return fixture.app.inject({ method, url: `/api/v1${path}`, payload,
    headers: { host: '127.0.0.1', authorization: `Bearer ${token}`, 'x-country': country, 'content-type': contentType } });
}

test('message membership and blocks protect contact while reporting remains available', async () => {
  const { request } = fixture;
  assert.equal((await request('GET', '/conversations/demo-conversation/messages', undefined, 'demo-admin')).statusCode, 404);
  assert.equal((await request('POST', '/conversations/demo-conversation/messages', { body: 'Fictional private message' })).statusCode, 200);
  assert.equal((await request('POST', '/blocks', { user_id: 'donor' })).statusCode, 200);
  assert.equal((await request('POST', '/conversations/demo-conversation/messages', { body: 'Blocked message' })).statusCode, 403);
  assert.equal((await request('POST', '/conversations', { donor_id: 'donor' })).statusCode, 404);
  assert.equal((await request('GET', '/conversations/demo-conversation/messages')).statusCode, 200);
  assert.equal((await request('POST', '/reports', reportBody)).statusCode, 200);
  assert.equal((await request('POST', '/reports', { ...reportBody, request_id: 'invented' })).statusCode, 422);
});

test('report retries are owner-scoped and public status never reveals internal evidence', async () => {
  const { request } = fixture;
  const submissions = await Promise.all([request('POST', '/reports', reportBody), request('POST', '/reports', reportBody)]);
  assert.deepEqual(submissions.map(r => r.statusCode), [200, 200]);
  const id = submissions[0].json().id;
  assert.equal(id, submissions[1].json().id);
  assert.equal((await request('POST', '/reports', { ...reportBody, details: 'Different details for same submission' })).statusCode, 409);
  const report = (await request('GET', `/reports/${id}`)).json();
  assert.equal(report.status, 'pending');
  assert.equal(report.outcome, null);
  assert.equal(report.reviewed_at, null);
  assert.equal(report.evidence, undefined);
  assert.equal(report.reported_id, undefined);
  assert.equal((await request('GET', `/reports/${id}`, undefined, 'demo-donor')).statusCode, 404);
  assert.equal((await request('GET', `/reports/${id}`, undefined, 'demo-admin')).statusCode, 404);
  assert.equal((await request('GET', '/admin/reports')).statusCode, 403);
});

test('review, global ban, audit, reporter event and outbox are atomic and resolve only once', async () => {
  const { request, ctx, store } = fixture;
  assert.equal((await request('POST', '/devices', { provider: 'apns', token: 'a'.repeat(64) })).statusCode, 200);
  const original = ctx.emitEvent;
  ctx.emitEvent = async () => { throw new Error('simulated outbox failure'); };
  const body = { decision: 'ban', note: 'Confidential fictional investigation note' };
  assert.equal((await request('POST', '/admin/reports/demo-report/resolve', body, 'demo-admin')).statusCode, 500);
  ctx.emitEvent = original;
  await store.transaction('BD', async db => {
    assert.equal((await db.one("SELECT banned FROM accounts WHERE id='reported'")).banned, 0);
    assert.equal((await db.one("SELECT status FROM reports WHERE id='demo-report'")).status, 'pending');
    assert.equal((await db.all("SELECT id FROM audit WHERE report_id='demo-report'")).length, 0);
  });
  const reviews = await Promise.all([request('POST', '/admin/reports/demo-report/resolve', body, 'demo-admin'), request('POST', '/admin/reports/demo-report/resolve', body, 'demo-admin')]);
  assert.deepEqual(reviews.map(r => r.statusCode).sort(), [200, 409]);
  const report = (await request('GET', '/reports/demo-report')).json();
  assert.equal(report.status, 'reviewed');
  assert.equal(report.outcome, 'banned');
  assert.ok(report.reviewed_at);
  assert.ok(!JSON.stringify(report).includes(body.note));
  await store.transaction('BD', async db => {
    assert.equal((await db.one("SELECT banned FROM accounts WHERE id='reported'")).banned, 1);
    assert.equal((await db.all("SELECT id FROM audit WHERE report_id='demo-report'")).length, 1);
    assert.equal((await db.all("SELECT id FROM events WHERE report_id='demo-report'")).length, 1);
    assert.equal((await db.all('SELECT event_id FROM push_outbox')).length, 1);
  });
});

test('private evidence is sanitized, deduplicated, bounded and immutable after review', async () => {
  const { request } = fixture;
  const { id } = (await request('POST', '/reports', reportBody)).json();
  const image = await sharp({ create: { width: 2400, height: 20, channels: 3, background: '#b42346' } }).png().toBuffer();
  const uploads = await Promise.all([imageRequest('POST', `/reports/${id}/evidence`, image), imageRequest('POST', `/reports/${id}/evidence`, image)]);
  assert.deepEqual(uploads.map(r => r.statusCode), [200, 200]);
  const attachment = uploads[0].json();
  assert.equal(attachment.id, uploads[1].json().id);
  const own = await request('GET', `/reports/${id}/evidence/${attachment.id}`);
  assert.equal(own.statusCode, 200);
  assert.equal(own.headers['cache-control'], 'no-store');
  const metadata = await sharp(own.rawPayload).metadata();
  assert.equal(metadata.format, 'jpeg');
  assert.equal(metadata.width, 2048);
  assert.equal(metadata.exif, undefined);
  assert.equal((await request('GET', `/reports/${id}/evidence/${attachment.id}`, undefined, 'demo-donor')).statusCode, 404);
  assert.equal((await request('GET', `/admin/reports/${id}/evidence/${attachment.id}`, undefined, 'demo-admin')).statusCode, 200);
  assert.equal((await imageRequest('POST', `/reports/${id}/evidence`, Buffer.from('not an image'))).statusCode, 422);
  for (const color of ['#ffffff', '#222222']) {
    const other = await sharp({ create: { width: 8, height: 8, channels: 3, background: color } }).png().toBuffer();
    assert.equal((await imageRequest('POST', `/reports/${id}/evidence`, other)).statusCode, 200);
  }
  const fourth = await sharp({ create: { width: 9, height: 9, channels: 3, background: '#123456' } }).png().toBuffer();
  assert.equal((await imageRequest('POST', `/reports/${id}/evidence`, fourth)).statusCode, 409);
  assert.equal((await request('POST', `/admin/reports/${id}/resolve`, { decision: 'ban', note: 'Not a money-request report' }, 'demo-admin')).statusCode, 422);
  assert.equal((await request('POST', `/admin/reports/${id}/resolve`, { decision: 'dismiss', note: 'Fictional report reviewed' }, 'demo-admin')).statusCode, 200);
  assert.equal((await imageRequest('POST', `/reports/${id}/evidence`, image)).statusCode, 409);
});

test('report owner retains status and evidence after travel without changing active country', async () => {
  const { request } = fixture;
  const image = await sharp({ create: { width: 8, height: 8, channels: 3, background: '#b42346' } }).png().toBuffer();
  const upload = await imageRequest('POST', '/reports/demo-report/evidence', image);
  assert.equal(upload.statusCode, 200);
  assert.equal((await request('POST', '/location', { country: 'AU', city: 'Sydney', latitude: -33.8688, longitude: 151.2093, mode: 'manual' })).statusCode, 200);
  const reports = (await request('GET', '/reports', undefined, 'demo-seeker', 'AU')).json();
  assert.ok(reports.items.some(row => row.id === 'demo-report' && row.country === 'BD'));
  assert.equal((await request('GET', '/reports/demo-report?country=BD', undefined, 'demo-seeker', 'AU')).statusCode, 200);
  assert.equal((await request('GET', `/reports/demo-report/evidence/${upload.json().id}?country=BD`, undefined, 'demo-seeker', 'AU')).statusCode, 200);
  assert.equal((await request('GET', '/me', undefined, 'demo-seeker', 'AU')).json().country, 'AU');
  assert.equal((await request('GET', '/reports/demo-report?country=ZZ', undefined, 'demo-seeker', 'AU')).statusCode, 404);
});

test('an accused administrator cannot inspect or resolve their own allegation', async () => {
  const { request, store } = fixture;
  await store.transaction('BD', async db => {
    await db.run("UPDATE reports SET reported_id='admin' WHERE id='demo-report'");
  });
  const reports = (await request('GET', '/admin/reports', undefined, 'demo-admin')).json();
  assert.ok(!reports.items.some(row => row.id === 'demo-report'));
  assert.equal((await request('POST', '/admin/reports/demo-report/resolve', { decision: 'dismiss', note: 'Attempted self review' }, 'demo-admin')).statusCode, 403);
  assert.equal((await request('GET', '/admin/reports/demo-report/evidence/invented', undefined, 'demo-admin')).statusCode, 404);
});

test('export contains only owner data and deletion keeps enforcement evidence while revoking access', async () => {
  const { request, store } = fixture;
  assert.equal((await request('POST', '/conversations/demo-conversation/messages', { body: 'Fictional owner message' })).statusCode, 200);
  const exported = (await request('GET', '/me/export')).json();
  const messages = exported.regions.flatMap(region => region.messages);
  assert.ok(messages.some(row => row.body === 'Fictional owner message'));
  assert.ok(!messages.some(row => row.id === 'demo-message'));
  const deleted = await request('DELETE', '/me');
  assert.equal(deleted.statusCode, 200);
  assert.deepEqual(deleted.json(), { status: 'deleted', erasure_pending: false });
  assert.equal((await request('GET', '/me')).statusCode, 403);
  await store.transaction('BD', async db => {
    assert.equal((await db.one("SELECT deleted FROM accounts WHERE id='seeker'")).deleted, 1);
    assert.equal(await db.one("SELECT id FROM profiles WHERE id='seeker'"), undefined);
    assert.ok(await db.one("SELECT id FROM reports WHERE id='demo-report'"));
    assert.ok((await db.all("SELECT body FROM messages WHERE sender_id='seeker'")).every(row => row.body === '[Message removed]'));
    assert.equal((await db.all("SELECT user_id FROM deletion_jobs WHERE user_id='seeker'")).length, 0);
  });
});
