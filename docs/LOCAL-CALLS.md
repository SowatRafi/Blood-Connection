# Local in-app calling

An initiative by Bindubashini Boys’ 2015 & Friends

This optional setup makes real voice transport available without a LiveKit cloud account. It uses Docker Desktop and the official LiveKit server image, pinned to the inspected digest for version **1.13.11**. It is intended only for local development. The committed API key/secret are public test fixtures.

## Start the media service

From the repository root, with Docker Desktop running:

```powershell
docker compose -f infra/compose.local-calls.yml up -d
docker compose -f infra/compose.local-calls.yml ps
```

Only `127.0.0.1:7880/tcp` (signaling/API) and `127.0.0.1:7881/tcp` (WebRTC media) are published. Nothing is published on the LAN or Internet. The server advertises a loopback address and clients use TCP because no UDP ports are exposed. The container does not automatically restart after a reboot.

The JavaScript/Fastify API uses Node 24 and the migrated PostgreSQL database. Start it with the local calling configuration:

```powershell
./tools/start-local.ps1 -Calls
```

The backend now reports `calling_enabled: true`. It issues short-lived, room-scoped, microphone-only tokens after the receiving person accepts the invitation. The media server's API secret never goes to mobile clients.

`backend/src/calls.js` authorizes each call transition and status read inside PostgreSQL transactions. A conversation row lock prevents concurrent invitations from creating multiple active calls. `backend/src/integrations.js` signs five-minute tokens with `jose`; the same module uses native bounded `fetch` requests for LiveKit participant removal and room deletion. Ending, blocking, banning, travel or account deletion writes durable cleanup work before the media request is attempted. Failed removal remains queued for the worker rather than being reported as successful revocation.

## Connected Android phone

Keep the phone connected over USB with debugging approved, and reverse both media ports as well as the API port:

```powershell
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:8000 tcp:8000
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:7880 tcp:7880
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:7881 tcp:7881
```

Run a demo build of the mobile app. Calls need two different signed-in demo roles or two configured real accounts; one user cannot call themselves. The receiving app must be open because background incoming-call delivery is not implemented. Donation and report-review notifications are separate and do not provide VoIP delivery. A native microphone permission prompt appears when joining a voice call; the person using the phone controls that permission.

The USB forwarding route is provided for device testing. A host-side synthetic test alone does **not** prove an audible two-device phone call. Verify Android permissions, audio routing, TCP ICE connectivity and two-way sound on actual devices before release. An iOS device build requires macOS/Xcode and its own reachable development media service.

## Synthetic transport check

This optional diagnostic does not capture or play sound. The Node launcher resets only the guarded `blood_connection_test` database and starts a separate JavaScript API on a random loopback port. A small Python LiveKit SDK client obtains credentials through that API, connects two participants, publishes a generated PCM tone, and asserts that the second participant receives at least five non-silent decoded frames. It ends the call through the JavaScript backend and checks that both participants disconnect.

Python is used only for this optional audio probe. It does not host the API, access PostgreSQL, or import FastAPI/the retired backend. Normal application startup and the automated backend suite require Node.js, not Python.

```powershell
. ./tools/use-node.ps1
docker compose -f infra/compose.local-database.yml up -d --wait
docker compose -f infra/compose.local-calls.yml up -d
python -m pip install -r infra/requirements-call-test.txt
node backend/scripts/check-calls.js
```

Set `PYTHON` to a specific interpreter path if the optional SDK is installed in a separate environment. The probe uses LiveKit server 1.13.11 and Python LiveKit SDK 1.2.1. Do not run it concurrently with the backend suite or relay diagnostic because they share the isolated test database. The test helper rejects a database name without the `_test` suffix. Test state does not modify the interactive demo users, messages or reports.

On 16 November 2026 the Node-backed diagnostic passed: both participants joined, the receiver decoded five non-silent synthetic frames, and ending the call through the JavaScript API disconnected both participants. No microphone or speaker was accessed. Local evidence: `artifacts/javascript-media-check.log`. This validates the local transport and cleanup path, not two-way audible calls on physical phones.

The SDK may print data-channel closure messages when the backend removes participants. Those messages accompany intentional transport teardown; the test still must print both PASS lines and exit successfully.

## Stop and troubleshoot

```powershell
docker compose -f infra/compose.local-calls.yml logs --tail 50
docker compose -f infra/compose.local-calls.yml down
```

If calls remain unavailable, restart the API after setting the variables and check `/api/v1/health`. If signaling works but audio does not, check port 7881 and both USB reverse mappings. The root API should bind to loopback in demo mode. Do not widen host bindings, reuse these keys for production, or expose this plaintext WebSocket configuration publicly.

Self-hosted LiveKit cannot instantly revoke a previously issued JWT. The backend closes active participants and deletes the room, while already-issued tokens remain usable until their five-minute expiry. Production needs an explicit revocation strategy or a managed service with token revocation, TLS, network traversal/relay configuration, monitoring, and testing under real mobile networks. This local setup is not a production hosting design.

Configuration was checked against LiveKit's [local server guide](https://docs.livekit.io/transport/self-hosting/local/) and [official server configuration reference](https://github.com/livekit/livekit/blob/master/config-sample.yaml).
