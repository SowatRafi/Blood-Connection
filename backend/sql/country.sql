-- __COUNTRY_SCHEMA__ is replaced only after ISO-code validation, never with raw request text.
-- The runtime transaction selects one country with SET LOCAL; the shared registry
-- retains global bans, cooldowns and account identity across travel.
CREATE SCHEMA IF NOT EXISTS __COUNTRY_SCHEMA__;
SET LOCAL search_path = __COUNTRY_SCHEMA__, registry, public;
CREATE TABLE IF NOT EXISTS profiles (
 id TEXT PRIMARY KEY REFERENCES registry.accounts(id), display_name TEXT NOT NULL,
 blood_type TEXT CHECK(blood_type IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
 height_cm DOUBLE PRECISION CHECK(height_cm BETWEEN 100 AND 250),
 weight_kg DOUBLE PRECISION CHECK(weight_kg BETWEEN 30 AND 300),
 city TEXT NOT NULL DEFAULT '', latitude DOUBLE PRECISION CHECK(latitude BETWEEN -90 AND 90),
 longitude DOUBLE PRECISION CHECK(longitude BETWEEN -180 AND 180),
 -- Derive the indexed point from the saved coordinates so search cannot drift from profile edits.
 location public.geography(Point,4326) GENERATED ALWAYS AS (
  CASE WHEN latitude IS NULL OR longitude IS NULL THEN NULL
   ELSE public.ST_SetSRID(public.ST_MakePoint(longitude,latitude),4326)::public.geography END
 ) STORED
);
CREATE INDEX IF NOT EXISTS profile_location ON profiles USING gist(location);
-- Writers sort the two user IDs before insertion so the pair has one canonical row.
CREATE TABLE IF NOT EXISTS conversations (
 id TEXT PRIMARY KEY, user_a TEXT NOT NULL REFERENCES registry.accounts(id),
 user_b TEXT NOT NULL REFERENCES registry.accounts(id), updated_at TEXT NOT NULL,
 UNIQUE(user_a,user_b), CHECK(user_a<>user_b)
);
CREATE TABLE IF NOT EXISTS messages (
 id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
 sender_id TEXT NOT NULL REFERENCES registry.accounts(id), body TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id,created_at);
-- Evidence is a bounded JSON snapshot captured when the report is submitted.
-- Later conversation edits/erasure do not silently change the reviewed snapshot.
CREATE TABLE IF NOT EXISTS reports (
 id TEXT PRIMARY KEY, reporter_id TEXT NOT NULL REFERENCES registry.accounts(id),
 reported_id TEXT NOT NULL REFERENCES registry.accounts(id),
 conversation_id TEXT NOT NULL REFERENCES conversations(id), reason TEXT NOT NULL, details TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','banned','dismissed')),
 evidence TEXT NOT NULL, created_at TEXT NOT NULL, request_id TEXT, idempotency_key TEXT, reviewed_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS report_intent_once ON reports(reporter_id,idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS report_owner_history ON reports(reporter_id,created_at);
-- Store sanitized JPEG bytes privately; the original-input digest makes retries
-- idempotent without preserving the original upload or exposing a public file URL.
CREATE TABLE IF NOT EXISTS report_attachments (
 id TEXT PRIMARY KEY, report_id TEXT NOT NULL REFERENCES reports(id), jpeg BYTEA NOT NULL,
 source_digest TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(report_id,source_digest)
);
CREATE TABLE IF NOT EXISTS calls (
 id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
 caller_id TEXT NOT NULL REFERENCES registry.accounts(id), callee_id TEXT NOT NULL REFERENCES registry.accounts(id),
 status TEXT NOT NULL CHECK(status IN ('ringing','accepted','ended')),
 created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS profile_photos (
 user_id TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE, jpeg BYTEA NOT NULL, updated_at TEXT NOT NULL
);
-- Requests belong to the country where matching occurred; they do not travel with
-- profiles. Accepted matches also reserve both people in the global registry.
CREATE TABLE IF NOT EXISTS donation_requests (
 id TEXT PRIMARY KEY, requester_id TEXT NOT NULL REFERENCES registry.accounts(id),
 blood_type TEXT NOT NULL CHECK(blood_type IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
 radius_km DOUBLE PRECISION NOT NULL CHECK(radius_km BETWEEN 1 AND 39),
 destination_name TEXT NOT NULL, destination_latitude DOUBLE PRECISION NOT NULL CHECK(destination_latitude BETWEEN -90 AND 90),
 destination_longitude DOUBLE PRECISION NOT NULL CHECK(destination_longitude BETWEEN -180 AND 180),
 status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','accepted','cancelled','completed','expired')),
 accepted_donor_id TEXT REFERENCES registry.accounts(id), conversation_id TEXT REFERENCES conversations(id),
 created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS one_active_request ON donation_requests(requester_id) WHERE status IN ('open','accepted');
CREATE TABLE IF NOT EXISTS request_invitations (
 request_id TEXT NOT NULL REFERENCES donation_requests(id), donor_id TEXT NOT NULL REFERENCES registry.accounts(id),
 status TEXT NOT NULL DEFAULT 'invited' CHECK(status IN ('invited','accepted','declined','closed')),
 PRIMARY KEY(request_id,donor_id)
);
-- Event IDs are local to this schema. Clients must retain the country with a cursor
-- or event reference; identical numeric IDs in different countries are unrelated.
CREATE TABLE IF NOT EXISTS events (
 id INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
 user_id TEXT NOT NULL REFERENCES registry.accounts(id), kind TEXT NOT NULL, title TEXT NOT NULL,
 body TEXT NOT NULL, request_id TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL,
 read INTEGER NOT NULL DEFAULT 0 CHECK(read IN (0,1)), report_id TEXT, report_country TEXT
);
CREATE INDEX IF NOT EXISTS event_inbox ON events(user_id,id);
CREATE UNIQUE INDEX IF NOT EXISTS report_review_event_once ON events(user_id,report_id) WHERE kind='report_reviewed' AND report_id IS NOT NULL;
-- One job per event/device is inserted with its inbox event. next_attempt doubles
-- as a short worker lease; network delivery happens only after that lease commits.
CREATE TABLE IF NOT EXISTS push_outbox (
 event_id INTEGER NOT NULL REFERENCES events(id), device_id TEXT NOT NULL REFERENCES registry.devices(id) ON DELETE CASCADE,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','sent','suppressed','failed','invalid')),
 attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0), next_attempt TEXT NOT NULL,
 PRIMARY KEY(event_id,device_id)
);
CREATE INDEX IF NOT EXISTS pending_push ON push_outbox(next_attempt) WHERE status='pending';
