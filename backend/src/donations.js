/** Donation coordination and actual donation records share database transactions, never client state. */
import { HttpError } from './errors.js';
import { schemas } from './schemas.js';
import { addThreeMonths, kmBetween, COUNTRIES } from './utils.js';

// Keep the established mobile contract while rejecting oversized identifiers before any database lookup.
const prefix = '/api/v1';
const requestParams = { type: 'object', required: ['rid'], additionalProperties: false, properties: { rid: { type: 'string', minLength: 1, maxLength: 80 } } };

/** Close invitations and release the global participant reservation in the same transaction. */
export async function closeRequest(db, requestId, status) {
  await db.run('UPDATE donation_requests SET status=$1 WHERE id=$2', [status, requestId]);
  await db.run("UPDATE request_invitations SET status='closed' WHERE request_id=$1 AND status IN ('invited','accepted')", [requestId]);
  await db.run('DELETE FROM active_matches WHERE request_id=$1', [requestId]);
}

/** Reads and deliveries recheck revocation so a stale accepted match cannot reveal a photo or destination. */
export async function expireRequests(db, country, ctx) {
  const requests = await db.all("SELECT * FROM donation_requests WHERE status IN ('open','accepted') ORDER BY id FOR UPDATE");
  for (const request of requests) {
    const owner = await db.one('SELECT * FROM accounts WHERE id=$1', [request.requester_id]);
    let invalid = !owner || owner.banned || owner.deleted || owner.country !== country;
    if (request.accepted_donor_id) {
      const donor = await db.one('SELECT * FROM accounts WHERE id=$1', [request.accepted_donor_id]);
      invalid ||= !donor || donor.banned || donor.deleted || donor.country !== country
        || await ctx.relationshipBlocked(db, request.requester_id, request.accepted_donor_id);
    }
    if (invalid) await closeRequest(db, request.id, 'cancelled');
    else if (request.status === 'open' && Date.parse(request.expires_at) <= Date.parse(ctx.stamp())) await closeRequest(db, request.id, 'expired');
  }
}

/** Project matching details explicitly; invited strangers never receive private counterpart or destination fields. */
export async function requestResult(db, requestId, userId) {
  const row = await db.one('SELECT * FROM donation_requests WHERE id=$1', [requestId]);
  const invitation = await db.one('SELECT status FROM request_invitations WHERE request_id=$1 AND donor_id=$2', [requestId, userId]);
  if (!row || (row.requester_id !== userId && !invitation)) throw new HttpError(404, 'Donation request not found');
  const isOwner = row.requester_id === userId;
  const wasMatched = Boolean(row.accepted_donor_id && [row.requester_id, row.accepted_donor_id].includes(userId));
  const matched = row.status === 'accepted' && wasMatched;
  const owner = await db.one('SELECT display_name FROM profiles WHERE id=$1', [row.requester_id]);
  const result = {
    id: row.id, status: row.status, requester_id: row.requester_id,
    requester_name: owner?.display_name ?? 'Unavailable member', blood_type: row.blood_type,
    radius_km: row.radius_km, created_at: row.created_at, expires_at: row.expires_at,
    is_requester: isOwner, invitation_status: invitation?.status ?? null,
    accepted_donor_id: matched ? row.accepted_donor_id : null,
    conversation_id: matched ? row.conversation_id : null,
    peer_id: null, peer_name: null, peer_has_photo: false,
    can_report: wasMatched, donation_recorded: false, donation_summary: null,
  };
  if (isOwner || matched) {
    for (const field of ['destination_name', 'destination_latitude', 'destination_longitude']) result[field] = row[field];
  }
  if (matched) {
    const peer = isOwner ? row.accepted_donor_id : row.requester_id;
    const person = await db.one('SELECT display_name FROM profiles WHERE id=$1', [peer]);
    Object.assign(result, { peer_id: peer, peer_name: person?.display_name ?? 'Member', peer_has_photo: Boolean(await db.one('SELECT 1 FROM profile_photos WHERE user_id=$1', [peer])) });
  }
  if (wasMatched) {
    result.accepted_donor_id = row.accepted_donor_id;
    const donation = await db.one('SELECT donated_at,facility_name,location_name,country,confirmed_by_role FROM donations WHERE request_id=$1', [requestId]);
    result.donation_recorded = Boolean(donation);
    result.donation_summary = donation ?? null;
  }
  return result;
}

/** Authorization is repeated after acquiring a transaction so travel or deletion cannot race a write. */
async function currentActor(db, user) {
  const account = await db.one('SELECT * FROM accounts WHERE id=$1 FOR UPDATE', [user.id]);
  if (!account || account.banned || account.deleted || account.country !== user.country) throw new HttpError(403, 'This account is unavailable');
  return account;
}

/** Both donor and seeker roles consume one participant slot; database constraints enforce the final race. */
async function hasMatch(db, userId) {
  return Boolean(await db.one('SELECT 1 FROM active_matches WHERE donor_id=$1 OR requester_id=$1', [userId]));
}

/** Keep dates as calendar strings; UTC conversion happens only after applying the donor's submitted offset. */
function donationTiming(body, now) {
  const day = body.donated_at;
  const parsed = new Date(`${day}T00:00:00.000Z`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || Number(day.slice(0, 4)) < 1 || !Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== day) throw new HttpError(422, 'Choose a valid donation date');
  const offset = body.utc_offset_minutes ?? 0;
  const localToday = new Date(Date.parse(now) + offset * 60_000).toISOString().slice(0, 10);
  if (day > localToday) throw new HttpError(422, 'Donation date cannot be in the future');
  const untilDay = addThreeMonths(day);
  return { untilDay, untilInstant: new Date(Date.parse(`${untilDay}T00:00:00.000Z`) - offset * 60_000).toISOString() };
}

/** Register routes against a shared context so all state changes use the same authentication and store. */
export function registerDonationRoutes(app, ctx) {
  const protectedRoute = { preHandler: ctx.authenticate };
  const requestRoute = { ...protectedRoute, schema: { params: requestParams } };

  // Invitation creation and its private inbox/outbox events commit together.
  app.post(`${prefix}/requests`, { ...protectedRoute, schema: { body: schemas.request } }, async ({ user, body }) => {
    await ctx.throttle(`request:${user.id}`, 10, 3600);
    return ctx.store.transaction(user.country, async db => {
      await currentActor(db, user);
      await expireRequests(db, user.country, ctx);
      const own = await ctx.completeProfile(db, user.id);
      if (await hasMatch(db, user.id) || await db.one("SELECT 1 FROM donation_requests WHERE requester_id=$1 AND status IN ('open','accepted')", [user.id])) throw new HttpError(409, 'Complete or cancel your current request first');
      const requested = body.donor_ids ? new Set(body.donor_ids) : null;
      // PostGIS narrows the search with its geography index; only private server-side code sees the point.
      const candidates = await db.all(`SELECT p.*,a.country,a.available,a.eligible_after,a.eligible_after_utc,a.banned,a.deleted
        FROM profiles p JOIN accounts a ON a.id=p.id
        WHERE p.blood_type=$1 AND p.id<>$2 AND a.country=$3
          AND ST_DWithin(p.location,ST_SetSRID(ST_MakePoint($4,$5),4326)::geography,$6,false)`,
      [body.blood_type, user.id, user.country, own.longitude, own.latitude, body.radius_km * 1000]);
      const eligible = [];
      for (const donor of candidates) {
        if (requested && !requested.has(donor.id)) continue;
        if (!ctx.available(donor) || donor.height_cm == null || donor.weight_kg == null || donor.latitude == null || donor.longitude == null || !donor.city) continue;
        if (await ctx.relationshipBlocked(db, user.id, donor.id) || await hasMatch(db, donor.id)) continue;
        const distance = kmBetween(own.latitude, own.longitude, donor.latitude, donor.longitude);
        if (distance <= body.radius_km) eligible.push({ distance, donor });
      }
      const donors = eligible.sort((a, b) => a.distance - b.distance).slice(0, 50).map(item => item.donor);
      if (requested && (requested.size !== donors.length || donors.some(donor => !requested.has(donor.id)))) throw new HttpError(409, 'A selected donor is no longer eligible nearby. Refresh your search');
      if (!donors.length) throw new HttpError(409, 'No eligible donors are available within this radius');
      const rid = ctx.newId();
      const now = ctx.stamp();
      await db.run('INSERT INTO donation_requests(id,requester_id,blood_type,radius_km,destination_name,destination_latitude,destination_longitude,created_at,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)', [rid, user.id, body.blood_type, body.radius_km, body.destination_name, body.destination_latitude, body.destination_longitude, now, new Date(Date.parse(now) + 86_400_000).toISOString()]);
      for (const donor of donors) {
        await db.run('INSERT INTO request_invitations(request_id,donor_id) VALUES($1,$2)', [rid, donor.id]);
        await ctx.emitEvent(db, donor.id, 'donation_request', 'A nearby donation request', `${donor.display_name}, someone nearby is looking for a voluntary blood donor. Open the request to respond.`, rid);
      }
      return requestResult(db, rid, user.id);
    });
  });

  // Refresh expired/revoked matches before listing them, including when the background worker is delayed.
  app.get(`${prefix}/requests`, protectedRoute, async ({ user }) => ctx.store.transaction(user.country, async db => {
    await expireRequests(db, user.country, ctx);
    const rows = await db.all('SELECT id FROM donation_requests WHERE requester_id=$1 OR id IN (SELECT request_id FROM request_invitations WHERE donor_id=$1) ORDER BY created_at DESC,id DESC LIMIT 100', [user.id]);
    const items = [];
    for (const row of rows) items.push(await requestResult(db, row.id, user.id));
    return { items };
  }));

  // Detail uses the same participant projection as the list, so guessing an ID grants no extra access.
  app.get(`${prefix}/requests/:rid`, requestRoute, async ({ user, params }) => ctx.store.transaction(user.country, async db => {
    await expireRequests(db, user.country, ctx);
    return requestResult(db, params.rid, user.id);
  }));

  // Serializable retry plus unique participant reservations chooses one winner even for simultaneous taps.
  app.post(`${prefix}/requests/:rid/accept`, requestRoute, async ({ user, params }) => ctx.store.transaction(user.country, async db => {
    await currentActor(db, user);
    await expireRequests(db, user.country, ctx);
    const rid = params.rid;
    const visible = await requestResult(db, rid, user.id);
    const request = await db.one('SELECT * FROM donation_requests WHERE id=$1 FOR UPDATE', [rid]);
    if (request.status === 'accepted' && request.accepted_donor_id === user.id) return visible;
    if (request.status !== 'open' || visible.invitation_status !== 'invited') throw new HttpError(409, 'This request is no longer available to accept');
    const donor = await ctx.completeProfile(db, user.id);
    const owner = await ctx.completeProfile(db, request.requester_id);
    const account = await db.one('SELECT * FROM accounts WHERE id=$1', [user.id]);
    if (!ctx.available(account) || account.country !== user.country || donor.blood_type !== request.blood_type || await ctx.relationshipBlocked(db, user.id, request.requester_id) || kmBetween(owner.latitude, owner.longitude, donor.latitude, donor.longitude) > request.radius_km) throw new HttpError(409, 'You are no longer eligible for this nearby request');
    if (await hasMatch(db, user.id) || await hasMatch(db, request.requester_id) || await db.one("SELECT 1 FROM donation_requests WHERE requester_id=$1 AND status IN ('open','accepted')", [user.id])) throw new HttpError(409, 'Complete or cancel your current request first');
    const [a, b] = [user.id, request.requester_id].sort();
    let conversation = await db.one('SELECT id FROM conversations WHERE user_a=$1 AND user_b=$2', [a, b]);
    if (!conversation) {
      conversation = { id: ctx.newId() };
      await db.run('INSERT INTO conversations(id,user_a,user_b,updated_at) VALUES($1,$2,$3,$4)', [conversation.id, a, b, ctx.stamp()]);
    }
    const others = await db.all("SELECT i.donor_id,p.display_name FROM request_invitations i JOIN profiles p ON p.id=i.donor_id WHERE i.request_id=$1 AND i.status='invited' AND i.donor_id<>$2", [rid, user.id]);
    await db.run('INSERT INTO active_matches(donor_id,requester_id,request_id,country) VALUES($1,$2,$3,$4)', [user.id, request.requester_id, rid, user.country]);
    await db.run("UPDATE donation_requests SET status='accepted',accepted_donor_id=$1,conversation_id=$2 WHERE id=$3", [user.id, conversation.id, rid]);
    await db.run("UPDATE request_invitations SET status=CASE WHEN donor_id=$1 THEN 'accepted' ELSE 'closed' END WHERE request_id=$2 AND status='invited'", [user.id, rid]);
    await ctx.emitEvent(db, request.requester_id, 'request_accepted', 'Your donation request was accepted', `${donor.display_name} accepted your request. You can now see your shared meeting place and private profile photos.`, rid);
    for (const other of others) {
      const otherAccount = await db.one('SELECT * FROM accounts WHERE id=$1', [other.donor_id]);
      if (otherAccount && ctx.available(otherAccount) && otherAccount.country === user.country && !await ctx.relationshipBlocked(db, other.donor_id, request.requester_id)) await ctx.emitEvent(db, other.donor_id, 'thank_you', 'Thank you for being willing to help', `Thank you, ${other.display_name}. Another donor has accepted this request. Your willingness to help makes a difference.`, rid);
    }
    return requestResult(db, rid, user.id);
  }));

  // Repeated declines are safe, but a closed or accepted invitation cannot be rewritten as pending.
  app.post(`${prefix}/requests/:rid/decline`, requestRoute, async ({ user, params }) => ctx.store.transaction(user.country, async db => {
    await currentActor(db, user);
    await expireRequests(db, user.country, ctx);
    const current = await requestResult(db, params.rid, user.id);
    if (current.status !== 'open' || !['invited', 'declined'].includes(current.invitation_status)) throw new HttpError(409, 'This invitation is no longer available');
    await db.run("UPDATE request_invitations SET status='declined' WHERE request_id=$1 AND donor_id=$2", [params.rid, user.id]);
    return requestResult(db, params.rid, user.id);
  }));

  /** Completion records the matched pair for independent reminders, without fabricating a donation. */
  async function finishRequest(user, rid, status) {
    return ctx.store.transaction(user.country, async db => {
      await currentActor(db, user);
      await expireRequests(db, user.country, ctx);
      const visible = await requestResult(db, rid, user.id);
      const original = await db.one('SELECT * FROM donation_requests WHERE id=$1 FOR UPDATE', [rid]);
      if (!visible.is_requester && original.accepted_donor_id !== user.id) throw new HttpError(403, 'Only matched participants can close this request');
      if (visible.status === status) return visible;
      if (!(status === 'cancelled' ? ['open', 'accepted'] : ['accepted']).includes(visible.status)) throw new HttpError(409, 'This request cannot be closed in that state');
      await closeRequest(db, rid, status);
      if (status === 'completed') {
        const donor = await db.one('SELECT display_name FROM profiles WHERE id=$1', [original.accepted_donor_id]);
        await db.run('INSERT INTO donation_confirmations(request_id,user_id,requester_id,donor_name,facility_name,country,created_at) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(request_id) DO NOTHING', [rid, original.accepted_donor_id, original.requester_id, donor?.display_name ?? 'Donor', original.destination_name, user.country, ctx.stamp()]);
      }
      if (visible.peer_id) await ctx.emitEvent(db, visible.peer_id, 'request_closed', 'Donation request updated', `Your shared donation request was ${status}. Profile-photo access has ended.`, rid);
      return requestResult(db, rid, user.id);
    });
  }
  app.post(`${prefix}/requests/:rid/cancel`, requestRoute, async ({ user, params }) => finishRequest(user, params.rid, 'cancelled'));
  app.post(`${prefix}/requests/:rid/complete`, requestRoute, async ({ user, params }) => finishRequest(user, params.rid, 'completed'));

  // History is global for travel, but every returned row still belongs to this authenticated donor.
  app.get(`${prefix}/donations`, protectedRoute, async ({ user }) => ctx.store.transaction(null, async db => ({ items: await db.all('SELECT id,donated_at,facility_name,location_name,country,request_id,created_at,confirmed_by_role FROM donations WHERE user_id=$1 ORDER BY donated_at DESC,created_at DESC,id', [user.id]) })));

  // Either matched participant can answer; each dismissal hides only that person's reminder.
  app.get(`${prefix}/donation-confirmations`, protectedRoute, async ({ user }) => ctx.store.transaction(null, async db => {
    const rows = await db.all("SELECT request_id,facility_name,location_name,country,created_at,donor_name,user_id FROM donation_confirmations WHERE status='pending' AND ((user_id=$1 AND donor_dismissed=0) OR (requester_id=$1 AND seeker_dismissed=0)) ORDER BY created_at,request_id", [user.id]);
    return { items: rows.map(({ user_id, donor_name, ...row }) => ({ ...row, donor_name: donor_name || 'Donor', is_donor: user_id === user.id })) };
  }));

  // Lock against a simultaneous Yes so a late No cannot undo an already recorded donation.
  app.post(`${prefix}/donation-confirmations/:rid/dismiss`, requestRoute, async ({ user, params }) => ctx.store.transaction(null, async db => {
    const row = await db.one('SELECT status,user_id FROM donation_confirmations WHERE request_id=$1 AND (user_id=$2 OR requester_id=$2) FOR UPDATE', [params.rid, user.id]);
    if (!row) throw new HttpError(404, 'Donation confirmation not found');
    if (row.status === 'recorded') throw new HttpError(409, 'This donation has already been recorded');
    const column = row.user_id === user.id ? 'donor_dismissed' : 'seeker_dismissed';
    await db.run(`UPDATE donation_confirmations SET ${column}=1 WHERE request_id=$1`, [params.rid]);
    return { status: 'dismissed' };
  }));

  // The completed receipt identifies the donor; a seeker can never choose an arbitrary target account.
  app.post(`${prefix}/donations`, { ...protectedRoute, schema: { body: schemas.donation } }, async ({ user, body }) => {
    const country = body.country.toUpperCase();
    if (!Object.hasOwn(COUNTRIES, country)) throw new HttpError(422, 'Choose a valid ISO country');
    const timing = donationTiming(body, ctx.stamp());
    await ctx.throttle(`donation:${user.id}`, 10, 3600);
    return ctx.store.transaction(user.country, async db => {
      await currentActor(db, user);
      await ctx.completeProfile(db, user.id);
      let donorId = user.id;
      if (body.request_id) {
        const receipt = await db.one('SELECT * FROM donation_confirmations WHERE request_id=$1 AND (user_id=$2 OR requester_id=$2) FOR UPDATE', [body.request_id, user.id]);
        if (!receipt) throw new HttpError(404, 'Donation confirmation not found');
        donorId = receipt.user_id;
      }
      const account = await db.one('SELECT * FROM accounts WHERE id=$1 FOR UPDATE', [donorId]);
      if (!account || account.deleted) throw new HttpError(409, 'The donor account is no longer available');
      const expected = { donated_at: body.donated_at, facility_name: body.facility_name, location_name: body.location_name, country, request_id: body.request_id ?? null };
      // Scope retry intent to the submitting actor; reuse with altered medical history is a conflict.
      if (body.idempotency_key) {
        const existing = await db.one('SELECT * FROM donations WHERE confirmed_by=$1 AND idempotency_key=$2', [user.id, body.idempotency_key]);
        if (existing) {
          if (Object.entries(expected).some(([key, value]) => existing[key] !== value)) throw new HttpError(409, 'This save was already recorded with different details. Review your donation history before starting a new entry');
          return ctx.profileFor(db, user.id);
        }
      }
      if (body.request_id && await db.one('SELECT 1 FROM donations WHERE request_id=$1', [body.request_id])) return ctx.profileFor(db, user.id);
      await db.run('INSERT INTO donations(id,user_id,donated_at,created_at,facility_name,location_name,country,request_id,idempotency_key,confirmed_by,confirmed_by_role) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)', [ctx.newId(), donorId, body.donated_at, ctx.stamp(), body.facility_name, body.location_name, country, body.request_id ?? null, body.idempotency_key ?? null, user.id, donorId === user.id ? 'donor' : 'seeker']);
      if (body.request_id) await db.run("UPDATE donation_confirmations SET status='recorded' WHERE request_id=$1", [body.request_id]);
      // An older donation may add history, but must never move the current pause deadline backwards.
      const previous = account.eligible_after_utc || (account.eligible_after ? `${account.eligible_after}T00:00:00.000Z` : null);
      if (!previous || Date.parse(timing.untilInstant) > Date.parse(previous)) {
        const displayDay = account.eligible_after && account.eligible_after > timing.untilDay ? account.eligible_after : timing.untilDay;
        await db.run('UPDATE accounts SET eligible_after=$1,eligible_after_utc=$2 WHERE id=$3', [displayDay, timing.untilInstant, donorId]);
      }
      return ctx.profileFor(db, user.id);
    });
  });
}
