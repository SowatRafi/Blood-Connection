# Security policy

An initiative by Bindubashini Boys’ 2015 & Friends.

This policy defines review scope and required properties. It does not certify that every property is implemented or authorize testing, disclosure, configuration changes or access to another system. Code, configuration and reproducible evidence must establish whether a control holds.

## System and scope

Blood Connection coordinates blood donors and seekers through Flutter mobile clients, a JavaScript/Fastify API and a PostgreSQL/PostGIS database. Administrators also have a browser moderation console. Review the first-party application, native bridges, server, SQL, provider adapters, imports, deployment examples, build configuration, dependency integration and CI in this repository.

The checked-in local deployment binds API/database/provider ports to loopback and uses explicitly public demo fixtures. Real sign-in and production infrastructure are not configured by those examples. Review supported non-demo API behavior as a potentially network-facing surface; absence of a deployed service is not evidence that a source-level boundary failure is safe.

The database contains a shared registry and logical country schemas. The API runtime can access the schemas needed for its workflows. They are not independent databases, geographic residency guarantees or an authorization boundary by themselves. Ordinary members, matched counterparts and administrators have different application permissions; administrators currently have global moderation authority rather than country-assigned roles.

Architecture and operational context: [architecture](docs/ARCHITECTURE.md), [API contract](docs/API.md), [privacy inventory](docs/PRIVACY.md), [operations](docs/OPERATIONS.md) and [delivery limitations](docs/DELIVERY.md).

## Threat model and trust boundaries

Important assets include social identity/session credentials, exact location, blood group and body measurements, donation history, private photos, messages, meeting points, report evidence and internal moderation notes, push endpoints, media credentials, bans and audit history.

Review unauthenticated callers, malicious authenticated members, abusive matched counterparts, account changes on a shared device and moderator actions constrained by the moderation rules. A member may call the API directly and choose request fields, identifiers, country hints, uploaded images, message content and push registration inputs. A notification or external navigation target is not proof of access. Browser-only UI restrictions and request headers do not establish native-app identity.

The configured identity service establishes social account identity; provider metadata, backend configuration and server-owned role assignment must not be interchangeable with member-editable profile fields. External service responses and device callbacks cross trust boundaries even when a provider is configured by an operator. Treat secrets and database/migration privileges as separate from public client configuration.

Inspect ownership and authority after parsing, lookup, travel, retries and lifecycle transitions, at the operation that consumes them. A user interface hiding a capability, a UUID being difficult to guess, or a country having a separate schema is insufficient enforcement.

## Security invariants

- Protected reads and mutations require current server-validated identity and object authorization. Members cannot assign roles, bypass a ban/deletion or acquire another account's state by changing country, identity fields or identifiers. Historical-country report/event access must retain ownership checks.
- Discovery exposes only the approved coarse donor projection and enforces the 39 km maximum. It must not return precise donor coordinates, contact information, body measurements, private photographs or unrelated history. Assess inference across repeated searches separately from direct field disclosure.
- A profile photo is accessible to its owner or a currently authorized accepted counterpart. Meeting coordinates are an explicitly shared request destination, not another member's live position. Revocation, blocking, travel and request closure must be checked at relevant access boundaries.
- Donation eligibility respects voluntary availability, active-account state, blocks and the minimum three-calendar-month pause. Either accepted participant may confirm a completed donation, but concurrent confirmations/retries must record the actual donor once and cannot shorten the pause or alter an unrelated member.
- Conversation content and call invitations belong to authorized participants. Media credentials are issued only after consent and are scoped to the authorized room/identity. Revocation must address active media as well as future token issuance; token expiry alone is not established-session termination.
- Reports and attached evidence are restricted to their reporter and authorized moderation access. Reporter responses must not reveal internal notes, audit records or captured conversation evidence. An accused administrator must not inspect or resolve their own allegation. A report alone must not impose a permanent ban; review, enforcement, audit and notification state must remain consistent under races and failures.
- Private content and session state must not cross account, background or disposal boundaries through stale asynchronous responses, image caches or retained widgets. Visual transitions must not extend private-content access or delay revocation. Notification previews remain generic; target identifiers require authenticated authorization when opened.
- Push registration preserves device ownership. Delivery rechecks applicable eligibility and uses the configured destination restrictions without credentials crossing redirects or unintended origins. Review network destinations at use, including parsed and resolved forms; an allowlist label alone is not proof against unintended network access.
- Untrusted bodies, query values, images and evidence are bounded and validated before sensitive use. SQL values are parameters, dynamic identifiers come from validated country mappings, uploaded images are decoded with resource limits and rebuilt without metadata, and browser content is rendered without interpreting member text as markup.
- Country moves and global safety state must commit consistently. Serialization retries, idempotency keys and reservations must preserve participant identity and intended action. External side effects require recoverable coordination rather than assuming a transaction also controls an external provider.
- The API uses restricted runtime database credentials. Schema ownership/migrations and extension provisioning remain separate; application audit history is append-only to the runtime role. Imports and test resets must not overwrite interactive or production data.
- Public client configuration, source, errors, logs, build artifacts and notifications must not disclose privileged credentials, session tokens, private health/location data or report evidence. Demo credentials must remain limited to their documented loopback fixture environment.

Implementation anchors include `backend/src/auth.js`, `profiles.js`, `donations.js`, `safety.js`, `notifications.js`, `calls.js`, `integrations.js`, `store.js`, `backend/sql/`, `mobile/lib/api.dart`, `private_photo.dart`, `reports.dart`, `notifications.dart`, and `admin/private-evidence.mjs`. Existing backend/admin/mobile tests describe intended behavior; passing tests alone do not prove the invariants.

## Reportable findings and severity context

Report a source-backed path that lets an in-scope actor cross an intended boundary, disclose private data, change another person's safety state, impersonate or escalate authority, escape network/filesystem restrictions, or cause meaningful service/resource disruption. Establish controlled input, closest control, reachable sensitive operation, preconditions and consequence. Include material counterevidence and separate a demonstrated failure from a hypothesis.

Calibrate severity to realistic access, exposure, data sensitivity, affected people, persistence and recovery. Exact-location disclosure, private evidence exposure and incorrect donation/enforcement state can have consequences beyond a cosmetic application defect. Do not automatically suppress a finding because the affected route is authenticated, administrator-facing, optional, local by default or not yet deployed. Conversely, a configuration warning, dependency version or dangerous API name alone does not establish an exploitable path.

## Exclusions, accepted risk and unresolved decisions

No additional owner-confirmed finding exclusions, severity reductions or accepted risks are established by this policy. Generated code, dependencies, demo paths and tests can provide reachability or control evidence; their labels are not blanket suppression authority. Findings in a third-party component should be tied to the shipped dependency and relevant integration when claiming application impact.

Owner confirmation is still required for production ingress and hosting, regional residency, operational roles, retention periods, minimum age, privacy/appeals contacts, a private vulnerability-reporting channel and response commitments. These decisions remain unresolved. Record decision-critical uncertainty; do not infer that an unknown exposure is either public or safe. Do not put real donor data, secrets, private evidence or exploit details in public issue reports.

## Known limitations and operational requirements

Ordinary messages are stored server-side; this build does not claim end-to-end encrypted chat. Application fields are not individually encrypted, country schemas share storage, provider identities do not establish a unique human across accounts, and coarse location display does not eliminate inference. These are documented design limitations, not permission to ignore bypasses or new disclosure paths.

Hosted operation still requires verified TLS, protected secrets/storage/backups, administrator identity controls, monitoring, restoration and capacity testing, provider setup, and a defined retention/appeals process. Local checks do not establish those deployment controls. Apple-device, standalone watch/car support and clinical/regulatory readiness must follow the actual delivery documentation. The application cooldown and BMI do not establish clinical donation eligibility.
