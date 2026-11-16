# Private background notifications

**An initiative by Bindubashini Boys’ 2015 & Friends**

Request creation, acceptance, closing and report review produce a durable authenticated inbox and a per-device delivery queue in the same transaction. The worker checks authorization again before sending. Donation alerts follow request state, applicable donor availability/cooldown, current country and relationship rules. Report-review alerts follow a different rule: only the report's submitter receives the outcome alert, even after travel, opting out of donation, entering cooldown or blocking the accused. Banned/deleted recipients remain excluded. Retries are bounded; no unconfigured service is reported as delivered. The authenticated inbox and report detail remain the source of truth.

The backend is JavaScript on Node.js 24 LTS with Fastify. A shared PostgreSQL database holds country-specific inbox/outbox tables in separate schemas and private device registrations in the registry schema. These boundaries keep review, ban and notification state in one transaction; schemas do not establish physical country residency. `backend/src/notifications.js` implements the routes and delivery worker, while `backend/src/integrations.js` contains the provider adapters.

Each worker pass claims a pending outbox row with a two-minute lease, commits that claim, and performs network delivery outside the database transaction. Completion is checked against the same lease so a delayed worker cannot overwrite a newer attempt. A failed attempt uses bounded backoff, with at most twelve attempts; stale, unauthorized or expired donation events are suppressed. The server must keep this worker running and monitor pending/failed jobs. Serial database retries never repeat network delivery inside a transaction.

Both a ban and a dismissal create a `report_reviewed` event. Review status/time, enforcement, audit, event and delivery entries commit together; a repeated resolution cannot enqueue the outcome again. The internal reviewer note never becomes notification text or a reporter-visible explanation. The provider can still deliver a retried message more than once: clients deduplicate by `(country,event_id)`, rather than treating one durable queue entry as an exactly-once network guarantee.

## Android: open-source delivery

The app uses UnifiedPush with a distributor such as the open-source ntfy Android app. Unlike a timer in Blood Connection, the distributor can receive messages while Blood Connection is backgrounded or its process is absent. The distributor holds the connection; users may need its documented battery settings. A force-stopped app, denied notifications, offline device or restrictive battery policy can still prevent timely delivery.

From Profile, press **Enable notifications** after setting up the distributor, then **Open notification companion** once. On the tested Android version, the distributor could not start its foreground service until it had been opened; do not skip this step. Blood Connection registers the installation's endpoint and encryption public key with the authenticated backend. The server uses encrypted Web Push payloads; only a generic preview is displayed. The Android F-Droid ntfy variant does not require Firebase. Installation and configuration of that separate distributor is currently a prerequisite, not an invisible built-in service.

For local testing on the connected Pixel:

```powershell
docker compose -f infra/compose.local-push.yml up -d
adb reverse tcp:8090 tcp:8090
$env:PUSH_ALLOWED_ORIGINS='http://127.0.0.1:8090'
```

Restart the demo API after setting this environment variable, or run `./tools/start-local.ps1 -Calls -Push` for both local services. In ntfy Settings → Default server, set `http://127.0.0.1:8090`; then enable notifications in Blood Connection. The local relay is deliberately bound to loopback. This configuration depends on USB forwarding and is not a public production service. The test distributor used here is the official ntfy F-Droid release 1.25.2, with the downloaded APK checked against GitHub's published SHA-256 digest.

Production requires a reachable HTTPS distributor, explicit `PUSH_ALLOWED_ORIGINS`, appropriate access/rate controls and monitoring. Endpoint registration rejects arbitrary origins; sends do not follow redirects. Never expose the local open relay configuration publicly. Consult the [UnifiedPush Android connector](https://pub.dev/packages/unifiedpush_android) and [ntfy Android setup](https://docs.ntfy.sh/subscribe/phone/).

The JavaScript adapter uses `web-push` for RFC 8291 `aes128gcm` encryption and Node's native `fetch` for bounded, non-redirecting delivery. Registration checks the actual P-256 public point and sixteen-byte auth secret. An account may register at most five devices; an endpoint cannot silently transfer to a different account. The opaque payload format remains compatible with the existing Android receiver.

## Apple: native APNs

The iOS app registers directly with APNs through a small native bridge; it does not add Firebase. Configure Push Notifications capability and provisioning in Xcode. The included entitlements select development for Debug and production for Release/Profile. The backend needs `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, and the matching `APNS_SANDBOX` setting. Keep signing keys outside Git.

The provider adapter uses Node's native HTTP/2 client and `jose` ES256 signatures. Provider tokens are reused for twenty minutes from issuance, including concurrent sends. Requests have a bounded timeout and response size; invalid device responses remove the old registration, while transport failures remain retryable. [Apple provider-token guidance](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)

APNs carries an alert, so presentation does not depend on a periodic background Dart task. The native bridge preserves the typed request or report target for authenticated navigation. Notification taps and the safe **Open on phone** action open the corresponding app flow; a report target includes its original country. Apple's signing, delivery network and distribution program are platform dependencies; they cannot be made self-hosted. This Windows workspace cannot compile or verify real iOS/APNs delivery. Adapter/bridge source and tests are not device-delivery proof. See [Apple APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns).

## Targets and travel

External delivery contains one of these routing payloads:

```json
{"event_id":"17","kind":"donation_request","country":"BD","request_id":"opaque-request-id"}
```

```json
{"event_id":"18","kind":"report_reviewed","country":"BD","report_id":"opaque-report-id","report_country":"BD"}
```

Report payloads omit `request_id`; a report is never represented by a fabricated donation link. `country` identifies the event's regional ID namespace, while `report_country` identifies the stored report. Neither identifies the recipient's current location. APNs adds a generic alert, sound and the `PRIVATE_UPDATE` category; Android decrypts the routing payload and displays a generic preview. Names, report reasons, outcomes and evidence are fetched only through authenticated APIs; internal review notes stay outside the reporter's view.

`GET /events` returns the latest 100 eligible events across stored regions. Report outcomes remain visible when the reporter moves again after resolution. Each inbox item carries its `country`; use it in `POST /events/{id}/read?country=BD`, and use `report_country` for `GET /reports/{report_id}?country=BD`. Keep the active profile country in `X-Country`. Explicit `after` cursors apply to one country only, not the combined inbox; see [API cursor semantics](API.md). Historical reviews are not given invented timestamps or retroactive notification events during migration.

## Privacy and lifecycle

- Payloads contain opaque request/report/event identifiers, their routing countries and generic preview text. Personalized names, thanks and review outcomes are fetched inside the app.
- Photos, coordinates, blood type, BMI and chat content never go into a notification payload.
- Enabling alerts is optional after registration. Disabling or signing out removes local alerts and attempts to revoke the server device registration; Android also unregisters the distributor instance.
- Failed remote revocation during an outage does not expose account details: local ownership rejects stale Android delivery, and Apple remote registration is stopped. No provider can retract a notification already delivered before revocation.
- Paired watch behavior is documented in [platform coverage](PLATFORMS.md). Notification mirroring is not a standalone watch application.

These alerts cover the donation-request lifecycle and reviews of reports submitted by the member. Messaging polling and live incoming-call UI are separate features; this delivery does not claim production VoIP PushKit/CallKit incoming-call delivery while terminated.

## Verification

Run `npm --prefix backend test` for private projection, request races, expiry, delivery suppression, device ownership, review rollback/concurrency and delivery after travel/block/cooldown. Provider tests decrypt actual encrypted bytes and verify JWT signatures while mocking network transports; APNs tests do not contact Apple's delivery network. Flutter tests cover payload validation and safe presentation configuration.

For a real local relay check, use Node 24 with the backend development dependencies installed:

```powershell
. ./tools/use-node.ps1
docker compose -f infra/compose.local-database.yml up -d --wait
docker compose -f infra/compose.local-push.yml up -d
node backend/scripts/check-push.js
```

This command resets only the dedicated `blood_connection_test` database through the guarded test helper, uses fictional accounts and a random ntfy topic, then retrieves and decrypts real request and cross-travel/cooldown report-review deliveries. Do not run it concurrently with the backend test suite. `TEST_DATABASE_URL` and `TEST_MIGRATION_DATABASE_URL` may select another matching database whose name ends in `_test`; the helper rejects non-test names. It does not touch the interactive `blood_connection` database, register a phone, or claim operating-system background delivery. The relay retains encrypted test messages according to its cache policy.

Record actual relay and physical background-delivery results in [delivery notes](DELIVERY.md). A successful unit or relay test alone is not proof of remote device delivery.

On 16 November 2026 the JavaScript relay diagnostic passed both request delivery and report-review delivery after travel and cooldown through the real local ntfy service. The verification retrieved encrypted bytes and independently decrypted the expected opaque fields. Local evidence: `artifacts/javascript-relay-check.log`.
