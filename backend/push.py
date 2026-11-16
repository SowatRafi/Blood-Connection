"""Small real UnifiedPush/APNs adapters; notification content stays in the authenticated inbox."""

import base64
import json
from functools import lru_cache
from pathlib import Path
import re
import time
from urllib.parse import urlsplit

from cryptography.hazmat.primitives.asymmetric import ec
import httpx
import jwt
from pywebpush import WebPusher


def validate_endpoint(url: str, allowed_origins: set[str], demo: bool) -> None:
    """Endpoint registration must not turn the notification worker into an arbitrary HTTP client."""
    parsed = urlsplit(url)
    origin = f"{parsed.scheme}://{parsed.netloc}"
    local_http = demo and parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if (parsed.scheme != "https" and not local_http) or origin not in allowed_origins or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or not parsed.path or any(ord(char) < 33 for char in url):
        raise ValueError("Choose a push distributor allowed by this server")


def validate_keys(public_key: str, auth: str) -> None:
    """Validate the actual P-256 point and auth-secret size before accepting durable subscriptions."""
    try:
        public = base64.b64decode(public_key + "=" * (-len(public_key) % 4), altchars=b"-_", validate=True)
        secret = base64.b64decode(auth + "=" * (-len(auth) % 4), altchars=b"-_", validate=True)
        if len(public) != 65 or len(secret) != 16:
            raise ValueError("Invalid encryption keys")
        ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), public)
    except (ValueError, TypeError) as error:
        raise ValueError("Invalid push encryption keys") from error


def send_push(settings, device: dict, event: dict) -> str:
    """Return sent/retry/invalid/unconfigured; never mark an unconfigured adapter as delivered."""
    payload = {"event_id": str(event["id"]), "kind": event["kind"], "country": event["country"]}
    if event["kind"] == "report_reviewed":
        # Typed opaque targets let the authenticated app open the owner's outcome after travel.
        # Neither the review decision, report text nor administrator note reaches the lock screen.
        payload.update({"report_id": event["report_id"], "report_country": event["report_country"]})
    else:
        payload["request_id"] = event["request_id"]
    try:
        if device["provider"] == "unifiedpush":
            validate_endpoint(device["token"], settings.push_origins, settings.demo)
            encrypted = WebPusher({"endpoint": device["token"], "keys": {"p256dh": device["pub_key"], "auth": device["auth"]}}).encode(json.dumps(payload).encode())
            # Encrypt with the standard library package, but send ourselves so redirects cannot
            # escape the configured origin allowlist. The distributor never sees names/photos.
            response = httpx.post(device["token"], content=encrypted["body"], headers={"Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", "TTL": "300", "X-UnifiedPush": "1"}, timeout=8, follow_redirects=False)
        else:
            if not all((settings.apns_key_path, settings.apns_key_id, settings.apns_team_id, settings.apns_topic)):
                return "unconfigured"
            token = apns_bearer(settings.apns_key_path, settings.apns_key_id, settings.apns_team_id, int(time.time()) // 1200)
            host = "api.sandbox.push.apple.com" if settings.apns_sandbox else "api.push.apple.com"
            body = {"aps": {"alert": {"title": "Blood Connection", "body": "You have a private update. Open the app to view it."}, "sound": "default", "category": "PRIVATE_UPDATE"}, **payload}
            with httpx.Client(http2=True, timeout=8, follow_redirects=False) as client:
                response = client.post(f"https://{host}/3/device/{device['token']}", json=body, headers={"authorization": f"bearer {token}", "apns-topic": settings.apns_topic, "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": str(int(time.time()) + 300)})
        if 200 <= response.status_code < 300:
            return "sent"
        if response.status_code in {404, 410}:
            return "invalid"
        if device["provider"] == "apns" and response.status_code == 400:
            if response.json().get("reason") in {"BadDeviceToken", "DeviceTokenNotForTopic"}:
                return "invalid"
        return "retry"
    except (httpx.HTTPError, OSError, ValueError, jwt.PyJWTError):
        return "retry"


def valid_apns_token(token: str) -> bool:
    """APNs device tokens are hex bytes, not URLs or arbitrary path fragments."""
    return re.fullmatch(r"[0-9a-fA-F]{64,200}", token) is not None and len(token) % 2 == 0


@lru_cache(maxsize=4)
def apns_bearer(key_path: str, key_id: str, team_id: str, twenty_minute_bucket: int) -> str:
    """Reuse provider JWTs within Apple's validity window instead of over-rotating on each alert."""
    return jwt.encode({"iss": team_id, "iat": twenty_minute_bucket * 1200}, Path(key_path).read_bytes(), algorithm="ES256", headers={"kid": key_id})
