# Setup and operations

## Local development

Follow the root README. Use the virtual environment's Python explicitly; activation is optional. The backend serves the admin console from the same origin, so no open CORS policy is necessary. Start the API on `127.0.0.1:8000`; `adb reverse tcp:8000 tcp:8000` connects the Pixel's loopback port to the computer without exposing the service on Wi-Fi. The phone must remain connected for that tunnel.

The demo database persists across restarts. Mutations such as donation cooldowns, blocks, and bans therefore persist too. Use a separate disposable data directory for destructive integration tests. Do not reset a user's local data silently. Stop the service and back up the configured data directory before an intentional reset.

## Provider configuration

1. Create a Supabase project for identity. Enable only Google, Apple, and Facebook. Disable password, anonymous, phone, and unwanted providers. Never put a Supabase service-role key in the mobile app or browser.
2. Create provider OAuth applications and configure callback URLs, bundle/package IDs, consent branding, authorized domains, and Android certificate fingerprints as applicable. Supabase's provider callback differs from the application's final deep-link redirect: configure both at their documented locations.
3. Allow the mobile redirect `bloodconnection://login-callback` in Supabase. Configure the admin redirect to the exact trusted admin origin/path. Restrict production redirects; avoid wildcards.
4. Set the backend Supabase URL and publishable/anonymous key using the names in `backend/.env.example`. Set server-owned administrator identity IDs. An ordinary user's mutable profile metadata must never grant administration.
5. Compile mobile with `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and HTTPS `API_URL`. `DEMO_MODE` defaults to false. For example:

```powershell
flutter build appbundle --dart-define=API_URL=https://api.example.org/api/v1 --dart-define=SUPABASE_URL=https://your-project.supabase.co --dart-define=SUPABASE_ANON_KEY=your-public-key
```

The example addresses are placeholders. Provider secrets belong only in the provider dashboard or backend secret environment. Public keys are not admin credentials. Android release builds deliberately fail until `mobile/android/key.properties` exists. That ignored file must contain `storeFile`, `storePassword`, `keyAlias`, and `keyPassword` for your release keystore. Store the keystore outside Git and keep a secure backup. Debug builds continue to use a local development certificate.

Official setup references: [Google](https://supabase.com/docs/guides/auth/social-sign-in/auth-google), [Apple](https://supabase.com/docs/guides/auth/social-sign-in/auth-apple), [Facebook](https://supabase.com/docs/guides/auth/social-sign-in/auth-facebook).

## Audio calling

Set up LiveKit Cloud or a securely hosted LiveKit service. Configure backend URL, API key and secret using the backend environment example; expose only room-scoped short-lived participant tokens to clients. Use secure WebSocket/HTTPS endpoints in production and verify TURN/media connectivity on mobile networks. Test caller invitation, callee consent, permission denial, mute, remote hang-up, blocked peers, revoked accounts, and network loss with two real signed-in devices. [LiveKit Flutter setup](https://docs.livekit.io/transport/sdk-platforms/flutter/).

No production LiveKit credentials are included. With calling unconfigured, the API rejects call creation explicitly and the UI explains the unavailable service. Foreground invitations do not provide background VoIP delivery. That requires APNs/FCM/CallKit/Android service configuration and additional testing.

Public demo keys for an optional loopback-only LiveKit container are provided in [local calling setup](LOCAL-CALLS.md). They are test fixtures, not production credentials. Its synthetic media test verifies two clients can exchange generated audio and be disconnected through the API; actual phone microphone/audio routing still requires a separate device test.

## Country rollout

The ISO catalog supports country selection. Production must explicitly enable supported countries. Deploying a country requires a regional database and backup location, reviewed privacy notices, local donor guidance, moderation coverage, and measured recovery procedures. The local implementation stores separate files on one computer; it is not geographically distributed.

Before distributing load across workers or hosts, replace local SQLite/in-process coordination with production regional storage and a shared global registry, distributed rate limiting, and atomic travel/account-state transitions. Keep the API contract and donor response privacy boundary. Verify cross-country ban and cooldown invariants during migration.

## Security operations

* Run one service worker for the local SQLite implementation. Put production behind a trusted HTTPS reverse proxy with body-size and connection limits. Restrict trusted hosts and forward headers only from the known proxy.
* Keep demo mode off. Verify demo tokens fail in a production-configured test and the public health response reports demo false.
* Use encrypted volumes and backups. Restrict service account access. Rotate provider/media credentials and remove departed administrators from the allowlist.
* Do not log bearer tokens, private profile bodies, location, conversation text, or report evidence. Keep audit events available only to authorized operators.
* Establish retention periods, backup expiry, account-deletion follow-through, report appeals, and an incident response contact before launch.
* Test backup restoration into an isolated environment. SQLite online backup or a stopped-service snapshot avoids inconsistent live file copies; include all country databases and the global registry together.

## iOS release

Windows can edit and analyze shared Dart code but cannot compile/sign an iOS application. On macOS, install current compatible Xcode and Flutter, configure the Apple team and unique bundle identifier, resolve native packages, and run on physical iPhone. Verify Keychain session storage, OAuth callbacks, location/microphone permission descriptions, background behavior, accessibility, and App Store privacy disclosures. Do not mark iOS verified based on an Android build.

## Team coordination

Ruflo was initialized locally with a four-member hierarchical topology and tasks for mobile, backend, admin, and integration. The actual code work uses the session's native agents; Ruflo tracks the work breakdown and local coordination state. `npx ruflo doctor` reports optional missing API keys and memory services; those are not required to run Blood Connection. Do not add its generated state, personal machine paths, or assistant co-author metadata to Git.
