"""Optional real local relay check: python -m backend.check_push (ntfy on loopback port 8090).

Uses disposable accounts/databases and an isolated random topic. This proves
encrypted relay interoperability, not Android/iOS OS-level background delivery.
"""

import base64
import json
from pathlib import Path
import tempfile
from uuid import uuid4

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient
import http_ece
import httpx

from backend.app import Settings, create_app, process_push


def main():
    """Publish from a real outbox, retrieve encrypted relay bytes, and decrypt as the client."""
    origin = "http://127.0.0.1:8090"
    topic = f"upbloodcheck{uuid4().hex}"
    private = ec.generate_private_key(ec.SECP256R1())
    public = private.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    auth = uuid4().bytes
    donor = {"Authorization": "Bearer demo-donor", "X-Country": "BD"}
    seeker = {"Authorization": "Bearer demo-seeker", "X-Country": "BD"}
    admin = {"Authorization": "Bearer demo-admin", "X-Country": "BD"}
    with tempfile.TemporaryDirectory() as directory:
        settings = Settings(data_dir=Path(directory), demo=True, push_origins={origin})
        app = create_app(settings)
        with TestClient(app) as client:
            registered = client.post("/api/v1/devices", headers=donor, json={"provider": "unifiedpush", "token": f"{origin}/{topic}?up=1", "pub_key": base64.urlsafe_b64encode(public).decode().rstrip("="), "auth": base64.urlsafe_b64encode(auth).decode().rstrip("=")})
            assert registered.status_code == 200, registered.text
            response = client.post("/api/v1/requests", headers=seeker, json={"blood_type": "O+", "radius_km": 39, "donor_ids": ["donor"], "destination_name": "Fictional test hospital", "destination_latitude": 23.8, "destination_longitude": 90.4})
            assert response.status_code == 200, response.text
            process_push(app.state.store, settings)
            relay = httpx.get(f"{origin}/{topic}/json", params={"poll": "1"}, timeout=5)
            relay.raise_for_status()
            entries = [json.loads(line) for line in relay.text.splitlines() if line]
            message = next(entry for entry in entries if entry.get("event") == "message")
            assert message.get("encoding") == "base64", "Expected opaque encrypted bytes at relay"
            decoded = json.loads(http_ece.decrypt(base64.b64decode(message["message"]), private_key=private, auth_secret=auth, version="aes128gcm"))
            assert decoded["request_id"] == response.json()["id"]
            assert set(decoded) == {"event_id", "kind", "request_id", "country"}
            with app.state.store.connect("BD") as db:
                assert db.execute("SELECT status FROM region.push_outbox").fetchone()[0] == "sent"
            # The same encrypted transport must carry a typed report outcome after the reporter travels.
            report = client.post("/api/v1/reports", headers=donor, json={"conversation_id": "demo-conversation", "reason": "other", "details": "Fictional local relay verification."})
            assert report.status_code == 200, report.text
            moved = client.post("/api/v1/location", headers=donor, json={"country": "AU", "city": "Sydney", "latitude": -33.86, "longitude": 151.2, "mode": "manual"})
            assert moved.status_code == 200, moved.text
            outcome = client.post(f"/api/v1/admin/reports/{report.json()['id']}/resolve", headers=admin, json={"decision": "dismiss", "note": "Private local test review note"})
            assert outcome.status_code == 200, outcome.text
            process_push(app.state.store, settings)
            relay = httpx.get(f"{origin}/{topic}/json", params={"poll": "1"}, timeout=5)
            relay.raise_for_status()
            decoded_messages = []
            for line in relay.text.splitlines():
                entry = json.loads(line)
                if entry.get("event") == "message":
                    decoded_messages.append(json.loads(http_ece.decrypt(base64.b64decode(entry["message"]), private_key=private, auth_secret=auth, version="aes128gcm")))
            reviewed = next(item for item in decoded_messages if item["kind"] == "report_reviewed")
            assert set(reviewed) == {"event_id", "kind", "report_id", "report_country", "country"}
            assert reviewed["report_id"] == report.json()["id"] and reviewed["report_country"] == "BD"
            inbox = client.get("/api/v1/events", headers={**donor, "X-Country": "AU"})
            assert any(item["report_id"] == reviewed["report_id"] for item in inbox.json()["items"])
    print("PASS: request and cross-travel report review -> durable outbox -> local ntfy -> authenticated decryption; no personal content in relay payload")


if __name__ == "__main__":
    main()
