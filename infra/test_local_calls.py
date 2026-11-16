"""Verify real local media with synthetic PCM, without opening a microphone or speaker.

Run `python -m infra.test_local_calls` after starting compose.local-calls.yml.
The API uses disposable databases; only the loopback LiveKit service is shared.
"""

import asyncio
from array import array
from math import pi, sin
from pathlib import Path
import tempfile

from fastapi.testclient import TestClient
from livekit import rtc

from backend.app import Settings, create_app


async def verify_media(client: TestClient):
    """Obtain credentials through real invitation/acceptance endpoints, then relay audio."""
    seeker = {"Authorization": "Bearer demo-seeker", "X-Country": "BD"}
    donor = {"Authorization": "Bearer demo-donor", "X-Country": "BD"}

    # Credential issuance is exercised through the app instead of minting unrestricted JWTs.
    def request(method, path, headers, body=None):
        response = client.request(method, f"/api/v1{path}", headers=headers, json=body)
        response.raise_for_status()
        return response.json()

    conversation = request("POST", "/conversations", seeker, {"donor_id": "donor"})
    call = request("POST", f"/conversations/{conversation['id']}/calls", seeker)
    callee = request("POST", f"/calls/{call['id']}/accept", donor)
    caller = request("GET", f"/calls/{call['id']}", seeker)
    sender_room, receiver_room = rtc.Room(), rtc.Room()
    sender_ended, receiver_ended = asyncio.Event(), asyncio.Event()
    received = asyncio.get_running_loop().create_future()
    tasks = []
    source = None

    # Backend termination must close both transports, not only update a database row.
    @sender_room.on("disconnected")
    def on_sender_end(reason):
        sender_ended.set()

    @receiver_room.on("disconnected")
    def on_receiver_end(reason):
        receiver_ended.set()

    # Decode a few non-silent frames to prove media transport, not merely signaling success.
    async def consume(track):
        stream = rtc.AudioStream(track, sample_rate=48000, num_channels=1)
        non_silent = 0
        try:
            async for event in stream:
                if any(abs(sample) > 20 for sample in event.frame.data):
                    non_silent += 1
                if non_silent >= 5:
                    if not received.done():
                        received.set_result(non_silent)
                    break
        except Exception as error:
            if not received.done():
                received.set_exception(error)
        finally:
            await stream.aclose()

    # A callback starts reading as soon as the receiving participant subscribes.
    @receiver_room.on("track_subscribed")
    def on_track(track, publication, participant):
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            tasks.append(asyncio.create_task(consume(track)))

    try:
        options = rtc.RoomOptions(connect_timeout=30, rtc_config=rtc.RtcConfiguration(ice_servers=[]))
        await receiver_room.connect(callee["url"], callee["token"], options)
        await sender_room.connect(caller["url"], caller["token"], options)
        source = rtc.AudioSource(48000, 1, queue_size_ms=200)
        track = rtc.LocalAudioTrack.create_audio_track("synthetic-qa-tone", source)
        await sender_room.local_participant.publish_track(track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        # The generated tone never touches audio hardware or any real person's recording.
        for chunk in range(200):
            pcm = array("h", (int(2000 * sin(2 * pi * 440 * (chunk * 480 + offset) / 48000)) for offset in range(480)))
            await source.capture_frame(rtc.AudioFrame(pcm.tobytes(), 48000, 1, 480))
            if received.done():
                break
        frames = await asyncio.wait_for(received, timeout=30)
        print(f"PASS: accepted call joined by two participants; {frames} non-silent synthetic audio frames received.")
        # End through the backend to verify the real room-revocation integration too.
        ended = await asyncio.to_thread(request, "POST", f"/calls/{call['id']}/end", seeker)
        assert ended["status"] == "ended"
        await asyncio.wait_for(asyncio.gather(sender_ended.wait(), receiver_ended.wait()), timeout=10)
        print("PASS: backend call end disconnected both participants; no microphone or speaker was accessed.")
    finally:
        await sender_room.disconnect()
        await receiver_room.disconnect()
        if source is not None:
            await source.aclose()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        # Cleanup also runs after transport failure so the shared local service stays tidy.
        try:
            await asyncio.to_thread(request, "POST", f"/calls/{call['id']}/end", seeker)
        except Exception:
            pass


def main():
    """A disposable API datastore keeps the user's demo accounts and reports untouched."""
    with tempfile.TemporaryDirectory(prefix="blood-connection-call-qa-") as directory:
        settings = Settings(data_dir=Path(directory), demo=True, livekit_url="ws://127.0.0.1:7880", livekit_key="bloodconnection-local", livekit_secret="local-development-only-blood-connection-not-for-production-2015")
        with TestClient(create_app(settings)) as client:
            asyncio.run(verify_media(client))


if __name__ == "__main__":
    main()
