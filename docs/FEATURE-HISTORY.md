# Feature history and code guide

An initiative by Bindubashini Boys’ 2015 & Friends.

## Original history and retrospective assembly

`main` contains the authentic published history. Its initial commit captured an already-developed local application; earlier individual feature edits were not committed. Git cannot recover their exact order, dates, discarded designs or intermediate behavior. A larger commit count cannot restore that missing evidence.

At the user's request, [`codex/reconstructed-feature-history`](https://github.com/SowatRafi/Blood-Connection/commits/codex/reconstructed-feature-history) provides a separate, explicitly retrospective review history. It has an independent root and must not be merged into `main`. The original branch and commit IDs remain intact. The new comment improvements are offered separately on `codex/feature-comments-and-history` for normal pull-request review.

The reconstruction uses only these published checkpoints and the subsequent comment/documentation commits:

| Checkpoint | What it actually records |
| --- | --- |
| [`4e90456`](https://github.com/SowatRafi/Blood-Connection/commit/4e9045697acafbf4bf5ff577db2826fd234f9fab) | First published development baseline: Flutter, Python API, moderation, assets, tests and documentation |
| [`c78ac92`](https://github.com/SowatRafi/Blood-Connection/commit/c78ac92) | JavaScript/Fastify and PostgreSQL implementation added alongside the existing API |
| [`1dbbafd`](https://github.com/SowatRafi/Blood-Connection/commit/1dbbafdb4db1a6fbc75d7b0a4ad48362691bda79) | Runtime/tooling/CI cutover to JavaScript and removal of the Python API |
| `codex/feature-comments-and-history` | Actual new, feature-scoped comment changes and this documentation |

Every reconstructed commit changes real tracked files, uses the date of reconstruction, identifies its source commit, and carries a `reconstruction(scope):` subject. Whole files are grouped by responsibility; no original implementation sequence is invented. Shared files such as the old Python API and the mobile application shell already contained several features, so their historical internals are not artificially split into pretend standalone implementations.

Intermediate assembly commits may have unresolved imports or missing scaffolding. They are reading checkpoints, **not independently buildable or tested releases**. Checkpoint boundaries reproduce their source Git trees exactly; the final tree reproduces the comment/documentation branch snapshot identified in the final commit. This verifies file paths, modes and content, not just a visual diff. Later development may make the live branches diverge; compare the immutable source hash in the reconstruction commit.

From a checkout with both branches fetched, verify the final snapshot using the source hash from the last reconstruction commit:

```sh
git show -s --format=%B origin/codex/reconstructed-feature-history
git rev-parse SOURCE_COMMIT^{tree}
git rev-parse origin/codex/reconstructed-feature-history^{tree}
git diff --exit-code SOURCE_COMMIT origin/codex/reconstructed-feature-history
```

Replace `SOURCE_COMMIT` with the full `Source-commit` value printed by the first command. Matching tree IDs and an empty diff establish exact parity. No force-push, backdated author metadata, empty filler commits, device data or unpublished working files are needed for this reconstruction.

## Feature-to-code map

Paths below describe the current JavaScript-backed application. They identify where to read and extend accepted features, not when each individual edit originally happened. All mobile/admin features were present in the first published baseline; their server implementations were ported in the JavaScript checkpoint.

| Feature | Main implementation | Existing verification / guide |
| --- | --- | --- |
| Sign-in, account session and member/admin routing | `mobile/lib/main.dart`, `api.dart`; `backend/src/auth.js`, `app.js` | `mobile/test/widget_test.dart`; `backend/test/api.test.js`; [access guide](LOCATION-AND-ACCESS.md) |
| Automatic travel and manual area selection | `mobile/lib/location.dart`; `backend/src/profiles.js`, `countries.js` | `mobile/test/location_test.dart`; [access guide](LOCATION-AND-ACCESS.md) |
| Full-screen donor map, blood-group/radius filters and donor sheet | `mobile/lib/search.dart`; `backend/src/profiles.js`, `store.js` | `mobile/test/search_test.dart`; `backend/test/api.test.js` |
| Height/weight units and informational BMI | `mobile/lib/profile.dart`, `measurements.dart`; `backend/src/schemas.js` | `mobile/test/measurements_test.dart`, `profile_measurements_test.dart` |
| Private profile photographs | `mobile/lib/private_photo.dart`, `profile.dart`; `backend/src/profiles.js`, `integrations.js` | `backend/test/api.test.js`, `integrations.test.js`; [privacy](PRIVACY.md) |
| Request invitation, acceptance and meeting-point navigation | `mobile/lib/requests.dart`; `backend/src/donations.js` | `mobile/test/requests_test.dart`; `backend/test/donations.test.js` |
| Availability, three-calendar-month cooldown and either-party donation confirmation | `mobile/lib/donation_status.dart`, `donations.dart`; `backend/src/donations.js` | `mobile/test/donation_status_test.dart`, `donations_test.dart`, `donation_prompt_test.dart`; [donations](DONATIONS.md) |
| Donation history, hospital/blood-bank and location record | `mobile/lib/donations.dart`; `backend/src/donations.js` | `backend/test/donations.test.js`; [donations](DONATIONS.md) |
| Private messages, blocking and in-app audio calls | `mobile/lib/messaging.dart`; `backend/src/safety.js`, `calls.js`, `integrations.js` | `mobile/test/call_cleanup_test.dart`; `backend/test/calls.test.js`, `safety.test.js`; [local calls](LOCAL-CALLS.md) |
| Background notifications and notification taps | `mobile/lib/notifications.dart`; Android `MainActivity.kt`; iOS `AppDelegate.swift`, `SceneDelegate.swift`; `backend/src/notifications.js` | `mobile/test/notifications_test.dart`; `backend/test/notifications.test.js`; [notifications](NOTIFICATIONS.md) |
| Participant reporting, private evidence, review status and outcomes | `mobile/lib/reports.dart`; `backend/src/safety.js` | `mobile/test/reports_test.dart`, `report_status_test.dart`; `backend/test/safety.test.js` |
| Mobile and browser administration | `mobile/lib/admin.dart`; `admin/app.js`, `helpers.mjs`, `private-evidence.mjs` | `mobile/test/admin_test.dart`; `admin/*.test.mjs`; `admin/QA.md` |
| Approved handshake/drop logo, typography and reusable UI | `design-system/`; `mobile/lib/ui.dart`; platform image assets; `tools/generate_icons.py` | [design system](../design-system/MASTER.md); [brand source](../design-system/brand/README.md) |
| Responsive phones/tablets, watch notification mirroring and external car navigation | `mobile/lib/main.dart`, feature layouts and native project configuration | [platform coverage and limitations](PLATFORMS.md) |
| Country schemas, global cooldown/bans and concurrency controls | `backend/src/store.js`, `shared.js`; `backend/sql/`; `backend/scripts/migrate.js` | `backend/test/store.test.js`, `donations.test.js`; [architecture](ARCHITECTURE.md) |
| Offline SQLite import and local PostgreSQL setup | `backend/scripts/import-sqlite.js`; `infra/compose.local-database.yml`, `postgres-init.sh` | [backend setup and migration](../backend/README.md) |
| Repeatable local checks and CI | `tools/check.ps1`, `use-node.ps1`; `.github/workflows/checks.yml` | [testing](TESTING.md); [delivery status](DELIVERY.md) |

## Comment conventions

Comments explain purpose, contracts and decisions that are easy to break during maintenance. They belong next to the code they describe and must change when that behavior changes. The comment review covers first-party Dart, JavaScript, SQL, native notification bridges and local tooling; generated platform scaffolding retains its upstream documentation.

- Use Dartdoc/JSDoc for reusable interfaces. Describe units, ownership, return values and errors when they are not obvious from names and types.
- Explain consent and authorization at private-photo, evidence, location and session boundaries. Coarse discovery coordinates are different from private profile coordinates and explicitly shared meeting points.
- Explain stale-response guards, notification enrollment epochs, idempotency keys, transaction reservations and resource disposal where they prevent cross-account leaks or duplicate state transitions.
- Describe limits accurately: country schemas share one PostgreSQL database; channel headers are not native-app attestation; push can redeliver; call admission-token expiry does not end an established media session.
- Keep test names focused on observable behavior. Avoid line-by-line narration, duplicate prose, speculative guarantees and comments that conceal unfinished behavior.

Refer to [contributing](../CONTRIBUTING.md) for focused commits and review, and [delivery status](DELIVERY.md) for work still needed before a production release. A retrospective feature commit does not establish production readiness or platform certification.
