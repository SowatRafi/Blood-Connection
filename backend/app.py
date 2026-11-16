"""Private country-scoped blood matching API.

Country files hold profiles and conversations. The small global registry holds
identity, availability, cooldown and enforcement state so travel cannot evade a
ban or a donation pause. Never return private profile fields in donor results.
"""

from __future__ import annotations

import calendar
import asyncio
import base64
import hashlib
from collections import defaultdict, deque
from contextlib import asynccontextmanager, closing, contextmanager
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
import ipaddress
from io import BytesIO
import json
import math
import os
from pathlib import Path
import sqlite3
import threading
import time
import warnings
from typing import Literal
from uuid import uuid4
from urllib.parse import urlsplit

import httpx
import jwt
import pycountry
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, field_validator
from PIL import Image, ImageOps, UnidentifiedImageError

from backend.push import send_push, valid_apns_token, validate_endpoint, validate_keys


GROUPS = {"A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"}
COUNTRIES = {c.alpha_2: c.name for c in pycountry.countries}
PROVIDERS = {"google", "apple", "facebook"}
PREFIX = "/api/v1"


def utcnow() -> datetime:
    """Use an aware UTC clock for all expiry decisions, independent of host timezone."""
    return datetime.now(timezone.utc)


def stamp() -> str:
    """Consistent sortable timestamps simplify local SQLite comparisons."""
    return utcnow().isoformat()


def add_three_months(day: date) -> date:
    """Calendar months, with end-of-month clamping, implement the requested pause."""
    month = day.month - 1 + 3
    year, month = day.year + month // 12, month % 12 + 1
    return date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


def km_between(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Haversine works across the date line and avoids planar-distance distortion."""
    a, b = math.radians(lat1), math.radians(lat2)
    dlat, dlon = b - a, math.radians(lon2 - lon1)
    hav = math.sin(dlat / 2) ** 2 + math.cos(a) * math.cos(b) * math.sin(dlon / 2) ** 2
    return 6371.0088 * 2 * math.asin(math.sqrt(min(1.0, max(0.0, hav))))


def coarse_map_area(latitude: float, longitude: float) -> dict:
    """Return a fixed area centroid, never a donor pin or query-dependent location jitter.

    Rows are 0.05 degrees (~5.56 km). Longitude bin counts use the row's
    poleward edge so their narrowest east-west arc is at least 5 km. The
    tiny top/bottom caps are each one area; all longitudes meet at a pole.
    These are display areas, not a guarantee against repeated-search inference.
    """
    row = min(3599, max(0, math.floor((latitude + 90) * 20)))
    if row in {0, 3599}:
        return {"id": f"area-v1-{row}-0", "latitude": -90.0 if row == 0 else 90.0, "longitude": 0.0}
    south, north = row / 20 - 90, (row + 1) / 20 - 90
    circumference = 2 * math.pi * 6371.0088 * math.cos(math.radians(max(abs(south), abs(north))))
    # A 100 m margin keeps great-circle widths and rounded centroids above ~5 km,
    # even though circumference measures the slightly longer latitude-circle arc.
    columns = max(1, math.floor(circumference / 5.1))
    width = 360 / columns
    # Center the first cell on the antimeridian: +180/-180 and nearby points
    # share the same cell instead of exposing an artificial seam in the map.
    normalized = (longitude + 180) % 360
    column = min(columns - 1, math.floor(((normalized + width / 2) % 360) / width))
    center_longitude = ((-180 + column * width) + 180) % 360 - 180
    return {"id": f"area-v1-{row}-{column}", "latitude": round((south + north) / 2, 6), "longitude": round(center_longitude, 6)}


@dataclass
class Settings:
    """Explicit settings let tests isolate data and make production opt in to countries."""

    data_dir: Path = field(default_factory=lambda: Path(os.getenv("DATA_DIR", "backend/data")))
    demo: bool = field(default_factory=lambda: os.getenv("DEMO_MODE", "0") == "1")
    supabase_url: str = field(default_factory=lambda: os.getenv("SUPABASE_URL", "").rstrip("/"))
    supabase_key: str = field(default_factory=lambda: os.getenv("SUPABASE_ANON_KEY", ""))
    countries: set[str] = field(default_factory=lambda: {c.strip().upper() for c in os.getenv("ENABLED_COUNTRIES", "").split(",") if c.strip()})
    admins: set[str] = field(default_factory=lambda: {c.strip() for c in os.getenv("ADMIN_USER_IDS", "").split(",") if c.strip()})
    origins: list[str] = field(default_factory=lambda: [c.strip() for c in os.getenv("CORS_ORIGINS", "http://localhost:8080,http://127.0.0.1:8080").split(",") if c.strip()])
    livekit_url: str = field(default_factory=lambda: os.getenv("LIVEKIT_URL", ""))
    livekit_key: str = field(default_factory=lambda: os.getenv("LIVEKIT_API_KEY", ""))
    livekit_secret: str = field(default_factory=lambda: os.getenv("LIVEKIT_API_SECRET", ""))
    push_origins: set[str] = field(default_factory=lambda: {value.strip().rstrip("/") for value in os.getenv("PUSH_ALLOWED_ORIGINS", "").split(",") if value.strip()})
    apns_key_path: str = field(default_factory=lambda: os.getenv("APNS_KEY_PATH", ""))
    apns_key_id: str = field(default_factory=lambda: os.getenv("APNS_KEY_ID", ""))
    apns_team_id: str = field(default_factory=lambda: os.getenv("APNS_TEAM_ID", ""))
    apns_topic: str = field(default_factory=lambda: os.getenv("APNS_TOPIC", ""))
    apns_sandbox: bool = field(default_factory=lambda: os.getenv("APNS_SANDBOX", "0") == "1")

    @property
    def calling_enabled(self) -> bool:
        """A call is available only when a real signalling/media service is configured."""
        return bool(self.livekit_url and self.livekit_key and self.livekit_secret)


class StrictModel(BaseModel):
    """Reject privilege fields and non-finite numbers instead of silently accepting them."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, allow_inf_nan=False)


class ProfileInput(StrictModel):
    """Profile validation is a server boundary, even when mobile forms also validate."""

    display_name: str = Field(min_length=2, max_length=60)
    blood_type: str
    height_cm: float = Field(ge=100, le=250)
    weight_kg: float = Field(ge=30, le=300)
    city: str = Field(min_length=2, max_length=80)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    available: bool

    @field_validator("blood_type")
    @classmethod
    def blood_group(cls, value: str) -> str:
        """Only explicit ABO/Rh groups are supported; no compatibility is inferred."""
        if value not in GROUPS:
            raise ValueError("Select a valid blood group")
        return value


class TravelInput(StrictModel):
    """An explicit consent flag prevents an incidental country selector from moving data."""

    country: str = Field(min_length=2, max_length=2)
    city: str = Field(min_length=2, max_length=80)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    consent: Literal[True]


class LocationInput(StrictModel):
    """Keep all location fields together so a country change cannot retain an old city's coordinates."""

    country: str = Field(min_length=2, max_length=2)
    city: str = Field(min_length=2, max_length=80)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    mode: Literal["automatic", "manual"]


class DonationInput(StrictModel):
    donated_at: date
    utc_offset_minutes: int = Field(default=0, ge=-720, le=840, strict=True)
    facility_name: str = Field(min_length=2, max_length=160)
    location_name: str = Field(min_length=2, max_length=160)
    country: str = Field(min_length=2, max_length=2)
    request_id: str | None = Field(default=None, min_length=1, max_length=80)
    idempotency_key: str | None = Field(default=None, min_length=16, max_length=128)

    @field_validator("country")
    @classmethod
    def donation_country(cls, value: str) -> str:
        """A private historical donation may have happened outside currently served countries."""
        if value.upper() not in COUNTRIES:
            raise ValueError("Choose a valid ISO country")
        return value.upper()


class DonationRequestInput(StrictModel):
    """The destination is a deliberately shared hospital/place, never inferred from a donor's GPS."""

    blood_type: str
    radius_km: float = Field(ge=1, le=39)
    destination_name: str = Field(min_length=2, max_length=160)
    destination_latitude: float = Field(ge=-90, le=90)
    destination_longitude: float = Field(ge=-180, le=180)
    donor_ids: list[str] | None = Field(default=None, min_length=1, max_length=50)


class DeviceInput(StrictModel):
    provider: Literal["unifiedpush", "apns"]
    token: str = Field(min_length=10, max_length=2048)
    pub_key: str | None = Field(default=None, max_length=200)
    auth: str | None = Field(default=None, max_length=100)


class DeviceRemovalInput(StrictModel):
    token: str = Field(min_length=10, max_length=2048)


class ConversationInput(StrictModel):
    donor_id: str = Field(min_length=1, max_length=80)


class MessageInput(StrictModel):
    body: str = Field(min_length=1, max_length=2000)


class ReportInput(StrictModel):
    conversation_id: str | None = Field(default=None, min_length=1, max_length=80)
    request_id: str | None = Field(default=None, min_length=1, max_length=80)
    idempotency_key: str | None = Field(default=None, min_length=16, max_length=128)
    reason: Literal["money_request", "harassment", "misleading_information", "no_show", "other"]
    details: str = Field(min_length=5, max_length=2000)


class BlockInput(StrictModel):
    user_id: str = Field(min_length=1, max_length=80)


class ResolutionInput(StrictModel):
    decision: Literal["ban", "dismiss"]
    note: str = Field(min_length=5, max_length=2000)


GLOBAL_SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
 id TEXT PRIMARY KEY, country TEXT NOT NULL, available INTEGER NOT NULL DEFAULT 0,
 eligible_after TEXT, eligible_after_utc TEXT, role TEXT NOT NULL DEFAULT 'member', banned INTEGER NOT NULL DEFAULT 0,
 deleted INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL,
 location_mode TEXT NOT NULL DEFAULT 'automatic' CHECK(location_mode IN ('automatic','manual'))
);
CREATE TABLE IF NOT EXISTS donations (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL, donated_at TEXT NOT NULL, created_at TEXT NOT NULL,
 facility_name TEXT, location_name TEXT, country TEXT, request_id TEXT, idempotency_key TEXT,
 confirmed_by TEXT, confirmed_by_role TEXT
);
CREATE TABLE IF NOT EXISTS donation_confirmations (
 request_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, facility_name TEXT NOT NULL,
 location_name TEXT, country TEXT NOT NULL, created_at TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','dismissed','recorded')),
 requester_id TEXT, donor_name TEXT, donor_dismissed INTEGER NOT NULL DEFAULT 0,
 seeker_dismissed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS blocks (
 blocker TEXT NOT NULL, blocked TEXT NOT NULL, created_at TEXT NOT NULL,
 PRIMARY KEY(blocker, blocked)
);
CREATE TABLE IF NOT EXISTS audit (
 id TEXT PRIMARY KEY, actor_id TEXT NOT NULL, subject_id TEXT NOT NULL, action TEXT NOT NULL,
 country TEXT NOT NULL, report_id TEXT, note TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TRIGGER IF NOT EXISTS audit_no_update BEFORE UPDATE ON audit
 BEGIN SELECT RAISE(ABORT, 'Audit records are append-only'); END;
CREATE TRIGGER IF NOT EXISTS audit_no_delete BEFORE DELETE ON audit
 BEGIN SELECT RAISE(ABORT, 'Audit records are append-only'); END;
CREATE TABLE IF NOT EXISTS media_cleanup (
 call_id TEXT PRIMARY KEY, caller_id TEXT NOT NULL, callee_id TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS deletion_jobs (
 user_id TEXT PRIMARY KEY, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL, provider TEXT NOT NULL, token TEXT NOT NULL UNIQUE,
 pub_key TEXT, auth TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS active_matches (
 donor_id TEXT PRIMARY KEY, requester_id TEXT NOT NULL UNIQUE, request_id TEXT NOT NULL UNIQUE,
 country TEXT NOT NULL
);
"""

REGION_SCHEMA = """
CREATE TABLE IF NOT EXISTS profiles (
 id TEXT PRIMARY KEY, display_name TEXT NOT NULL, blood_type TEXT, height_cm REAL,
 weight_kg REAL, city TEXT NOT NULL DEFAULT '', latitude REAL, longitude REAL
);
CREATE TABLE IF NOT EXISTS conversations (
 id TEXT PRIMARY KEY, user_a TEXT NOT NULL, user_b TEXT NOT NULL, updated_at TEXT NOT NULL,
 UNIQUE(user_a,user_b)
);
CREATE TABLE IF NOT EXISTS messages (
 id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, sender_id TEXT NOT NULL,
 body TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id,created_at);
CREATE TABLE IF NOT EXISTS reports (
 id TEXT PRIMARY KEY, reporter_id TEXT NOT NULL, reported_id TEXT NOT NULL,
 conversation_id TEXT NOT NULL, reason TEXT NOT NULL, details TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending', evidence TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS report_attachments (
 id TEXT PRIMARY KEY, report_id TEXT NOT NULL, jpeg BLOB NOT NULL,
 source_digest TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(report_id,source_digest)
);
CREATE TABLE IF NOT EXISTS calls (
 id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, caller_id TEXT NOT NULL,
 callee_id TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS profile_photos (
 user_id TEXT PRIMARY KEY, jpeg BLOB NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS donation_requests (
 id TEXT PRIMARY KEY, requester_id TEXT NOT NULL, blood_type TEXT NOT NULL, radius_km REAL NOT NULL,
 destination_name TEXT NOT NULL, destination_latitude REAL NOT NULL, destination_longitude REAL NOT NULL,
 status TEXT NOT NULL DEFAULT 'open', accepted_donor_id TEXT, conversation_id TEXT,
 created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS one_active_request ON donation_requests(requester_id) WHERE status IN ('open','accepted');
CREATE TABLE IF NOT EXISTS request_invitations (
 request_id TEXT NOT NULL, donor_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'invited',
 PRIMARY KEY(request_id,donor_id)
);
CREATE TABLE IF NOT EXISTS events (
 id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
 body TEXT NOT NULL, request_id TEXT NOT NULL, created_at TEXT NOT NULL, read INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS event_inbox ON events(user_id,id);
CREATE TABLE IF NOT EXISTS push_outbox (
 event_id INTEGER NOT NULL, device_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
 attempts INTEGER NOT NULL DEFAULT 0, next_attempt TEXT NOT NULL,
 PRIMARY KEY(event_id,device_id)
);
"""


class Store:
    """SQLite provides real persistence and transactions without a service dependency.

    ponytail: one host owns these country files; use region-local PostgreSQL and
    an authenticated account registry before multi-host/country-resident rollout.
    """

    def __init__(self, settings: Settings):
        self.settings = settings
        self.directory = settings.data_dir.resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.schema_lock = threading.Lock()
        self.regions: set[str] = set()
        with self.connect() as db:
            db.executescript(GLOBAL_SCHEMA)
            # Existing installations retain accounts and cooldowns; serialize the additive migration.
            db.execute("BEGIN IMMEDIATE")
            if "location_mode" not in {row["name"] for row in db.execute("PRAGMA table_info(accounts)")}:
                db.execute("ALTER TABLE accounts ADD COLUMN location_mode TEXT NOT NULL DEFAULT 'automatic' CHECK(location_mode IN ('automatic','manual'))")
            if "eligible_after_utc" not in {row["name"] for row in db.execute("PRAGMA table_info(accounts)")}:
                # Null preserves the legacy UTC-date rule until a new locally dated donation is logged.
                db.execute("ALTER TABLE accounts ADD COLUMN eligible_after_utc TEXT")
            # Legacy donations lack place details; retain null instead of inventing medical history.
            donation_columns = {row["name"] for row in db.execute("PRAGMA table_info(donations)")}
            for column in ("facility_name", "location_name", "country", "request_id", "idempotency_key", "confirmed_by", "confirmed_by_role"):
                if column not in donation_columns:
                    db.execute(f"ALTER TABLE donations ADD COLUMN {column} TEXT")
            # Either participant may confirm, but one completed request produces only one donor record.
            db.execute("CREATE UNIQUE INDEX IF NOT EXISTS donation_request_once ON donations(request_id) WHERE request_id IS NOT NULL")
            db.execute("UPDATE donations SET confirmed_by=user_id,confirmed_by_role='donor' WHERE confirmed_by IS NULL")
            db.execute("CREATE UNIQUE INDEX IF NOT EXISTS donation_actor_intent_once ON donations(confirmed_by,idempotency_key) WHERE idempotency_key IS NOT NULL")
            # The actor now may be a seeker; the old donor-key index would collide across two actors.
            db.execute("DROP INDEX IF EXISTS donation_intent_once")
            confirmation_columns = {row["name"] for row in db.execute("PRAGMA table_info(donation_confirmations)")}
            for column, definition in (("requester_id", "TEXT"), ("donor_name", "TEXT"), ("donor_dismissed", "INTEGER NOT NULL DEFAULT 0"), ("seeker_dismissed", "INTEGER NOT NULL DEFAULT 0")):
                if column not in confirmation_columns:
                    db.execute(f"ALTER TABLE donation_confirmations ADD COLUMN {column} {definition}")
            # A legacy No was the donor's answer only; do not suppress the seeker's new prompt.
            db.execute("UPDATE donation_confirmations SET donor_dismissed=1,status='pending' WHERE status='dismissed'")
            # Recover participants only from persisted completed matches, never from client assertions.
            # Read regional files separately to keep global schema migration atomic without attachment limits.
            for path in self.directory.glob("??.sqlite3"):
                if path.stem not in COUNTRIES:
                    continue
                with closing(sqlite3.connect(path)) as region:
                    if not region.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='donation_requests'").fetchone():
                        continue
                    rows = region.execute("SELECT r.id,r.requester_id,p.display_name FROM donation_requests r LEFT JOIN profiles p ON p.id=r.accepted_donor_id WHERE r.status='completed'").fetchall()
                    for rid, requester, donor_name in rows:
                        db.execute("UPDATE donation_confirmations SET requester_id=?,donor_name=COALESCE(donor_name,?) WHERE request_id=? AND requester_id IS NULL", (requester, donor_name or "Donor", rid))

    @contextmanager
    def connect(self, country: str | None = None):
        """Attach only validated country files; values in all SQL remain bound parameters."""
        db = sqlite3.connect(self.directory / "registry.sqlite3", timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            if country:
                self.ensure_region(country)
                db.execute("ATTACH DATABASE ? AS region", (str(self.directory / f"{country}.sqlite3"),))
            with db:
                yield db
        finally:
            db.close()

    def ensure_region(self, country: str):
        """Country codes are checked before constructing paths, preventing traversal."""
        if country not in COUNTRIES:
            raise HTTPException(400, "Choose a valid ISO country")
        with self.schema_lock:
            if country not in self.regions:
                with closing(sqlite3.connect(self.directory / f"{country}.sqlite3", timeout=10)) as db:
                    with db:
                        db.executescript(REGION_SCHEMA)
                        # Add report targeting/retry metadata without changing existing evidence snapshots.
                        columns = {row[1] for row in db.execute("PRAGMA table_info(reports)")}
                        for column in ("request_id", "idempotency_key", "reviewed_at"):
                            if column not in columns:
                                db.execute(f"ALTER TABLE reports ADD COLUMN {column} TEXT")
                        db.execute("CREATE UNIQUE INDEX IF NOT EXISTS report_intent_once ON reports(reporter_id,idempotency_key) WHERE idempotency_key IS NOT NULL")
                        db.execute("CREATE INDEX IF NOT EXISTS report_owner_history ON reports(reporter_id,created_at)")
                        event_columns = {row[1] for row in db.execute("PRAGMA table_info(events)")}
                        for column in ("report_id", "report_country"):
                            if column not in event_columns:
                                db.execute(f"ALTER TABLE events ADD COLUMN {column} TEXT")
                        # Resolution commits once; this also prevents accidental duplicate outcome events.
                        db.execute("CREATE UNIQUE INDEX IF NOT EXISTS report_review_event_once ON events(user_id,report_id) WHERE kind='report_reviewed' AND report_id IS NOT NULL")
                self.regions.add(country)

    def seed(self):
        """Fictional local fixtures are idempotent and never run with production auth."""
        fixtures = [
            ("donor", "Nadia (demo)", "O+", 165, 62, 23.8103, 90.4125, True),
            ("seeker", "Rafi (demo)", "B+", 175, 73, 23.8110, 90.4130, False),
            ("admin", "Community admin (demo)", "AB+", 170, 65, 23.8103, 90.4125, False),
            ("donor-two", "Arif (demo)", "O+", 178, 78, 23.8203, 90.4225, True),
            ("donor-three", "Maya (demo)", "A+", 162, 56, 23.7913, 90.4035, True),
            ("reported", "Reported account (demo)", "B-", 170, 68, 23.8313, 90.4235, True),
        ]
        with self.connect("BD") as db:
            if db.execute("SELECT 1 FROM accounts WHERE id='seeker'").fetchone():
                return
            for uid, name, group, height, weight, lat, lon, available in fixtures:
                db.execute("INSERT INTO accounts(id,country,available,role,created_at) VALUES(?,?,?,?,?)", (uid, "BD", available, "admin" if uid == "admin" else "member", stamp()))
                db.execute("INSERT INTO region.profiles VALUES(?,?,?,?,?,?,?,?)", (uid, name, group, height, weight, "Dhaka", lat, lon))
            db.execute("INSERT INTO region.conversations VALUES(?,?,?,?)", ("demo-conversation", "donor", "seeker", stamp()))
            db.execute("INSERT INTO region.messages VALUES(?,?,?,?,?)", ("demo-message", "demo-conversation", "donor", "Hello! This is a fictional demo conversation. Blood donation is always voluntary and free.", stamp()))
            db.execute("INSERT INTO region.conversations VALUES(?,?,?,?)", ("demo-report-conversation", "reported", "seeker", stamp()))
            evidence = [{"sender_id": "reported", "body": "Fictional report evidence: please send money before I donate.", "created_at": stamp()}]
            db.execute("INSERT INTO region.messages VALUES(?,?,?,?,?)", ("demo-evidence-message", "demo-report-conversation", "reported", evidence[0]["body"], evidence[0]["created_at"]))
            db.execute("INSERT INTO region.reports(id,reporter_id,reported_id,conversation_id,reason,details,status,evidence,created_at) VALUES(?,?,?,?,?,?,?,?,?)", ("demo-report", "seeker", "reported", "demo-report-conversation", "money_request", "Fictional sample report for reviewing the admin workflow.", "pending", json.dumps(evidence), stamp()))


def sanitized_image(raw: bytes, max_edge: int) -> bytes:
    """Bound decoding and retain only fresh oriented pixels; evidence needs more detail than avatars."""
    if len(raw) > 5 * 1024 * 1024:
        raise HTTPException(413, "Choose an image no larger than 5 MB")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(BytesIO(raw)) as original:
                if original.format not in {"JPEG", "PNG"} or original.width * original.height > 12_000_000 or getattr(original, "n_frames", 1) != 1:
                    raise ValueError("Unsupported image")
                original.load()
                oriented = ImageOps.exif_transpose(original)
                oriented.thumbnail((max_edge, max_edge))
                clean = Image.new("RGB", oriented.size, "white")
                if "A" in oriented.getbands():
                    clean.paste(oriented, mask=oriented.getchannel("A"))
                else:
                    clean.paste(oriented.convert("RGB"))
                output = BytesIO()
                clean.save(output, "JPEG", quality=85, optimize=True)
                return output.getvalue()
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise HTTPException(422, "Choose a valid JPEG or PNG image under 12 megapixels") from None


def cooldown_deadline(account: sqlite3.Row | dict) -> datetime | None:
    """Interpret new absolute deadlines and legacy UTC-date records through one consistent rule."""
    if account["eligible_after_utc"]:
        return datetime.fromisoformat(account["eligible_after_utc"])
    if account["eligible_after"]:
        return datetime.fromisoformat(account["eligible_after"]).replace(tzinfo=timezone.utc)
    return None


def available(account: sqlite3.Row | dict) -> bool:
    """Derive availability on every read, so cooldown expiry needs no fragile cron job."""
    deadline = cooldown_deadline(account)
    return bool(account["available"] and not account["banned"] and not account["deleted"] and (deadline is None or deadline <= utcnow()))


def profile_for(db: sqlite3.Connection, uid: str, schema: Literal["region", "destination"] = "region") -> dict:
    """Only the owner receives measurements and coordinates; other endpoints project fields."""
    account = db.execute("SELECT * FROM accounts WHERE id=?", (uid,)).fetchone()
    # Schema is a fixed internal attachment name; callers can never provide it through the API.
    row = db.execute(f"SELECT * FROM {schema}.profiles WHERE id=?", (uid,)).fetchone()
    if not account or not row:
        raise HTTPException(404, "Profile not found in this country")
    result = dict(row)
    result.update({"country": account["country"], "available": bool(account["available"]), "eligible_after": account["eligible_after"], "eligible_after_utc": account["eligible_after_utc"], "is_available": available(account), "role": account["role"], "location_mode": account["location_mode"]})
    result["bmi"] = round(row["weight_kg"] / (row["height_cm"] / 100) ** 2, 1) if row["height_cm"] and row["weight_kg"] else None
    result["has_photo"] = db.execute(f"SELECT 1 FROM {schema}.profile_photos WHERE user_id=?", (uid,)).fetchone() is not None
    return result


def complete_profile(db: sqlite3.Connection, uid: str) -> sqlite3.Row:
    """Matching cannot use missing measurements or an implicit default location."""
    row = db.execute("SELECT * FROM region.profiles WHERE id=?", (uid,)).fetchone()
    if not row or any(row[key] is None for key in ("blood_type", "height_cm", "weight_kg", "latitude", "longitude")) or not row["city"]:
        raise HTTPException(409, "Complete your profile and location first")
    return row


def relationship_blocked(db: sqlite3.Connection, user: str, peer: str) -> bool:
    """Either participant's block closes matching, messaging and calling in both directions."""
    return db.execute("SELECT 1 FROM blocks WHERE (blocker=? AND blocked=?) OR (blocker=? AND blocked=?)", (user, peer, peer, user)).fetchone() is not None


def close_request(db: sqlite3.Connection, request_id: str, status: str):
    """Revoking a match closes invitations and releases its global single-match reservation."""
    db.execute("UPDATE region.donation_requests SET status=? WHERE id=?", (status, request_id))
    db.execute("UPDATE region.request_invitations SET status='closed' WHERE request_id=? AND status IN ('invited','accepted')", (request_id,))
    db.execute("DELETE FROM active_matches WHERE request_id=?", (request_id,))


def expire_requests(db: sqlite3.Connection, country: str):
    """Recheck revocations on reads and delivery, so bans/travel/blocks remove photo/map access."""
    for request in db.execute("SELECT * FROM region.donation_requests WHERE status IN ('open','accepted')").fetchall():
        owner = db.execute("SELECT * FROM accounts WHERE id=?", (request["requester_id"],)).fetchone()
        invalid = not owner or owner["banned"] or owner["deleted"] or owner["country"] != country
        if request["accepted_donor_id"]:
            donor = db.execute("SELECT * FROM accounts WHERE id=?", (request["accepted_donor_id"],)).fetchone()
            invalid = invalid or not donor or donor["banned"] or donor["deleted"] or donor["country"] != country or relationship_blocked(db, request["requester_id"], request["accepted_donor_id"])
        if invalid:
            close_request(db, request["id"], "cancelled")
        elif request["status"] == "open" and request["expires_at"] <= stamp():
            close_request(db, request["id"], "expired")


def emit_event(db: sqlite3.Connection, uid: str, kind: str, title: str, body: str, request_id: str | None = None, *, report_id: str | None = None, report_country: str | None = None):
    """Inbox/outbox commit with the transition; report targets never masquerade as donation requests."""
    # Older SQLite schemas require a non-null request_id. Empty storage means no link and is
    # projected as null/omitted at API/push boundaries, without rebuilding existing event IDs.
    event_id = db.execute("INSERT INTO region.events(user_id,kind,title,body,request_id,created_at,report_id,report_country) VALUES(?,?,?,?,?,?,?,?)", (uid, kind, title, body, request_id or "", stamp(), report_id, report_country)).lastrowid
    db.execute("INSERT INTO region.push_outbox(event_id,device_id,next_attempt) SELECT ?,id,? FROM devices WHERE user_id=?", (event_id, stamp(), uid))


def event_allowed(db: sqlite3.Connection, event: sqlite3.Row, country: str) -> bool:
    """Evaluate notification eligibility at delivery time, not only when the event was created."""
    account = db.execute("SELECT * FROM accounts WHERE id=?", (event["user_id"],)).fetchone()
    if not account or account["banned"] or account["deleted"]:
        return False
    if event["kind"] == "report_reviewed":
        # Moderation outcomes belong to the reporter despite travel, blocks, or donor cooldown.
        # The accused gets neither the event nor any private report details.
        report = db.execute("SELECT reporter_id,status FROM region.reports WHERE id=?", (event["report_id"],)).fetchone()
        return bool(report and report["reporter_id"] == event["user_id"] and report["status"] in {"banned", "dismissed"} and event["report_country"] == country)
    request = db.execute("SELECT * FROM region.donation_requests WHERE id=?", (event["request_id"],)).fetchone()
    if account["country"] != country or not request:
        return False
    if event["user_id"] != request["requester_id"]:
        if not available(account) or relationship_blocked(db, event["user_id"], request["requester_id"]):
            return False
    if event["kind"] == "donation_request":
        invitation = db.execute("SELECT status FROM region.request_invitations WHERE request_id=? AND donor_id=?", (request["id"], event["user_id"])).fetchone()
        return request["status"] == "open" and bool(invitation and invitation["status"] == "invited")
    if event["kind"] == "thank_you":
        return request["status"] in {"accepted", "completed"}
    if event["kind"] == "request_accepted":
        return request["status"] == "accepted"
    return request["status"] in {"cancelled", "completed", "expired"}


def process_push(store: Store, settings: Settings):
    """A durable at-least-once outbox survives restarts; clients deduplicate country/event IDs."""
    for path in store.directory.glob("??.sqlite3"):
        if path.stem not in COUNTRIES:
            continue
        with store.connect(path.stem) as db:
            db.execute("BEGIN IMMEDIATE")
            expire_requests(db, path.stem)
            jobs = db.execute("SELECT o.event_id,o.device_id,o.attempts FROM region.push_outbox o WHERE o.status='pending' AND o.next_attempt<=? ORDER BY o.event_id LIMIT 20", (stamp(),)).fetchall()
        for job in jobs:
            # Reserve a short lease to avoid simultaneous workers sending the same pending row.
            with store.connect(path.stem) as db:
                db.execute("BEGIN IMMEDIATE")
                lease = db.execute("UPDATE region.push_outbox SET next_attempt=? WHERE event_id=? AND device_id=? AND status='pending' AND next_attempt<=?", ((utcnow() + timedelta(minutes=2)).isoformat(), job["event_id"], job["device_id"], stamp()))
                if not lease.rowcount:
                    continue
                event = db.execute("SELECT * FROM region.events WHERE id=?", (job["event_id"],)).fetchone()
                device = db.execute("SELECT * FROM devices WHERE id=?", (job["device_id"],)).fetchone()
                if not event or not device or device["user_id"] != event["user_id"] or not event_allowed(db, event, path.stem) or event["created_at"] < (utcnow() - timedelta(hours=24)).isoformat():
                    db.execute("UPDATE region.push_outbox SET status='suppressed' WHERE event_id=? AND device_id=?", (job["event_id"], job["device_id"]))
                    continue
            result = send_push(settings, dict(device), {**dict(event), "country": path.stem})
            with store.connect(path.stem) as db:
                attempts = job["attempts"] + 1
                status = "sent" if result == "sent" else "invalid" if result == "invalid" else "failed" if attempts >= 12 else "pending"
                delay = min(3600, 15 * 2 ** min(attempts, 8))
                db.execute("UPDATE region.push_outbox SET status=?,attempts=?,next_attempt=? WHERE event_id=? AND device_id=?", (status, attempts, (utcnow() + timedelta(seconds=delay)).isoformat(), job["event_id"], job["device_id"]))
                if result == "invalid":
                    db.execute("DELETE FROM devices WHERE id=?", (job["device_id"],))


def request_result(db: sqlite3.Connection, request_id: str, uid: str) -> dict:
    """Project destination/photo access only for the owner or their accepted counterpart."""
    row = db.execute("SELECT * FROM region.donation_requests WHERE id=?", (request_id,)).fetchone()
    invitation = db.execute("SELECT status FROM region.request_invitations WHERE request_id=? AND donor_id=?", (request_id, uid)).fetchone()
    if not row or (row["requester_id"] != uid and not invitation):
        raise HTTPException(404, "Donation request not found")
    is_owner = row["requester_id"] == uid
    matched = row["status"] == "accepted" and uid in {row["requester_id"], row["accepted_donor_id"]}
    was_matched = bool(row["accepted_donor_id"] and uid in {row["requester_id"], row["accepted_donor_id"]})
    owner = db.execute("SELECT display_name FROM region.profiles WHERE id=?", (row["requester_id"],)).fetchone()
    result = {"id": row["id"], "status": row["status"], "requester_id": row["requester_id"], "requester_name": owner["display_name"] if owner else "Unavailable member", "blood_type": row["blood_type"], "radius_km": row["radius_km"], "created_at": row["created_at"], "expires_at": row["expires_at"], "is_requester": is_owner, "invitation_status": invitation["status"] if invitation else None, "accepted_donor_id": row["accepted_donor_id"] if matched else None, "conversation_id": row["conversation_id"] if matched else None, "peer_id": None, "peer_name": None, "peer_has_photo": False}
    if is_owner or matched:
        result.update({key: row[key] for key in ("destination_name", "destination_latitude", "destination_longitude")})
    if matched:
        peer = row["accepted_donor_id"] if is_owner else row["requester_id"]
        person = db.execute("SELECT display_name FROM region.profiles WHERE id=?", (peer,)).fetchone()
        result.update({"peer_id": peer, "peer_name": person["display_name"] if person else "Member", "peer_has_photo": db.execute("SELECT 1 FROM region.profile_photos WHERE user_id=?", (peer,)).fetchone() is not None})
    # A closed/blocked match remains reportable; only its participants see the shared outcome.
    result.update({"can_report": was_matched, "donation_recorded": False, "donation_summary": None})
    if was_matched:
        result["accepted_donor_id"] = row["accepted_donor_id"]
        recorded = db.execute("SELECT donated_at,facility_name,location_name,country,confirmed_by_role FROM donations WHERE request_id=?", (request_id,)).fetchone()
        result["donation_recorded"] = recorded is not None
        result["donation_summary"] = dict(recorded) if recorded else None
    return result


def conversation_peer(db: sqlite3.Connection, cid: str, uid: str, writable: bool = False) -> str:
    """Authorize object access before returning content; guessed IDs reveal no conversation."""
    conversation = db.execute("SELECT * FROM region.conversations WHERE id=? AND (user_a=? OR user_b=?)", (cid, uid, uid)).fetchone()
    if not conversation:
        raise HTTPException(404, "Conversation not found")
    peer = conversation["user_b"] if conversation["user_a"] == uid else conversation["user_a"]
    if writable:
        account = db.execute("SELECT * FROM accounts WHERE id=?", (peer,)).fetchone()
        caller = db.execute("SELECT country FROM accounts WHERE id=?", (uid,)).fetchone()
        if not account or account["banned"] or account["deleted"] or account["country"] != caller["country"] or relationship_blocked(db, uid, peer):
            raise HTTPException(403, "This conversation is unavailable")
    return peer


def end_matching_calls(db: sqlite3.Connection, clause: str, values: tuple):
    """Persist revocation work before closing calls, so media-service outages can be retried."""
    # The SQL clause comes only from fixed server literals, never request data.
    calls = db.execute(f"SELECT * FROM region.calls WHERE ({clause}) AND status IN ('ringing','accepted')", values).fetchall()
    for call in calls:
        if call["status"] == "accepted":
            db.execute("INSERT OR IGNORE INTO media_cleanup VALUES(?,?,?)", (call["id"], call["caller_id"], call["callee_id"]))
        db.execute("UPDATE region.calls SET status='ended' WHERE id=?", (call["id"],))


def cleanup_media(store: Store, settings: Settings):
    """Expire abandoned calls and retry durable LiveKit revocations without retaining tokens."""
    if not settings.calling_enabled:
        return
    for path in store.directory.glob("??.sqlite3"):
        if path.stem in COUNTRIES:
            with store.connect(path.stem) as db:
                end_matching_calls(db, "expires_at<=?", (stamp(),))
                # Enforcement is global even if an admin reviewed evidence in a previous country.
                end_matching_calls(db, "caller_id IN (SELECT id FROM accounts WHERE banned=1 OR deleted=1 OR country<>?) OR callee_id IN (SELECT id FROM accounts WHERE banned=1 OR deleted=1 OR country<>?)", (path.stem, path.stem))
    with store.connect() as db:
        pending = db.execute("SELECT * FROM media_cleanup LIMIT 20").fetchall()
    base = settings.livekit_url.replace("wss://", "https://", 1).replace("ws://", "http://", 1).rstrip("/")
    for call in pending:
        now = utcnow()
        room = f"blood-{call['call_id']}"
        claims = {"iss": settings.livekit_key, "nbf": int(now.timestamp()) - 5, "exp": int((now + timedelta(seconds=60)).timestamp()), "video": {"roomCreate": True, "roomAdmin": True, "room": room}}
        headers = {"Authorization": f"Bearer {jwt.encode(claims, settings.livekit_secret, algorithm='HS256')}"}
        try:
            # RemoveParticipant also revokes its current token on LiveKit Cloud. Self-hosted
            # LiveKit cannot revoke previously issued JWTs; their maximum TTL is five minutes.
            for identity in (call["caller_id"], call["callee_id"]):
                response = httpx.post(f"{base}/twirp/livekit.RoomService/RemoveParticipant", headers=headers, json={"room": room, "identity": identity}, timeout=3, follow_redirects=False)
                if response.status_code not in {200, 404}:
                    raise httpx.HTTPError("Media participant removal failed")
            response = httpx.post(f"{base}/twirp/livekit.RoomService/DeleteRoom", headers=headers, json={"room": room}, timeout=3, follow_redirects=False)
            if response.status_code not in {200, 404}:
                continue
        except httpx.HTTPError:
            # Keep the durable queue entry; a later worker pass retries after an outage.
            continue
        with store.connect() as db:
            db.execute("DELETE FROM media_cleanup WHERE call_id=?", (call["call_id"],))


def scrub_deleted_accounts(store: Store):
    """Retry interrupted regional erasure from a durable job, even after tokens are revoked."""
    with store.connect() as db:
        jobs = db.execute("SELECT user_id FROM deletion_jobs LIMIT 20").fetchall()
    for job in jobs:
        uid = job["user_id"]
        for path in store.directory.glob("??.sqlite3"):
            if path.stem not in COUNTRIES:
                continue
            with store.connect(path.stem) as db:
                db.execute("DELETE FROM region.profiles WHERE id=?", (uid,))
                db.execute("DELETE FROM region.profile_photos WHERE user_id=?", (uid,))
                db.execute("DELETE FROM region.push_outbox WHERE event_id IN (SELECT id FROM region.events WHERE user_id=?)", (uid,))
                db.execute("DELETE FROM region.events WHERE user_id=?", (uid,))
                expire_requests(db, path.stem)
                # Shared request IDs may remain for other participants, but a deleted owner's
                # destination and generated name-bearing notifications need not be retained.
                db.execute("UPDATE region.events SET body='This request is no longer available.' WHERE request_id IN (SELECT id FROM region.donation_requests WHERE requester_id=? OR accepted_donor_id=?)", (uid, uid))
                db.execute("UPDATE region.donation_requests SET destination_name='[Removed]',destination_latitude=0,destination_longitude=0 WHERE requester_id=?", (uid,))
                db.execute("UPDATE region.messages SET body='[Message removed]' WHERE sender_id=?", (uid,))
                end_matching_calls(db, "caller_id=? OR callee_id=?", (uid, uid))
        with store.connect() as db:
            db.execute("DELETE FROM deletion_jobs WHERE user_id=?", (uid,))


def create_app(settings: Settings | None = None) -> FastAPI:
    """Factory isolates tests and exposes no development login on production installations."""
    settings = settings or Settings()
    if not settings.demo and settings.supabase_url and not settings.supabase_url.startswith("https://"):
        raise RuntimeError("Production SUPABASE_URL must use HTTPS")
    if "*" in settings.origins:
        raise RuntimeError("CORS_ORIGINS must contain explicit origins")
    # The browser key is intentionally public; refuse secret-key formats before exposing config.
    if settings.supabase_key.startswith("sb_secret_"):
        raise RuntimeError("Use a Supabase publishable/anon key, never a secret key")
    if settings.supabase_key.count(".") == 2:
        try:
            if jwt.decode(settings.supabase_key, options={"verify_signature": False}).get("role") == "service_role":
                raise RuntimeError("Use the Supabase anon key, never the service_role key")
        except jwt.PyJWTError:
            raise RuntimeError("SUPABASE_ANON_KEY is not a valid public key") from None
    auth_origin = ""
    if settings.supabase_url:
        parsed = urlsplit(settings.supabase_url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.path or parsed.query or parsed.fragment or parsed.username or parsed.password:
            raise RuntimeError("SUPABASE_URL must be an HTTPS origin without a path or credentials")
        auth_origin = f" {parsed.scheme}://{parsed.netloc}"
    if settings.livekit_url:
        media = urlsplit(settings.livekit_url)
        if media.scheme not in ({"wss", "ws"} if settings.demo else {"wss"}) or not media.hostname or media.path not in {"", "/"} or media.query or media.fragment or media.username or media.password:
            raise RuntimeError("LIVEKIT_URL must be a secure WebSocket origin")
    store = Store(settings)
    if settings.demo:
        store.seed()

    @asynccontextmanager
    async def lifespan(application: FastAPI):
        """A small durable cleanup worker ends abandoned media sessions even when apps crash."""
        async def worker():
            while True:
                try:
                    await asyncio.to_thread(scrub_deleted_accounts, store)
                    await asyncio.to_thread(cleanup_media, store, settings)
                    await asyncio.to_thread(process_push, store, settings)
                except (sqlite3.Error, OSError):
                    # A transient DB lock/service outage must not silently kill future cleanup.
                    pass
                await asyncio.sleep(15)
        task = asyncio.create_task(worker())
        try:
            yield
        finally:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    api = FastAPI(title="Blood Connection", version="0.1.0", docs_url="/docs" if settings.demo else None, redoc_url=None, lifespan=lifespan)
    api.state.store, api.state.settings = store, settings
    api.add_middleware(CORSMiddleware, allow_origins=settings.origins, allow_methods=["GET", "POST", "PUT", "DELETE"], allow_headers=["Authorization", "Content-Type", "X-Country"])
    # ponytail: process-local limits suit a single local server; move to shared Redis for replicas.
    limits: dict[str, deque] = defaultdict(deque)
    limiter_lock = threading.Lock()

    @api.middleware("http")
    async def security_headers(request: Request, call_next):
        """Do not trust forwarded client IPs; demo tokens work only on loopback/test transports."""
        if settings.demo:
            host = request.client.host if request.client else ""
            try:
                loopback = ipaddress.ip_address(host).is_loopback
            except ValueError:
                loopback = host == "testclient"
            if not loopback or request.url.hostname not in {"127.0.0.1", "localhost", "::1", "testserver"}:
                return JSONResponse({"detail": "Demo mode is only available over loopback"}, status_code=403)
        # Reject oversized requests before JSON parsing; reverse proxy must enforce the same cap.
        image_upload = (request.method == "PUT" and request.url.path == f"{PREFIX}/me/photo") or (request.method == "POST" and request.url.path.startswith(f"{PREFIX}/reports/") and request.url.path.endswith("/evidence"))
        limit = 5 * 1024 * 1024 if image_upload else 32768
        length = request.headers.get("content-length")
        if length and (not length.isdecimal() or int(length) > limit):
            return JSONResponse({"detail": "Request body is too large"}, status_code=413)
        # Enforce the cap on streamed/chunked bodies too, rather than trusting Content-Length.
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > limit:
                return JSONResponse({"detail": "Request body is too large"}, status_code=413)
        request._body = bytes(body)
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Permissions-Policy"] = "camera=(), geolocation=(self), microphone=(self)"
        response.headers["Content-Security-Policy"] = f"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'{auth_origin}; img-src 'self' data: blob:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
        return response

    @api.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError):
        """Return readable errors without echoing private rejected input into responses/logs."""
        fields = ", ".join(".".join(str(x) for x in error["loc"][1:]) or "request" for error in exc.errors())
        return JSONResponse({"detail": f"Check these fields: {fields}"}, status_code=422)

    def country_code(value: str) -> str:
        """Only configured country codes can create or access a regional database."""
        code = value.upper()
        if code not in COUNTRIES:
            raise HTTPException(400, "Choose a valid ISO country")
        if not settings.demo and code not in settings.countries:
            raise HTTPException(409, "Blood Connection is not available in this country yet")
        return code

    def stored_country(value: str | None, user: dict) -> str:
        """Old-region owner reads never move a profile or create a country database."""
        code = (value or user["country"]).strip().upper()
        if code not in COUNTRIES or not (store.directory / f"{code}.sqlite3").is_file():
            raise HTTPException(404, "Saved country not found")
        return code

    def throttle(key: str, count: int, seconds: int):
        """Bound matching/contact abuse while leaving routine profile reads responsive."""
        now = time.monotonic()
        with limiter_lock:
            queue = limits[key]
            while queue and queue[0] <= now - seconds:
                queue.popleft()
            if len(queue) >= count:
                raise HTTPException(429, "Please wait before trying again", headers={"Retry-After": str(seconds)})
            queue.append(now)
            # Limit stale limiter keys as well as requests; never retain bearer tokens.
            if len(limits) > 10000:
                for old in list(limits):
                    if not limits[old] or limits[old][-1] <= now - 3600:
                        del limits[old]

    def current_user(request: Request, authorization: str = Header(default=""), x_country: str = Header(default="")) -> dict:
        """Supabase verifies signed access tokens; roles come only from server configuration."""
        requested_country = x_country.strip().upper()
        if requested_country and requested_country not in COUNTRIES:
            raise HTTPException(400, "Choose a valid ISO country")
        if not authorization.startswith("Bearer ") or len(authorization) > 8192:
            raise HTTPException(401, "Sign in to continue")
        token = authorization[7:]
        display_name = "New member"
        if settings.demo:
            uid = {"demo-donor": "donor", "demo-seeker": "seeker", "demo-admin": "admin"}.get(token)
            if not uid:
                raise HTTPException(401, "Invalid local demo session")
        else:
            if not settings.supabase_url or not settings.supabase_key:
                raise HTTPException(503, "Sign-in service has not been configured")
            throttle(f"auth:{request.client.host if request.client else 'unknown'}", 120, 60)
            try:
                response = httpx.get(f"{settings.supabase_url}/auth/v1/user", headers={"Authorization": f"Bearer {token}", "apikey": settings.supabase_key}, timeout=8, follow_redirects=False)
                if response.status_code != 200:
                    raise HTTPException(401, "Your session has expired. Please sign in again")
                user = response.json()
            except (httpx.HTTPError, ValueError) as error:
                raise HTTPException(503, "Sign-in service is temporarily unavailable") from error
            # app_metadata is server-controlled; user_metadata must never authorize providers or roles.
            if user.get("app_metadata", {}).get("provider") not in PROVIDERS or not user.get("id"):
                raise HTTPException(403, "Use Google, Apple or Facebook to sign in")
            uid = str(user["id"])
            display_name = str(user.get("user_metadata", {}).get("full_name") or "New member")[:60]
        with store.connect() as db:
            account = db.execute("SELECT * FROM accounts WHERE id=?", (uid,)).fetchone()
            role = account["role"] if settings.demo and account else ("admin" if uid in settings.admins else "member")
            if account and account["banned"]:
                raise HTTPException(403, "This account has been permanently banned")
            if account and account["deleted"]:
                raise HTTPException(403, "This account has been deleted")
            # Normal browsers attach Origin and/or Fetch Metadata. This closes browser member
            # access, but absent headers are NOT proof of a genuine app: deployment needs attestation.
            browser_request = "origin" in request.headers or any(key.startswith("sec-fetch-") for key in request.headers)
            if browser_request and role != "admin":
                raise HTTPException(403, "This website is for administrators. Please use the mobile app")
            if not account:
                code = requested_country
                if not code and role == "admin":
                    # Admin bootstrap is an operational region, not a claim about GPS position.
                    code = "BD" if settings.demo else next(iter(sorted(settings.countries)), "")
                if not code:
                    raise HTTPException(409, "Location required: choose or detect your country first")
                code = country_code(code)
                store.ensure_region(code)
                db.execute("ATTACH DATABASE ? AS region", (str(store.directory / f"{code}.sqlite3"),))
                db.execute("INSERT INTO accounts(id,country,role,created_at) VALUES(?,?,?,?)", (uid, code, role, stamp()))
                db.execute("INSERT INTO region.profiles(id,display_name) VALUES(?,?)", (uid, display_name))
                account = db.execute("SELECT * FROM accounts WHERE id=?", (uid,)).fetchone()
            if not settings.demo and account["role"] != role:
                db.execute("UPDATE accounts SET role=? WHERE id=?", (role, uid))
            if (request.method == "GET" and request.url.path == f"{PREFIX}/me") or request.url.path == f"{PREFIX}/location":
                # Cold clients can recover their country; GPS updates use the saved source region.
                code = account["country"]
            else:
                code = country_code(requested_country or account["country"])
            if account["country"] != code and not (role == "admin" and request.url.path.startswith(f"{PREFIX}/admin/")):
                raise HTTPException(409, f"Your active country is {account['country']}. Use travel to change it")
            return {"id": uid, "country": code, "role": role}

    def administrator(user: dict = Depends(current_user)) -> dict:
        """Admin access is checked server-side on every administration endpoint."""
        if user["role"] != "admin":
            raise HTTPException(403, "Administrator access required")
        return user

    @api.get(f"{PREFIX}/health")
    def health():
        """Expose capabilities, never secrets or internal database paths."""
        return {"status": "ok", "demo": settings.demo, "calling_enabled": settings.calling_enabled}

    @api.get("/", include_in_schema=False)
    def website_root():
        """The hosted website exposes the admin portal; members use the native application."""
        return RedirectResponse("/admin/", status_code=307)

    @api.get(f"{PREFIX}/countries")
    def countries():
        """The client must show deployed countries rather than promising unavailable regions."""
        return {"items": [{"code": code, "name": name} for code, name in sorted(COUNTRIES.items(), key=lambda item: item[1]) if settings.demo or code in settings.countries]}

    @api.get(f"{PREFIX}/auth/config")
    def auth_config():
        """Only Supabase's public browser key is exposed; service-role keys must never be configured."""
        return {"supabase_url": settings.supabase_url or None, "supabase_anon_key": settings.supabase_key or None}

    @api.get(f"{PREFIX}/me")
    def me(user: dict = Depends(current_user)):
        with store.connect(user["country"]) as db:
            return profile_for(db, user["id"])

    @api.put(f"{PREFIX}/me")
    def update_me(body: ProfileInput, user: dict = Depends(current_user)):
        """Update owner fields only; bans, roles and cooldown can never be assigned by clients."""
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            account = db.execute("SELECT * FROM accounts WHERE id=?", (user["id"],)).fetchone()
            if not account or account["banned"] or account["deleted"]:
                raise HTTPException(403, "This account is unavailable")
            if account["country"] != user["country"]:
                raise HTTPException(409, "Your country changed. Refresh your profile and try again")
            original = db.execute("SELECT city,latitude,longitude FROM region.profiles WHERE id=?", (user["id"],)).fetchone()
            if not original or original["city"] != body.city or original["latitude"] != body.latitude or original["longitude"] != body.longitude:
                raise HTTPException(409, "Location changed or is missing. Update location and refresh your profile before saving")
            # Location belongs to /location in both modes; a stale form cannot undo a GPS update.
            db.execute("UPDATE region.profiles SET display_name=?,blood_type=?,height_cm=?,weight_kg=? WHERE id=?", (body.display_name, body.blood_type, body.height_cm, body.weight_kg, user["id"]))
            db.execute("UPDATE accounts SET available=? WHERE id=?", (body.available, user["id"]))
            return profile_for(db, user["id"])

    def save_location(body: LocationInput, user: dict, require_complete: bool = False) -> dict:
        """Update or transfer one current profile atomically, without changing global safety state."""
        destination = country_code(body.country)
        store.ensure_region(destination)
        with store.connect(user["country"]) as db:
            if destination != user["country"]:
                db.execute("ATTACH DATABASE ? AS destination", (str(store.directory / f"{destination}.sqlite3"),))
            # Serialize the read+move so concurrent foreground requests cannot resurrect stale rows.
            db.execute("BEGIN IMMEDIATE")
            account = db.execute("SELECT * FROM accounts WHERE id=?", (user["id"],)).fetchone()
            if not account or account["banned"] or account["deleted"]:
                raise HTTPException(403, "This account is unavailable")
            if account["country"] != user["country"]:
                raise HTTPException(409, "Your country changed. Refresh your profile and try again")
            original = complete_profile(db, user["id"]) if require_complete else db.execute("SELECT * FROM region.profiles WHERE id=?", (user["id"],)).fetchone()
            if not original:
                raise HTTPException(409, "Refresh your profile before updating location")
            same_location = destination == user["country"] and original["city"] == body.city and original["latitude"] == body.latitude and original["longitude"] == body.longitude
            if same_location and account["location_mode"] == body.mode:
                return profile_for(db, user["id"])
            if not same_location:
                # One update per foreground minute is supported. Repeated exact readings do not
                # consume this budget or rewrite storage; GPS attestation is deliberately not claimed.
                throttle(f"location-update:{user['id']}", 60, 3600)
                if destination != user["country"]:
                    throttle(f"travel:{user['id']}", 10, 3600)
            if destination == user["country"]:
                if not same_location:
                    db.execute("UPDATE region.profiles SET city=?,latitude=?,longitude=? WHERE id=?", (body.city, body.latitude, body.longitude, user["id"]))
                db.execute("UPDATE accounts SET location_mode=? WHERE id=?", (body.mode, user["id"]))
                return profile_for(db, user["id"])
            # Only current source health/name fields travel. Destination location is supplied as
            # a validated complete group, replacing any obsolete destination profile atomically.
            db.execute("INSERT OR REPLACE INTO destination.profiles(id,display_name,blood_type,height_cm,weight_kg,city,latitude,longitude) VALUES(?,?,?,?,?,?,?,?)", (user["id"], original["display_name"], original["blood_type"], original["height_cm"], original["weight_kg"], body.city, body.latitude, body.longitude))
            db.execute("DELETE FROM destination.profile_photos WHERE user_id=?", (user["id"],))
            db.execute("INSERT INTO destination.profile_photos SELECT * FROM region.profile_photos WHERE user_id=?", (user["id"],))
            db.execute("DELETE FROM region.profile_photos WHERE user_id=?", (user["id"],))
            db.execute("DELETE FROM region.profiles WHERE id=?", (user["id"],))
            db.execute("UPDATE accounts SET country=?,location_mode=? WHERE id=?", (destination, body.mode, user["id"]))
            expire_requests(db, user["country"])
            end_matching_calls(db, "caller_id=? OR callee_id=?", (user["id"], user["id"]))
            # Capture one coherent result before unlocking; another location update may follow.
            return profile_for(db, user["id"], "destination")

    @api.post(f"{PREFIX}/location")
    def location(body: LocationInput, user: dict = Depends(current_user)):
        """Native clients obtain location permission/consent; incomplete new profiles may locate first."""
        return save_location(body, user)

    @api.post(f"{PREFIX}/travel")
    def travel(body: TravelInput, user: dict = Depends(current_user)):
        """Preserve the consent-based legacy travel endpoint and select manual location mode."""
        return save_location(LocationInput(country=body.country, city=body.city, latitude=body.latitude, longitude=body.longitude, mode="manual"), user, require_complete=True)

    @api.get(f"{PREFIX}/donors")
    def donors(blood_type: str, radius_km: float = Query(ge=1, le=39, allow_inf_nan=False), latitude: float = Query(ge=-90, le=90, allow_inf_nan=False), longitude: float = Query(ge=-180, le=180, allow_inf_nan=False), user: dict = Depends(current_user)):
        """Filter on exact server coordinates, but expose only distance bands and fixed map areas."""
        if blood_type not in GROUPS:
            raise HTTPException(422, "Select a valid blood group")
        throttle(f"search:{user['id']}", 30, 60)
        with store.connect(user["country"]) as db:
            own = complete_profile(db, user["id"])
            # Queries must originate near the saved location to reduce arbitrary location probing.
            if km_between(own["latitude"], own["longitude"], latitude, longitude) > 1:
                raise HTTPException(409, "Update your profile location before searching this area")
            rows = db.execute("SELECT p.*,a.country,a.available,a.eligible_after,a.eligible_after_utc,a.banned,a.deleted FROM region.profiles p JOIN accounts a ON a.id=p.id WHERE p.blood_type=? AND p.id<>? AND a.country=?", (blood_type, user["id"], user["country"])).fetchall()
            results = []
            for row in rows:
                if not available(row) or row["latitude"] is None or row["longitude"] is None or relationship_blocked(db, user["id"], row["id"]):
                    continue
                distance = km_between(latitude, longitude, row["latitude"], row["longitude"])
                if distance <= radius_km:
                    band = min(39, max(5, math.ceil(distance / 5) * 5))
                    results.append((distance, {"id": row["id"], "display_name": row["display_name"], "blood_type": row["blood_type"], "city": row["city"], "distance_band": f"Within {band} km", "map_area": coarse_map_area(row["latitude"], row["longitude"])}))
            return {"items": [row for _, row in sorted(results, key=lambda item: item[0])[:50]]}

    @api.put(f"{PREFIX}/me/photo")
    async def upload_photo(request: Request, user: dict = Depends(current_user)):
        """Decode a bounded real image, orient/resize it, and encode fresh pixels without metadata."""
        if request.headers.get("content-type", "").split(";")[0] not in {"image/jpeg", "image/png"}:
            raise HTTPException(415, "Upload a JPEG or PNG photo")
        throttle(f"photo:{user['id']}", 10, 3600)
        jpeg = sanitized_image(await request.body(), 512)
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            account = db.execute("SELECT * FROM accounts WHERE id=?", (user["id"],)).fetchone()
            if account["country"] != user["country"] or account["banned"] or account["deleted"]:
                raise HTTPException(409, "Your account changed. Refresh your profile")
            db.execute("INSERT OR REPLACE INTO region.profile_photos VALUES(?,?,?)", (user["id"], jpeg, stamp()))
        return {"has_photo": True}

    @api.delete(f"{PREFIX}/me/photo")
    def delete_photo(user: dict = Depends(current_user)):
        with store.connect(user["country"]) as db:
            db.execute("DELETE FROM region.profile_photos WHERE user_id=?", (user["id"],))
        return {"has_photo": False}

    @api.get(f"{PREFIX}/profiles/{{uid}}/photo")
    def photo(uid: str, user: dict = Depends(current_user)):
        """A guessed identifier or old match must never expose a private photo."""
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            expire_requests(db, user["country"])
            if uid != user["id"]:
                accepted = db.execute("SELECT 1 FROM region.donation_requests WHERE status='accepted' AND ((requester_id=? AND accepted_donor_id=?) OR (requester_id=? AND accepted_donor_id=?))", (uid, user["id"], user["id"], uid)).fetchone()
                if not accepted or relationship_blocked(db, uid, user["id"]):
                    raise HTTPException(404, "Photo not available")
            row = db.execute("SELECT jpeg FROM region.profile_photos WHERE user_id=?", (uid,)).fetchone()
            if not row:
                raise HTTPException(404, "Photo not available")
            return Response(content=row["jpeg"], media_type="image/jpeg", headers={"Cache-Control": "no-store"})

    @api.post(f"{PREFIX}/requests")
    def create_request(body: DonationRequestInput, user: dict = Depends(current_user)):
        """Invite only currently eligible nearby donors; creation and notifications share a transaction."""
        if body.blood_type not in GROUPS:
            raise HTTPException(422, "Select a valid blood group")
        throttle(f"request:{user['id']}", 10, 3600)
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            expire_requests(db, user["country"])
            own = complete_profile(db, user["id"])
            account = db.execute("SELECT * FROM accounts WHERE id=?", (user["id"],)).fetchone()
            if account["country"] != user["country"] or account["banned"] or account["deleted"]:
                raise HTTPException(403, "This account is unavailable")
            if db.execute("SELECT 1 FROM region.donation_requests WHERE requester_id=? AND status IN ('open','accepted')", (user["id"],)).fetchone() or db.execute("SELECT 1 FROM active_matches WHERE donor_id=? OR requester_id=?", (user["id"], user["id"])).fetchone():
                raise HTTPException(409, "Complete or cancel your current request first")
            requested = set(body.donor_ids) if body.donor_ids else None
            candidates = db.execute("SELECT p.*,a.country,a.available,a.eligible_after,a.eligible_after_utc,a.banned,a.deleted FROM region.profiles p JOIN accounts a ON a.id=p.id WHERE p.blood_type=? AND p.id<>? AND a.country=?", (body.blood_type, user["id"], user["country"])).fetchall()
            donors = []
            for donor in candidates:
                if requested is not None and donor["id"] not in requested:
                    continue
                if not available(donor) or donor["height_cm"] is None or donor["weight_kg"] is None or donor["latitude"] is None or donor["longitude"] is None or relationship_blocked(db, user["id"], donor["id"]):
                    continue
                if db.execute("SELECT 1 FROM active_matches WHERE donor_id=? OR requester_id=?", (donor["id"], donor["id"])).fetchone():
                    continue
                distance = km_between(own["latitude"], own["longitude"], donor["latitude"], donor["longitude"])
                if distance <= body.radius_km:
                    donors.append((distance, donor))
            donors = [donor for _, donor in sorted(donors, key=lambda item: item[0])[:50]]
            if requested is not None and requested != {donor["id"] for donor in donors}:
                raise HTTPException(409, "A selected donor is no longer eligible nearby. Refresh your search")
            if not donors:
                raise HTTPException(409, "No eligible donors are available within this radius")
            rid = str(uuid4())
            db.execute("INSERT INTO region.donation_requests(id,requester_id,blood_type,radius_km,destination_name,destination_latitude,destination_longitude,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?)", (rid, user["id"], body.blood_type, body.radius_km, body.destination_name, body.destination_latitude, body.destination_longitude, stamp(), (utcnow() + timedelta(hours=24)).isoformat()))
            for donor in donors:
                db.execute("INSERT INTO region.request_invitations(request_id,donor_id) VALUES(?,?)", (rid, donor["id"]))
                emit_event(db, donor["id"], "donation_request", "A nearby donation request", f"{donor['display_name']}, someone nearby is looking for a voluntary blood donor. Open the request to respond.", rid)
            return request_result(db, rid, user["id"])

    @api.get(f"{PREFIX}/requests")
    def requests(user: dict = Depends(current_user)):
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            expire_requests(db, user["country"])
            rows = db.execute("SELECT id FROM region.donation_requests WHERE requester_id=? OR id IN (SELECT request_id FROM region.request_invitations WHERE donor_id=?) ORDER BY created_at DESC LIMIT 100", (user["id"], user["id"])).fetchall()
            return {"items": [request_result(db, row["id"], user["id"]) for row in rows]}

    @api.get(f"{PREFIX}/requests/{{rid}}")
    def get_request(rid: str, user: dict = Depends(current_user)):
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            expire_requests(db, user["country"])
            return request_result(db, rid, user["id"])

    @api.post(f"{PREFIX}/requests/{{rid}}/accept")
    def accept_request(rid: str, user: dict = Depends(current_user)):
        """An immediate SQLite transaction makes acceptance one-winner even for simultaneous taps."""
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            expire_requests(db, user["country"])
            visible = request_result(db, rid, user["id"])
            request = db.execute("SELECT * FROM region.donation_requests WHERE id=?", (rid,)).fetchone()
            if request["status"] == "accepted" and request["accepted_donor_id"] == user["id"]:
                return visible
            if request["status"] != "open" or visible["invitation_status"] != "invited":
                raise HTTPException(409, "This request is no longer available to accept")
            donor = complete_profile(db, user["id"])
            owner = complete_profile(db, request["requester_id"])
            account = db.execute("SELECT * FROM accounts WHERE id=?", (user["id"],)).fetchone()
            if not available(account) or account["country"] != user["country"] or donor["blood_type"] != request["blood_type"] or relationship_blocked(db, user["id"], request["requester_id"]) or km_between(owner["latitude"], owner["longitude"], donor["latitude"], donor["longitude"]) > request["radius_km"]:
                raise HTTPException(409, "You are no longer eligible for this nearby request")
            if db.execute("SELECT 1 FROM active_matches WHERE donor_id IN (?,?) OR requester_id IN (?,?)", (user["id"], request["requester_id"], user["id"], request["requester_id"])).fetchone() or db.execute("SELECT 1 FROM region.donation_requests WHERE requester_id=? AND status IN ('open','accepted')", (user["id"],)).fetchone():
                raise HTTPException(409, "Complete or cancel your current request first")
            a, b = sorted([user["id"], request["requester_id"]])
            existing = db.execute("SELECT id FROM region.conversations WHERE user_a=? AND user_b=?", (a, b)).fetchone()
            conversation = existing["id"] if existing else str(uuid4())
            if not existing:
                db.execute("INSERT INTO region.conversations VALUES(?,?,?,?)", (conversation, a, b, stamp()))
            others = db.execute("SELECT i.donor_id,p.display_name FROM region.request_invitations i JOIN region.profiles p ON p.id=i.donor_id WHERE i.request_id=? AND i.status='invited' AND i.donor_id<>?", (rid, user["id"])).fetchall()
            db.execute("INSERT INTO active_matches VALUES(?,?,?,?)", (user["id"], request["requester_id"], rid, user["country"]))
            db.execute("UPDATE region.donation_requests SET status='accepted',accepted_donor_id=?,conversation_id=? WHERE id=?", (user["id"], conversation, rid))
            db.execute("UPDATE region.request_invitations SET status=CASE WHEN donor_id=? THEN 'accepted' ELSE 'closed' END WHERE request_id=? AND status='invited'", (user["id"], rid))
            emit_event(db, request["requester_id"], "request_accepted", "Your donation request was accepted", f"{donor['display_name']} accepted your request. You can now see your shared meeting place and private profile photos.", rid)
            for other in others:
                other_account = db.execute("SELECT * FROM accounts WHERE id=?", (other["donor_id"],)).fetchone()
                if available(other_account) and other_account["country"] == user["country"] and not relationship_blocked(db, other["donor_id"], request["requester_id"]):
                    emit_event(db, other["donor_id"], "thank_you", "Thank you for being willing to help", f"Thank you, {other['display_name']}. Another donor has accepted this request. Your willingness to help makes a difference.", rid)
            return request_result(db, rid, user["id"])

    @api.post(f"{PREFIX}/requests/{{rid}}/decline")
    def decline_request(rid: str, user: dict = Depends(current_user)):
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            expire_requests(db, user["country"])
            current = request_result(db, rid, user["id"])
            if current["status"] != "open" or current["invitation_status"] not in {"invited", "declined"}:
                raise HTTPException(409, "This invitation is no longer available")
            db.execute("UPDATE region.request_invitations SET status='declined' WHERE request_id=? AND donor_id=?", (rid, user["id"]))
            return request_result(db, rid, user["id"])

    def finish_request(rid: str, user: dict, status: str):
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            expire_requests(db, user["country"])
            request = request_result(db, rid, user["id"])
            original = db.execute("SELECT * FROM region.donation_requests WHERE id=?", (rid,)).fetchone()
            if not request["is_requester"] and original["accepted_donor_id"] != user["id"]:
                raise HTTPException(403, "Only matched participants can close this request")
            if request["status"] == status:
                return request
            if request["status"] not in ({"open", "accepted"} if status == "cancelled" else {"accepted"}):
                raise HTTPException(409, "This request cannot be closed in that state")
            close_request(db, rid, status)
            if status == "completed":
                # Completion is coordination, not proof of donation. Both participants receive
                # independent prompts that survive travel; never copy donor GPS into history.
                donor = db.execute("SELECT display_name FROM region.profiles WHERE id=?", (original["accepted_donor_id"],)).fetchone()
                db.execute("INSERT OR IGNORE INTO donation_confirmations(request_id,user_id,requester_id,donor_name,facility_name,country,created_at) VALUES(?,?,?,?,?,?,?)", (rid, original["accepted_donor_id"], original["requester_id"], donor["display_name"] if donor else "Donor", original["destination_name"], user["country"], stamp()))
            peer = request["peer_id"]
            if peer:
                emit_event(db, peer, "request_closed", "Donation request updated", f"Your shared donation request was {status}. Profile-photo access has ended.", rid)
            return request_result(db, rid, user["id"])

    @api.post(f"{PREFIX}/requests/{{rid}}/cancel")
    def cancel_request(rid: str, user: dict = Depends(current_user)):
        return finish_request(rid, user, "cancelled")

    @api.post(f"{PREFIX}/requests/{{rid}}/complete")
    def complete_request(rid: str, user: dict = Depends(current_user)):
        """Closing a coordination request does not claim a clinical donation occurred."""
        return finish_request(rid, user, "completed")

    @api.get(f"{PREFIX}/events")
    def events(after: int | None = Query(default=None, ge=0), country: str | None = Query(default=None, min_length=2, max_length=2), user: dict = Depends(current_user)):
        """Default inbox includes old-country report outcomes; numeric cursors are explicitly regional."""
        cursor_country = stored_country(country, user)
        countries = [cursor_country] if country is not None or after is not None else sorted(path.stem for path in store.directory.glob("??.sqlite3") if path.stem in COUNTRIES)
        items, next_after = [], after or 0
        for code in countries:
            with store.connect(code) as db:
                db.execute("BEGIN IMMEDIATE")
                expire_requests(db, code)
                regional_items = []
                cursor = after if after is not None else 9223372036854775807
                newest_seen = after or 0
                direction, order = (">", "ASC") if after is not None else ("<", "DESC")
                # Scan further batches so obsolete requests cannot hide a new eligible report outcome.
                while len(regional_items) < 100:
                    rows = db.execute(f"SELECT * FROM region.events WHERE user_id=? AND id{direction}? ORDER BY id {order} LIMIT 100", (user["id"], cursor)).fetchall()
                    if not rows:
                        break
                    for row in rows:
                        cursor = row["id"]
                        newest_seen = max(newest_seen, cursor)
                        if event_allowed(db, row, code):
                            regional_items.append({"id": str(row["id"]), "country": code, "kind": row["kind"], "title": row["title"], "body": row["body"], "request_id": row["request_id"] or None, "report_id": row["report_id"], "report_country": row["report_country"], "created_at": row["created_at"], "read": bool(row["read"])})
                        if len(regional_items) == 100:
                            break
                items.extend(regional_items)
                if code == cursor_country:
                    next_after = newest_seen
        if after is None:
            items.sort(key=lambda item: (item["created_at"], item["country"], int(item["id"])), reverse=True)
        return {"items": items[:100], "next_after": str(next_after), "cursor_country": cursor_country}

    @api.post(f"{PREFIX}/events/{{event_id}}/read")
    def read_event(event_id: int, country: str | None = Query(default=None, min_length=2, max_length=2), user: dict = Depends(current_user)):
        with store.connect(stored_country(country, user)) as db:
            result = db.execute("UPDATE region.events SET read=1 WHERE id=? AND user_id=?", (event_id, user["id"]))
            if not result.rowcount:
                raise HTTPException(404, "Notification not found")
        return {"status": "read"}

    @api.post(f"{PREFIX}/devices")
    def register_device(body: DeviceInput, user: dict = Depends(current_user)):
        """Authenticated opt-in enrolls a device; it never registers a new user account."""
        throttle(f"device:{user['id']}", 20, 3600)
        try:
            if body.provider == "unifiedpush":
                validate_endpoint(body.token, settings.push_origins, settings.demo)
                validate_keys(body.pub_key or "", body.auth or "")
            elif not valid_apns_token(body.token):
                raise ValueError("Invalid APNs device token")
        except ValueError as error:
            raise HTTPException(422, str(error)) from None
        with store.connect() as db:
            existing = db.execute("SELECT id,user_id FROM devices WHERE token=?", (body.token,)).fetchone()
            if existing and existing["user_id"] != user["id"]:
                raise HTTPException(409, "This device is already registered to another account. Sign out there first")
            if not existing and db.execute("SELECT COUNT(*) FROM devices WHERE user_id=?", (user["id"],)).fetchone()[0] >= 5:
                raise HTTPException(409, "Remove an old device before registering another")
            did = existing["id"] if existing else str(uuid4())
            db.execute("INSERT OR REPLACE INTO devices VALUES(?,?,?,?,?,?,?)", (did, user["id"], body.provider, body.token, body.pub_key, body.auth, stamp()))
            return {"id": did, "provider": body.provider, "status": "registered"}

    @api.delete(f"{PREFIX}/devices")
    def remove_device(body: DeviceRemovalInput, user: dict = Depends(current_user)):
        with store.connect() as db:
            db.execute("DELETE FROM devices WHERE token=? AND user_id=?", (body.token, user["id"]))
        return {"status": "removed"}

    @api.get(f"{PREFIX}/donations")
    def donation_history(user: dict = Depends(current_user)):
        """Only the authenticated owner can read their global history, regardless of travel."""
        with store.connect() as db:
            return {"items": [dict(row) for row in db.execute("SELECT id,donated_at,facility_name,location_name,country,request_id,created_at,confirmed_by_role FROM donations WHERE user_id=? ORDER BY donated_at DESC,created_at DESC,id", (user["id"],))]}

    @api.get(f"{PREFIX}/donation-confirmations")
    def donation_confirmations(user: dict = Depends(current_user)):
        """Each participant can answer independently; a No never suppresses the other person's Yes."""
        with store.connect() as db:
            rows = db.execute("SELECT request_id,facility_name,location_name,country,created_at,donor_name,user_id FROM donation_confirmations WHERE status='pending' AND ((user_id=? AND donor_dismissed=0) OR (requester_id=? AND seeker_dismissed=0)) ORDER BY created_at,request_id", (user["id"], user["id"]))
            return {"items": [{**{key: row[key] for key in ("request_id", "facility_name", "location_name", "country", "created_at")}, "donor_name": row["donor_name"] or "Donor", "is_donor": row["user_id"] == user["id"]} for row in rows]}

    @api.post(f"{PREFIX}/donation-confirmations/{{rid}}/dismiss")
    def dismiss_donation_confirmation(rid: str, user: dict = Depends(current_user)):
        """A no-donation answer removes the prompt without recording history or starting cooldown."""
        with store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT status,user_id FROM donation_confirmations WHERE request_id=? AND (user_id=? OR requester_id=?)", (rid, user["id"], user["id"])).fetchone()
            if not row:
                raise HTTPException(404, "Donation confirmation not found")
            if row["status"] == "recorded":
                raise HTTPException(409, "This donation has already been recorded")
            column = "donor_dismissed" if row["user_id"] == user["id"] else "seeker_dismissed"
            db.execute(f"UPDATE donation_confirmations SET {column}=1 WHERE request_id=?", (rid,))
        return {"status": "dismissed"}

    @api.post(f"{PREFIX}/donations")
    def donation(body: DonationInput, user: dict = Depends(current_user)):
        """A new log can extend but never shorten the global cooldown, including during travel."""
        local_zone = timezone(timedelta(minutes=body.utc_offset_minutes))
        if body.donated_at > utcnow().astimezone(local_zone).date():
            raise HTTPException(422, "Donation date cannot be in the future")
        throttle(f"donation:{user['id']}", 10, 3600)
        until_day = add_three_months(body.donated_at)
        # The app uses calendar-day pauses, ending at midnight in the supplied local offset.
        # Store the absolute UTC instant so western timezones do not reappear early at UTC midnight.
        until_instant = datetime(until_day.year, until_day.month, until_day.day, tzinfo=local_zone).astimezone(timezone.utc)
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            complete_profile(db, user["id"])
            caller = db.execute("SELECT * FROM accounts WHERE id=?", (user["id"],)).fetchone()
            if caller["banned"] or caller["deleted"] or caller["country"] != user["country"]:
                raise HTTPException(403, "This account is unavailable")
            donor_id = user["id"]
            if body.request_id:
                # The server's completed-match receipt establishes both participants even after travel.
                confirmation = db.execute("SELECT * FROM donation_confirmations WHERE request_id=? AND (user_id=? OR requester_id=?)", (body.request_id, user["id"], user["id"])).fetchone()
                if not confirmation:
                    raise HTTPException(404, "Donation confirmation not found")
                donor_id = confirmation["user_id"]
            account = db.execute("SELECT * FROM accounts WHERE id=?", (donor_id,)).fetchone()
            if not account or account["deleted"]:
                raise HTTPException(409, "The donor account is no longer available")
            if body.idempotency_key:
                # A response may be lost after commit. The same owner intent must not create
                # another medical-history entry; changed details require a deliberately new intent.
                existing = db.execute("SELECT * FROM donations WHERE confirmed_by=? AND idempotency_key=?", (user["id"], body.idempotency_key)).fetchone()
                if existing:
                    expected = {"donated_at": body.donated_at.isoformat(), "facility_name": body.facility_name, "location_name": body.location_name, "country": body.country, "request_id": body.request_id}
                    if any(existing[key] != value for key, value in expected.items()):
                        raise HTTPException(409, "This save was already recorded with different details. Review your donation history before starting a new entry")
                    return profile_for(db, user["id"])
            if body.request_id:
                if db.execute("SELECT 1 FROM donations WHERE request_id=?", (body.request_id,)).fetchone():
                    return profile_for(db, user["id"])
            previous = cooldown_deadline(account)
            role = "donor" if donor_id == user["id"] else "seeker"
            db.execute("INSERT INTO donations(id,user_id,donated_at,created_at,facility_name,location_name,country,request_id,idempotency_key,confirmed_by,confirmed_by_role) VALUES(?,?,?,?,?,?,?,?,?,?,?)", (str(uuid4()), donor_id, body.donated_at.isoformat(), stamp(), body.facility_name, body.location_name, body.country, body.request_id, body.idempotency_key, user["id"], role))
            if body.request_id:
                db.execute("UPDATE donation_confirmations SET status='recorded' WHERE request_id=?", (body.request_id,))
            if previous is None or until_instant > previous:
                display_day = max(account["eligible_after"] or "", until_day.isoformat())
                db.execute("UPDATE accounts SET eligible_after=?,eligible_after_utc=? WHERE id=?", (display_day, until_instant.isoformat(), donor_id))
            # A seeker receives only their own profile; donor measurements/cooldown never leak here.
            return profile_for(db, user["id"])

    @api.get(f"{PREFIX}/conversations")
    def conversations(user: dict = Depends(current_user)):
        """Only current regional conversations and participant-safe summaries are listed."""
        with store.connect(user["country"]) as db:
            rows = db.execute("SELECT * FROM region.conversations WHERE user_a=? OR user_b=? ORDER BY updated_at DESC LIMIT 100", (user["id"], user["id"])).fetchall()
            items = []
            for row in rows:
                peer = row["user_b"] if row["user_a"] == user["id"] else row["user_a"]
                person = db.execute("SELECT display_name,blood_type FROM region.profiles WHERE id=?", (peer,)).fetchone()
                last = db.execute("SELECT body FROM region.messages WHERE conversation_id=? ORDER BY created_at DESC LIMIT 1", (row["id"],)).fetchone()
                items.append({"id": row["id"], "peer_id": peer, "peer_name": person["display_name"] if person else "Unavailable member", "blood_type": person["blood_type"] if person else None, "last_message": last["body"] if last else "", "updated_at": row["updated_at"], "is_blocked": relationship_blocked(db, user["id"], peer)})
            return {"items": items}

    @api.post(f"{PREFIX}/conversations")
    def start_conversation(body: ConversationInput, user: dict = Depends(current_user)):
        """Creating an object by ID cannot bypass search distance or availability rules."""
        throttle(f"contact:{user['id']}", 15, 3600)
        with store.connect(user["country"]) as db:
            own = complete_profile(db, user["id"])
            row = db.execute("SELECT p.*,a.country,a.available,a.eligible_after,a.eligible_after_utc,a.banned,a.deleted FROM region.profiles p JOIN accounts a ON p.id=a.id WHERE p.id=?", (body.donor_id,)).fetchone()
            if not row or row["id"] == user["id"] or row["country"] != user["country"] or not available(row) or row["latitude"] is None or row["longitude"] is None or relationship_blocked(db, user["id"], body.donor_id) or km_between(own["latitude"], own["longitude"], row["latitude"], row["longitude"]) > 39:
                raise HTTPException(404, "This donor is not available nearby")
            a, b = sorted([user["id"], body.donor_id])
            existing = db.execute("SELECT id FROM region.conversations WHERE user_a=? AND user_b=?", (a, b)).fetchone()
            cid = existing["id"] if existing else str(uuid4())
            if not existing:
                db.execute("INSERT INTO region.conversations VALUES(?,?,?,?)", (cid, a, b, stamp()))
            return {"id": cid, "peer_id": body.donor_id, "peer_name": row["display_name"], "blood_type": row["blood_type"]}

    @api.get(f"{PREFIX}/conversations/{{cid}}/messages")
    def messages(cid: str, user: dict = Depends(current_user)):
        with store.connect(user["country"]) as db:
            conversation_peer(db, cid, user["id"])
            rows = db.execute("SELECT id,sender_id,body,created_at FROM (SELECT * FROM region.messages WHERE conversation_id=? ORDER BY created_at DESC LIMIT 200) ORDER BY created_at", (cid,)).fetchall()
            return {"items": [dict(row) for row in rows]}

    @api.post(f"{PREFIX}/conversations/{{cid}}/messages")
    def send_message(cid: str, body: MessageInput, user: dict = Depends(current_user)):
        """Persist messages only between allowed participants; no external notifications are sent."""
        throttle(f"message:{user['id']}", 60, 60)
        with store.connect(user["country"]) as db:
            conversation_peer(db, cid, user["id"], writable=True)
            message = {"id": str(uuid4()), "sender_id": user["id"], "body": body.body, "created_at": stamp()}
            db.execute("INSERT INTO region.messages VALUES(?,?,?,?,?)", (message["id"], cid, user["id"], body.body, message["created_at"]))
            db.execute("UPDATE region.conversations SET updated_at=? WHERE id=?", (message["created_at"], cid))
            return message

    def report_explanation(status: str) -> str | None:
        """Fixed public outcomes never copy the administrator's confidential reasoning."""
        if status == "banned":
            return "Your report was reviewed. Action was taken for a confirmed request for money."
        if status == "dismissed":
            return "Your report was reviewed. No account action was taken from this report."
        return None

    def owner_report(db: sqlite3.Connection, row: sqlite3.Row, country: str) -> dict:
        """Project only the reporter's submission, attachments, and safe review outcome."""
        return {"id": row["id"], "country": country, "request_id": row["request_id"], "reason": row["reason"], "details": row["details"], "status": "pending" if row["status"] == "pending" else "reviewed", "outcome": None if row["status"] == "pending" else row["status"], "submitted_at": row["created_at"], "reviewed_at": row["reviewed_at"], "outcome_explanation": report_explanation(row["status"]), "attachments": attachment_metadata(db, row["id"])}

    @api.get(f"{PREFIX}/reports")
    def own_reports(user: dict = Depends(current_user)):
        """Bound private cross-country history without exposing reports submitted by anybody else."""
        items = []
        for path in store.directory.glob("??.sqlite3"):
            if path.stem not in COUNTRIES:
                continue
            with store.connect(path.stem) as db:
                rows = db.execute("SELECT * FROM region.reports WHERE reporter_id=? ORDER BY created_at DESC,id DESC LIMIT 100", (user["id"],)).fetchall()
                items.extend(owner_report(db, row, path.stem) for row in rows)
            items.sort(key=lambda item: (item["submitted_at"], item["country"], item["id"]), reverse=True)
            items = items[:100]
        return {"items": items}

    @api.get(f"{PREFIX}/reports/{{rid}}")
    def own_report(rid: str, country: str | None = Query(default=None, min_length=2, max_length=2), user: dict = Depends(current_user)):
        code = stored_country(country, user)
        with store.connect(code) as db:
            row = db.execute("SELECT * FROM region.reports WHERE id=? AND reporter_id=?", (rid, user["id"])).fetchone()
            if not row:
                raise HTTPException(404, "Report not found")
            return owner_report(db, row, code)

    @api.post(f"{PREFIX}/reports")
    def report(body: ReportInput, user: dict = Depends(current_user)):
        """Snapshot limited evidence for admin review; a report alone must never ban someone."""
        if bool(body.conversation_id) == bool(body.request_id):
            raise HTTPException(422, "Choose one conversation or donation request to report")
        throttle(f"report:{user['id']}", 10, 3600)
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            account = db.execute("SELECT country,banned,deleted FROM accounts WHERE id=?", (user["id"],)).fetchone()
            if account["banned"] or account["deleted"] or account["country"] != user["country"]:
                raise HTTPException(403, "This account is unavailable")
            conversation_id = body.conversation_id
            if body.request_id:
                matched = db.execute("SELECT * FROM region.donation_requests WHERE id=? AND accepted_donor_id IS NOT NULL AND (requester_id=? OR accepted_donor_id=?)", (body.request_id, user["id"], user["id"])).fetchone()
                if not matched:
                    raise HTTPException(404, "Matched donation request not found")
                peer = matched["accepted_donor_id"] if matched["requester_id"] == user["id"] else matched["requester_id"]
                conversation_id = matched["conversation_id"]
            else:
                # Reporting intentionally uses read membership, so blocking never silences misconduct reports.
                peer = conversation_peer(db, conversation_id, user["id"])
            if body.idempotency_key:
                existing = db.execute("SELECT * FROM region.reports WHERE reporter_id=? AND idempotency_key=?", (user["id"], body.idempotency_key)).fetchone()
                if existing:
                    if any(existing[key] != value for key, value in {"conversation_id": conversation_id, "request_id": body.request_id, "reason": body.reason, "details": body.details}.items()):
                        raise HTTPException(409, "This report was already submitted with different details")
                    return {"id": existing["id"], "status": existing["status"]}
            evidence = [dict(row) for row in db.execute("SELECT sender_id,body,created_at FROM region.messages WHERE conversation_id=? ORDER BY created_at DESC LIMIT 20", (conversation_id,)).fetchall()]
            rid = str(uuid4())
            db.execute("INSERT INTO region.reports(id,reporter_id,reported_id,conversation_id,reason,details,status,evidence,created_at,request_id,idempotency_key) VALUES(?,?,?,?,?,?,?,?,?,?,?)", (rid, user["id"], peer, conversation_id, body.reason, body.details, "pending", json.dumps(evidence), stamp(), body.request_id, body.idempotency_key))
            return {"id": rid, "status": "pending"}

    def attachment_metadata(db: sqlite3.Connection, rid: str) -> list[dict]:
        return [{**dict(row), "content_type": "image/jpeg"} for row in db.execute("SELECT id,created_at FROM region.report_attachments WHERE report_id=? ORDER BY created_at,id", (rid,))]

    @api.post(f"{PREFIX}/reports/{{rid}}/evidence")
    async def upload_report_evidence(rid: str, request: Request, user: dict = Depends(current_user)):
        """Reporter-only, bounded, metadata-free images remain private regional moderation evidence."""
        with store.connect(user["country"]) as db:
            own = db.execute("SELECT status FROM region.reports WHERE id=? AND reporter_id=?", (rid, user["id"])).fetchone()
            if not own:
                raise HTTPException(404, "Report not found")
            if own["status"] != "pending":
                raise HTTPException(409, "Reviewed report evidence cannot be changed")
        if request.headers.get("content-type", "").split(";")[0] not in {"image/jpeg", "image/png"}:
            raise HTTPException(415, "Upload a JPEG or PNG image")
        throttle(f"report-photo:{user['id']}", 30, 3600)
        raw = await request.body()
        digest = hashlib.sha256(raw).hexdigest()
        jpeg = sanitized_image(raw, 2048)
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            # Recheck after decoding: moderation/deletion may have raced the upload.
            own = db.execute("SELECT r.status,a.banned,a.deleted,a.country FROM region.reports r JOIN accounts a ON a.id=r.reporter_id WHERE r.id=? AND r.reporter_id=?", (rid, user["id"])).fetchone()
            if not own or own["banned"] or own["deleted"] or own["country"] != user["country"]:
                raise HTTPException(404, "Report not found")
            if own["status"] != "pending":
                raise HTTPException(409, "Reviewed report evidence cannot be changed")
            existing = db.execute("SELECT id,created_at FROM region.report_attachments WHERE report_id=? AND source_digest=?", (rid, digest)).fetchone()
            if existing:
                return {**dict(existing), "content_type": "image/jpeg"}
            if db.execute("SELECT COUNT(*) FROM region.report_attachments WHERE report_id=?", (rid,)).fetchone()[0] >= 3:
                raise HTTPException(409, "A report can have at most three evidence images")
            aid, created = str(uuid4()), stamp()
            db.execute("INSERT INTO region.report_attachments VALUES(?,?,?,?,?)", (aid, rid, jpeg, digest, created))
            return {"id": aid, "content_type": "image/jpeg", "created_at": created}

    def evidence_response(rid: str, aid: str, user: dict, admin: bool = False, country: str | None = None):
        with store.connect(user["country"] if admin else stored_country(country, user)) as db:
            report = db.execute("SELECT reporter_id,reported_id FROM region.reports WHERE id=?", (rid,)).fetchone()
            # An accused administrator cannot inspect their own allegation or its attachments.
            allowed = report and ((admin and report["reported_id"] != user["id"]) or (not admin and report["reporter_id"] == user["id"]))
            if not allowed:
                raise HTTPException(404, "Evidence not found")
            row = db.execute("SELECT jpeg FROM region.report_attachments WHERE id=? AND report_id=?", (aid, rid)).fetchone()
            if not row:
                raise HTTPException(404, "Evidence not found")
            return Response(content=row["jpeg"], media_type="image/jpeg", headers={"Cache-Control": "no-store"})

    @api.get(f"{PREFIX}/reports/{{rid}}/evidence/{{aid}}")
    def own_report_evidence(rid: str, aid: str, country: str | None = Query(default=None, min_length=2, max_length=2), user: dict = Depends(current_user)):
        return evidence_response(rid, aid, user, country=country)

    @api.get(f"{PREFIX}/admin/reports/{{rid}}/evidence/{{aid}}")
    def admin_report_evidence(rid: str, aid: str, user: dict = Depends(administrator)):
        return evidence_response(rid, aid, user, admin=True)

    @api.post(f"{PREFIX}/blocks")
    def block(body: BlockInput, user: dict = Depends(current_user)):
        """Require an existing relationship to avoid arbitrary ID probing through block writes."""
        with store.connect(user["country"]) as db:
            a, b = sorted([body.user_id, user["id"]])
            if body.user_id == user["id"] or not db.execute("SELECT 1 FROM region.conversations WHERE user_a=? AND user_b=?", (a, b)).fetchone():
                raise HTTPException(404, "Conversation peer not found")
            db.execute("INSERT OR IGNORE INTO blocks VALUES(?,?,?)", (user["id"], body.user_id, stamp()))
            end_matching_calls(db, "(caller_id=? AND callee_id=?) OR (caller_id=? AND callee_id=?)", (user["id"], body.user_id, body.user_id, user["id"]))
            return {"status": "blocked"}

    def livekit_credentials(call: sqlite3.Row, user: dict) -> dict:
        """Room-scoped, short-lived audio-only credentials avoid exposing API secrets or phone numbers."""
        now = utcnow()
        claims = {"iss": settings.livekit_key, "sub": user["id"], "nbf": int(now.timestamp()) - 5, "exp": int((now + timedelta(minutes=5)).timestamp()), "video": {"roomJoin": True, "room": f"blood-{call['id']}", "canPublish": True, "canSubscribe": True, "canPublishData": False, "canPublishSources": ["microphone"]}}
        return {"url": settings.livekit_url, "token": jwt.encode(claims, settings.livekit_secret, algorithm="HS256")}

    def authorized_call(db: sqlite3.Connection, call_id: str, user: dict) -> sqlite3.Row:
        """Call authorization rechecks the relationship, so bans/blocks stop token issuance."""
        call = db.execute("SELECT * FROM region.calls WHERE id=? AND (caller_id=? OR callee_id=?)", (call_id, user["id"], user["id"])).fetchone()
        if not call:
            raise HTTPException(404, "Call not found")
        conversation_peer(db, call["conversation_id"], user["id"], writable=True)
        if call["status"] in {"ringing", "accepted"} and call["expires_at"] <= stamp():
            end_matching_calls(db, "id=?", (call_id,))
            call = db.execute("SELECT * FROM region.calls WHERE id=?", (call_id,)).fetchone()
        return call

    @api.get(f"{PREFIX}/calls")
    def incoming_calls(user: dict = Depends(current_user)):
        """Cooldown and voluntary unavailability suppress incoming call invitations."""
        with store.connect(user["country"]) as db:
            account = db.execute("SELECT * FROM accounts WHERE id=?", (user["id"],)).fetchone()
            if not available(account):
                return {"items": []}
            rows = db.execute("SELECT c.*,p.display_name AS caller_name FROM region.calls c JOIN accounts a ON a.id=c.caller_id LEFT JOIN region.profiles p ON p.id=c.caller_id WHERE c.callee_id=? AND c.status='ringing' AND c.expires_at>? AND a.banned=0 AND a.deleted=0 AND a.country=?", (user["id"], stamp(), user["country"])).fetchall()
            return {"items": [{"id": row["id"], "conversation_id": row["conversation_id"], "caller_id": row["caller_id"], "caller_name": row["caller_name"] or "Member", "status": row["status"]} for row in rows if not relationship_blocked(db, user["id"], row["caller_id"])]}

    @api.post(f"{PREFIX}/conversations/{{cid}}/calls")
    def start_call(cid: str, user: dict = Depends(current_user)):
        """Never fake a connection when LiveKit is missing; only available peers may be rung."""
        if not settings.calling_enabled:
            raise HTTPException(503, "In-app calling is not configured yet")
        throttle(f"call:{user['id']}", 10, 3600)
        with store.connect(user["country"]) as db:
            peer = conversation_peer(db, cid, user["id"], writable=True)
            target = db.execute("SELECT * FROM accounts WHERE id=?", (peer,)).fetchone()
            if not available(target):
                raise HTTPException(409, "This member is not available for calls")
            end_matching_calls(db, "conversation_id=? AND expires_at<=?", (cid, stamp()))
            if db.execute("SELECT 1 FROM region.calls WHERE conversation_id=? AND status IN ('accepted','ringing') AND expires_at>?", (cid, stamp())).fetchone():
                raise HTTPException(409, "A call is already in progress")
            call_id = str(uuid4())
            db.execute("INSERT INTO region.calls VALUES(?,?,?,?,?,?,?)", (call_id, cid, user["id"], peer, "ringing", stamp(), (utcnow() + timedelta(seconds=60)).isoformat()))
            return {"id": call_id, "status": "ringing"}

    @api.post(f"{PREFIX}/calls/{{call_id}}/accept")
    def accept_call(call_id: str, user: dict = Depends(current_user)):
        with store.connect(user["country"]) as db:
            call = authorized_call(db, call_id, user)
            if call["callee_id"] != user["id"]:
                raise HTTPException(403, "Only the invited member can accept")
            account = db.execute("SELECT * FROM accounts WHERE id=?", (user["id"],)).fetchone()
            if not available(account) or call["status"] != "ringing":
                raise HTTPException(409, "This call is no longer available")
            db.execute("UPDATE region.calls SET status='accepted',expires_at=? WHERE id=?", ((utcnow() + timedelta(hours=1)).isoformat(), call_id))
            return {"id": call_id, **livekit_credentials(call, user)}

    @api.get(f"{PREFIX}/calls/{{call_id}}")
    def call_status(call_id: str, user: dict = Depends(current_user)):
        with store.connect(user["country"]) as db:
            call = authorized_call(db, call_id, user)
            result = {"id": call_id, "status": call["status"]}
            if call["status"] == "accepted":
                result.update(livekit_credentials(call, user))
            return result

    @api.post(f"{PREFIX}/calls/{{call_id}}/end")
    def end_call(call_id: str, user: dict = Depends(current_user)):
        with store.connect(user["country"]) as db:
            authorized_call(db, call_id, user)
            end_matching_calls(db, "id=?", (call_id,))
        cleanup_media(store, settings)
        return {"status": "ended"}

    @api.get(f"{PREFIX}/admin/reports")
    def admin_reports(user: dict = Depends(administrator)):
        """Evidence is disclosed solely to authenticated admins in the selected country."""
        with store.connect(user["country"]) as db:
            rows = db.execute("SELECT id,reporter_id,reported_id,reason,details,status,created_at,evidence,request_id,reviewed_at FROM region.reports WHERE reported_id<>? ORDER BY created_at DESC LIMIT 200", (user["id"],)).fetchall()
            return {"items": [{**dict(row), "evidence": json.loads(row["evidence"]), "attachments": attachment_metadata(db, row["id"])} for row in rows]}

    @api.post(f"{PREFIX}/admin/reports/{{report_id}}/resolve")
    def resolve_report(report_id: str, body: ResolutionInput, user: dict = Depends(administrator)):
        """A verified money request creates a permanent global ban and append-only audit record."""
        with store.connect(user["country"]) as db:
            db.execute("BEGIN IMMEDIATE")
            report = db.execute("SELECT * FROM region.reports WHERE id=?", (report_id,)).fetchone()
            if not report:
                raise HTTPException(404, "Report not found")
            if report["status"] != "pending":
                raise HTTPException(409, "This report has already been reviewed")
            if body.decision == "ban" and report["reason"] != "money_request":
                raise HTTPException(422, "Lifetime bans require a confirmed money request")
            if report["reported_id"] == user["id"]:
                raise HTTPException(403, "Another administrator must review a report about you")
            status = "banned" if body.decision == "ban" else "dismissed"
            if body.decision == "ban":
                db.execute("UPDATE accounts SET banned=1,available=0 WHERE id=?", (report["reported_id"],))
                end_matching_calls(db, "caller_id=? OR callee_id=?", (report["reported_id"], report["reported_id"]))
            reviewed_at = stamp()
            db.execute("UPDATE region.reports SET status=?,reviewed_at=? WHERE id=?", (status, reviewed_at, report_id))
            db.execute("INSERT INTO audit VALUES(?,?,?,?,?,?,?,?)", (str(uuid4()), user["id"], report["reported_id"], status, user["country"], report_id, body.note, stamp()))
            # Outcome + audit + inbox + per-device outbox either commit together or all roll back.
            emit_event(db, report["reporter_id"], "report_reviewed", "Your report was reviewed", "Open My reports to see the outcome of your report.", report_id=report_id, report_country=user["country"])
            return {"status": status}

    @api.get(f"{PREFIX}/admin/summary")
    def summary(user: dict = Depends(administrator)):
        with store.connect(user["country"]) as db:
            return {"pending_reports": db.execute("SELECT COUNT(*) FROM region.reports WHERE status='pending'").fetchone()[0], "banned_accounts": db.execute("SELECT COUNT(*) FROM accounts WHERE banned=1").fetchone()[0], "active_donors": sum(available(row) for row in db.execute("SELECT * FROM accounts WHERE country=?", (user["country"],)).fetchall()), "country": user["country"]}

    @api.get(f"{PREFIX}/me/export")
    def export_account(user: dict = Depends(current_user)):
        """Export only the owner's records; other participants' messages remain private to their data."""
        with store.connect(user["country"]) as db:
            result = {"profile": profile_for(db, user["id"]), "donations": [dict(row) for row in db.execute("SELECT id,donated_at,facility_name,location_name,country,request_id,created_at,confirmed_by_role FROM donations WHERE user_id=?", (user["id"],)).fetchall()], "donation_confirmations": [dict(row) for row in db.execute("SELECT request_id,facility_name,location_name,country,created_at,status FROM donation_confirmations WHERE user_id=? OR requester_id=?", (user["id"], user["id"])).fetchall()], "regions": []}
            own_photo = db.execute("SELECT jpeg FROM region.profile_photos WHERE user_id=?", (user["id"],)).fetchone()
            result["photo_jpeg_base64"] = base64.b64encode(own_photo["jpeg"]).decode() if own_photo else None
        for path in store.directory.glob("??.sqlite3"):
            if path.stem not in COUNTRIES:
                continue
            with store.connect(path.stem) as db:
                own_messages = [dict(row) for row in db.execute("SELECT id,conversation_id,body,created_at FROM region.messages WHERE sender_id=?", (user["id"],)).fetchall()]
                own_reports = [dict(row) for row in db.execute("SELECT id,reason,details,status,created_at,reviewed_at FROM region.reports WHERE reporter_id=?", (user["id"],)).fetchall()]
                for report in own_reports:
                    report["attachments"] = [{"id": row["id"], "created_at": row["created_at"], "content_type": "image/jpeg", "jpeg_base64": base64.b64encode(row["jpeg"]).decode()} for row in db.execute("SELECT id,created_at,jpeg FROM region.report_attachments WHERE report_id=?", (report["id"],))]
                if own_messages or own_reports:
                    result["regions"].append({"country": path.stem, "messages": own_messages, "reports": own_reports})
        return result

    @api.delete(f"{PREFIX}/me")
    def delete_account(user: dict = Depends(current_user)):
        """Tombstone identity first, then scrub regional personal data; preserve enforcement evidence.

        A tombstone rejects all old OAuth tokens and avoids silently recreating an account.
        A durable job retries interrupted erasure; retention policies still require launch review.
        """
        with store.connect() as db:
            db.execute("UPDATE accounts SET deleted=1,available=0 WHERE id=?", (user["id"],))
            db.execute("DELETE FROM donations WHERE user_id=?", (user["id"],))
            db.execute("DELETE FROM donation_confirmations WHERE user_id=?", (user["id"],))
            db.execute("DELETE FROM blocks WHERE blocker=? OR blocked=?", (user["id"], user["id"]))
            db.execute("DELETE FROM devices WHERE user_id=?", (user["id"],))
            db.execute("INSERT OR IGNORE INTO deletion_jobs VALUES(?,?)", (user["id"], stamp()))
        try:
            scrub_deleted_accounts(store)
        except (sqlite3.Error, OSError):
            # Access stays revoked while the durable worker retries filesystem/lock failures.
            return {"status": "deleted", "erasure_pending": True}
        return {"status": "deleted", "erasure_pending": False}

    # Keep administration same-origin so tokens need not cross a public third-party frontend.
    admin_path = Path(__file__).resolve().parent.parent / "admin"
    if admin_path.is_dir():
        api.mount("/admin", StaticFiles(directory=admin_path, html=True), name="admin")
    return api


# Uvicorn imports this instance; tests instantiate create_app with an isolated temporary directory.
app = create_app()
