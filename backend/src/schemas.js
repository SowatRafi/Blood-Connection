import { GROUPS } from './utils.js';

// Every body is allowlisted; clients cannot smuggle roles or moderation flags into profile writes.
const text = (minLength, maxLength) => ({ type: 'string', minLength, maxLength });
const number = (minimum, maximum) => ({ type: 'number', minimum, maximum });
const optional = schema => ({ anyOf: [schema, { type: 'null' }] });
const object = (properties, required = Object.keys(properties)) => ({ type: 'object', additionalProperties: false, properties, required });
const place = { country: text(2, 2), city: text(2, 80), latitude: number(-90, 90), longitude: number(-180, 180) };
const id = text(1, 80);
const key = optional(text(16, 128));
export const schemas = {
  profile: object({ display_name: text(2, 60), blood_type: { enum: [...GROUPS] }, height_cm: number(100, 250), weight_kg: number(30, 300), city: place.city, latitude: place.latitude, longitude: place.longitude, available: { type: 'boolean' } }),
  location: object({ ...place, mode: { enum: ['automatic', 'manual'] } }),
  travel: object({ ...place, consent: { const: true } }),
  request: object({ blood_type: { enum: [...GROUPS] }, radius_km: number(1, 39), destination_name: text(2, 160), destination_latitude: place.latitude, destination_longitude: place.longitude, donor_ids: optional({ type: 'array', items: id, minItems: 1, maxItems: 50 }) }, ['blood_type', 'radius_km', 'destination_name', 'destination_latitude', 'destination_longitude']),
  donation: object({ donated_at: { type: 'string', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, utc_offset_minutes: { type: 'integer', minimum: -720, maximum: 840 }, facility_name: text(2, 160), location_name: text(2, 160), country: text(2, 2), request_id: optional(id), idempotency_key: key }, ['donated_at', 'facility_name', 'location_name', 'country']),
  device: object({ provider: { enum: ['unifiedpush', 'apns'] }, token: text(10, 2048), pub_key: optional(text(1, 200)), auth: optional(text(1, 100)) }, ['provider', 'token']),
  deviceRemoval: object({ token: text(10, 2048) }),
  conversation: object({ donor_id: id }),
  message: object({ body: text(1, 2000) }),
  report: object({ conversation_id: optional(id), request_id: optional(id), idempotency_key: key, reason: { enum: ['money_request', 'harassment', 'misleading_information', 'no_show', 'other'] }, details: text(5, 2000) }, ['reason', 'details']),
  block: object({ user_id: id }),
  resolution: object({ decision: { enum: ['ban', 'dismiss'] }, note: text(5, 2000) }),
};
