import assert from 'node:assert/strict';
import test from 'node:test';
import { createTestApp } from './helpers.js';
import { addThreeMonths } from '../src/utils.js';
import { requestResult } from '../src/donations.js';

// Relative calendar dates keep the fixture meaningful as time passes; all people and places are fictional.
const donorToken = 'demo-donor';
const seekerToken = 'demo-seeker';
const adminToken = 'demo-admin';
const today = () => new Date().toISOString().slice(0, 10);
const dateAgo = days => new Date(Date.now() - days * 86_400_000).toISOString().slice(0, 10);
const requestBody = (donors = ['donor']) => ({ blood_type: 'O+', radius_km: 39, destination_name: 'Demo Hospital main entrance', destination_latitude: 23.8, destination_longitude: 90.4, donor_ids: donors });
const donationBody = (extra = {}) => ({ donated_at: today(), facility_name: 'Demo Blood Bank', location_name: 'Dhaka', country: 'BD', ...extra });

/** Include the response when assertions fail so API regressions can be diagnosed without private logging. */
function body(response, status = 200) {
  assert.equal(response.statusCode, status, response.body);
  return response.json();
}

/** Each scenario owns a resettable dedicated test database; the interactive demo database is never used. */
async function fixture(t) {
  const f = await createTestApp();
  t.after(() => f.app.close());
  return f;
}

/** Real requests establish the relationship rather than forging completion receipts in test setup. */
async function matched(f, { complete = false, donors = ['donor'] } = {}) {
  const rid = body(await f.request('POST', '/requests', requestBody(donors))).id;
  body(await f.request('POST', `/requests/${rid}/accept`, {}, donorToken));
  if (complete) body(await f.request('POST', `/requests/${rid}/complete`, {}));
  return rid;
}

test('calendar month cooldowns clamp month-end and preserve leap years', () => {
  assert.equal(addThreeMonths('2023-11-30'), '2024-02-29');
  assert.equal(addThreeMonths('2024-11-30'), '2025-02-28');
  assert.equal(addThreeMonths('2026-01-31'), '2026-04-30');
  assert.equal(addThreeMonths('0099-11-30'), '0100-02-28');
});

test('request validation enforces radius, explicit group and selected donor eligibility', async t => {
  const f = await fixture(t);
  for (const extra of [{ radius_km: 40 }, { radius_km: 0 }, { blood_type: 'C+' }, { destination_name: ' ' }, { destination_latitude: 91 }, { admin: true }, { donor_ids: [] }]) {
    body(await f.request('POST', '/requests', { ...requestBody(), ...extra }), 422);
  }
  body(await f.request('POST', '/requests', requestBody(['donor-three'])), 409);
  body(await f.request('POST', '/requests', requestBody(['missing-account'])), 409);
  const request = body(await f.request('POST', '/requests', requestBody()));
  body(await f.request('POST', '/requests', requestBody()), 409);
  body(await f.request('GET', `/requests/${request.id}`, undefined, adminToken), 404);
  body(await f.request('POST', `/requests/${request.id}/accept`, {}, adminToken), 404);
});

test('only the accepted pair receives private meeting and counterpart fields', async t => {
  const f = await fixture(t);
  const rid = body(await f.request('POST', '/requests', requestBody(['donor', 'donor-two']))).id;
  const invitation = body(await f.request('GET', `/requests/${rid}`, undefined, donorToken));
  assert.equal(invitation.peer_id, null);
  assert.equal(invitation.conversation_id, null);
  assert.equal(invitation.peer_has_photo, false);
  assert.ok(!Object.hasOwn(invitation, 'destination_latitude'));
  body(await f.request('POST', `/requests/${rid}/accept`, {}, donorToken));
  const accepted = body(await f.request('GET', `/requests/${rid}`, undefined, donorToken));
  assert.equal(accepted.peer_id, 'seeker');
  assert.equal(accepted.destination_latitude, 23.8);
  assert.ok(accepted.conversation_id);
  const outsider = await f.store.transaction('BD', db => requestResult(db, rid, 'donor-two'));
  assert.equal(outsider.peer_id, null);
  assert.ok(!Object.hasOwn(outsider, 'destination_longitude'));
  body(await f.request('POST', `/requests/${rid}/cancel`, {}));
  const closed = body(await f.request('GET', `/requests/${rid}`, undefined, donorToken));
  assert.equal(closed.peer_id, null);
  assert.equal(closed.conversation_id, null);
  assert.ok(!Object.hasOwn(closed, 'destination_latitude'));
  assert.equal(closed.can_report, true);
});

test('simultaneous acceptance has one winner, one event and a personal thanks for the other donor', async t => {
  const f = await fixture(t);
  await f.store.transaction('BD', async db => {
    await db.run("UPDATE accounts SET available=1 WHERE id='admin'");
    await db.run("UPDATE profiles SET blood_type='O+' WHERE id='admin'");
  });
  const rid = body(await f.request('POST', '/requests', requestBody(['donor', 'admin']))).id;
  const tokens = [donorToken, adminToken];
  const responses = await Promise.all(tokens.map(token => f.request('POST', `/requests/${rid}/accept`, {}, token)));
  assert.deepEqual(responses.map(r => r.statusCode).sort(), [200, 409], responses.map(r => r.body).join('\n'));
  const winner = tokens[responses.findIndex(r => r.statusCode === 200)];
  const loser = tokens[responses.findIndex(r => r.statusCode === 409)];
  body(await f.request('POST', `/requests/${rid}/accept`, {}, winner));
  body(await f.request('POST', '/requests', requestBody(), winner), 409);
  body(await f.request('POST', `/requests/${rid}/complete`, {}));
  const events = body(await f.request('GET', '/events', undefined, loser)).items;
  assert.equal(events.length, 1);
  assert.equal(events[0].kind, 'thank_you');
  assert.ok(events[0].body.includes(body(await f.request('GET', '/me', undefined, loser)).display_name));
  const counts = await f.store.transaction('BD', async db => ({
    accepted: await db.one("SELECT COUNT(*)::int AS count FROM events WHERE kind='request_accepted'"),
    matches: await db.one('SELECT COUNT(*)::int AS count FROM active_matches'),
    participants: await db.one('SELECT COUNT(*)::int AS count FROM match_participants'),
  }));
  assert.equal(counts.accepted.count, 1);
  assert.equal(counts.matches.count, 0);
  assert.equal(counts.participants.count, 0);
});

test('cooldown and declined invitation cannot be bypassed by accepting an old request', async t => {
  const f = await fixture(t);
  const rid = body(await f.request('POST', '/requests', requestBody())).id;
  body(await f.request('POST', '/donations', donationBody(), donorToken));
  body(await f.request('POST', `/requests/${rid}/accept`, {}, donorToken), 409);
  assert.deepEqual(body(await f.request('GET', '/events', undefined, donorToken)).items, []);
  body(await f.request('POST', `/requests/${rid}/decline`, {}, donorToken));
  body(await f.request('POST', `/requests/${rid}/decline`, {}, donorToken));
  body(await f.request('POST', `/requests/${rid}/accept`, {}, donorToken), 409);
  body(await f.request('POST', `/requests/${rid}/cancel`, {}));
});

test('expired requests cannot be accepted and release their active request slot', async t => {
  const f = await fixture(t);
  const rid = body(await f.request('POST', '/requests', requestBody())).id;
  await f.store.transaction('BD', db => db.run('UPDATE donation_requests SET expires_at=$1 WHERE id=$2', [new Date(Date.now() - 1000).toISOString(), rid]));
  assert.equal(body(await f.request('GET', `/requests/${rid}`)).status, 'expired');
  body(await f.request('POST', `/requests/${rid}/accept`, {}, donorToken), 409);
  body(await f.request('POST', '/requests', requestBody()));
});

test('blocking an accepted peer revokes meeting access and global reservations', async t => {
  const f = await fixture(t);
  const rid = await matched(f);
  body(await f.request('POST', '/blocks', { user_id: 'donor' }));
  const closed = body(await f.request('GET', `/requests/${rid}`, undefined, donorToken));
  assert.equal(closed.status, 'cancelled');
  assert.equal(closed.peer_has_photo, false);
  assert.ok(!Object.hasOwn(closed, 'destination_latitude'));
  assert.equal((await f.store.transaction(null, db => db.one('SELECT COUNT(*)::int AS count FROM active_matches'))).count, 0);
});

test('concurrent completion creates one shared reminder and no actual donation', async t => {
  const f = await fixture(t);
  const rid = await matched(f);
  const results = await Promise.all([donorToken, seekerToken].map(token => f.request('POST', `/requests/${rid}/complete`, {}, token)));
  results.forEach(result => body(result));
  const donorPending = body(await f.request('GET', '/donation-confirmations', undefined, donorToken)).items;
  const seekerPending = body(await f.request('GET', '/donation-confirmations')).items;
  assert.equal(donorPending.length, 1);
  assert.equal(seekerPending.length, 1);
  assert.equal(donorPending[0].is_donor, true);
  assert.equal(seekerPending[0].is_donor, false);
  assert.equal(donorPending[0].facility_name, 'Demo Hospital main entrance');
  assert.equal(donorPending[0].location_name, null);
  assert.ok(!Object.hasOwn(donorPending[0], 'destination_latitude'));
  assert.deepEqual(body(await f.request('GET', '/donations', undefined, donorToken)).items, []);
  assert.equal(body(await f.request('GET', '/me', undefined, donorToken)).is_available, true);
  body(await f.request('POST', `/donation-confirmations/${rid}/dismiss`, {}, adminToken), 404);
});

test('completion rollback leaves no receipt or closed request when event creation fails', async t => {
  const f = await fixture(t);
  const rid = await matched(f);
  const original = f.app.ctx.emitEvent;
  f.app.ctx.emitEvent = async () => { throw new Error('Simulated transaction failure'); };
  try { body(await f.request('POST', `/requests/${rid}/complete`, {}), 500); }
  finally { f.app.ctx.emitEvent = original; }
  assert.equal(body(await f.request('GET', `/requests/${rid}`)).status, 'accepted');
  assert.deepEqual(body(await f.request('GET', '/donation-confirmations', undefined, donorToken)).items, []);
  assert.equal((await f.store.transaction(null, db => db.one('SELECT COUNT(*)::int AS count FROM active_matches'))).count, 1);
});

test('each No is independent and seeker confirmation still works after donor travel', async t => {
  const f = await fixture(t);
  const rid = await matched(f, { complete: true });
  body(await f.request('POST', `/donation-confirmations/${rid}/dismiss`, {}, donorToken));
  assert.deepEqual(body(await f.request('GET', '/donation-confirmations', undefined, donorToken)).items, []);
  assert.equal(body(await f.request('GET', '/donation-confirmations')).items.length, 1);
  body(await f.request('POST', '/location', { country: 'AU', city: 'Sydney', latitude: -33.86, longitude: 151.2, mode: 'automatic' }, donorToken));
  const confirmed = body(await f.request('POST', '/donations', donationBody({ request_id: rid, idempotency_key: 'seeker-confirmation-unique' })));
  assert.equal(confirmed.id, 'seeker');
  assert.equal(confirmed.eligible_after_utc, null);
  assert.deepEqual(body(await f.request('GET', '/donations')).items, []);
  const history = body(await f.request('GET', '/donations', undefined, donorToken, 'AU')).items;
  assert.equal(history.length, 1);
  assert.equal(history[0].confirmed_by_role, 'seeker');
  assert.equal(history[0].country, 'BD');
  assert.equal(body(await f.request('GET', '/me', undefined, donorToken, 'AU')).is_available, false);
  body(await f.request('POST', '/donations', donationBody({ request_id: rid }), donorToken, 'AU'));
  assert.deepEqual(body(await f.request('GET', '/donations', undefined, donorToken, 'AU')).items, history);
  body(await f.request('DELETE', '/me'));
  assert.deepEqual(body(await f.request('GET', '/donations', undefined, donorToken, 'AU')).items, history);
});

test('simultaneous donor and seeker Yes records once and returns each caller own profile', async t => {
  const f = await fixture(t);
  const rid = await matched(f, { complete: true, donors: ['donor', 'donor-two'] });
  const responses = await Promise.all([donorToken, seekerToken].map(token => f.request('POST', '/donations', donationBody({ request_id: rid }), token)));
  assert.deepEqual(responses.map(r => body(r).id), ['donor', 'seeker']);
  assert.equal(body(await f.request('GET', '/donations', undefined, donorToken)).items.length, 1);
  for (const token of [donorToken, seekerToken]) {
    const detail = body(await f.request('GET', `/requests/${rid}`, undefined, token));
    assert.equal(detail.donation_recorded, true);
    assert.equal(detail.can_report, true);
    assert.ok(!Object.hasOwn(detail.donation_summary, 'height_cm'));
    assert.equal(detail.donation_summary.donated_at, today());
  }
  const outsider = await f.store.transaction('BD', db => requestResult(db, rid, 'donor-two'));
  assert.equal(outsider.donation_summary, null);
  assert.equal(outsider.donation_recorded, false);
  assert.equal(outsider.can_report, false);
  body(await f.request('POST', `/donation-confirmations/${rid}/dismiss`, {}, donorToken), 409);
});

test('uncompleted or unrelated requests cannot become a donation receipt', async t => {
  const f = await fixture(t);
  const rid = body(await f.request('POST', '/requests', requestBody())).id;
  body(await f.request('POST', '/donations', donationBody({ request_id: rid }), donorToken), 404);
  body(await f.request('POST', `/requests/${rid}/accept`, {}, donorToken));
  body(await f.request('POST', '/donations', donationBody({ request_id: rid }), donorToken), 404);
  body(await f.request('POST', `/requests/${rid}/complete`, {}));
  body(await f.request('POST', '/donations', donationBody({ request_id: rid }), adminToken), 404);
});

test('manual donation retries are idempotent and keys belong to the actor', async t => {
  const f = await fixture(t);
  const data = donationBody({ idempotency_key: 'local-test-save-intent-123' });
  body(await f.request('POST', '/donations', data, donorToken));
  const deadline = body(await f.request('GET', '/me', undefined, donorToken)).eligible_after_utc;
  const retried = await Promise.all([1, 2].map(() => f.request('POST', '/donations', data, donorToken)));
  retried.forEach(response => assert.equal(body(response).eligible_after_utc, deadline));
  const history = body(await f.request('GET', '/donations', undefined, donorToken)).items;
  assert.equal(history.length, 1);
  assert.ok(!Object.hasOwn(history[0], 'idempotency_key'));
  body(await f.request('POST', '/donations', { ...data, facility_name: 'Different blood bank' }, donorToken), 409);
  body(await f.request('POST', '/donations', data, seekerToken));
  assert.equal(body(await f.request('GET', '/donations')).items.length, 1);
  assert.deepEqual(body(await f.request('GET', '/donations', undefined, adminToken)).items, []);
});

test('donation validation rejects invalid dates, unknown fields and blank place labels', async t => {
  const f = await fixture(t);
  for (const extra of [{ facility_name: ' ' }, { location_name: ' ' }, { country: 'ZZ' }, { user_id: 'seeker' }, { donated_at: '2026-02-30' }, { donated_at: '0000-01-01' }, { donated_at: dateAgo(-2) }, { utc_offset_minutes: -721 }, { utc_offset_minutes: 841 }, { utc_offset_minutes: 0.5 }]) {
    body(await f.request('POST', '/donations', donationBody(extra), donorToken), 422);
  }
  body(await f.request('POST', '/donations', { donated_at: today() }, donorToken), 422);
  body(await f.request('POST', '/donations', donationBody({ facility_name: '  Demo Blood Bank  ', location_name: '  Dhaka  ', country: 'bd' }), donorToken));
  const record = body(await f.request('GET', '/donations', undefined, donorToken)).items[0];
  assert.equal(record.facility_name, 'Demo Blood Bank');
  assert.equal(record.location_name, 'Dhaka');
  assert.equal(record.country, 'BD');
});

test('UTC offset produces exact cooldown and an older donation cannot shorten it', async t => {
  const f = await fixture(t);
  const donatedAt = dateAgo(1);
  const record = donationBody({ donated_at: donatedAt, utc_offset_minutes: -720 });
  const profile = body(await f.request('POST', '/donations', record, donorToken));
  const expected = new Date(Date.parse(`${addThreeMonths(donatedAt)}T00:00:00.000Z`) + 720 * 60_000).toISOString();
  assert.equal(profile.eligible_after_utc, expected);
  const older = body(await f.request('POST', '/donations', donationBody({ donated_at: dateAgo(100), utc_offset_minutes: 840 }), donorToken));
  assert.equal(older.eligible_after_utc, expected);
  assert.equal(older.is_available, false);
  await f.store.transaction(null, db => db.run("UPDATE accounts SET available=0,eligible_after_utc=$1 WHERE id='donor'", [new Date(Date.now() - 60_000).toISOString()]));
  assert.equal(body(await f.request('GET', '/me', undefined, donorToken)).is_available, false);
});

test('history and reminders stay private across travel, export and donor deletion', async t => {
  const f = await fixture(t);
  const rid = await matched(f, { complete: true });
  body(await f.request('POST', '/donations', donationBody({ request_id: rid }), donorToken));
  const history = body(await f.request('GET', '/donations', undefined, donorToken)).items;
  body(await f.request('POST', '/location', { country: 'AU', city: 'Sydney', latitude: -33.86, longitude: 151.2, mode: 'manual' }, donorToken));
  assert.deepEqual(body(await f.request('GET', '/donations', undefined, donorToken, 'AU')).items, history);
  const exported = body(await f.request('GET', '/me/export', undefined, donorToken, 'AU'));
  assert.deepEqual(exported.donations, history);
  assert.equal(exported.donation_confirmations[0].status, 'recorded');
  body(await f.request('DELETE', '/me', undefined, donorToken, 'AU'));
  const counts = await f.store.transaction(null, async db => ({ history: await db.one("SELECT COUNT(*)::int AS count FROM donations WHERE user_id='donor'"), receipts: await db.one("SELECT COUNT(*)::int AS count FROM donation_confirmations WHERE user_id='donor'") }));
  assert.equal(counts.history.count, 0);
  assert.equal(counts.receipts.count, 0);
});
