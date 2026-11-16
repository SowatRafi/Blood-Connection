# Blood Connection

**An initiative by Bindubashini Boys’ 2015 & Friends**

A privacy-focused blood donor and seeker application, with a separate moderation console. Flutter shares the Android and iOS application. JavaScript on Node.js 24 LTS and Fastify enforces matching, account safety and country routing; PostgreSQL with PostGIS stores the data. This repository is a local development build, not a deployed emergency service.

## Start locally on Windows

Prerequisites: Node.js 24 LTS, Docker with Compose, Flutter 3.44.2, Android SDK, and an Android phone with USB debugging enabled. From this repository:

```powershell
npm --prefix backend ci --ignore-scripts
./tools/start-local.ps1
```

Keep that terminal open. In another terminal:

```powershell
& "$env:LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe" reverse tcp:8000 tcp:8000
cd mobile
flutter pub get
flutter run --dart-define=DEMO_MODE=true --dart-define=API_URL=http://127.0.0.1:8000/api/v1
```

Open [the admin console](http://127.0.0.1:8000/admin/) on the computer. Local demo mode uses fictional records and separate donor, seeker, and administrator identities. It must remain bound to loopback. Normal builds do not expose demo sign-in.

To enable real local audio transport without a cloud account, follow [local calling setup](docs/LOCAL-CALLS.md). It runs a loopback-only LiveKit container and includes a synthetic two-participant media check.

## Product behavior

* Google, Apple, and Facebook are the only production sign-in providers. Their developer accounts and Supabase configuration are required before real sign-in can work.
* Donors and seekers use the same account. Matching uses an exact blood-group filter and a server-enforced maximum radius of 39 km. Medical staff must determine transfusion compatibility and donor eligibility.
* Search fills the screen with a pannable map, floating blood-group/range filters and a draggable donor-card sheet. Area markers group nearby volunteers using fixed coarse centers; tapping one opens its donors. Results show a display name, blood group, city and approximate distance band, never phone numbers, email, body measurements or precise donor coordinates.
* Height and weight are private profile fields; BMI is calculated for information only.
* A donation creates a three-calendar-month minimum app pause. Availability returns after that time only if the donor's voluntary availability preference is on. Turning it off remains respected.
* Automatic foreground location updates keep country and area aligned when travelling. A manual country/area choice resolves fresh coordinates together. A shared registry preserves cooldowns and bans. Each country uses its own schema in one PostgreSQL database, as selected for this version. This is logical separation, not separate country hosting or geographic data residency.
* Members use the mobile app only. Administrators can use the dedicated mobile workspace and admin website. See [location and access behavior](docs/LOCATION-AND-ACCESS.md).
* Photos are optional and private. Only an accepted request's matched pair can view each other's photo; discovery results never include photos. Requests invite nearby volunteers, accept one donor atomically and thank the other invited donors by name inside their private inbox.
* Accepted requests reveal an explicitly shared hospital/meeting point, a map and straight-line distance. **Go** opens Google Maps, Apple Maps or Waze for navigation.
* Conversations stay inside the app. Audio calling integrates with LiveKit when configured; there is no telephone dialing or disclosure. Donation-request alerts use encrypted UnifiedPush on Android and native APNs on Apple. See [notification setup](docs/NOTIFICATIONS.md); production incoming-call delivery remains separate.
* Phone layouts adapt to tablet side navigation and large text. Paired watches receive supported private notifications; car directions use the chosen navigation app. These are companion integrations, not standalone watch or car applications. See [platform coverage](docs/PLATFORMS.md).
* Members can block a conversation peer or report a money request. Administrators review evidence before confirming a permanent account ban. A report alone never bans someone.

## Repository guide

| Path | Responsibility |
| --- | --- |
| `mobile/` | Flutter app, Android/iOS settings, UI tests |
| `backend/` | API, storage, authentication, authorization, tests |
| `admin/` | Separate browser-based moderation app |
| `docs/API.md` | Client/server interface contract |
| `docs/ARCHITECTURE.md` | Data boundaries, decisions, known limits |
| `docs/OPERATIONS.md` | Setup, provider configuration, release process |
| `docs/PRIVACY.md` | Data inventory and retention decisions |
| `docs/TESTING.md` | Reproducible tests and device checks |
| `docs/DELIVERY.md` | Verified build results and remaining launch work |
| `docs/LOCAL-CALLS.md` | Optional local media service and synthetic audio test |
| `docs/NOTIFICATIONS.md` | Open-source local push relay, Apple setup and delivery limits |
| `docs/PLATFORMS.md` | Phone/tablet, paired-watch and navigation handoff coverage |
| `docs/OPEN-SOURCE.md` | Dependency licenses, self-hosting and service boundaries |
| `design-system/MASTER.md` | UI decisions and accessibility rules |
| `CONTRIBUTING.md` | Git branches, commits, review and publication checks |
| `docs/FEATURE-HISTORY.md` | Feature-to-code map and explicitly retrospective history provenance |
| `CHANGELOG.md` | Recorded development milestones and release status |

## Verification

```powershell
npm --prefix backend test
node --test admin/*.test.mjs
cd mobile
flutter analyze
flutter test
flutter build apk --debug --dart-define=DEMO_MODE=true
```

See the backend/admin READMEs if their test discovery paths differ. iOS builds require macOS, Xcode, and Apple signing credentials. Never distribute the demo APK as a production build.

Backend tests require the local database container (`docker compose -f infra/compose.local-database.yml up -d --wait`) and use only the dedicated `blood_connection_test` database. Existing SQLite data can be imported once with read-only backups; see [backend migration instructions](backend/README.md). The API runtime no longer uses Python or SQLite.

`tools/check.ps1` runs the component checks together. The GitHub Actions workflow repeats them on pushes and pull requests; it does not deploy or use production secrets. That workflow must run on GitHub after the project is pushed before its remote result can be claimed.

## Attribution and development

The project signature is **An initiative by Bindubashini Boys’ 2015 & Friends**. Do not add assistant or tool co-author trailers. Third-party packages retain their own licenses and notices. Product code includes purpose comments around functions and non-obvious decisions; generated platform files retain their upstream comments. Ruflo is used for local task coordination; its runtime state and personal configuration are excluded from source control.
