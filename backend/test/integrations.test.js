import assert from 'node:assert/strict';
import { createECDH, generateKeyPairSync, randomBytes } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import http2 from 'node:http2';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { crc32 } from 'node:zlib';
import test from 'node:test';
import ece from 'http_ece';
import { jwtVerify } from 'jose';
import sharp from 'sharp';
import {
  livekitCredentials, revokeMedia, sanitizeImage, sendPush,
  validateEndpoint, validateKeys, validApnsToken,
} from '../src/integrations.js';

// Disposable receiver keys prove compatibility with an independent RFC 8291 decryptor.
function subscription() {
  const receiver = createECDH('prime256v1');
  const publicKey = receiver.generateKeys().toString('base64url');
  const auth = randomBytes(16).toString('base64url');
  return { receiver, device: { provider: 'unifiedpush', token: 'http://127.0.0.1:8090/up-demo', pub_key: publicKey, auth } };
}
const pushSettings = { demo: true, pushOrigins: new Set(['http://127.0.0.1:8090', 'https://push.example.invalid']) };
const callSettings = {
  livekitUrl: 'wss://media.example.invalid', livekitKey: 'local-test-key',
  livekitSecret: 'fictional-test-secret-only-never-use-in-production',
};
const event = { id: 17, kind: 'request_invitation', country: 'BD', request_id: 'request-17', body: 'Private donor name and message' };

test('push destinations require explicit origins, HTTPS or opted-in loopback, and no URL credentials', () => {
  validateEndpoint('https://push.example.invalid/device', pushSettings);
  validateEndpoint('http://127.0.0.1:8090/device', pushSettings);
  for (const endpoint of [
    'https://attacker.example/push', 'http://169.254.169.254/latest/meta-data',
    'http://127.0.0.1:8090@attacker.example/push', 'https://user:secret@push.example.invalid/device',
    'https://push.example.invalid/device#fragment', 'https://push.example.invalid/ bad', '\nhttps://push.example.invalid/device',
  ]) assert.throws(() => validateEndpoint(endpoint, pushSettings), { statusCode: 422 });
  assert.throws(() => validateEndpoint('http://127.0.0.1:8090/device', { ...pushSettings, demo: false }), { statusCode: 422 });
});

test('push registration validates real curve points and canonical auth bytes', () => {
  const { device } = subscription();
  validateKeys(device.pub_key, device.auth);
  for (const [key, auth] of [
    [Buffer.alloc(65, 4).toString('base64url'), device.auth], [device.pub_key, randomBytes(15).toString('base64url')],
    [device.pub_key + '!', device.auth], [device.pub_key, device.auth + ' '], ['', ''],
  ]) assert.throws(() => validateKeys(key, auth), { statusCode: 422 });
  assert.equal(validApnsToken('ab'.repeat(32)), true);
  for (const token of ['ab'.repeat(31), 'a'.repeat(65), '../secret', 'https://example.invalid', null]) {
    assert.equal(validApnsToken(token), false);
  }
});

test('images are oriented, bounded and rebuilt without metadata; transparency becomes white', async () => {
  const original = await sharp({ create: { width: 1000, height: 500, channels: 3, background: '#b42346' } })
    .withMetadata({ orientation: 6 }).withExif({ IFD0: { Artist: 'Private photographer' } }).jpeg().toBuffer();
  const clean = await sanitizeImage(original, 512);
  const metadata = await sharp(clean).metadata();
  assert.equal(metadata.format, 'jpeg');
  assert.equal(metadata.width, 256);
  assert.equal(metadata.height, 512);
  assert.equal(metadata.exif, undefined);
  assert.equal(metadata.icc, undefined);
  assert.equal(metadata.orientation, undefined);
  const transparent = await sharp({ create: { width: 1, height: 1, channels: 4, background: '#00000000' } }).png().toBuffer();
  const pixel = await sharp(await sanitizeImage(transparent, 2048)).raw().toBuffer();
  assert.deepEqual([...pixel], [255, 255, 255]);
});

test('image boundary rejects oversized input, too many pixels and non-raster uploads', async () => {
  await assert.rejects(sanitizeImage(Buffer.alloc(5 * 1024 * 1024 + 1), 512), { statusCode: 413 });
  const large = await sharp({ create: { width: 3500, height: 3500, channels: 3, background: 'white' } }).png().toBuffer();
  await assert.rejects(sanitizeImage(large, 512), { statusCode: 422 });
  // The PNG decoder may return first-frame metadata even when an animation control chunk exists.
  const png = await sharp({ create: { width: 2, height: 2, channels: 3, background: 'red' } }).png().toBuffer();
  const chunk = Buffer.alloc(20);
  chunk.writeUInt32BE(8, 0); chunk.write('acTL', 4); chunk.writeUInt32BE(2, 8);
  chunk.writeUInt32BE(crc32(chunk.subarray(4, 16)), 16);
  const animated = Buffer.concat([png.subarray(0, 33), chunk, png.subarray(33)]);
  await assert.rejects(sanitizeImage(animated, 512), { statusCode: 422 });
  for (const raw of [Buffer.from('not an image'), Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>')]) {
    await assert.rejects(sanitizeImage(raw, 512), { statusCode: 422 });
  }
});

test('UnifiedPush encrypts a compatible opaque payload and never follows distributor redirects', async t => {
  const { receiver, device } = subscription();
  const sent = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => { sent.push({ url, options }); return new Response(null, { status: 201 }); });
  assert.equal(await sendPush(device, event, pushSettings), 'sent');
  const { options } = sent[0];
  assert.equal(sent[0].url, device.token);
  assert.equal(options.redirect, 'manual');
  assert.equal(options.headers['Content-Encoding'], 'aes128gcm');
  assert.equal(options.headers['X-UnifiedPush'], '1');
  assert.equal(options.headers.TTL, '300');
  const decrypted = ece.decrypt(options.body, { version: 'aes128gcm', privateKey: receiver, authSecret: device.auth });
  assert.deepEqual(JSON.parse(decrypted.toString()), { event_id: '17', kind: 'request_invitation', country: 'BD', request_id: 'request-17' });
  assert.equal(options.body.includes(Buffer.from(event.body)), false);
  const review = { id: 18, kind: 'report_reviewed', country: 'AU', report_id: 'report-18', report_country: 'BD', body: 'Internal review note' };
  assert.equal(await sendPush(device, review, pushSettings), 'sent');
  const reviewed = JSON.parse(ece.decrypt(sent[1].options.body, { version: 'aes128gcm', privateKey: receiver, authSecret: device.auth }).toString());
  assert.deepEqual(reviewed, { event_id: '18', kind: 'report_reviewed', country: 'AU', report_id: 'report-18', report_country: 'BD' });
});

test('push results keep redirects and outages retryable while invalid endpoints are removable', async t => {
  const { device } = subscription();
  let status = 302;
  const transport = t.mock.method(globalThis, 'fetch', async () => new Response(null, { status }));
  for (const [code, expected] of [[302, 'retry'], [503, 'retry'], [404, 'invalid'], [410, 'invalid'], [204, 'sent']]) {
    status = code;
    assert.equal(await sendPush(device, event, pushSettings), expected);
  }
  transport.mock.mockImplementation(async () => { throw new Error('Network outage'); });
  assert.equal(await sendPush(device, event, pushSettings), 'retry');
  const previous = transport.mock.callCount();
  assert.equal(await sendPush({ ...device, token: 'https://attacker.example/device' }, event, pushSettings), 'retry');
  assert.equal(transport.mock.callCount(), previous);
});

// Mock only the HTTP/2 transport; real ephemeral ES256 signatures are verified below.
function apnsTransport(t) {
  const sent = [];
  const behavior = { status: 200, body: '', error: false };
  t.mock.method(http2, 'connect', origin => {
    const session = new EventEmitter();
    session.destroy = () => session.emit('close');
    session.request = headers => {
      const request = new EventEmitter();
      request.end = body => {
        sent.push({ origin, headers, body: JSON.parse(body) });
        queueMicrotask(() => {
          if (behavior.error) request.emit('error', new Error('HTTP/2 outage'));
          else {
            request.emit('response', { ':status': behavior.status });
            if (behavior.body) request.emit('data', Buffer.from(behavior.body));
            request.emit('end');
          }
        });
      };
      return request;
    };
    return session;
  });
  return { sent, behavior };
}

test('APNs uses HTTP/2, verifiable cached tokens and generic notification content', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'blood-push-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const keyPath = join(directory, 'test-key.p8');
  await writeFile(keyPath, privateKey.export({ format: 'pem', type: 'pkcs8' }));
  const settings = { apnsKeyPath: keyPath, apnsKeyId: 'TESTKEY', apnsTeamId: 'TESTTEAM', apnsTopic: 'org.bindubashini.bloodconnection', apnsSandbox: true };
  const device = { provider: 'apns', token: 'ab'.repeat(32) };
  const { sent, behavior } = apnsTransport(t);
  assert.equal(await sendPush(device, event, settings), 'sent');
  assert.equal(sent[0].origin, 'https://api.sandbox.push.apple.com');
  assert.equal(sent[0].headers[':path'], `/3/device/${device.token}`);
  assert.equal(sent[0].headers['apns-topic'], settings.apnsTopic);
  const bearer = sent[0].headers.authorization.slice('bearer '.length);
  const { payload, protectedHeader } = await jwtVerify(bearer, publicKey, { algorithms: ['ES256'], issuer: 'TESTTEAM' });
  assert.equal(protectedHeader.kid, 'TESTKEY');
  assert.ok(Math.abs(payload.iat - Math.floor(Date.now() / 1000)) < 5);
  assert.equal(sent[0].body.aps.category, 'PRIVATE_UPDATE');
  assert.equal(sent[0].body.aps.alert.body, 'You have a private update. Open the app to view it.');
  assert.equal(JSON.stringify(sent[0].body).includes(event.body), false);
  const review = { id: 18, kind: 'report_reviewed', country: 'BD', report_id: 'report-18', report_country: 'BD' };
  assert.equal(await sendPush(device, review, settings), 'sent');
  assert.equal(sent[1].headers.authorization, sent[0].headers.authorization);
  assert.equal(sent[1].body.report_id, 'report-18');
  assert.equal('request_id' in sent[1].body, false);
  behavior.status = 400;
  behavior.body = JSON.stringify({ reason: 'DeviceTokenNotForTopic' });
  assert.equal(await sendPush(device, event, settings), 'invalid');
  behavior.body = JSON.stringify({ reason: 'TooManyProviderTokenUpdates' });
  assert.equal(await sendPush(device, event, settings), 'retry');
  behavior.error = true;
  assert.equal(await sendPush(device, event, settings), 'retry');
  assert.equal(await sendPush(device, event, { ...settings, apnsKeyPath: '' }), 'unconfigured');
  assert.equal(await sendPush({ ...device, token: '../bad' }, event, settings), 'invalid');
});

test('LiveKit grants are signed, room scoped, audio only and limited to five minutes', async () => {
  const before = Math.floor(Date.now() / 1000);
  const result = await livekitCredentials({ id: 'call-1' }, { id: 'opaque-user' }, callSettings);
  assert.equal(result.url, callSettings.livekitUrl);
  const { payload } = await jwtVerify(result.token, Buffer.from(callSettings.livekitSecret), { algorithms: ['HS256'], issuer: callSettings.livekitKey, subject: 'opaque-user' });
  assert.deepEqual(payload.video, { roomJoin: true, room: 'blood-call-1', canPublish: true, canSubscribe: true, canPublishData: false, canPublishSources: ['microphone'] });
  assert.ok(payload.exp >= before + 300 && payload.exp <= Math.floor(Date.now() / 1000) + 300);
  await assert.rejects(livekitCredentials({ id: 'call-1' }, { id: 'user' }, {}), { statusCode: 503 });
});

test('media revocation confirms all cleanup, accepts already absent participants, and keeps failed jobs retryable', async t => {
  const sent = [];
  let statuses = [200, 404, 200];
  t.mock.method(globalThis, 'fetch', async (url, options) => { sent.push({ url, options }); return new Response(null, { status: statuses.shift() ?? 503 }); });
  const job = { call_id: 'call-1', caller_id: 'user-1', callee_id: 'user-2' };
  assert.equal(await revokeMedia(job, callSettings), true);
  assert.equal(sent.length, 3);
  assert.equal(sent[0].options.redirect, 'manual');
  assert.deepEqual(JSON.parse(sent[0].options.body), { room: 'blood-call-1', identity: 'user-1' });
  assert.deepEqual(JSON.parse(sent[1].options.body), { room: 'blood-call-1', identity: 'user-2' });
  assert.equal(sent[2].url, 'https://media.example.invalid/twirp/livekit.RoomService/DeleteRoom');
  const { payload } = await jwtVerify(sent[0].options.headers.Authorization.slice(7), Buffer.from(callSettings.livekitSecret), { algorithms: ['HS256'] });
  assert.deepEqual(payload.video, { roomCreate: true, roomAdmin: true, room: 'blood-call-1' });
  statuses = [503];
  assert.equal(await revokeMedia(job, callSettings), false);
  assert.equal(sent.length, 4);
  assert.equal(await revokeMedia(job, {}), false);
});
