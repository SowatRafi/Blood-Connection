import { ECDH } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import http2 from 'node:http2';
import { SignJWT, importPKCS8 } from 'jose';
import sharp from 'sharp';
import { encrypt } from 'web-push';
import { HttpError } from './errors.js';

// Decode bounded image pixels, never retain the uploader's EXIF, comments or original file.
export async function sanitizeImage(raw, maxEdge) {
  if (!Buffer.isBuffer(raw)) throw new HttpError(422, 'Choose a valid JPEG or PNG image under 12 megapixels');
  if (raw.length > 5 * 1024 * 1024) throw new HttpError(413, 'Choose an image no larger than 5 MB');
  try {
    const source = sharp(raw, { limitInputPixels: 12_000_000, failOn: 'warning', animated: true });
    const metadata = await source.metadata();
    if (!['jpeg', 'png'].includes(metadata.format) || (metadata.pages ?? 1) !== 1 ||
        !metadata.width || !metadata.height || metadata.width * metadata.height > 12_000_000) {
      throw new Error('Unsupported image');
    }
    // libvips may expose only APNG's first frame; reject its animation-control chunk explicitly.
    if (metadata.format === 'png') {
      for (let offset = 8; offset + 12 <= raw.length;) {
        const size = raw.readUInt32BE(offset);
        if (size > raw.length - offset - 12) break;
        if (raw.toString('ascii', offset + 4, offset + 8) === 'acTL') throw new Error('Animated image');
        offset += size + 12;
      }
    }
    return await source.rotate().resize(maxEdge, maxEdge, { fit: 'inside', withoutEnlargement: true })
      .flatten({ background: '#ffffff' }).jpeg({ quality: 85 }).toBuffer();
  } catch {
    throw new HttpError(422, 'Choose a valid JPEG or PNG image under 12 megapixels');
  }
}

// Durable endpoint registration must not give the push worker an arbitrary-network request primitive.
export function validateEndpoint(endpoint, settings) {
  try {
    if (typeof endpoint !== 'string' || /[\x00-\x20\x7f]/.test(endpoint)) throw new Error();
    const url = new URL(endpoint);
    const localHttp = settings.demo && url.protocol === 'http:' &&
      ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
    if ((!localHttp && url.protocol !== 'https:') || !settings.pushOrigins.has(url.origin) ||
        url.username || url.password || url.hash || !url.pathname) throw new Error();
  } catch {
    throw new HttpError(422, 'Choose a push distributor allowed by this server');
  }
}

// Buffer's permissive decoder must not silently accept malformed subscription keys.
function decodeKey(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(value)) throw new Error();
  const decoded = Buffer.from(value, 'base64');
  const normalized = value.replace(/=+$/, '').replaceAll('+', '-').replaceAll('/', '_');
  if (decoded.toString('base64url') !== normalized) throw new Error();
  return decoded;
}

// Check the actual P-256 point and exact auth-secret size before accepting a subscription.
export function validateKeys(publicKey, auth) {
  try {
    const publicBytes = decodeKey(publicKey);
    const authBytes = decodeKey(auth);
    if (publicBytes.length !== 65 || publicBytes[0] !== 4 || authBytes.length !== 16) throw new Error();
    ECDH.convertKey(publicBytes, 'prime256v1', undefined, undefined, 'uncompressed');
  } catch {
    throw new HttpError(422, 'Invalid push encryption keys');
  }
}

// A device token is a hex identifier, never a URL or an arbitrary HTTP path.
export function validApnsToken(token) {
  return typeof token === 'string' && /^[0-9a-fA-F]{64,200}$/.test(token) && token.length % 2 === 0;
}

// Copy only opaque routing fields even when a caller supplies a full database event.
function privatePushPayload(event) {
  const payload = { event_id: String(event.event_id ?? event.id), kind: event.kind, country: event.country };
  if (event.kind === 'report_reviewed') {
    payload.report_id = event.report_id;
    payload.report_country = event.report_country;
  } else {
    payload.request_id = event.request_id;
  }
  return payload;
}

// Bound the cache to the few deployment identities this process actually uses.
const apnsTokens = new Map();
// Reuse Apple tokens for twenty minutes from issuance, not a wall-clock bucket that may turn over early.
async function apnsBearer(settings) {
  const now = Math.floor(Date.now() / 1000);
  const cacheKey = JSON.stringify([settings.apnsKeyPath, settings.apnsKeyId, settings.apnsTeamId]);
  const cached = apnsTokens.get(cacheKey);
  if (cached && now >= cached.createdAt && now - cached.createdAt < 1200) return cached.token;
  if (apnsTokens.size >= 4) apnsTokens.delete(apnsTokens.keys().next().value);
  const token = (async () => {
    const key = await importPKCS8(await readFile(settings.apnsKeyPath, 'utf8'), 'ES256');
    return new SignJWT({ iss: settings.apnsTeamId, iat: now })
      .setProtectedHeader({ alg: 'ES256', kid: settings.apnsKeyId }).sign(key);
  })();
  apnsTokens.set(cacheKey, { createdAt: now, token });
  try { return await token; } catch (error) {
    if (apnsTokens.get(cacheKey)?.token === token) apnsTokens.delete(cacheKey);
    throw error;
  }
}

// APNs requires HTTP/2; the built-in client avoids another provider SDK and never follows redirects.
async function sendApns(device, payload, settings) {
  const bearer = await apnsBearer(settings);
  const origin = settings.apnsSandbox ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
  return new Promise((resolve, reject) => {
    const session = http2.connect(origin);
    let settled = false;
    let status = 0;
    let length = 0;
    const chunks = [];
    // Timeout, stream failure and session closure can race; release resources and settle exactly once.
    const finish = (error, response) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      session.destroy();
      if (error) reject(error); else resolve(response);
    };
    const timeout = setTimeout(() => finish(new Error('APNs request timed out')), 8000);
    session.on('error', error => finish(error));
    session.on('close', () => finish(new Error('APNs connection closed')));
    let request;
    try {
      request = session.request({
        ':method': 'POST', ':path': `/3/device/${device.token}`,
        authorization: `bearer ${bearer}`, 'content-type': 'application/json',
        'apns-topic': settings.apnsTopic, 'apns-push-type': 'alert', 'apns-priority': '10',
        'apns-expiration': String(Math.floor(Date.now() / 1000) + 300),
      });
    } catch (error) { finish(error); return; }
    request.on('error', error => finish(error));
    request.on('response', headers => { status = Number(headers[':status']); });
    request.on('data', chunk => {
      length += chunk.length;
      if (length > 4096) finish(new Error('APNs response too large'));
      else chunks.push(Buffer.from(chunk));
    });
    request.on('end', () => finish(null, { status, body: Buffer.concat(chunks).toString('utf8') }));
    request.end(JSON.stringify({
      aps: { alert: { title: 'Blood Connection', body: 'You have a private update. Open the app to view it.' },
        sound: 'default', category: 'PRIVATE_UPDATE' },
      ...payload,
    }));
  });
}

// Delivery outcomes let the durable outbox retry outages without claiming unconfigured delivery.
export async function sendPush(device, event, settings) {
  try {
    const payload = privatePushPayload(event);
    let response;
    if (device.provider === 'unifiedpush') {
      validateEndpoint(device.token, settings);
      validateKeys(device.pub_key, device.auth);
      const encrypted = encrypt(device.pub_key, device.auth, Buffer.from(JSON.stringify(payload)), 'aes128gcm');
      response = await fetch(device.token, {
        method: 'POST', body: encrypted.cipherText, redirect: 'manual', signal: AbortSignal.timeout(8000),
        headers: { 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '300', 'X-UnifiedPush': '1' },
      });
      await response.body?.cancel();
    } else if (device.provider === 'apns') {
      if (!settings.apnsKeyPath || !settings.apnsKeyId || !settings.apnsTeamId || !settings.apnsTopic) return 'unconfigured';
      if (!validApnsToken(device.token)) return 'invalid';
      response = await sendApns(device, payload, settings);
    } else return 'invalid';
    if (response.status >= 200 && response.status < 300) return 'sent';
    if ([404, 410].includes(response.status)) return 'invalid';
    if (device.provider === 'apns' && response.status === 400) {
      const reason = JSON.parse(response.body).reason;
      if (['BadDeviceToken', 'DeviceTokenNotForTopic'].includes(reason)) return 'invalid';
    }
    return 'retry';
  } catch {
    return 'retry';
  }
}

// Authorization occurs in the call route; credentials reveal no names and permit only this audio room.
// The five-minute JWT bounds admission, not an already-connected media session;
// ending access also requires the durable participant/room cleanup path below.
export async function livekitCredentials(call, user, settings) {
  if (!settings.livekitUrl || !settings.livekitKey || !settings.livekitSecret) {
    throw new HttpError(503, 'Calling has not been configured');
  }
  const now = Math.floor(Date.now() / 1000);
  const token = await new SignJWT({ video: {
    roomJoin: true, room: `blood-${call.id}`, canPublish: true, canSubscribe: true,
    canPublishData: false, canPublishSources: ['microphone'],
  } }).setProtectedHeader({ alg: 'HS256', typ: 'JWT' }).setIssuer(settings.livekitKey)
    .setSubject(user.id).setNotBefore(now - 5).setExpirationTime(now + 300)
    .sign(Buffer.from(settings.livekitSecret));
  return { url: settings.livekitUrl, token };
}

// The caller deletes its durable cleanup job only after both participants and their room are gone.
export async function revokeMedia(job, settings) {
  if (!settings.livekitUrl || !settings.livekitKey || !settings.livekitSecret) return false;
  try {
    const room = `blood-${job.call_id}`;
    const now = Math.floor(Date.now() / 1000);
    const token = await new SignJWT({ video: { roomCreate: true, roomAdmin: true, room } })
      .setProtectedHeader({ alg: 'HS256', typ: 'JWT' }).setIssuer(settings.livekitKey)
      .setNotBefore(now - 5).setExpirationTime(now + 60).sign(Buffer.from(settings.livekitSecret));
    const origin = settings.livekitUrl.replace(/^wss:/, 'https:').replace(/^ws:/, 'http:').replace(/\/$/, '');
    const removals = [
      ['RemoveParticipant', { room, identity: job.caller_id }],
      ['RemoveParticipant', { room, identity: job.callee_id }],
      ['DeleteRoom', { room }],
    ];
    for (const [method, body] of removals) {
      const response = await fetch(`${origin}/twirp/livekit.RoomService/${method}`, {
        method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(3000),
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      await response.body?.cancel();
      if (![200, 404].includes(response.status)) return false;
    }
    return true;
  } catch { return false; }
}
