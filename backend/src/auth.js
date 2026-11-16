import { HttpError } from './errors.js';
import { COUNTRIES, stamp } from './utils.js';

/** Keep role/provider checks on the server; user-editable profile metadata never authorizes access. */
export function authContext(store, settings) {
  const countryCode = value => {
    const code = String(value || '').toUpperCase();
    if (!Object.hasOwn(COUNTRIES, code)) throw new HttpError(400, 'Choose a valid ISO country');
    if (!settings.demo && !settings.countries.has(code)) throw new HttpError(409, 'Blood Connection is not available in this country yet');
    return code;
  };
  // Historical reports/events can belong to an earlier country after travel. This
  // validates the schema only; callers must still check the record's owner there.
  const storedCountry = async (value, user) => {
    const code = String(value || user.country).trim().toUpperCase();
    if (!Object.hasOwn(COUNTRIES, code) || !(await store.countries()).includes(code)) throw new HttpError(404, 'Saved country not found');
    return code;
  };
  // PostgreSQL makes limits consistent across workers, without requiring another infrastructure service.
  const throttle = async (key, count, seconds, connection = null) => {
    const work = async db => {
      const now = Date.now(), cutoff = now - seconds * 1000;
      const row = await db.one(`INSERT INTO rate_limits(key,window_start,count) VALUES($1,$2,1)
        ON CONFLICT(key) DO UPDATE SET window_start=CASE WHEN rate_limits.window_start<=$3 THEN $2 ELSE rate_limits.window_start END,
        count=CASE WHEN rate_limits.window_start<=$3 THEN 1 ELSE rate_limits.count+1 END RETURNING count`, [key, now, cutoff]);
      if (row.count > count) throw new HttpError(429, 'Please wait before trying again');
    };
    // Reuse a caller's connection to avoid a nested transaction holding conflicting
    // locks. In that case, the allowance is committed or rolled back with its action.
    return connection ? work(connection) : store.transaction(null, work);
  };
  const authenticate = async request => {
    if (request.user) return;
    const requested = String(request.headers['x-country'] || '').trim().toUpperCase();
    if (requested && !Object.hasOwn(COUNTRIES, requested)) throw new HttpError(400, 'Choose a valid ISO country');
    const authorization = request.headers.authorization || '';
    if (!authorization.startsWith('Bearer ') || authorization.length > 8192) throw new HttpError(401, 'Sign in to continue');
    const token = authorization.slice(7);
    let uid, displayName = 'New member';
    if (settings.demo) {
      uid = new Map([['demo-donor', 'donor'], ['demo-seeker', 'seeker'], ['demo-admin', 'admin']]).get(token);
      if (!uid) throw new HttpError(401, 'Invalid local demo session');
    } else {
      if (!settings.supabaseUrl || !settings.supabaseKey) throw new HttpError(503, 'Sign-in service has not been configured');
      await throttle(`auth:${request.ip}`, 120, 60);
      let user;
      try {
        const response = await fetch(`${settings.supabaseUrl}/auth/v1/user`, { headers: { authorization: `Bearer ${token}`, apikey: settings.supabaseKey }, redirect: 'manual', signal: AbortSignal.timeout(8000) });
        if (response.status !== 200) throw new HttpError(401, 'Your session has expired. Please sign in again');
        user = await response.json();
      } catch (error) {
        if (error instanceof HttpError) throw error;
        throw new HttpError(503, 'Sign-in service is temporarily unavailable');
      }
      if (!['google', 'apple', 'facebook'].includes(user.app_metadata?.provider) || typeof user.id !== 'string' || !user.id || user.id.length > 128) throw new HttpError(403, 'Use Google, Apple or Facebook to sign in');
      uid = user.id; displayName = String(user.user_metadata?.full_name || 'New member').slice(0, 60);
    }
    request.user = await store.transaction(null, async db => {
      let account = await db.one('SELECT * FROM accounts WHERE id=$1 FOR UPDATE', [uid]);
      const role = settings.demo && account ? account.role : settings.admins.has(uid) ? 'admin' : 'member';
      if (account?.banned || account?.deleted) throw new HttpError(403, account.banned ? 'This account has been permanently banned' : 'This account has been deleted');
      // Browser headers support the admin-only website policy, but are not proof
      // of a native app. Resource ownership and admin roles are enforced separately.
      if ((Object.hasOwn(request.headers, 'origin') || Object.keys(request.headers).some(k => k.startsWith('sec-fetch-'))) && role !== 'admin') throw new HttpError(403, 'This website is for administrators. Please use the mobile app');
      if (!account) {
        const code = requested || (role === 'admin' ? settings.demo ? 'BD' : [...settings.countries].sort()[0] : '');
        if (!code) throw new HttpError(409, 'Location required: choose or detect your country first');
        countryCode(code); await store.ensureRegion(code);
        await db.run('INSERT INTO accounts(id,country,role,created_at) VALUES($1,$2,$3,$4)', [uid, code, role, stamp()]);
        await db.run(`INSERT INTO ${db.schema(code)}.profiles(id,display_name) VALUES($1,$2)`, [uid, displayName]);
        account = await db.one('SELECT * FROM accounts WHERE id=$1', [uid]);
      }
      if (!settings.demo && account.role !== role) await db.run('UPDATE accounts SET role=$1 WHERE id=$2', [role, uid]);
      const path = request.url.split('?')[0];
      // Recovery reads and location updates use the saved country, so a new GPS
      // country header cannot prevent a traveler from completing the actual move.
      const code = (request.method === 'GET' && path === '/api/v1/me') || path === '/api/v1/location' ? account.country : countryCode(requested || account.country);
      if (account.country !== code && !(role === 'admin' && path.startsWith('/api/v1/admin/'))) throw new HttpError(409, `Your active country is ${account.country}. Use travel to change it`);
      return { id: uid, country: code, role };
    });
  };
  const administrator = async request => {
    await authenticate(request);
    if (request.user.role !== 'admin') throw new HttpError(403, 'Administrator access required');
  };
  return { authenticate, administrator, throttle, countryCode, storedCountry };
}
