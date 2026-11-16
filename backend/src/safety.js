import { createHash } from 'node:crypto';
import { HttpError } from './errors.js';
import { schemas } from './schemas.js';
import { available, kmBetween, newId, stamp } from './utils.js';
import { sanitizeImage } from './integrations.js';
import { assertAccount, completeProfile, conversationPeer, emitEvent, endMatchingCalls, profileFor, relationshipBlocked } from './shared.js';

const prefix = '/api/v1';
const countryQuery = { type: 'object', additionalProperties: false, properties: { country: { type: 'string', minLength: 2, maxLength: 2 } } };

/** Fixed public outcomes cannot disclose an administrator's confidential assessment. */
function reportExplanation(status) {
  return status === 'banned' ? 'Your report was reviewed. Action was taken for a confirmed request for money.'
    : status === 'dismissed' ? 'Your report was reviewed. No account action was taken from this report.' : null;
}

/** Metadata contains no download URL; bytes require a separately authorized request. */
async function attachmentMetadata(db, reportId) {
  return (await db.all('SELECT id,created_at FROM report_attachments WHERE report_id=$1 ORDER BY created_at,id', [reportId]))
    .map(row => ({ ...row, content_type: 'image/jpeg' }));
}

/** The reporter receives only their own submission and a public review outcome. */
async function ownerReport(db, row, country) {
  return { id: row.id, country, request_id: row.request_id, reason: row.reason, details: row.details,
    status: row.status === 'pending' ? 'pending' : 'reviewed', outcome: row.status === 'pending' ? null : row.status,
    submitted_at: row.created_at, reviewed_at: row.reviewed_at, outcome_explanation: reportExplanation(row.status),
    attachments: await attachmentMetadata(db, row.id) };
}

/** Retry interrupted regional erasure while the global tombstone already rejects all existing tokens. */
export async function scrubDeletedAccounts(store, ctx) {
  const jobs = await store.transaction(null, db => db.all('SELECT user_id FROM deletion_jobs ORDER BY created_at LIMIT 20'));
  for (const { user_id: uid } of jobs) {
    for (const country of store.countries()) {
      await store.transaction(country, async db => {
        await db.run('DELETE FROM profile_photos WHERE user_id=$1', [uid]);
        await db.run('DELETE FROM profiles WHERE id=$1', [uid]);
        await db.run('DELETE FROM push_outbox WHERE event_id IN (SELECT id FROM events WHERE user_id=$1)', [uid]);
        await db.run('DELETE FROM events WHERE user_id=$1', [uid]);
        await ctx.expireRequests(db, country);
        await db.run("UPDATE events SET body='This request is no longer available.' WHERE request_id IN (SELECT id FROM donation_requests WHERE requester_id=$1 OR accepted_donor_id=$1)", [uid]);
        await db.run("UPDATE donation_requests SET destination_name='[Removed]',destination_latitude=0,destination_longitude=0 WHERE requester_id=$1", [uid]);
        await db.run("UPDATE messages SET body='[Message removed]' WHERE sender_id=$1", [uid]);
        await endMatchingCalls(db, 'caller_id=$1 OR callee_id=$1', [uid]);
      });
    }
    await store.transaction(null, db => db.run('DELETE FROM deletion_jobs WHERE user_id=$1', [uid]));
  }
}

/** All routes enforce server-side membership; submitted IDs never establish a relationship. */
export function registerSafetyRoutes(app, ctx) {
  const { store, authenticate, administrator, throttle, storedCountry } = ctx;
  const member = { preHandler: authenticate };
  const admin = { preHandler: administrator };

  app.get(`${prefix}/conversations`, member, request => store.transaction(request.user.country, async db => {
    await assertAccount(db, request.user);
    const rows = await db.all('SELECT * FROM conversations WHERE user_a=$1 OR user_b=$1 ORDER BY updated_at DESC LIMIT 100', [request.user.id]);
    const items = [];
    for (const row of rows) {
      const peer = row.user_a === request.user.id ? row.user_b : row.user_a;
      const person = await db.one('SELECT display_name,blood_type FROM profiles WHERE id=$1', [peer]);
      const last = await db.one('SELECT body FROM messages WHERE conversation_id=$1 ORDER BY created_at DESC LIMIT 1', [row.id]);
      items.push({ id: row.id, peer_id: peer, peer_name: person?.display_name || 'Unavailable member', blood_type: person?.blood_type ?? null,
        last_message: last?.body || '', updated_at: row.updated_at, is_blocked: await relationshipBlocked(db, request.user.id, peer) });
    }
    return { items };
  }));

  app.post(`${prefix}/conversations`, { ...member, schema: { body: schemas.conversation } }, async request => {
    const { user, body } = request;
    await throttle(`contact:${user.id}`, 15, 3600);
    return store.transaction(user.country, async db => {
      await assertAccount(db, user);
      const own = await completeProfile(db, user.id);
      const row = await db.one('SELECT p.*,a.country,a.available,a.eligible_after,a.eligible_after_utc,a.banned,a.deleted FROM profiles p JOIN accounts a ON p.id=a.id WHERE p.id=$1', [body.donor_id]);
      if (!row || row.id === user.id || row.country !== user.country || !available(row) || row.latitude == null || row.longitude == null ||
          await relationshipBlocked(db, user.id, body.donor_id) || kmBetween(own.latitude, own.longitude, row.latitude, row.longitude) > 39) {
        throw new HttpError(404, 'This donor is not available nearby');
      }
      const [a, b] = [user.id, body.donor_id].sort();
      const existing = await db.one('SELECT id FROM conversations WHERE user_a=$1 AND user_b=$2', [a, b]);
      const id = existing?.id || newId();
      if (!existing) await db.run('INSERT INTO conversations(id,user_a,user_b,updated_at) VALUES($1,$2,$3,$4)', [id, a, b, stamp()]);
      return { id, peer_id: body.donor_id, peer_name: row.display_name, blood_type: row.blood_type };
    });
  });

  app.get(`${prefix}/conversations/:cid/messages`, member, request => store.transaction(request.user.country, async db => {
    await assertAccount(db, request.user);
    await conversationPeer(db, request.params.cid, request.user.id);
    return { items: await db.all('SELECT id,sender_id,body,created_at FROM (SELECT * FROM messages WHERE conversation_id=$1 ORDER BY created_at DESC LIMIT 200) recent ORDER BY created_at', [request.params.cid]) };
  }));

  app.post(`${prefix}/conversations/:cid/messages`, { ...member, schema: { body: schemas.message } }, async request => {
    await throttle(`message:${request.user.id}`, 60, 60);
    return store.transaction(request.user.country, async db => {
      await assertAccount(db, request.user);
      await conversationPeer(db, request.params.cid, request.user.id, true);
      const message = { id: newId(), sender_id: request.user.id, body: request.body.body, created_at: stamp() };
      await db.run('INSERT INTO messages(id,conversation_id,sender_id,body,created_at) VALUES($1,$2,$3,$4,$5)', [message.id, request.params.cid, message.sender_id, message.body, message.created_at]);
      await db.run('UPDATE conversations SET updated_at=$1 WHERE id=$2', [message.created_at, request.params.cid]);
      return message;
    });
  });

  app.get(`${prefix}/reports`, member, async request => {
    let items = [];
    for (const country of store.countries()) {
      const regional = await store.transaction(country, async db => {
        await assertAccount(db, request.user, { country: false });
        const rows = await db.all('SELECT * FROM reports WHERE reporter_id=$1 ORDER BY created_at DESC,id DESC LIMIT 100', [request.user.id]);
        return Promise.all(rows.map(row => ownerReport(db, row, country)));
      });
      items = items.concat(regional).sort((a, b) => b.submitted_at.localeCompare(a.submitted_at) || b.country.localeCompare(a.country) || b.id.localeCompare(a.id)).slice(0, 100);
    }
    return { items };
  });

  app.get(`${prefix}/reports/:rid`, { ...member, schema: { querystring: countryQuery } }, async request => {
    const country = await storedCountry(request.query.country, request.user);
    return store.transaction(country, async db => {
      await assertAccount(db, request.user, { country: false });
      const row = await db.one('SELECT * FROM reports WHERE id=$1 AND reporter_id=$2', [request.params.rid, request.user.id]);
      if (!row) throw new HttpError(404, 'Report not found');
      return ownerReport(db, row, country);
    });
  });

  app.post(`${prefix}/reports`, { ...member, schema: { body: schemas.report } }, async request => {
    const { user, body } = request;
    if (Boolean(body.conversation_id) === Boolean(body.request_id)) throw new HttpError(422, 'Choose one conversation or donation request to report');
    await throttle(`report:${user.id}`, 10, 3600);
    return store.transaction(user.country, async db => {
      await assertAccount(db, user);
      let conversationId = body.conversation_id, peer;
      if (body.request_id) {
        const matched = await db.one('SELECT * FROM donation_requests WHERE id=$1 AND accepted_donor_id IS NOT NULL AND (requester_id=$2 OR accepted_donor_id=$2)', [body.request_id, user.id]);
        if (!matched) throw new HttpError(404, 'Matched donation request not found');
        peer = matched.requester_id === user.id ? matched.accepted_donor_id : matched.requester_id;
        conversationId = matched.conversation_id;
      } else peer = await conversationPeer(db, conversationId, user.id);
      if (body.idempotency_key) {
        const existing = await db.one('SELECT * FROM reports WHERE reporter_id=$1 AND idempotency_key=$2', [user.id, body.idempotency_key]);
        if (existing) {
          if (existing.conversation_id !== conversationId || existing.request_id !== (body.request_id || null) || existing.reason !== body.reason || existing.details !== body.details) {
            throw new HttpError(409, 'This report was already submitted with different details');
          }
          return { id: existing.id, status: existing.status };
        }
      }
      const evidence = await db.all('SELECT sender_id,body,created_at FROM messages WHERE conversation_id=$1 ORDER BY created_at DESC LIMIT 20', [conversationId]);
      const id = newId();
      await db.run('INSERT INTO reports(id,reporter_id,reported_id,conversation_id,reason,details,status,evidence,created_at,request_id,idempotency_key) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)',
        [id, user.id, peer, conversationId, body.reason, body.details, 'pending', JSON.stringify(evidence), stamp(), body.request_id || null, body.idempotency_key || null]);
      return { id, status: 'pending' };
    });
  });

  app.post(`${prefix}/reports/:rid/evidence`, { ...member, bodyLimit: 5 * 1024 * 1024 }, async request => {
    const { user } = request;
    await store.transaction(user.country, async db => {
      await assertAccount(db, user);
      const report = await db.one('SELECT status FROM reports WHERE id=$1 AND reporter_id=$2', [request.params.rid, user.id]);
      if (!report) throw new HttpError(404, 'Report not found');
      if (report.status !== 'pending') throw new HttpError(409, 'Reviewed report evidence cannot be changed');
    });
    if (!['image/jpeg', 'image/png'].includes(String(request.headers['content-type'] || '').split(';')[0])) throw new HttpError(415, 'Upload a JPEG or PNG image');
    await throttle(`report-photo:${user.id}`, 30, 3600);
    const jpeg = await sanitizeImage(request.body, 2048);
    const digest = createHash('sha256').update(request.body).digest('hex');
    return store.transaction(user.country, async db => {
      await assertAccount(db, user);
      // Lock the report after decoding so concurrent review/upload cannot exceed limits or mutate closed evidence.
      const report = await db.one('SELECT status FROM reports WHERE id=$1 AND reporter_id=$2 FOR UPDATE', [request.params.rid, user.id]);
      if (!report) throw new HttpError(404, 'Report not found');
      if (report.status !== 'pending') throw new HttpError(409, 'Reviewed report evidence cannot be changed');
      const existing = await db.one('SELECT id,created_at FROM report_attachments WHERE report_id=$1 AND source_digest=$2', [request.params.rid, digest]);
      if (existing) return { ...existing, content_type: 'image/jpeg' };
      const count = await db.one('SELECT COUNT(*)::integer AS count FROM report_attachments WHERE report_id=$1', [request.params.rid]);
      if (count.count >= 3) throw new HttpError(409, 'A report can have at most three evidence images');
      const id = newId(), created = stamp();
      await db.run('INSERT INTO report_attachments(id,report_id,jpeg,source_digest,created_at) VALUES($1,$2,$3,$4,$5)', [id, request.params.rid, jpeg, digest, created]);
      return { id, content_type: 'image/jpeg', created_at: created };
    });
  });

  /** Return private image bytes only after reporter/admin ownership checks, including accused-admin exclusion. */
  const evidenceResponse = async (request, reply, isAdmin) => {
    const country = isAdmin ? request.user.country : await storedCountry(request.query.country, request.user);
    const image = await store.transaction(country, async db => {
      await assertAccount(db, request.user, { country: false });
      const report = await db.one('SELECT reporter_id,reported_id FROM reports WHERE id=$1', [request.params.rid]);
      if (!report || (isAdmin ? report.reported_id === request.user.id : report.reporter_id !== request.user.id)) throw new HttpError(404, 'Evidence not found');
      const row = await db.one('SELECT jpeg FROM report_attachments WHERE id=$1 AND report_id=$2', [request.params.aid, request.params.rid]);
      if (!row) throw new HttpError(404, 'Evidence not found');
      return row.jpeg;
    });
    return reply.type('image/jpeg').header('Cache-Control', 'no-store').send(image);
  };
  app.get(`${prefix}/reports/:rid/evidence/:aid`, { ...member, schema: { querystring: countryQuery } }, (request, reply) => evidenceResponse(request, reply, false));
  app.get(`${prefix}/admin/reports/:rid/evidence/:aid`, admin, (request, reply) => evidenceResponse(request, reply, true));

  app.post(`${prefix}/blocks`, { ...member, schema: { body: schemas.block } }, request => store.transaction(request.user.country, async db => {
    await assertAccount(db, request.user);
    const [a, b] = [request.user.id, request.body.user_id].sort();
    if (a === b || !await db.one('SELECT id FROM conversations WHERE user_a=$1 AND user_b=$2', [a, b])) throw new HttpError(404, 'Conversation peer not found');
    await db.run('INSERT INTO blocks(blocker,blocked,created_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING', [request.user.id, request.body.user_id, stamp()]);
    await endMatchingCalls(db, '(caller_id=$1 AND callee_id=$2) OR (caller_id=$2 AND callee_id=$1)', [request.user.id, request.body.user_id]);
    await ctx.expireRequests(db, request.user.country);
    return { status: 'blocked' };
  }));

  app.get(`${prefix}/admin/reports`, admin, request => store.transaction(request.user.country, async db => {
    await assertAccount(db, request.user, { country: false });
    const rows = await db.all('SELECT id,reporter_id,reported_id,reason,details,status,created_at,evidence,request_id,reviewed_at FROM reports WHERE reported_id<>$1 ORDER BY created_at DESC LIMIT 200', [request.user.id]);
    return { items: await Promise.all(rows.map(async row => ({ ...row, evidence: JSON.parse(row.evidence), attachments: await attachmentMetadata(db, row.id) }))) };
  }));

  app.post(`${prefix}/admin/reports/:rid/resolve`, { ...admin, schema: { body: schemas.resolution } }, request => store.transaction(request.user.country, async db => {
    await assertAccount(db, request.user, { country: false });
    const report = await db.one('SELECT * FROM reports WHERE id=$1 FOR UPDATE', [request.params.rid]);
    if (!report) throw new HttpError(404, 'Report not found');
    if (report.status !== 'pending') throw new HttpError(409, 'This report has already been reviewed');
    if (request.body.decision === 'ban' && report.reason !== 'money_request') throw new HttpError(422, 'Lifetime bans require a confirmed money request');
    if (report.reported_id === request.user.id) throw new HttpError(403, 'Another administrator must review a report about you');
    const status = request.body.decision === 'ban' ? 'banned' : 'dismissed';
    if (status === 'banned') {
      await db.run('UPDATE accounts SET banned=1,available=0 WHERE id=$1', [report.reported_id]);
      await endMatchingCalls(db, 'caller_id=$1 OR callee_id=$1', [report.reported_id]);
      await ctx.expireRequests(db, request.user.country);
    }
    await db.run('UPDATE reports SET status=$1,reviewed_at=$2 WHERE id=$3', [status, stamp(), report.id]);
    await db.run('INSERT INTO audit(id,actor_id,subject_id,action,country,report_id,note,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
      [newId(), request.user.id, report.reported_id, status, request.user.country, report.id, request.body.note, stamp()]);
    // A failed inbox/outbox write rolls back the review, global ban and immutable audit insertion together.
    await (ctx.emitEvent || emitEvent)(db, report.reporter_id, 'report_reviewed', 'Your report was reviewed', 'Open My reports to see the outcome of your report.', null,
      { report_id: report.id, report_country: request.user.country });
    return { status };
  }));

  app.get(`${prefix}/admin/summary`, admin, request => store.transaction(request.user.country, async db => {
    await assertAccount(db, request.user, { country: false });
    return { pending_reports: (await db.one("SELECT COUNT(*)::integer AS count FROM reports WHERE status='pending'")).count,
      banned_accounts: (await db.one('SELECT COUNT(*)::integer AS count FROM accounts WHERE banned=1')).count,
      active_donors: (await db.all('SELECT * FROM accounts WHERE country=$1', [request.user.country])).filter(available).length, country: request.user.country };
  }));

  app.get(`${prefix}/me/export`, member, async request => {
    const result = await store.transaction(request.user.country, async db => {
      await assertAccount(db, request.user);
      const ownPhoto = await db.one('SELECT jpeg FROM profile_photos WHERE user_id=$1', [request.user.id]);
      return { profile: await profileFor(db, request.user.id),
        donations: await db.all('SELECT id,donated_at,facility_name,location_name,country,request_id,created_at,confirmed_by_role FROM donations WHERE user_id=$1', [request.user.id]),
        donation_confirmations: await db.all('SELECT request_id,facility_name,location_name,country,created_at,status FROM donation_confirmations WHERE user_id=$1 OR requester_id=$1', [request.user.id]),
        photo_jpeg_base64: ownPhoto ? ownPhoto.jpeg.toString('base64') : null, regions: [] };
    });
    for (const country of store.countries()) {
      const region = await store.transaction(country, async db => {
        await assertAccount(db, request.user, { country: false });
        const messages = await db.all('SELECT id,conversation_id,body,created_at FROM messages WHERE sender_id=$1', [request.user.id]);
        const reports = await db.all('SELECT id,reason,details,status,created_at,reviewed_at FROM reports WHERE reporter_id=$1', [request.user.id]);
        for (const report of reports) report.attachments = (await db.all('SELECT id,created_at,jpeg FROM report_attachments WHERE report_id=$1', [report.id]))
          .map(row => ({ id: row.id, created_at: row.created_at, content_type: 'image/jpeg', jpeg_base64: row.jpeg.toString('base64') }));
        return { country, messages, reports };
      });
      if (region.messages.length || region.reports.length) result.regions.push(region);
    }
    return result;
  });

  app.delete(`${prefix}/me`, member, async request => {
    await store.transaction(null, async db => {
      await assertAccount(db, request.user, { country: false });
      await db.run('UPDATE accounts SET deleted=1,available=0 WHERE id=$1', [request.user.id]);
      await db.run('DELETE FROM donations WHERE user_id=$1', [request.user.id]);
      await db.run('DELETE FROM donation_confirmations WHERE user_id=$1', [request.user.id]);
      await db.run('DELETE FROM blocks WHERE blocker=$1 OR blocked=$1', [request.user.id]);
      await db.run('DELETE FROM devices WHERE user_id=$1', [request.user.id]);
      await db.run('INSERT INTO deletion_jobs(user_id,created_at) VALUES($1,$2) ON CONFLICT DO NOTHING', [request.user.id, stamp()]);
    });
    try { await scrubDeletedAccounts(store, ctx); }
    catch { return { status: 'deleted', erasure_pending: true }; }
    return { status: 'deleted', erasure_pending: false };
  });
}
