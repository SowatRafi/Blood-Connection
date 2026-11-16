import { schemas } from './schemas.js';
import { HttpError } from './errors.js';
import { GROUPS, available, kmBetween, coarseMapArea, stamp } from './utils.js';
import { assertAccount } from './shared.js';
import { sanitizeImage } from './integrations.js';

/** Private profile and location routes retain the existing mobile contract during the storage migration. */
export function registerProfileRoutes(app, ctx) {
  const { store, authenticate, countryCode, throttle, profileFor, completeProfile, relationshipBlocked } = ctx;
  const prefix = '/api/v1';
  app.get(`${prefix}/me`, { preHandler: authenticate }, request => store.transaction(request.user.country, db => profileFor(db, request.user.id)));
  // Profile edits cannot silently overwrite newer automatic/manual location data;
  // location changes use the dedicated path that also handles cross-country state.
  app.put(`${prefix}/me`, { preHandler: authenticate, schema: { body: schemas.profile } }, request => store.transaction(request.user.country, async db => {
    const user = request.user, body = request.body;
    await assertAccount(db, user);
    const original = await db.one('SELECT city,latitude,longitude FROM profiles WHERE id=$1', [user.id]);
    if (!original || ['city', 'latitude', 'longitude'].some(k => original[k] !== body[k])) throw new HttpError(409, 'Location changed or is missing. Update location and refresh your profile before saving');
    await db.run('UPDATE profiles SET display_name=$1,blood_type=$2,height_cm=$3,weight_kg=$4 WHERE id=$5', [body.display_name, body.blood_type, body.height_cm, body.weight_kg, user.id]);
    await db.run('UPDATE accounts SET available=$1 WHERE id=$2', [Number(body.available), user.id]);
    return profileFor(db, user.id);
  }));

  /** Moving a profile, photo, registry country and active relationships is one PostgreSQL transaction. */
  const saveLocation = async (body, user, requireComplete = false) => {
    const destination = countryCode(body.country);
    await store.ensureRegion(destination);
    return store.transaction(user.country, async db => {
      const account = await assertAccount(db, user);
      const original = requireComplete ? await completeProfile(db, user.id) : await db.one('SELECT * FROM profiles WHERE id=$1', [user.id]);
      if (!original) throw new HttpError(409, 'Refresh your profile before updating location');
      const same = destination === user.country && ['city', 'latitude', 'longitude'].every(k => original[k] === body[k]);
      if (same && account.location_mode === body.mode) return profileFor(db, user.id);
      if (!same) {
        await throttle(`location-update:${user.id}`, 60, 3600, db);
        if (destination !== user.country) await throttle(`travel:${user.id}`, 10, 3600, db);
      }
      if (destination === user.country) {
        if (!same) await db.run('UPDATE profiles SET city=$1,latitude=$2,longitude=$3 WHERE id=$4', [body.city, body.latitude, body.longitude, user.id]);
        await db.run('UPDATE accounts SET location_mode=$1 WHERE id=$2', [body.mode, user.id]);
        return profileFor(db, user.id);
      }
      const dest = db.schema(destination);
      await db.run(`INSERT INTO ${dest}.profiles(id,display_name,blood_type,height_cm,weight_kg,city,latitude,longitude) VALUES($1,$2,$3,$4,$5,$6,$7,$8)
        ON CONFLICT(id) DO UPDATE SET display_name=EXCLUDED.display_name,blood_type=EXCLUDED.blood_type,height_cm=EXCLUDED.height_cm,weight_kg=EXCLUDED.weight_kg,city=EXCLUDED.city,latitude=EXCLUDED.latitude,longitude=EXCLUDED.longitude`,
      [user.id, original.display_name, original.blood_type, original.height_cm, original.weight_kg, body.city, body.latitude, body.longitude]);
      await db.run(`DELETE FROM ${dest}.profile_photos WHERE user_id=$1`, [user.id]);
      await db.run(`INSERT INTO ${dest}.profile_photos SELECT * FROM profile_photos WHERE user_id=$1`, [user.id]);
      await db.run('DELETE FROM profiles WHERE id=$1', [user.id]);
      await db.run('UPDATE accounts SET country=$1,location_mode=$2 WHERE id=$3', [destination, body.mode, user.id]);
      await ctx.expireRequests(db, user.country);
      await ctx.endMatchingCalls(db, 'caller_id=$1 OR callee_id=$1', [user.id]);
      return profileFor(db, user.id, destination);
    });
  };
  app.post(`${prefix}/location`, { preHandler: authenticate, schema: { body: schemas.location } }, request => saveLocation(request.body, request.user));
  app.post(`${prefix}/travel`, { preHandler: authenticate, schema: { body: schemas.travel } }, request => saveLocation({ ...request.body, mode: 'manual' }, request.user, true));

  app.get(`${prefix}/donors`, { preHandler: authenticate, schema: { querystring: { type: 'object', additionalProperties: false,
    required: ['blood_type', 'radius_km', 'latitude', 'longitude'], properties: { blood_type: { enum: [...GROUPS] }, radius_km: { type: 'number', minimum: 1, maximum: 39 }, latitude: { type: 'number', minimum: -90, maximum: 90 }, longitude: { type: 'number', minimum: -180, maximum: 180 } } } } }, async request => {
    const user = request.user, query = request.query;
    await throttle(`search:${user.id}`, 30, 60);
    return store.transaction(user.country, async db => {
      const own = await completeProfile(db, user.id);
      if (kmBetween(own.latitude, own.longitude, query.latitude, query.longitude) > 1) throw new HttpError(409, 'Update your profile location before searching this area');
      // The spatial index narrows exact private points; only fixed coarse cells leave the server.
      const rows = await db.all(`SELECT p.id,p.display_name,p.blood_type,p.city,p.latitude,p.longitude,
        ST_Distance(p.location,ST_SetSRID(ST_MakePoint($1,$2),4326)::geography,false)/1000 AS distance
        FROM profiles p JOIN accounts a ON a.id=p.id
        WHERE p.blood_type=$3 AND p.id<>$4 AND a.country=$5 AND a.available=1 AND a.banned=0 AND a.deleted=0
        AND p.height_cm IS NOT NULL AND p.weight_kg IS NOT NULL AND p.city<>''
        AND (COALESCE(a.eligible_after_utc,a.eligible_after||'T00:00:00.000Z') IS NULL OR COALESCE(a.eligible_after_utc,a.eligible_after||'T00:00:00.000Z')<=$6)
        AND NOT EXISTS(SELECT 1 FROM blocks b WHERE (b.blocker=$4 AND b.blocked=p.id) OR (b.blocker=p.id AND b.blocked=$4))
        AND ST_DWithin(p.location,ST_SetSRID(ST_MakePoint($1,$2),4326)::geography,$7,false)
        ORDER BY distance,p.id LIMIT 50`, [query.longitude, query.latitude, query.blood_type, user.id, user.country, stamp(), query.radius_km * 1000]);
      return { items: rows.map(row => ({ id: row.id, display_name: row.display_name, blood_type: row.blood_type, city: row.city,
        distance_band: `Within ${Math.min(39, Math.max(5, Math.ceil(row.distance / 5) * 5))} km`, map_area: coarseMapArea(row.latitude, row.longitude) })) };
    });
  });

  app.put(`${prefix}/me/photo`, { preHandler: authenticate, bodyLimit: 5 * 1024 * 1024 }, async request => {
    if (!['image/jpeg', 'image/png'].includes(request.headers['content-type']?.split(';')[0])) throw new HttpError(415, 'Upload a JPEG or PNG photo');
    await throttle(`photo:${request.user.id}`, 10, 3600);
    const jpeg = await sanitizeImage(request.body, 512);
    return store.transaction(request.user.country, async db => {
      await assertAccount(db, request.user);
      await db.run('INSERT INTO profile_photos(user_id,jpeg,updated_at) VALUES($1,$2,$3) ON CONFLICT(user_id) DO UPDATE SET jpeg=EXCLUDED.jpeg,updated_at=EXCLUDED.updated_at', [request.user.id, jpeg, stamp()]);
      return { has_photo: true };
    });
  });
  app.delete(`${prefix}/me/photo`, { preHandler: authenticate }, request => store.transaction(request.user.country, async db => {
    await assertAccount(db, request.user);
    await db.run('DELETE FROM profile_photos WHERE user_id=$1', [request.user.id]);
    return { has_photo: false };
  }));
  // Peer photo access is a current accepted-match permission, not a permanent URL grant.
  // Return the same unavailable response for absent photos and unauthorized peers.
  app.get(`${prefix}/profiles/:uid/photo`, { preHandler: authenticate }, async (request, reply) => {
    const jpeg = await store.transaction(request.user.country, async db => {
      const uid = request.params.uid, user = request.user;
      await ctx.expireRequests(db, user.country);
      if (uid !== user.id && (!await db.one("SELECT 1 FROM donation_requests WHERE status='accepted' AND ((requester_id=$1 AND accepted_donor_id=$2) OR (requester_id=$2 AND accepted_donor_id=$1))", [uid, user.id]) || await relationshipBlocked(db, uid, user.id))) throw new HttpError(404, 'Photo not available');
      const row = await db.one('SELECT jpeg FROM profile_photos WHERE user_id=$1', [uid]);
      if (!row) throw new HttpError(404, 'Photo not available');
      return row.jpeg;
    });
    return reply.type('image/jpeg').send(jpeg);
  });
}
