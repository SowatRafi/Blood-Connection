import { randomUUID } from 'node:crypto';
export { COUNTRIES } from './countries.js';

export const GROUPS = new Set(['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']);
export const stamp = () => new Date().toISOString();
export const newId = () => randomUUID();

/** Clamp the day at month-end: the requested pause is three calendar months, not 90 days. */
export function addThreeMonths(value) {
  const [year, month, day] = String(value).slice(0, 10).split('-').map(Number);
  const end = new Date(0);
  end.setUTCFullYear(year, month + 3, 0);
  end.setUTCDate(Math.min(day, end.getUTCDate()));
  return end.toISOString().slice(0, 10);
}

/** Legacy dates retain UTC midnight; new entries store an exact UTC deadline. */
export function cooldownDeadline(account) {
  return account.eligible_after_utc || (account.eligible_after ? `${account.eligible_after}T00:00:00.000Z` : null);
}

/** Derive availability at read time so no scheduler can accidentally shorten a donation pause. */
export function available(account) {
  if (!account || account.banned || account.deleted || !account.available) return false;
  const deadline = cooldownDeadline(account);
  return !deadline || Date.parse(deadline) <= Date.now();
}

/** Haversine is also used to enforce that a search begins near the member's saved location. */
export function kmBetween(lat1, lon1, lat2, lon2) {
  const rad = Math.PI / 180;
  const a = Math.sin((lat2 - lat1) * rad / 2) ** 2
    + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin((lon2 - lon1) * rad / 2) ** 2;
  return 6371.0088 * 2 * Math.asin(Math.sqrt(Math.min(1, Math.max(0, a))));
}

/** Stable coarse areas preserve the existing map contract without exposing donor coordinates. */
export function coarseMapArea(latitude, longitude) {
  const mod = (n, d) => ((n % d) + d) % d;
  const row = Math.min(3599, Math.max(0, Math.floor((latitude + 90) * 20)));
  if (row === 0 || row === 3599) return { id: `area-v1-${row}-0`, latitude: row === 0 ? -90 : 90, longitude: 0 };
  const south = row / 20 - 90, north = (row + 1) / 20 - 90;
  const circumference = 2 * Math.PI * 6371.0088 * Math.cos(Math.max(Math.abs(south), Math.abs(north)) * Math.PI / 180);
  const columns = Math.max(1, Math.floor(circumference / 5.1)), width = 360 / columns;
  const column = Math.min(columns - 1, Math.floor(mod(mod(longitude + 180, 360) + width / 2, 360) / width));
  return { id: `area-v1-${row}-${column}`, latitude: Number(((south + north) / 2).toFixed(6)), longitude: Number((mod(column * width, 360) - 180).toFixed(6)) };
}
