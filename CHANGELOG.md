# Changelog

An initiative by Bindubashini Boys’ 2015 & Friends.

## Unreleased

### JavaScript and PostgreSQL migration — 2026-11-16

- Replaced the Python/FastAPI API with JavaScript on Node.js 24 LTS and Fastify while preserving the mobile/admin contract.
- Replaced SQLite runtime storage with PostgreSQL 18 and PostGIS 3.7, separate country schemas, restricted runtime credentials, serializable transactions and database-enforced match reservations.
- Added an offline importer with read-only SQLite backups; copied all 78 existing local records without overwriting the original files.
- Ported authorization, donation requests/history, private photos and evidence, report outcomes, encrypted notifications and calls, with developer-facing purpose comments and 60 backend tests.
- Switched development tools and GitHub checks to the JavaScript backend; retained historical validation below as a record of the original baseline.

### Initial development baseline — 2026-11-16

- Flutter mobile app and separate mobile/browser administrator interfaces, backed by a local FastAPI service.
- Private donor discovery, full-screen filtered map, donor availability and donation cooldown/history, request matching, in-app communication and navigation handoff.
- Participant reports with private evidence, administrator review, owner-visible status and review notifications.
- Automatic/manual location, country routing, metric/imperial profile measurements, private photos and the user-selected handshake blood-drop logo.
- Backend/admin/mobile tests, GitHub Actions checks, platform assets, font notices and setup, privacy, API, operations and design documentation.

This is the first committed snapshot of work developed locally; individual earlier changes have no separate Git history. Local validation passed 137 tests plus Flutter analysis. Android was built and installed on the Pixel 6. Real sign-in accounts, production infrastructure, Apple-device verification and other launch work remain outstanding; see [delivery status](docs/DELIVERY.md). GitHub Actions runs are the authority for remote CI results.
