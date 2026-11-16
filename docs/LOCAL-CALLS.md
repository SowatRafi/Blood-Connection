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

Restart the backend with these environment values:

```powershell
$env:DEMO_MODE = '1'
$env:HOST = '127.0.0.1'
$env:LIVEKIT_URL = 'ws://127.0.0.1:7880'
$env:LIVEKIT_API_KEY = 'bloodconnection-local'
$env:LIVEKIT_API_SECRET = 'local-development-only-blood-connection-not-for-production-2015'
python -m backend
```

The backend now reports `calling_enabled: true`. It issues short-lived, room-scoped, microphone-only tokens after the receiving person accepts the invitation. The media server's API secret never goes to mobile clients.

## Connected Android phone

Keep the phone connected over USB with debugging approved, and reverse both media ports as well as the API port:

```powershell
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:8000 tcp:8000
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:7880 tcp:7880
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:7881 tcp:7881
```

Run a demo build of the mobile app. Calls need two different signed-in demo roles or two configured real accounts; one user cannot call themselves. The receiving app must be open because background push delivery is not configured in the local build. A native microphone permission prompt appears when joining a voice call; the person using the phone controls that permission.

The USB forwarding route is provided for device testing. A host-side synthetic test alone does **not** prove an audible two-device phone call. Verify Android permissions, audio routing, TCP ICE connectivity and two-way sound on actual devices before release. An iOS device build requires macOS/Xcode and its own reachable development media service.

## Synthetic transport check

This check does not capture or play sound. It creates disposable backend databases, creates and accepts an invitation through the real API, connects two LiveKit SDK participants, publishes a generated PCM tone, and asserts that the second participant receives at least five non-silent decoded frames. It also ends the call through the backend and checks that both participants disconnect.

```powershell
python -m pip install -r backend/requirements.txt -r infra/requirements-call-test.txt
python -m infra.test_local_calls
```

Verified on 15 November 2026 with Docker Desktop server 29.8.2, LiveKit server 1.13.11 and Python LiveKit SDK 1.2.1. Both participants joined and the synthetic audio check passed. Test state does not modify the main demo users, messages or reports.

The SDK may print data-channel closure messages when the backend removes participants. Those messages accompany intentional transport teardown; the test still must print both PASS lines and exit successfully.

## Stop and troubleshoot

```powershell
docker compose -f infra/compose.local-calls.yml logs --tail 50
docker compose -f infra/compose.local-calls.yml down
```

If calls remain unavailable, restart the API after setting the variables and check `/api/v1/health`. If signaling works but audio does not, check port 7881 and both USB reverse mappings. The root API should bind to loopback in demo mode. Do not widen host bindings, reuse these keys for production, or expose this plaintext WebSocket configuration publicly.

Self-hosted LiveKit cannot instantly revoke a previously issued JWT. The backend closes active participants and deletes the room, while already-issued tokens remain usable until their five-minute expiry. Production needs an explicit revocation strategy or a managed service with token revocation, TLS, network traversal/relay configuration, monitoring, and testing under real mobile networks. This local setup is not a production hosting design.

Configuration was checked against LiveKit's [local server guide](https://docs.livekit.io/transport/self-hosting/local/) and [official server configuration reference](https://github.com/livekit/livekit/blob/master/config-sample.yaml).
