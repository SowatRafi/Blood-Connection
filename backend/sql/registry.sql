-- The registry coordinates worldwide safety state; country data stays in separate schemas.
-- These are logical partitions in one PostgreSQL database, not country-local hosting.
CREATE SCHEMA IF NOT EXISTS registry;
SET LOCAL search_path = registry, public;
CREATE TABLE IF NOT EXISTS schema_migrations (
 scope TEXT PRIMARY KEY, version INTEGER NOT NULL, applied_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS accounts (
 id TEXT PRIMARY KEY, country TEXT NOT NULL CHECK(country ~ '^[A-Z]{2}$'),
 available INTEGER NOT NULL DEFAULT 0 CHECK(available IN (0,1)),
 eligible_after TEXT, eligible_after_utc TEXT,
 role TEXT NOT NULL DEFAULT 'member' CHECK(role IN ('member','admin')),
 banned INTEGER NOT NULL DEFAULT 0 CHECK(banned IN (0,1)),
 deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)), created_at TEXT NOT NULL,
 location_mode TEXT NOT NULL DEFAULT 'automatic' CHECK(location_mode IN ('automatic','manual'))
);
-- Global history and cooldown state follow the donor when the active profile moves.
-- Date-only donation days and canonical UTC timestamp strings preserve the mobile contract.
CREATE TABLE IF NOT EXISTS donations (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES accounts(id),
 donated_at TEXT NOT NULL, created_at TEXT NOT NULL, facility_name TEXT,
 location_name TEXT, country TEXT, request_id TEXT, idempotency_key TEXT,
 confirmed_by TEXT, confirmed_by_role TEXT CHECK(confirmed_by_role IN ('donor','seeker'))
);
-- Either matched participant may confirm; a shared request key records one donation,
-- while actor-scoped retry keys distinguish retried submissions from changed intent.
CREATE UNIQUE INDEX IF NOT EXISTS donation_request_once ON donations(request_id) WHERE request_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS donation_actor_intent_once ON donations(confirmed_by,idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS donation_owner_history ON donations(user_id,donated_at DESC,created_at DESC);
CREATE TABLE IF NOT EXISTS donation_confirmations (
 request_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES accounts(id),
 facility_name TEXT NOT NULL, location_name TEXT, country TEXT NOT NULL, created_at TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','recorded')),
 requester_id TEXT, donor_name TEXT,
 donor_dismissed INTEGER NOT NULL DEFAULT 0 CHECK(donor_dismissed IN (0,1)),
 seeker_dismissed INTEGER NOT NULL DEFAULT 0 CHECK(seeker_dismissed IN (0,1))
);
-- A block is stored once by its author; relationship checks apply it in both directions.
CREATE TABLE IF NOT EXISTS blocks (
 blocker TEXT NOT NULL REFERENCES accounts(id), blocked TEXT NOT NULL REFERENCES accounts(id),
 created_at TEXT NOT NULL, PRIMARY KEY(blocker,blocked), CHECK(blocker<>blocked)
);
CREATE TABLE IF NOT EXISTS audit (
 id TEXT PRIMARY KEY, actor_id TEXT NOT NULL, subject_id TEXT NOT NULL, action TEXT NOT NULL,
 country TEXT NOT NULL, report_id TEXT, note TEXT NOT NULL, created_at TEXT NOT NULL
);
-- Reject row mutations as well as revoking UPDATE/DELETE/TRUNCATE from the runtime role.
-- Database owners remain privileged; this is application-level append-only enforcement.
CREATE OR REPLACE FUNCTION registry.reject_audit_mutation() RETURNS trigger
 LANGUAGE plpgsql SET search_path=pg_catalog AS $$
 BEGIN RAISE EXCEPTION 'Audit records are append-only' USING ERRCODE='42501'; END;
$$;
DROP TRIGGER IF EXISTS audit_no_mutation ON audit;
CREATE TRIGGER audit_no_mutation BEFORE UPDATE OR DELETE ON audit
 FOR EACH ROW EXECUTE FUNCTION registry.reject_audit_mutation();
-- Durable jobs survive API restarts. External media revocation and regional erasure
-- finish after the transaction marks the call ended or tombstones the account.
CREATE TABLE IF NOT EXISTS media_cleanup (
 call_id TEXT PRIMARY KEY, caller_id TEXT NOT NULL, callee_id TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS deletion_jobs (user_id TEXT PRIMARY KEY, created_at TEXT NOT NULL);
-- Device tokens are private delivery endpoints. Token uniqueness lets registration
-- enforce one owner while explicitly rejecting cross-account reassignment.
CREATE TABLE IF NOT EXISTS devices (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES accounts(id), provider TEXT NOT NULL,
 token TEXT NOT NULL UNIQUE, pub_key TEXT, auth TEXT, created_at TEXT NOT NULL,
 CHECK(provider IN ('unifiedpush','apns'))
);
CREATE INDEX IF NOT EXISTS devices_owner ON devices(user_id);
CREATE TABLE IF NOT EXISTS active_matches (
 donor_id TEXT PRIMARY KEY REFERENCES accounts(id), requester_id TEXT NOT NULL UNIQUE REFERENCES accounts(id),
 request_id TEXT NOT NULL UNIQUE, country TEXT NOT NULL, CHECK(donor_id<>requester_id)
);
-- Two reservations enforce uniqueness across BOTH roles, unlike separate donor/requester indexes.
CREATE TABLE IF NOT EXISTS match_participants (
 user_id TEXT PRIMARY KEY REFERENCES accounts(id),
 request_id TEXT NOT NULL REFERENCES active_matches(request_id) ON DELETE CASCADE
);
CREATE OR REPLACE FUNCTION registry.reserve_match_participants() RETURNS trigger
 LANGUAGE plpgsql SET search_path=pg_catalog AS $$
 BEGIN
  -- Stable insertion order reduces conflicting lock orders when two matches race.
  INSERT INTO registry.match_participants(user_id,request_id)
   SELECT participant,NEW.request_id FROM unnest(ARRAY[NEW.donor_id,NEW.requester_id]) participant ORDER BY participant;
  RETURN NEW;
 END;
$$;
DROP TRIGGER IF EXISTS reserve_match_participants ON active_matches;
CREATE TRIGGER reserve_match_participants AFTER INSERT ON active_matches
 FOR EACH ROW EXECUTE FUNCTION registry.reserve_match_participants();
-- Replacing a participant must release the old reservations through DELETE first.
CREATE OR REPLACE FUNCTION registry.reject_match_reassignment() RETURNS trigger
 LANGUAGE plpgsql SET search_path=pg_catalog AS $$
 BEGIN RAISE EXCEPTION 'Close an active match before replacing it' USING ERRCODE='23514'; END;
$$;
DROP TRIGGER IF EXISTS no_match_reassignment ON active_matches;
CREATE TRIGGER no_match_reassignment BEFORE UPDATE ON active_matches
 FOR EACH ROW EXECUTE FUNCTION registry.reject_match_reassignment();
-- Rates are stored centrally so adding an API worker cannot bypass an account limit.
CREATE TABLE IF NOT EXISTS rate_limits (
 key TEXT PRIMARY KEY, window_start BIGINT NOT NULL, count INTEGER NOT NULL CHECK(count>=0)
);
