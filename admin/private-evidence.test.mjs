import test from 'node:test';
import assert from 'node:assert/strict';
import { PrivateEvidence } from './private-evidence.mjs';

// Track real lifecycle outcomes without a browser or retained private files.
function setup() {
  const created = [], revoked = [];
  const images = new PrivateEvidence({
    createObjectURL(blob) { const url = `blob:private-${created.length}`; created.push(blob); return url; },
    revokeObjectURL(url) { revoked.push(url); },
  });
  return { images, created, revoked };
}

test('leaving evidence revokes previews and rejects late responses after abort', async () => {
  const { images, created, revoked } = setup();
  const jpeg = new Blob(['fictional-jpeg'], { type: 'image/jpeg' });
  assert.equal(await images.load(async () => jpeg), 'blob:private-0');
  let resolve, signal;
  const late = images.load(received => { signal = received; return new Promise(done => { resolve = done; }); });
  images.clear();
  assert.equal(signal.aborted, true);
  assert.deepEqual(revoked, ['blob:private-0']);
  resolve(jpeg);
  assert.equal(await late, null);
  assert.equal(created.length, 1);
  assert.equal(await images.load(async () => jpeg), 'blob:private-1');
  images.clear();
  assert.deepEqual(revoked, ['blob:private-0', 'blob:private-1']);
});

test('non-JPEG, empty and oversized responses never become browser image URLs', async () => {
  const { images, created } = setup();
  for (const blob of [new Blob(['<svg/>'], { type: 'image/svg+xml' }), new Blob([], { type: 'image/jpeg' }), new Blob([new Uint8Array(5 * 1024 * 1024 + 1)], { type: 'image/jpeg' })]) {
    await assert.rejects(images.load(async () => blob), /safely/);
  }
  assert.equal(created.length, 0);
});
