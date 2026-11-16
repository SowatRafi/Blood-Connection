import test from 'node:test';
import assert from 'node:assert/strict';
import { authBase, errorMessage, readableDate, validateDecision, validOAuthReturn, visibleReports } from './helpers.mjs';

// These checks cover the consequential choices rather than mirroring every UI render.
test('a permanent ban requires a pending money report, review note and confirmation', () => {
  const report = { status: 'pending', reason: 'money_request' };
  assert.equal(validateDecision(report, 'ban', 'Evidence confirms a money request.', true), null);
  assert.match(validateDecision(report, 'ban', 'Evidence reviewed', false), /Confirm/);
  assert.match(validateDecision({ ...report, reason: 'harassment' }, 'ban', 'Evidence reviewed', true), /money/);
  assert.match(validateDecision({ ...report, status: 'dismissed' }, 'ban', 'Evidence reviewed', true), /no longer/);
  assert.match(validateDecision(report, 'ban', '   ', true), /note/);
  assert.equal(validateDecision(report, 'dismiss', 'Insufficient evidence.', false), null);
});

test('inbox pending filter never includes a resolved report', () => {
  const data = [{ id: 'a', status: 'pending' }, { id: 'b', status: 'dismissed' }];
  assert.deepEqual(visibleReports(data, 'pending'), [data[0]]);
  assert.deepEqual(visibleReports(data, 'all'), data);
});

test('auth endpoints cannot use cleartext remote hosts or embedded credentials', () => {
  assert.equal(authBase('https://project.supabase.co'), 'https://project.supabase.co');
  assert.equal(authBase('http://127.0.0.1:54321'), 'http://127.0.0.1:54321');
  for (const invalid of ['http://auth.example.com', 'https://secret@auth.example.com', 'javascript:alert(1)', 'https://auth.example.com?redirect=evil']) assert.throws(() => authBase(invalid));
});

test('unknown failures and invalid dates do not expose raw structured payloads', () => {
  assert.match(errorMessage({ detail: [{ loc: ['secret'], input: 'private' }] }, 500), /could not be completed/);
  assert.match(errorMessage({}, 401), /expired/);
  assert.equal(readableDate('invalid-date'), 'Date unavailable');
});

test('OAuth callbacks require matching state, origin, verifier and unexpired creation time', () => {
  const pending = { verifier: 'a'.repeat(43), state: 'b'.repeat(43), base: 'https://project.supabase.co', created: 1000000 };
  assert.equal(validOAuthReturn(pending, pending.state, pending.base, 1000001), true);
  assert.equal(validOAuthReturn(pending, 'wrong-state', pending.base, 1000001), false);
  assert.equal(validOAuthReturn(pending, pending.state, 'https://other.supabase.co', 1000001), false);
  assert.equal(validOAuthReturn(pending, pending.state, pending.base, 1600001), false);
  assert.equal(validOAuthReturn(pending, pending.state, pending.base, 999999), false);
  assert.equal(validOAuthReturn({ ...pending, created: undefined }, pending.state, pending.base, 1000001), false);
  assert.equal(validOAuthReturn({ ...pending, verifier: 'short' }, pending.state, pending.base, 1000001), false);
  assert.equal(validOAuthReturn(null, pending.state, pending.base, 1000001), false);
});
