# Local delivery — 16 November 2026

**An initiative by Bindubashini Boys’ 2015 & Friends**

This is a working local development application with the final Android APK installed on the connected Pixel 6, mobile and browser admin interfaces, a persistent API, and local calling and push services. It is not a production worldwide deployment. Real social-provider accounts are not configured; clearly labelled development entries use fictional people.

## Implemented scope

| Capability | Local implementation |
| --- | --- |
| Members and administrators | Members use the mobile application; administrators have native and browser interfaces with server-enforced roles |
| Branding and layout | User-selected blood-drop handshake logo, full-colour Android adaptive icon, crimson/warm-white/teal palette, bundled Manrope typography, single community signature, adaptive phone/tablet navigation |
| Registration | Google/Apple/Facebook integration; necessary profile fields, metric/imperial measurement entry with account-scoped display preferences, server-calculated BMI, optional profile photo; no phone number |
| Location and travel | Permission-based native location and country/area resolution, foreground refresh, coherent manual override, separate country databases with shared safety state |
| Nearby donors | Full-screen pannable map, floating blood-group/radius filters, draggable donor-card sheet, stable approximate-area markers and server maximum 39 km |
| Availability | Compact Home switch/countdown, detailed settings sheet and private history; three-calendar-month recovery with month-end clamping and voluntary automatic return |
| Donation requests | Invitation, acceptance, decline, withdrawal, cancellation and completion; both matched participants can confirm, with one donor record/cooldown per request |
| Private photos | Upload, validation and metadata removal; photo access restricted to the owner and accepted counterpart, revoked when the match closes |
| Notifications | Encrypted UnifiedPush on Android, direct APNs integration for iOS, transactional event outbox; generic lock-screen text and personalized authenticated inbox messages |
| Meeting and navigation | Accepted-only meeting point/map, clearly labelled straight-line distance, external Google Maps/Apple Maps/Waze handoff |
| Communication | Authorized private conversations and LiveKit audio invitation/accept/end controls; no telephone-number disclosure |
| Community safety | Both matched parties can report from requests/chat, including after closure/block; private evidence, own report status/timeline and public outcome; review alerts across travel/offline/cooldown; admin evidence views, reviewed money-request lifetime bans, export/deletion |
| Companion devices | Safe phone-notification actions for watches and external navigation handoff for cars; no standalone watch or car application |
| Documentation | API, architecture, privacy, operations, testing, location, notifications, platforms and open-source dependencies |

Country-separated local files demonstrate routing; they do not establish physical data residency. The recovery period is an application policy and does not determine clinical eligibility. BMI is informational.

## Verification actually performed

The latest full `tools/check.ps1` run passed **50 backend tests, 7 admin/browser tests and 80 Flutter tests: 137 total**, recorded in `artifacts/review-polish-checks.log`. Flutter analysis found no issues; the existing Python environment previously passed `pip check`. Tests cover request races, photo authorization and revocation, country moves, cooldown boundaries, device ownership, push delivery, notification enrollment/sign-out races, administrator access, small-screen/large-text forms and tablet navigation. Map tests cover stable coarse areas, polar/date-line behavior, stale searches, radius confirmation, initial tile decoding, independent map/sheet gestures, immediate donor-card previews, visible zoom controls and unobstructed attribution. New tests check interruptible 280ms camera motion, reduced motion and preserving a user's pan after a delayed search. Unit conversion/Profile tests cover canonical precision, BMI, remembered preferences and travel-safe saving. A final two-decimal display refinement passed all four relevant measurement/Profile tests again before rebuilding (`artifacts/measurement-final-check.log`).

Report tests cover owner-only list/detail/evidence across travel, safe outcomes without internal notes, transactional review/event/outbox rollback and concurrent resolution, notification parsing/deferred navigation, large text, private image cleanup and report routing without mutating the active country. The encrypted local ntfy relay check also passed report-review delivery after country changes. Primary/muted text and crimson/teal button pairs measure at least 5.4:1 contrast against their intended surfaces; this is a light-theme implementation.

Donation tests additionally cover owner-only history across travel, legacy migrations, confirmation ownership, concurrent linked saves, idempotent manual retries, unchanged cooldown on No/Later, popup suppression within a session, return-to-availability preferences and large-text status/recording forms. Review caught and fixed a manual retry duplication gap and a history-loading race. The prior donation run is in `artifacts/donation-final-checks.log`; the prior shared-confirmation/evidence run is in `artifacts/shared-report-final-checks.log`. It also checks independent No answers, simultaneous opposite-party Yes, caller-only profile responses, cross-country confirmation, preservation of donor history after seeker deletion, attachment authorization/type/size/count, safe upload retries, private admin preview cleanup and report navigation/partial-save behavior. That earlier run contained 119 tests.

The final Android debug build succeeded and was installed on the physical Pixel 6. Physical-device checks included:

- Local entry, navigation, nearby donor search, profile/BMI saving and persistent messages.
- Gallery photo selection/upload; authenticated seeker photo access returned 404 before acceptance, 200 after acceptance, and 404 again after withdrawal.
- A real donation-request push through the local ntfy service while the app process was absent. Android started the headless receiver and displayed generic private-update text. Tapping the notification led to the request after local demo entry.
- Acceptance revealing the meeting map; the Go action opening the destination in Google Maps; withdrawal removing accepted details. Road navigation was not started.
- A personalized thank-you event naming another fictional invited donor after someone else accepted.
- Native geocoding resolving Sydney to Australia and saving the country move. The fictional fixture was then restored to Dhaka. Automatic GPS travel detection has automated coverage but was not physically exercised across countries.
- Native administrator entry showing country-scoped review and summary without member navigation.
- Full-screen search with real OSM tiles, floating filters and a shared O+ area bubble for two fictional donors. One-finger panning moves the map while controls remain fixed; marker selection opens its donor sheet. The earlier startup-timing fix remains in place: tiles load without a gesture. The correct one-recipient request form and the Profile's short signature were also verified in the preceding pass.
- The earlier helping-pair adaptive icon rendered centered and unclipped inside Android's native circular app-info mask. It has since been replaced by the interlocking-ribbon mark. At that stage the same vector supplied the in-app mark and generated platform icons; the subsequent selected illustration is described below. iOS rendering remains unverified on hardware.
- The final Pixel build shows a donor-card preview immediately, opens the matching sheet on marker tap, collapses by dragging without moving the map and keeps map credit clear of blood filters. Revised profile/location/photo labels were inspected on the device. Marker emphasis and sheet transitions are restrained; reduced motion is covered by widget tests rather than a change to the owner's device settings.

- The donation pass verified Available and Offline states, a donor popup after the seeker completed a fictional accepted request, recording through the native form, and the resulting cooldown countdown plus private history. The November 15, 2026 demo entry contains “Demo Blood Bank”, Dhaka, BD; its pause ends February 15, 2027. The seeker received no access to that history, and the pending reminder cleared only after save. The Pixel is left on fictional donor Nadia’s cooldown status. Screenshots: `artifacts/pixel-donation-prompt.png`, `artifacts/pixel-donation-status.png`, `artifacts/pixel-donation-history.png`.

- The latest Pixel build shows the compact cooldown row with Find a blood donor visible on Home, and its donation settings sheet. In a new fictional B+ request, Nadia acted as seeker and Rafi as donor. The seeker-facing popup named Rafi and explicitly described which account would pause. Saving produced one Rafi history entry marked confirmed by seeker; the completed request displayed that outcome and exposed Report this match. A Something else report was submitted through the native form. Evidence screenshot: `artifacts/pixel-shared-prompt.png`, `artifacts/pixel-compact-home.png`, `artifacts/pixel-report-form.png`.
- A known repository logo fixture was uploaded to that fictional report via the local API. Repeating the upload returned the same attachment ID, the administrator received sanitized JPEG bytes with no-store, and the accused fixture received 404. Results are in `artifacts/shared-report-device-check.json`. The new Android gallery-picker upload and live admin image-preview UI were not manually rerun; upload retries and admin preview lifecycle were covered by automated tests. The phone was released back to the user on Home.

- The November 16 polish pass verified the custom interlocking-ribbon mark on the welcome screen and inside Android's circular app-info mask (`artifacts/pixel-connection-brand.png`, `artifacts/pixel-connection-launcher.png`). The warm-white/crimson/teal theme, feet/inches and pounds selectors, unchanged BMI, map pan/zoom/recenter and marker-selected sheet were inspected on the Pixel. A subsequent display-only refinement reduced converted values to two decimals; focused tests passed and the rebuilt APK was installed. Map screenshots: `artifacts/pixel-map-polish.png`, `artifacts/pixel-map-area-polish.png`.
- My reports showed the fictional submission as Awaiting review, then Reviewed · closed with submission/review times, public explanation and its private attachment. The internal administrator note was absent (`artifacts/pixel-report-reviewed.png`, `artifacts/report-review-device-check.json`). The old logo visible inside that attachment is historical test evidence, not the current brand asset.
- The notification test initially found local notifications off and the ntfy companion disconnected; a server outbox marked sent alone did not establish delivery. After enabling notifications through Profile and opening the companion until connected, a fresh fictional report review produced a native private notification while Blood Connection was backgrounded and Nadia remained in cooldown. ntfy received it at 00:11:53.828 Sydney, the app callback ran at 00:11:53.880 and Android created the notification at 00:11:53.918. The title was Blood Connection and body was generic private-update text, with no report contents/outcome. Evidence is in `artifacts/report-notification-device.txt`; report ID is in `artifacts/report-review-push-id.txt`. Native report-alert tapping was not manually completed because Android's notification-shade accessibility dump would not become idle; deferred authenticated routing and cross-country opening passed automated tests. Apple delivery remains unverified.

The later logo pass adopted the exact PNG selected by the user. The master, mobile asset and APK-bundled asset have SHA-256 `2e4356ce94116847a04834006e630be2063f19b67a4dcac8273b5f4850bf1508`. The mobile widget uses cached image decoding; the admin uses a PNG rendered from the same artwork. Five existing widget tests and targeted Flutter analysis passed. The Android build and Pixel installation succeeded. The app-drawer screenshot `artifacts/pixel-selected-handshake-icon.png` shows the selected logo inside the native circular mask; the adaptive artwork bounds fit its central 66dp safe area. iOS assets were generated but remain unverified on hardware. The monochrome layer is omitted to preserve the white handshake. See `design-system/brand/README.md` for artwork provenance and reproduction.

Browser-admin verification used isolated fictional data for evidence review, a confirmed lifetime ban, country switching, sign-out, invalid/missing OAuth configuration, and desktop/375px layouts. See `admin/QA.md`.

The local LiveKit check used two SDK participants exchanging generated PCM audio through backend-issued credentials. Both disconnected after the API ended the call. Invitation/cancellation was also tested on the Pixel. This does not establish audible two-way communication on physical phones. See `docs/LOCAL-CALLS.md`.

The Android notification service must be opened once during setup on this Pixel; Profile includes an **Open notification companion** action and explanation. Delivery depends on the configured distributor, network and OS background restrictions. Messages and incoming calls do not yet have production background delivery.

## Build and local services

APK: `mobile/build/app/outputs/flutter-apk/app-debug.apk`

SHA-256: `BCD651E66C003B78B4226992E9AD482C149C44733EF530DED18224387E492A4A`

Application ID: `org.bindubashini.bloodconnection`. Size: 228,423,308 bytes, approximately 218 MiB. This is a debug multi-architecture build, not a store release or a production size/performance benchmark. Demo entries are compile-time gated. Release signing must be configured explicitly.

The API is at `http://127.0.0.1:8000`, with the admin console at `/admin/`. USB reverse mappings cover API port 8000, LiveKit ports 7880/7881 and local ntfy port 8090. This mode requires the computer, its services and the USB connection.

Restart the API with `./tools/start-local.ps1 -Calls -Push`. Docker configuration and service startup are documented in `docs/LOCAL-CALLS.md` and `docs/NOTIFICATIONS.md`; the API script does not start Docker for you.

## Remaining production and platform work

1. Configure and test Google/Apple/Facebook authentication, Supabase, trusted redirects, release signing and administrator MFA. Prepare regional hosting, encrypted backups and production monitoring.
2. Deploy a secured push distributor and real-device delivery tests. Configure Apple APNs credentials/entitlements and test on signed iOS builds. Production incoming calls and background chat alerts remain separate work.
3. Build and test on macOS/Xcode, iPhone and iPad. Implement and test dedicated watchOS/Wear OS applications if independent wrist use is required. CarPlay/Android Auto have no dedicated application here; validate external navigation on actual supported vehicles.
4. Complete two-physical-device audio, network-loss, microphone denial, routing and relay tests. Self-hosted LiveKit credentials may remain usable until their five-minute expiry after room cleanup.
5. Validate release performance, battery use, accessibility, localization and the full device matrix. This delivery uses an intentional light theme; simulator/widget layouts do not prove every device works.
6. Finalize country-specific clinical, privacy, retention and consent requirements, moderation/appeals, deletion operations and recovery procedures. Messaging is not end-to-end encrypted. An account ban cannot prove a unique human across every social account.

Core tooling is open source. Apple delivery/store services, social identity providers, external navigation and hosted infrastructure have separate terms and possible costs; see `docs/OPEN-SOURCE.md` and `docs/PLATFORMS.md`.

The build reports upstream media-plugin Kotlin migration warnings, and backend tests report a Starlette test-client deprecation warning. Neither failed the verified checks. The November 16 Git baseline check reran all 137 tests and Flutter analysis successfully (`artifacts/git-baseline-checks.log`). Gitleaks 8.30.1 found no secrets in the source/asset candidates; local data and device evidence are excluded from Git. GitHub push protection initially matched a credential-shaped substring in inline PNG base64; the decoded bytes matched the selected image. Packaging now uses a relative source image and rendered admin PNG, with push protection left enabled. The initial Git commit captures the current project together; it does not reconstruct the earlier editing history. GitHub Actions records remote verification separately. No app-store submission or assistant co-author trailer was made.
