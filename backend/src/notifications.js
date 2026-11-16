import { HttpError } from './errors.js';
import { schemas } from './schemas.js';
import { assertAccount } from './shared.js';
import { sendPush, validateEndpoint, validateKeys, validApnsToken } from './integrations.js';

const prefix = '/api/v1';
const countryProperty = { type: 'string', minLength: 2, maxLength: 2 };
const countryQuery = { type: 'object', additionalProperties: false, properties: { country: countryProperty } };

// Review outcomes remain available after travel/cooldown, but never to the accused or a deleted account.
export async function eventAllowed(db, event, country, ctx) {
  const account = await db.one('SELECT * FROM accounts WHERE id=$1', [event.user_id]);
  if (!account || account.banned || account.deleted) return false;
  if (event.kind === 'report_reviewed') {
    const report = await db.one('SELECT reporter_id,status FROM reports WHERE id=$1', [event.report_id]);
    return Boolean(report && report.reporter_id === event.user_id && ['banned', 'dismissed'].includes(report.status) && event.report_country === country);
  }
  const request = await db.one('SELECT * FROM donation_requests WHERE id=$1', [event.request_id]);
  if (account.country !== country || !request) return false;
  // An old invitation cannot override a donor's newer opt-out, cooldown or relationship block.
  if (event.user_id !== request.requester_id && (!ctx.available(account) || await ctx.relationshipBlocked(db, event.user_id, request.requester_id))) return false;
  if (event.kind === 'donation_request') {
    const invitation = await db.one('SELECT status FROM request_invitations WHERE request_id=$1 AND donor_id=$2', [request.id, event.user_id]);
    return request.status === 'open' && invitation?.status === 'invited';
  }
  if (event.kind === 'thank_you') return ['accepted', 'completed'].includes(request.status);
  if (event.kind === 'request_accepted') return request.status === 'accepted';
  return ['cancelled', 'completed', 'expired'].includes(request.status);
}

// The lease is committed before network I/O; a retrying transaction must never send a second notification.
export async function processPush(store, settings, ctx) {
  for (const country of await store.countries()) {
    const jobs = await store.transaction(country, async db => {
      // Close revoked/expired matches before evaluating any pending invitation for delivery.
      await ctx.expireRequests(db, country, ctx);
      return db.all("SELECT event_id,device_id FROM push_outbox WHERE status='pending' AND next_attempt::timestamptz<=now() ORDER BY event_id LIMIT 20");
    });
    for (const job of jobs) {
      // Claim one job just before sending; a batch of slow network calls must not consume all leases.
      const lease = new Date(Date.now() + 120_000).toISOString();
      const claimed = await store.transaction(country, async db => {
        const work = await db.one("UPDATE push_outbox SET next_attempt=$1 WHERE event_id=$2 AND device_id=$3 AND status='pending' AND next_attempt::timestamptz<=now() RETURNING attempts", [lease, job.event_id, job.device_id]);
        if (!work) return null;
        const event = await db.one('SELECT * FROM events WHERE id=$1', [job.event_id]);
        const device = await db.one('SELECT * FROM devices WHERE id=$1', [job.device_id]);
        if (!event || !device || device.user_id !== event.user_id || !await eventAllowed(db, event, country, ctx) || Date.parse(event.created_at) < Date.now() - 86_400_000) {
          await db.run("UPDATE push_outbox SET status='suppressed' WHERE event_id=$1 AND device_id=$2", [job.event_id, job.device_id]);
          return null;
        }
        return { event, device, attempts: work.attempts };
      });
      if (!claimed) continue;
      const result = await sendPush(claimed.device, { ...claimed.event, country }, settings);
      await store.transaction(country, async db => {
        const attempts = claimed.attempts + 1;
        const status = result === 'sent' ? 'sent' : result === 'invalid' ? 'invalid' : attempts >= 12 ? 'failed' : 'pending';
        const delay = Math.min(3600, 15 * 2 ** Math.min(attempts, 8));
        // A delayed worker cannot overwrite a newer lease or remove a newly enrolled replacement device.
        const changed = await db.run("UPDATE push_outbox SET status=$1,attempts=$2,next_attempt=$3 WHERE event_id=$4 AND device_id=$5 AND status='pending' AND next_attempt=$6", [status, attempts, new Date(Date.now() + delay * 1000).toISOString(), job.event_id, job.device_id, lease]);
        if (result === 'invalid' && changed.rowCount) {
          await db.run('DELETE FROM devices WHERE id=$1 AND user_id=$2 AND created_at=$3 AND token=$4', [job.device_id, claimed.device.user_id, claimed.device.created_at, claimed.device.token]);
        }
      });
    }
  }
}

// Regional cursors never masquerade as a global sequence; combined history is only a newest-first inbox.
export function registerNotificationRoutes(app, ctx) {
  const { store, settings, authenticate } = ctx;
  app.get(`${prefix}/events`, { preHandler: authenticate, schema: { querystring: {
    type: 'object', additionalProperties: false,
    properties: { country: countryProperty, after: { type: 'integer', minimum: 0, maximum: Number.MAX_SAFE_INTEGER } },
  } } }, async request => {
    const user = request.user;
    const { after, country } = request.query;
    const cursorCountry = await ctx.storedCountry(country, user);
    const countries = country != null || after != null ? [cursorCountry] : await store.countries();
    const items = [];
    let nextAfter = after ?? 0;
    for (const code of countries) {
      const regional = await store.transaction(code, async db => {
        await assertAccount(db, user, { country: false });
        await ctx.expireRequests(db, code, ctx);
        const found = [];
        let cursor = after ?? '9223372036854775807';
        let newest = after ?? 0;
        const direction = after != null ? '>' : '<';
        const order = after != null ? 'ASC' : 'DESC';
        // Scan past obsolete events so they cannot hide a later eligible report review.
        while (found.length < 100) {
          const rows = await db.all(`SELECT * FROM events WHERE user_id=$1 AND id${direction}$2::bigint ORDER BY id ${order} LIMIT 100`, [user.id, cursor]);
          if (!rows.length) break;
          for (const row of rows) {
            cursor = row.id;
            newest = Math.max(newest, row.id);
            if (await eventAllowed(db, row, code, ctx)) found.push({
              id: String(row.id), country: code, kind: row.kind, title: row.title, body: row.body,
              request_id: row.request_id || null, report_id: row.report_id, report_country: row.report_country,
              created_at: row.created_at, read: Boolean(row.read),
            });
            if (found.length === 100) break;
          }
        }
        return { found, newest };
      });
      items.push(...regional.found);
      if (code === cursorCountry) nextAfter = regional.newest;
    }
    if (after == null) items.sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || b.country.localeCompare(a.country) || Number(b.id) - Number(a.id));
    return { items: items.slice(0, 100), next_after: String(nextAfter), cursor_country: cursorCountry };
  });

  app.post(`${prefix}/events/:eventId/read`, { preHandler: authenticate, schema: {
    querystring: countryQuery, params: { type: 'object', required: ['eventId'], properties: { eventId: { type: 'string', pattern: '^[0-9]{1,10}$' } } },
  } }, async request => {
    if (Number(request.params.eventId) < 1 || Number(request.params.eventId) > 2147483647) throw new HttpError(422, 'Invalid notification ID');
    const country = await ctx.storedCountry(request.query.country, request.user);
    await store.transaction(country, async db => {
      await assertAccount(db, request.user, { country: false });
      const result = await db.run('UPDATE events SET read=1 WHERE id=$1 AND user_id=$2', [request.params.eventId, request.user.id]);
      if (!result.rowCount) throw new HttpError(404, 'Notification not found');
    });
    return { status: 'read' };
  });

  // The account lock and token upsert preserve both the five-device cap and cross-account ownership.
  app.post(`${prefix}/devices`, { preHandler: authenticate, schema: { body: schemas.device } }, async request => {
    const body = request.body;
    await ctx.throttle(`device:${request.user.id}`, 20, 3600);
    if (body.provider === 'unifiedpush') {
      validateEndpoint(body.token, settings);
      validateKeys(body.pub_key ?? '', body.auth ?? '');
    } else if (!validApnsToken(body.token)) throw new HttpError(422, 'Invalid APNs device token');
    return store.transaction(null, async db => {
      await assertAccount(db, request.user);
      const existing = await db.one('SELECT id,user_id FROM devices WHERE token=$1', [body.token]);
      if (existing && existing.user_id !== request.user.id) throw new HttpError(409, 'This device is already registered to another account. Sign out there first');
      const count = await db.one('SELECT COUNT(*)::int AS count FROM devices WHERE user_id=$1', [request.user.id]);
      if (!existing && count.count >= 5) throw new HttpError(409, 'Remove an old device before registering another');
      const device = await db.one(`INSERT INTO devices(id,user_id,provider,token,pub_key,auth,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)
        ON CONFLICT(token) DO UPDATE SET provider=EXCLUDED.provider,pub_key=EXCLUDED.pub_key,auth=EXCLUDED.auth,created_at=EXCLUDED.created_at
        WHERE devices.user_id=EXCLUDED.user_id RETURNING id`,
      [existing?.id ?? ctx.newId(), request.user.id, body.provider, body.token, body.pub_key ?? null, body.auth ?? null, ctx.stamp()]);
      if (!device) throw new HttpError(409, 'This device is already registered to another account. Sign out there first');
      return { id: device.id, provider: body.provider, status: 'registered' };
    });
  });

  app.delete(`${prefix}/devices`, { preHandler: authenticate, schema: { body: schemas.deviceRemoval } }, async request => {
    await store.transaction(null, async db => {
      await assertAccount(db, request.user);
      await db.run('DELETE FROM devices WHERE token=$1 AND user_id=$2', [request.body.token, request.user.id]);
    });
    return { status: 'removed' };
  });
}
