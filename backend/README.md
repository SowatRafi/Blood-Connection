# Blood Connection JavaScript API

An initiative by Bindubashini Boys’ 2015 & Friends.

The backend runs on **Node.js 24, Fastify and PostgreSQL 18 with PostGIS**. The mobile and admin clients retain the `/api/v1` contract. Fastify validates request schemas; parameterized PostgreSQL queries and server-side authorization protect the data boundary. Python, FastAPI and SQLite are no longer application runtime dependencies.

## Start a fresh local database

Install Node.js 24 and Docker, then run from the repository root:

```powershell
docker compose -f infra/compose.local-database.yml up -d --wait
cd backend
npm ci
$env:DEMO_MODE = '1'
$env:DATABASE_URL = 'postgresql://blood_connection_app:local-development-runtime-only@127.0.0.1:5436/blood_connection'
$env:MIGRATION_DATABASE_URL = 'postgresql://blood_connection_migrator:local-development-migration-only@127.0.0.1:5436/blood_connection'
npm run db:migrate
Remove-Item Env:MIGRATION_DATABASE_URL
npm start
```

The credentials above are deliberately public **local fixtures**. Compose binds PostgreSQL to `127.0.0.1:5436`; the API defaults to `127.0.0.1:8000`. Never reuse these credentials for hosted infrastructure. Override the Compose `BC_POSTGRES_PASSWORD`, `BC_MIGRATION_PASSWORD` and `BC_RUNTIME_PASSWORD` variables on first initialization if different local credentials are required; changing those variables does not rotate an already initialized database.

The administrator website is served at `/admin/` on the API origin. Connect the Pixel using `adb reverse tcp:8000 tcp:8000`. Demo mode checks both listener configuration and request address/Host; it must remain local. Public `demo-seeker`, `demo-donor` and `demo-admin` bearer tokens are fictional development fixtures. Production builds and services must disable demo mode.

`npm run db:migrate` creates the country schemas and seeds fictional accounts only in explicit demo mode. It provisions all ISO countries for a local demo unless `ENABLED_COUNTRIES` narrows the list. Production requires an explicit list. Runtime startup never creates schemas and uses the restricted application role. Settings come from the process environment; `backend/.env.example` documents them and is not automatically loaded.

## Preserve an existing SQLite installation

Stop the old API first. Use an **empty PostgreSQL target**, and run the import instead of the fresh demo seeding command:

```powershell
# From backend/, with DATABASE_URL and MIGRATION_DATABASE_URL set as above.
npm run db:import -- data ../artifacts/sqlite-migration-backup
```

The importer accepts the committed SQLite baseline `4e90456`; older layouts must first be upgraded to that baseline. The one-time Node.js importer opens the old SQLite files read-only, creates consistent file backups, provisions PostgreSQL schemas, and imports inside a transaction. It refuses a target that already contains accounts, normalizes timestamp strings, restores event sequences, and preserves IDs, photos, report evidence and safety/history records. Stale delivery jobs pointing to removed devices may be excluded and are counted separately. The backup and old files remain local and ignored by Git. Do not erase them until migration verification and the retention plan are complete. The importer’s use of Node’s SQLite reader does not make SQLite part of the running API.

## Run checks

The test database is separate from the interactive demonstration:

```powershell
$env:TEST_DATABASE_URL = 'postgresql://blood_connection_app:local-development-runtime-only@127.0.0.1:5436/blood_connection_test'
$env:TEST_MIGRATION_DATABASE_URL = 'postgresql://blood_connection_migrator:local-development-migration-only@127.0.0.1:5436/blood_connection_test'
npm test
```

Tests run serially against PostgreSQL. Reset is guarded: both URLs must identify the same database with a name ending in `_test`. Never point tests at the interactive or production database. Coverage includes privacy authorization, country transfer rollback, concurrent matching and confirmation, report review/outbox atomicity, image handling, device delivery rules, and database privileges. See [delivery status](../docs/DELIVERY.md) for results actually obtained; test descriptions alone are not evidence of a successful run.

## Database boundaries

The user-approved local layout is **one database with isolated country schemas**. `registry` holds identity, current country, availability, cooldowns, donation history/confirmation receipts, blocks, bans, append-only audit, device registrations, active-match reservations, rate counters and durable cleanup jobs. `country_bd`, `country_au` and other provisioned schemas contain local profiles, private photos, conversations/messages, reports/evidence, donation requests, invitations, events and delivery outboxes.

These are logical boundaries on one PostgreSQL service. They are not separate country databases or proof of country-local hosting. Application authorization and explicit country routing remain mandatory; a single backend service has the privileges needed to coordinate its enabled schemas. Geographic residency or independent country databases require a separately designed deployment and cross-region coordination policy.

The application role has table/sequence access without schema creation or audit mutation privileges. The migration role owns application schema changes; neither local role is a PostgreSQL superuser or can create roles/databases. Extension installation and database provisioning belong to the administrator initialization step. Keep migration credentials out of the runtime process.

Domain transactions use `SERIALIZABLE` isolation with bounded retries for serialization/deadlock failures. All queries in a transaction share one connection. Travel moves profile/photo and global active-country state atomically. Unique constraints and participant reservations prevent two donors winning a request or one person joining concurrent matches in opposite roles. A report outcome, global ban, immutable audit record, reporter event and delivery entries commit together. External push/media requests occur outside retried database callbacks.

PostGIS stores a generated private `geography(Point,4326)` and GiST index for nearby searches. `ST_DWithin` enforces the radius in meters; donor responses still return only a display name, blood group, city, coarse area and distance band. Exact coordinates and health measurements never appear in donor results. PostgreSQL-backed rate counters apply across API workers.

## Authentication and privacy

Production tokens are verified with the configured Supabase `/auth/v1/user` endpoint. Only Google, Apple and Facebook provider identities are accepted. `ADMIN_USER_IDS` is server-owned; user profile metadata cannot grant a role. The public auth configuration rejects Supabase secret/service-role keys. Administrator MFA still requires deployment configuration and assurance-level enforcement before launch.

Members use mobile; administrators may use mobile and browser. Browser member requests are rejected when browser headers are present, but headers are not device attestation. Android Play Integrity and Apple App Attest are not implemented.

Photos and report evidence accept only bounded JPEG/PNG data. Sharp validates decoded dimensions/animation, applies orientation, resizes and writes metadata-free JPEGs. No public photo/evidence URLs exist; every read checks ownership or the current accepted counterpart. Reporters see safe review outcomes, not internal audit notes or conversation evidence snapshots. A report alone never bans someone; reviewed money-request findings can create a permanent global account ban.

Deletion first tombstones the identity and removes owned global data/devices, then scrubs regional profiles, photo/event data and ordinary message content through a durable retry job. Moderation evidence/audit and the enforcement tombstone remain under the documented retention policy. Upstream Supabase identity deletion is separate. Donation history is donor-owned; a matched seeker sees only the outcome for their request.

## Push and calling

Transactional event/outbox records support encrypted Android UnifiedPush and direct APNs HTTP/2 delivery. Push endpoint origins are allowlisted; URLs and encryption keys are validated, redirects are not followed, and private notification previews remain generic. Workers lease delivery jobs, recheck eligibility and retry failures. A provider success response is not proof of display on a physical device. Report-review alerts remain eligible after travel, voluntary donor opt-out and cooldown; banned/deleted users remain excluded.

LiveKit supplies audio transport. Tokens are short-lived, room-scoped and audio-only; callers receive them only after acceptance. End/block/ban/travel/deletion queue media cleanup. A self-hosted server can still accept an already issued token until expiry, and an outage can delay cleanup. Chat and incoming-call background delivery remain separate launch work. See [notifications](../docs/NOTIFICATIONS.md) and [local calling](../docs/LOCAL-CALLS.md).

## Production requirements

Use TLS for public API and remote database connections, encrypted disks/backups, unique managed credentials, explicit trusted origins, bounded connections/body sizes, monitored workers and tested restoration. PostgreSQL does not automatically encrypt application fields at rest; messages are not end-to-end encrypted. Do not log tokens, health details, private locations, messages or report evidence. Prepare real OAuth/media/push accounts and devices, administrator MFA, clinical guidance, country rollout, retention/appeals and incident procedures before a public launch.

See [API contract](../docs/API.md), [architecture](../docs/ARCHITECTURE.md), [operations](../docs/OPERATIONS.md) and [privacy](../docs/PRIVACY.md).
