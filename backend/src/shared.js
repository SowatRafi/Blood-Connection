import { HttpError } from './errors.js';
import { available, stamp } from './utils.js';

/** Recheck inside mutations: authentication alone cannot protect against concurrent travel or bans. */
export async function assertAccount(db, user, { country = true } = {}) {
  const account = await db.one('SELECT * FROM accounts WHERE id=$1 FOR UPDATE', [user.id]);
  if (!account || account.banned || account.deleted) throw new HttpError(403, 'This account is unavailable');
  if (country && account.country !== user.country) throw new HttpError(409, 'Your country changed. Refresh your profile and try again');
  return account;
}

/** Explicit projection prevents PostGIS columns or future private fields leaking through owner responses. */
export async function profileFor(db, uid, schema = '') {
  const table = schema ? `${db.schema(schema)}.profiles` : 'profiles';
  const photos = schema ? `${db.schema(schema)}.profile_photos` : 'profile_photos';
  const account = await db.one('SELECT * FROM accounts WHERE id=$1', [uid]);
  const row = await db.one(`SELECT id,display_name,blood_type,height_cm,weight_kg,city,latitude,longitude FROM ${table} WHERE id=$1`, [uid]);
  if (!account || !row) throw new HttpError(404, 'Profile not found in this country');
  return { ...row, country: account.country, available: Boolean(account.available), eligible_after: account.eligible_after,
    eligible_after_utc: account.eligible_after_utc, is_available: available(account), role: account.role, location_mode: account.location_mode,
    bmi: row.height_cm && row.weight_kg ? Math.round(row.weight_kg / (row.height_cm / 100) ** 2 * 10) / 10 : null,
    has_photo: Boolean(await db.one(`SELECT 1 FROM ${photos} WHERE user_id=$1`, [uid])) };
}

/** Discovery needs a complete profile and deliberately selected location. */
export async function completeProfile(db, uid) {
  const row = await db.one('SELECT * FROM profiles WHERE id=$1', [uid]);
  if (!row || ['blood_type', 'height_cm', 'weight_kg', 'latitude', 'longitude'].some(k => row[k] == null) || !row.city) throw new HttpError(409, 'Complete your profile and location first');
  return row;
}

/** Either person's block prevents further contact in both directions. */
export async function relationshipBlocked(db, uid, peer) {
  return Boolean(await db.one('SELECT 1 FROM blocks WHERE (blocker=$1 AND blocked=$2) OR (blocker=$2 AND blocked=$1)', [uid, peer]));
}

/** Read membership survives blocking so participants can still report misconduct. */
export async function conversationPeer(db, cid, uid, writable = false) {
  const conversation = await db.one('SELECT * FROM conversations WHERE id=$1 AND (user_a=$2 OR user_b=$2)', [cid, uid]);
  if (!conversation) throw new HttpError(404, 'Conversation not found');
  const peer = conversation.user_a === uid ? conversation.user_b : conversation.user_a;
  if (writable) {
    const caller = await db.one('SELECT * FROM accounts WHERE id=$1', [uid]);
    const account = await db.one('SELECT * FROM accounts WHERE id=$1', [peer]);
    if (!caller || caller.banned || caller.deleted || !account || account.banned || account.deleted || account.country !== caller.country || await relationshipBlocked(db, uid, peer)) throw new HttpError(403, 'This conversation is unavailable');
  }
  return peer;
}

/** Queue revocation in the same transaction as ending calls; only internal SQL clauses are accepted. */
export async function endMatchingCalls(db, clause, values) {
  const calls = await db.all(`SELECT * FROM calls WHERE (${clause}) AND status IN ('ringing','accepted') FOR UPDATE`, values);
  for (const call of calls) {
    if (call.status === 'accepted') await db.run('INSERT INTO media_cleanup(call_id,caller_id,callee_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING', [call.id, call.caller_id, call.callee_id]);
    await db.run("UPDATE calls SET status='ended' WHERE id=$1", [call.id]);
  }
}

/** Inbox and outbox are part of the caller's transaction, never an after-commit best effort. */
export async function emitEvent(db, uid, kind, title, body, requestId = null, targets = {}) {
  const event = await db.one('INSERT INTO events(user_id,kind,title,body,request_id,created_at,report_id,report_country) VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id',
    [uid, kind, title, body, requestId || '', stamp(), targets.report_id || null, targets.report_country || null]);
  await db.run('INSERT INTO push_outbox(event_id,device_id,next_attempt) SELECT $1,id,$2 FROM devices WHERE user_id=$3 ON CONFLICT DO NOTHING', [event.id, stamp(), uid]);
  return event.id;
}
