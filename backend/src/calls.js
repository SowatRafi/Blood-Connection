import { HttpError } from './errors.js';
import { assertAccount } from './shared.js';
import { livekitCredentials, revokeMedia } from './integrations.js';

const prefix = '/api/v1';
const callParams = { type: 'object', required: ['callId'], properties: { callId: { type: 'string', minLength: 1, maxLength: 80 } } };

// Expire abandoned media and queue enforcement cleanup transactionally; external revocation is retryable.
export async function cleanupMedia(store, settings, ctx) {
  if (!settings.livekitUrl || !settings.livekitKey || !settings.livekitSecret) return;
  for (const country of await store.countries()) {
    await store.transaction(country, async db => {
      await ctx.endMatchingCalls(db, 'expires_at::timestamptz<=now()', []);
      await ctx.endMatchingCalls(db, 'caller_id IN (SELECT id FROM accounts WHERE banned=1 OR deleted=1 OR country<>$1) OR callee_id IN (SELECT id FROM accounts WHERE banned=1 OR deleted=1 OR country<>$1)', [country]);
    });
  }
  const pending = await store.transaction(null, db => db.all('SELECT * FROM media_cleanup ORDER BY call_id LIMIT 20'));
  for (const job of pending) {
    if (await revokeMedia(job, settings)) await store.transaction(null, db => db.run('DELETE FROM media_cleanup WHERE call_id=$1', [job.call_id]));
  }
}

// Every status read and write checks membership and current relationship authorization before signing.
async function authorizedCall(db, callId, user, ctx) {
  await assertAccount(db, user);
  let call = await db.one('SELECT * FROM calls WHERE id=$1 AND (caller_id=$2 OR callee_id=$2) FOR UPDATE', [callId, user.id]);
  if (!call) throw new HttpError(404, 'Call not found');
  await ctx.conversationPeer(db, call.conversation_id, user.id, true);
  if (['ringing', 'accepted'].includes(call.status) && Date.parse(call.expires_at) <= Date.now()) {
    await ctx.endMatchingCalls(db, 'id=$1', [callId]);
    call = await db.one('SELECT * FROM calls WHERE id=$1', [callId]);
  }
  return call;
}

// Keep the existing mobile call contract while all state transitions are authorized in PostgreSQL.
export function registerCallRoutes(app, ctx) {
  const { store, settings, authenticate } = ctx;
  app.get(`${prefix}/calls`, { preHandler: authenticate }, async request => store.transaction(request.user.country, async db => {
    const account = await assertAccount(db, request.user);
    if (!ctx.available(account)) return { items: [] };
    const rows = await db.all(`SELECT c.*,p.display_name AS caller_name FROM calls c
      JOIN accounts a ON a.id=c.caller_id LEFT JOIN profiles p ON p.id=c.caller_id
      WHERE c.callee_id=$1 AND c.status='ringing' AND c.expires_at::timestamptz>now() AND a.banned=0 AND a.deleted=0 AND a.country=$2`, [request.user.id, request.user.country]);
    const items = [];
    for (const row of rows) {
      if (!await ctx.relationshipBlocked(db, request.user.id, row.caller_id)) items.push({ id: row.id, conversation_id: row.conversation_id, caller_id: row.caller_id, caller_name: row.caller_name || 'Member', status: row.status });
    }
    return { items };
  }));

  app.post(`${prefix}/conversations/:cid/calls`, { preHandler: authenticate, schema: {
    params: { type: 'object', required: ['cid'], properties: { cid: { type: 'string', minLength: 1, maxLength: 80 } } },
  } }, async request => {
    if (!settings.callingEnabled) throw new HttpError(503, 'In-app calling is not configured yet');
    await ctx.throttle(`call:${request.user.id}`, 10, 3600);
    return store.transaction(request.user.country, async db => {
      await assertAccount(db, request.user);
      const cid = request.params.cid;
      const peer = await ctx.conversationPeer(db, cid, request.user.id, true);
      // Serialize call creation per conversation so simultaneous invites produce one active call.
      await db.one('SELECT id FROM conversations WHERE id=$1 FOR UPDATE', [cid]);
      const target = await db.one('SELECT * FROM accounts WHERE id=$1', [peer]);
      if (!ctx.available(target)) throw new HttpError(409, 'This member is not available for calls');
      await ctx.endMatchingCalls(db, 'conversation_id=$1 AND expires_at::timestamptz<=now()', [cid]);
      if (await db.one("SELECT 1 FROM calls WHERE conversation_id=$1 AND status IN ('ringing','accepted') AND expires_at::timestamptz>now()", [cid])) throw new HttpError(409, 'A call is already in progress');
      const id = ctx.newId();
      await db.run("INSERT INTO calls(id,conversation_id,caller_id,callee_id,status,created_at,expires_at) VALUES($1,$2,$3,$4,'ringing',$5,$6)", [id, cid, request.user.id, peer, ctx.stamp(), new Date(Date.now() + 60_000).toISOString()]);
      return { id, status: 'ringing' };
    });
  });

  app.post(`${prefix}/calls/:callId/accept`, { preHandler: authenticate, schema: { params: callParams } }, async request => {
    return store.transaction(request.user.country, async db => {
      const row = await authorizedCall(db, request.params.callId, request.user, ctx);
      if (row.callee_id !== request.user.id) throw new HttpError(403, 'Only the invited member can accept');
      const account = await db.one('SELECT * FROM accounts WHERE id=$1', [request.user.id]);
      if (!ctx.available(account) || row.status !== 'ringing') throw new HttpError(409, 'This call is no longer available');
      await db.run("UPDATE calls SET status='accepted',expires_at=$1 WHERE id=$2", [new Date(Date.now() + 3_600_000).toISOString(), row.id]);
      // Signing is local work: keep it inside the transaction so a signing failure rolls back acceptance.
      return { id: row.id, ...await livekitCredentials(row, request.user, settings) };
    });
  });

  app.get(`${prefix}/calls/:callId`, { preHandler: authenticate, schema: { params: callParams } }, async request => {
    return store.transaction(request.user.country, async db => {
      const call = await authorizedCall(db, request.params.callId, request.user, ctx);
      const result = { id: call.id, status: call.status };
      if (call.status === 'accepted') Object.assign(result, await livekitCredentials(call, request.user, settings));
      return result;
    });
  });

  app.post(`${prefix}/calls/:callId/end`, { preHandler: authenticate, schema: { params: callParams } }, async request => {
    await store.transaction(request.user.country, async db => {
      await authorizedCall(db, request.params.callId, request.user, ctx);
      await ctx.endMatchingCalls(db, 'id=$1', [request.params.callId]);
    });
    await cleanupMedia(store, settings, ctx);
    return { status: 'ended' };
  });
}
