# Blood Connection mobile

An initiative by Bindubashini Boys’ 2015 & Friends

Flutter Android and iOS application with a web target restricted to administrators. See the repository README and docs for backend setup, data boundaries and release requirements.

## Local development

Start the backend with `DEMO_MODE=1` bound to `127.0.0.1:8000`. For an attached Android phone, run `adb reverse tcp:8000 tcp:8000`, then:

```powershell
flutter pub get
flutter run --dart-define=DEMO_MODE=true
```

Select **Explore local demo** for the fictional seeker, **Try donor demo** for the fictional donor, or **Open admin demo** for administration. The browser exposes only the admin entry. These entry points and their allowlisted tokens exist only when `DEMO_MODE=true` is compiled into the application. Local data must never be treated as real donor records. Demo accounts keep their fixture location until the user deliberately changes Location settings.

## Production configuration

```powershell
flutter run --dart-define=API_URL=https://api.example.org/api/v1 --dart-define=SUPABASE_URL=https://project.supabase.co --dart-define=SUPABASE_ANON_KEY=PUBLIC_PUBLISHABLE_KEY
```

Do not set `DEMO_MODE` in production. Social sign-in requires configured Google, Apple and Facebook providers in Supabase and the `bloodconnection://login-callback` redirect. Only the public Supabase publishable key belongs in client configuration; never embed a service-role secret. The client refuses non-HTTPS production API URLs. OAuth sessions use platform-backed secure storage on phones and memory-only storage on the web admin target. Administrator roles are assigned and checked on the server; they cannot be selected during signup.

On first member entry, automatic location is the primary choice, with clear consent for foreground country/area detection and moving the active profile when travelling. Native GPS and reverse geocoding identify the country and city; no street address enters the public profile. Updates happen on startup/resume, before a search and every five minutes while foregrounded. A failed refresh blocks stale searches. No background location permission or tracking is used.

Manual location remains available. The selected city/suburb is geocoded afresh and reverse-checked against the chosen country before confirmation. Manual mode persists and disables automatic updates. Country, cooldown and ban state are resolved by the server; the client never silently creates a production profile in Bangladesh.

Donation dates are submitted with the phone's UTC offset so a legitimate local “today” is not rejected in countries ahead of UTC. Countdown and call suppression prefer the server's absolute `eligible_after_utc` timestamp; legacy date-only records use their original UTC-midnight boundary. The displayed calendar date remains the server's donation-pause date.

## Requests, photos and directions

Find donors by exact blood group within 1–39 km, then invite a single donor or the displayed matches. The requester chooses a hospital/public meeting point, reviews its resolved address, and consents to sharing it after acceptance. The Requests tab contains invitations, outgoing requests and unread updates. Acceptance reveals the agreed destination, private partner photo if present, and the app conversation. Both matched members can close or withdraw from coordination. Completing a request does not falsely record an actual donation.

Profile photos are optional after signup. The system gallery picker selects a JPEG/PNG; the client bounds size and the server sanitizes the upload. Photos use authenticated binary responses, not public URLs. Private decoded images are evicted when their widget closes, the app backgrounds, or the participant changes; resumed display requires fresh authorization.

Discovery uses a full-screen pannable map with floating blood-group/range filters and a draggable donor sheet. Markers group stable approximate areas; tapping one selects its real donor cards. Panning changes only the camera, never the saved search origin. Expand/Collapse and zoom buttons provide alternatives to gestures. Marker/sheet transitions respect reduced motion, and map attribution stays visible without covering filters.

The accepted-request map marks only the explicitly shared hospital/meeting point. Distance is labelled **straight-line** from the viewer's own saved location. **Go** opens Google Maps, Apple Maps or Waze with that destination. No donor home point is drawn or passed to a map provider.

The map uses `flutter_map`, with configurable `MAP_TILE_URL` and `MAP_ATTRIBUTION` compile-time values. The default OpenStreetMap tile source uses visible attribution, an identifying user-agent and the library's HTTP-aware native cache. There is no offline prefetch. Configure suitable hosted or self-hosted tiles before a large rollout and follow the provider's terms; community OSM tiles do not provide a service-level guarantee.

## Notifications

Profile contains explicit enable/disable controls. Android uses UnifiedPush and needs an installed distributor such as ntfy; iOS uses Apple's native APNs with server credentials and provisioning. Firebase is not required. The local notification opens Requests and can mirror to a paired watch using the operating system's settings. This is not a standalone watch application.

Push payloads contain an opaque request identifier and generic wording; names, photos, destination details and blood groups are fetched only after sign-in. Background alert delivery depends on platform permission, distributor/APNs setup and backend delivery configuration. Foreground inbox polling remains available. Messages and call invitations currently refresh while the app is open; native background call interfaces are not implemented.

## Code map

- `lib/api.dart`: authenticated JSON/private-image requests, country header, timeout, controlled errors and demo build boundary.
- `lib/main.dart`: startup, social sign-in, role routing, phone/tablet shell, home, donor discovery and incoming-call invitations.
- `lib/location.dart`: consent, native country/area lookup, persistent manual mode, travel updates and refresh throttling.
- `lib/profile.dart`: private measurements, BMI, optional photo, location settings, donation records, notifications, export and deletion.
- `lib/private_photo.dart`: authorized in-memory photo display and cache/lifecycle cleanup.
- `lib/requests.dart`: request/invitation workflow, unread updates, acceptance-gated meeting map and external directions.
- `lib/messaging.dart`: participant conversations, reports, blocks, call signalling and LiveKit audio lifecycle.
- `lib/notifications.dart`: UnifiedPush/APNs registration, safe notification parsing, local alerts and request navigation.
- `lib/admin.dart`: server-authorized evidence review, country selection and confirmed lifetime-ban decisions.
- `lib/ui.dart`: fixed-light accessible visual tokens and native reusable controls.

The first release intentionally uses a consistent light appearance even when the device requests dark mode. Native text scaling is supported; widget checks cover 320px and 375px phones, landscape at 200% text, scrollable map/destination dialogs, and tablet navigation. Phones use five bottom destinations; widths of at least 720px use a navigation rail. No decorative animation overrides reduced-motion settings. Controls retain Material accessibility, focus and minimum touch sizes.

## Verification

```powershell
flutter analyze
flutter test
flutter build apk --debug --dart-define=DEMO_MODE=true
```

Tests check social-only production entry, member/admin separation, private evidence and photo removal, acceptance-gated destination display, donor withdrawal, country matching and travel failures, foreground throttling, call-cancellation cleanup, safe push parsing and responsive layouts. Real OAuth callbacks, two-device audio, VoiceOver/TalkBack, native gallery upload, geocoder coverage, iOS compilation/provisioning and end-to-end push delivery still need their corresponding environments. Calls fail visibly when no LiveKit server is configured. Incoming call prompts are suppressed during the donation pause.

Messaging is protected by server authorization and production TLS, but is not end-to-end encrypted. Reporting sends the conversation identifier for server-side evidence review. Phone numbers are neither requested nor displayed. Export displays selectable JSON on the owner's device without automatically copying it to a shared clipboard.
