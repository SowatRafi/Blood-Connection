"""Runnable local integration checks for privacy boundaries and critical donation workflows.

Run from repository root: python -m unittest backend.test_app -v
Every test uses disposable SQLite files; no test modifies a real account.
"""

from datetime import date, datetime, timedelta, timezone
import base64
import json
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
import jwt
from PIL import Image
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization
import http_ece

from backend.app import Settings, add_three_months, cleanup_media, coarse_map_area, create_app, km_between, process_push, scrub_deleted_accounts, utcnow
from backend.push import send_push


class ApiTests(unittest.TestCase):
    """Exercise endpoints rather than duplicating their implementation in tests."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(data_dir=Path(self.temp.name), demo=True)
        self.app = create_app(self.settings)
        self.client = TestClient(self.app)
        self.seeker = {"Authorization": "Bearer demo-seeker", "X-Country": "BD"}
        self.donor = {"Authorization": "Bearer demo-donor", "X-Country": "BD"}
        self.admin = {"Authorization": "Bearer demo-admin", "X-Country": "BD"}

    def tearDown(self):
        self.client.close()
        self.temp.cleanup()

    def get(self, path, headers=None, **kwargs):
        return self.client.get(f"/api/v1{path}", headers=headers or self.seeker, **kwargs)

    def post(self, path, body, headers=None):
        # Existing endpoint scenarios share a real donation-place fixture; validation tests bypass this helper.
        if path == "/donations":
            body = {"facility_name": "Demo Blood Bank", "location_name": "Dhaka", "country": "BD", **body}
        return self.client.post(f"/api/v1{path}", json=body, headers=headers or self.seeker)

    def search(self, **overrides):
        params = {"blood_type": "O+", "radius_km": 39, "latitude": 23.811, "longitude": 90.413}
        params.update(overrides)
        return self.get("/donors", params=params)

    def test_calendar_months_and_dateline(self):
        self.assertEqual(add_three_months(date(2023, 11, 30)), date(2024, 2, 29))
        self.assertEqual(add_three_months(date(2024, 11, 30)), date(2025, 2, 28))
        self.assertEqual(add_three_months(date(2026, 1, 31)), date(2026, 4, 30))
        self.assertLess(km_between(0, 179.99, 0, -179.99), 3)

    def test_donation_uses_local_today_and_absolute_cooldown_deadline(self):
        # Sydney's morning date is already tomorrow relative to UTC, so this is legitimate.
        with patch("backend.app.utcnow", return_value=datetime(2026, 11, 14, 22, 30, tzinfo=timezone.utc)):
            logged = self.post("/donations", {"donated_at": "2026-11-15", "utc_offset_minutes": 660}, self.donor)
            self.assertEqual(logged.status_code, 200, logged.text)
            self.assertEqual(logged.json()["eligible_after"], "2027-02-15")
            self.assertEqual(logged.json()["eligible_after_utc"], "2027-02-14T13:00:00+00:00")
            self.assertEqual(self.post("/donations", {"donated_at": "2026-11-16", "utc_offset_minutes": 660}, self.donor).status_code, 422)
            for offset in (-721, 841, 1.5, True):
                self.assertEqual(self.post("/donations", {"donated_at": "2026-11-14", "utc_offset_minutes": offset}, self.donor).status_code, 422)
        with patch("backend.app.utcnow", return_value=datetime(2027, 2, 14, 12, 59, tzinfo=timezone.utc)):
            self.assertFalse(self.get("/me", self.donor).json()["is_available"])
        with patch("backend.app.utcnow", return_value=datetime(2027, 2, 14, 13, 0, tzinfo=timezone.utc)):
            self.assertTrue(self.get("/me", self.donor).json()["is_available"])

    def test_western_offset_cannot_release_early_or_shorten_existing_pause(self):
        with patch("backend.app.utcnow", return_value=datetime(2026, 11, 15, 20, 0, tzinfo=timezone.utc)):
            logged = self.post("/donations", {"donated_at": "2026-11-15", "utc_offset_minutes": -480}, self.donor)
            self.assertEqual(logged.json()["eligible_after_utc"], "2027-02-15T08:00:00+00:00")
            shortened = self.post("/donations", {"donated_at": "2026-11-15", "utc_offset_minutes": 660}, self.donor)
            self.assertEqual(shortened.json()["eligible_after_utc"], logged.json()["eligible_after_utc"])
        with patch("backend.app.utcnow", return_value=datetime(2027, 2, 15, 7, 59, tzinfo=timezone.utc)):
            self.assertFalse(self.get("/me", self.donor).json()["is_available"])
            self.assertNotIn("donor", {row["id"] for row in self.search().json()["items"]})
        with patch("backend.app.utcnow", return_value=datetime(2027, 2, 15, 8, 0, tzinfo=timezone.utc)):
            self.assertTrue(self.get("/me", self.donor).json()["is_available"])

    def test_private_donation_history_validates_details_and_survives_travel(self):
        body = {"donated_at": utcnow().date().isoformat(), "facility_name": "  Demo Blood Bank  ", "location_name": "  Dhaka  ", "country": "bd"}
        for invalid in ({"facility_name": " "}, {"location_name": " "}, {"country": "ZZ"}, {"user_id": "seeker"}, {"facility_name": "x" * 161}):
            response = self.client.post("/api/v1/donations", json={**body, **invalid}, headers=self.donor)
            self.assertEqual(response.status_code, 422, response.text)
        self.assertEqual(self.client.post("/api/v1/donations", json={"donated_at": body["donated_at"]}, headers=self.donor).status_code, 422)
        self.assertEqual(self.client.get("/api/v1/donations").status_code, 401)
        self.assertEqual(self.client.get("/api/v1/donation-confirmations").status_code, 401)
        self.assertEqual(self.post("/donations", body, self.donor).status_code, 200)
        first = self.get("/donations", self.donor).json()["items"][0]
        self.assertEqual((first["facility_name"], first["location_name"], first["country"]), ("Demo Blood Bank", "Dhaka", "BD"))
        self.assertIsNone(first["request_id"])
        self.assertEqual(self.get("/donations").json()["items"], [])
        self.assertEqual(self.get("/donations", self.admin).json()["items"], [])
        self.post("/location", {"country": "AU", "city": "Sydney", "latitude": -33.86, "longitude": 151.2, "mode": "manual"}, self.donor)
        au = {**self.donor, "X-Country": "AU"}
        self.assertEqual(self.get("/donations", au).json()["items"], [first])
        self.assertEqual(self.get("/me/export", au).json()["donations"], [first])
        self.assertEqual(self.client.delete("/api/v1/me", headers=au).status_code, 200)
        with self.app.state.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM donations WHERE user_id='donor'").fetchone()[0], 0)

    def test_completed_request_confirmation_is_owner_only_atomic_and_travel_safe(self):
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        body = {"donated_at": utcnow().date().isoformat(), "request_id": rid}
        self.assertEqual(self.post("/donations", body, self.donor).status_code, 404)
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.assertEqual(self.get("/donation-confirmations", self.donor).json()["items"], [])
        self.assertEqual(self.post("/donations", body, self.donor).status_code, 404)
        # Both matched participants may complete concurrently, but there is just one donor receipt.
        with ThreadPoolExecutor(max_workers=2) as pool:
            completed = list(pool.map(lambda headers: self.post(f"/requests/{rid}/complete", {}, headers), [self.donor, self.seeker]))
        self.assertEqual([response.status_code for response in completed], [200, 200])
        pending = self.get("/donation-confirmations", self.donor).json()["items"]
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["request_id"], rid)
        self.assertEqual(pending[0]["facility_name"], "Demo Hospital main entrance")
        self.assertIsNone(pending[0]["location_name"])
        self.assertNotIn("destination_latitude", pending[0])
        self.assertFalse(self.get("/donation-confirmations").json()["items"][0]["is_donor"])
        self.assertTrue(pending[0]["is_donor"])
        self.assertEqual(self.post(f"/donation-confirmations/{rid}/dismiss", {}, self.admin).status_code, 404)
        self.assertEqual(self.post("/donations", body, self.admin).status_code, 404)
        self.assertTrue(self.get("/me", self.donor).json()["is_available"])
        self.assertEqual(self.get("/donations", self.donor).json()["items"], [])
        self.post("/location", {"country": "AU", "city": "Sydney", "latitude": -33.86, "longitude": 151.2, "mode": "automatic"}, self.donor)
        au = {**self.donor, "X-Country": "AU"}
        self.assertEqual(self.get("/donation-confirmations", au).json()["items"], pending)
        invalid = self.post("/donations", {**body, "donated_at": (utcnow().date() + timedelta(days=2)).isoformat()}, au)
        self.assertEqual(invalid.status_code, 422)
        self.assertEqual(self.get("/donation-confirmations", au).json()["items"], pending)
        with ThreadPoolExecutor(max_workers=2) as pool:
            logged = list(pool.map(lambda _: self.post("/donations", body, au), range(2)))
        self.assertEqual([response.status_code for response in logged], [200, 200])
        self.assertEqual(logged[0].json()["eligible_after_utc"], logged[1].json()["eligible_after_utc"])
        self.assertFalse(logged[0].json()["is_available"])
        self.assertEqual(len(self.get("/donations", au).json()["items"]), 1)
        self.assertEqual(self.get("/donation-confirmations", au).json()["items"], [])
        # A later retry cannot edit the existing history or extend its cooldown with a changed body.
        self.post("/donations", {**body, "facility_name": "Changed hospital"}, au)
        self.assertEqual(self.get("/donations", au).json()["items"][0]["facility_name"], "Demo Blood Bank")
        self.assertEqual(self.post(f"/donation-confirmations/{rid}/dismiss", {}, au).status_code, 409)
        exported = self.get("/me/export", au).json()
        self.assertEqual(exported["donation_confirmations"][0]["status"], "recorded")
        self.client.delete("/api/v1/me", headers=au)
        with self.app.state.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM donation_confirmations WHERE user_id='donor'").fetchone()[0], 0)

    def test_manual_donation_lost_response_retry_is_idempotent_and_owner_scoped(self):
        # Discard the first successful response to model a server commit followed by a lost connection.
        body = {"donated_at": utcnow().date().isoformat(), "idempotency_key": "local-test-save-intent-123"}
        self.assertEqual(self.post("/donations", body, self.donor).status_code, 200)
        before = self.get("/me", self.donor).json()["eligible_after_utc"]
        with ThreadPoolExecutor(max_workers=2) as pool:
            retries = list(pool.map(lambda _: self.post("/donations", body, self.donor), range(2)))
        self.assertEqual([response.status_code for response in retries], [200, 200])
        self.assertEqual([response.json()["eligible_after_utc"] for response in retries], [before, before])
        history = self.get("/donations", self.donor).json()["items"]
        self.assertEqual(len(history), 1)
        self.assertNotIn("idempotency_key", history[0])
        changed = self.post("/donations", {**body, "facility_name": "Different blood bank"}, self.donor)
        self.assertEqual(changed.status_code, 409)
        self.assertIn("Review your donation history", changed.json()["detail"])
        self.assertEqual(self.get("/donations", self.donor).json()["items"], history)
        # A key is scoped to the authenticated owner; another account cannot retrieve that owner's row.
        self.assertEqual(self.post("/donations", body).status_code, 200)
        self.assertNotEqual(self.get("/donations").json()["items"][0]["id"], history[0]["id"])
        self.assertNotIn("idempotency_key", self.get("/me/export", self.donor).json()["donations"][0])

    def test_either_participant_confirmation_updates_only_actual_donor_after_travel(self):
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.post(f"/requests/{rid}/complete", {})
        self.post(f"/donation-confirmations/{rid}/dismiss", {}, self.donor)
        self.assertEqual(self.get("/donation-confirmations", self.donor).json()["items"], [])
        self.assertEqual(self.get("/donation-confirmations").json()["items"][0]["request_id"], rid)
        self.post("/location", {"country": "AU", "city": "Sydney", "latitude": -33.86, "longitude": 151.2, "mode": "automatic"}, self.donor)
        self.post("/location", {"country": "GB", "city": "London", "latitude": 51.5, "longitude": -.1, "mode": "manual"})
        seeker = {**self.seeker, "X-Country": "GB"}
        donor = {**self.donor, "X-Country": "AU"}
        body = {"donated_at": utcnow().date().isoformat(), "request_id": rid, "idempotency_key": "seeker-confirmation-unique"}
        confirmed = self.post("/donations", body, seeker)
        self.assertEqual(confirmed.status_code, 200, confirmed.text)
        self.assertEqual(confirmed.json()["id"], "seeker")
        self.assertIsNone(confirmed.json()["eligible_after_utc"])
        self.assertFalse(self.get("/me", donor).json()["is_available"])
        self.assertEqual(self.get("/donations", seeker).json()["items"], [])
        history = self.get("/donations", donor).json()["items"]
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["confirmed_by_role"], "seeker")
        self.assertEqual(history[0]["country"], "BD")
        self.assertEqual(self.post("/donations", body, donor).status_code, 200)
        self.assertEqual(self.get("/donations", donor).json()["items"], history)
        self.assertEqual(self.get("/donation-confirmations", seeker).json()["items"], [])
        with self.app.state.store.connect() as db:
            log = db.execute("SELECT user_id,confirmed_by,confirmed_by_role FROM donations WHERE request_id=?", (rid,)).fetchone()
            self.assertEqual(tuple(log), ("donor", "seeker", "seeker"))
        # A confirming seeker's account deletion must never erase the donor's own medical history.
        deadline = self.get("/me", donor).json()["eligible_after_utc"]
        self.assertEqual(self.client.delete("/api/v1/me", headers=seeker).status_code, 200)
        self.assertEqual(self.get("/donations", donor).json()["items"], history)
        self.assertEqual(self.get("/me", donor).json()["eligible_after_utc"], deadline)

    def test_simultaneous_donor_and_seeker_yes_records_once_and_summary_is_match_only(self):
        rid = self.post("/requests", self.request_body(["donor", "donor-two"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.post(f"/requests/{rid}/complete", {})
        self.post(f"/donation-confirmations/{rid}/dismiss", {})
        self.assertEqual(self.get("/donation-confirmations").json()["items"], [])
        self.assertEqual(len(self.get("/donation-confirmations", self.donor).json()["items"]), 1)
        body = {"donated_at": utcnow().date().isoformat(), "request_id": rid}
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda headers: self.post("/donations", body, headers), [self.donor, self.seeker]))
        self.assertEqual([result.status_code for result in results], [200, 200])
        self.assertEqual([result.json()["id"] for result in results], ["donor", "seeker"])
        self.assertEqual(len(self.get("/donations", self.donor).json()["items"]), 1)
        for headers in (self.donor, self.seeker):
            detail = self.get(f"/requests/{rid}", headers).json()
            self.assertTrue(detail["donation_recorded"])
            self.assertTrue(detail["can_report"])
            self.assertEqual(detail["donation_summary"]["donated_at"], body["donated_at"])
            self.assertNotIn("height_cm", detail["donation_summary"])
        from backend.app import request_result
        with self.app.state.store.connect("BD") as db:
            outsider = request_result(db, rid, "donor-two")
            self.assertFalse(outsider["donation_recorded"])
            self.assertFalse(outsider["can_report"])
            self.assertIsNone(outsider["donation_summary"])

    def test_legacy_donor_only_receipt_migrates_to_independent_seeker_prompt(self):
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.post(f"/requests/{rid}/complete", {})
        with self.app.state.store.connect() as db:
            db.execute("DROP TABLE donation_confirmations")
            db.execute("CREATE TABLE donation_confirmations(request_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,facility_name TEXT NOT NULL,location_name TEXT,country TEXT NOT NULL,created_at TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'pending')")
            db.execute("INSERT INTO donation_confirmations VALUES(?,?,?,?,?,?,?)", (rid, "donor", "Legacy Hospital", None, "BD", utcnow().isoformat(), "dismissed"))
        for _ in range(2):
            migrated = create_app(self.settings)
            with TestClient(migrated) as client:
                self.assertEqual(client.get("/api/v1/donation-confirmations", headers=self.donor).json()["items"], [])
                items = client.get("/api/v1/donation-confirmations", headers=self.seeker).json()["items"]
                self.assertEqual(len(items), 1)
                self.assertFalse(items[0]["is_donor"])
                self.assertEqual(items[0]["donor_name"], "Nadia (demo)")

    def test_no_donation_dismissal_and_cancellation_never_start_cooldown(self):
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.post(f"/requests/{rid}/cancel", {}, self.donor)
        self.assertEqual(self.get("/donation-confirmations", self.donor).json()["items"], [])
        self.assertEqual(self.post("/donations", {"donated_at": utcnow().date().isoformat(), "request_id": rid}, self.donor).status_code, 404)
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.post(f"/requests/{rid}/complete", {})
        for _ in range(2):
            self.assertEqual(self.post(f"/donation-confirmations/{rid}/dismiss", {}, self.donor).json(), {"status": "dismissed"})
        self.post(f"/requests/{rid}/complete", {})
        self.assertEqual(self.get("/donation-confirmations", self.donor).json()["items"], [])
        self.assertTrue(self.get("/me", self.donor).json()["is_available"])
        self.assertEqual(self.get("/donations", self.donor).json()["items"], [])
        # An explicit later confirmation may correct a previous dismissal, still only once.
        self.assertEqual(self.post("/donations", {"donated_at": utcnow().date().isoformat(), "request_id": rid}, self.donor).status_code, 200)
        with self.app.state.store.connect() as db:
            db.execute("UPDATE accounts SET banned=1 WHERE id='donor'")
        for path in ("/donations", "/donation-confirmations"):
            self.assertEqual(self.get(path, self.donor).status_code, 403)

    def test_search_privacy_radius_and_origin(self):
        response = self.search()
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(response.json()["items"]), 2)
        for donor in response.json()["items"]:
            self.assertEqual(set(donor), {"id", "display_name", "blood_type", "city", "distance_band", "map_area"})
            self.assertEqual(set(donor["map_area"]), {"id", "latitude", "longitude"})
        for radius in (0, 39.1, 100):
            self.assertEqual(self.search(radius_km=radius).status_code, 422)
        self.assertEqual(self.search(latitude=-33.86).status_code, 409)
        self.assertEqual(self.search(blood_type="universal").status_code, 422)
        self.assertEqual(self.search(latitude="nan").status_code, 422)

    def test_map_areas_are_stable_coarse_and_shared_across_search_origins(self):
        first = {row["id"]: row for row in self.search().json()["items"]}
        shifted = {row["id"]: row for row in self.search(latitude=23.812, longitude=90.414, radius_km=10).json()["items"]}
        for uid in ("donor", "donor-two"):
            self.assertEqual(first[uid]["map_area"], shifted[uid]["map_area"])
        area = first["donor"]["map_area"]
        self.assertNotEqual((area["latitude"], area["longitude"]), (23.8103, 90.4125))
        self.assertEqual(area, coarse_map_area(23.8103, 90.4125))
        self.assertEqual(coarse_map_area(23.8103, 90.4125), coarse_map_area(23.8113, 90.4135))
        self.assertNotEqual(coarse_map_area(23.8103, 90.4125)["id"], coarse_map_area(23.91, 90.4125)["id"])
        self.assertNotEqual(coarse_map_area(23.8103, 90.4125)["id"], coarse_map_area(23.8103, 90.52)["id"])
        # The coarse centroid may be outside a small query radius; selection still uses the
        # actual private donor coordinate, rather than filtering on the displayed area center.
        within_one = self.search(radius_km=1).json()["items"]
        self.assertIn("donor", {row["id"] for row in within_one})

    def test_coarse_map_global_edges_and_minimum_nonpolar_cell_width(self):
        self.assertEqual(coarse_map_area(10.01, 180), coarse_map_area(10.01, -180))
        self.assertEqual(coarse_map_area(10.01, 179.999), coarse_map_area(10.01, -179.999))
        self.assertEqual(coarse_map_area(89.99, -179), coarse_map_area(90, 120))
        self.assertEqual(coarse_map_area(-89.99, -170), coarse_map_area(-90, 70))
        for latitude in (-90, -89.975, -89.925, -80, -45, 0, 45, 80, 89.925, 89.975, 90):
            for longitude in (-180, -179.999, 0, 179.999, 180):
                area = coarse_map_area(latitude, longitude)
                self.assertGreaterEqual(area["latitude"], -90)
                self.assertLessEqual(area["latitude"], 90)
                self.assertGreaterEqual(area["longitude"], -180)
                self.assertLess(area["longitude"], 180)
                # A centroid belongs to its own area, including the seam and both polar caps.
                self.assertEqual(area, coarse_map_area(area["latitude"], area["longitude"]))
            if abs(latitude) < 89.95:
                area = coarse_map_area(latitude, 0)
                poleward = max(abs(area["latitude"] - .025), abs(area["latitude"] + .025))
                neighbor = coarse_map_area(latitude, 0)
                step = .001
                while neighbor["id"] == area["id"]:
                    step *= 2
                    neighbor = coarse_map_area(latitude, step)
                # Full latitude extent exceeds 5 km; east/west neighboring centers remain
                # separated by >=5 km on the row's narrowest edge (spherical geometry).
                self.assertGreaterEqual(km_between(area["latitude"] - .025, 0, area["latitude"] + .025, 0), 5)
                self.assertGreaterEqual(km_between(poleward, area["longitude"], poleward, neighbor["longitude"]), 5)

    def test_donation_cooldown_travel_and_opt_out(self):
        today = utcnow().date()
        response = self.post("/donations", {"donated_at": today.isoformat()}, self.donor)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertFalse(response.json()["is_available"])
        self.assertTrue(response.json()["available"])
        until = response.json()["eligible_after"]
        self.assertNotIn("donor", {x["id"] for x in self.search().json()["items"]})
        older = self.post("/donations", {"donated_at": (today - timedelta(days=30)).isoformat()}, self.donor)
        self.assertEqual(older.json()["eligible_after"], until)
        moved = self.post("/travel", {"country": "AU", "city": "Sydney", "latitude": -33.8688, "longitude": 151.2093, "consent": True}, self.donor)
        self.assertEqual(moved.status_code, 200, moved.text)
        self.assertEqual(moved.json()["eligible_after"], until)
        self.assertEqual(moved.json()["location_mode"], "manual")
        self.assertFalse(moved.json()["is_available"])
        self.assertEqual(self.get("/me", self.donor).json()["country"], "AU")
        self.assertEqual(self.get("/conversations", self.donor).status_code, 409)
        with self.app.state.store.connect("BD") as db:
            self.assertIsNone(db.execute("SELECT 1 FROM region.profiles WHERE id='donor'").fetchone())
            db.execute("UPDATE accounts SET eligible_after='2000-01-01',eligible_after_utc=NULL,available=0 WHERE id='donor'")
        au = {**self.donor, "X-Country": "AU"}
        self.assertFalse(self.get("/me", au).json()["is_available"])
        with self.app.state.store.connect() as db:
            db.execute("UPDATE accounts SET available=1 WHERE id='donor'")
        self.assertTrue(self.get("/me", au).json()["is_available"])
        self.assertEqual(self.post("/donations", {"donated_at": (today + timedelta(days=1)).isoformat()}, au).status_code, 422)

    def test_idor_and_block_enforcement(self):
        self.assertEqual(self.get("/conversations/demo-conversation/messages", self.admin).status_code, 404)
        response = self.post("/conversations/demo-conversation/messages", {"body": "Can we coordinate through the hospital?"})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.post("/blocks", {"user_id": "donor"}).status_code, 200)
        self.assertEqual(self.post("/conversations/demo-conversation/messages", {"body": "Blocked"}, self.donor).status_code, 403)
        self.assertNotIn("donor", {row["id"] for row in self.search().json()["items"]})
        self.assertEqual(self.post("/conversations", {"donor_id": "donor"}).status_code, 404)

    def test_report_is_not_ban_until_review_and_ban_is_global(self):
        report = self.post("/reports", {"conversation_id": "demo-conversation", "reason": "money_request", "details": "Asked for money in our conversation"})
        self.assertEqual(report.status_code, 200, report.text)
        rid = report.json()["id"]
        self.assertEqual(self.get("/me", self.donor).status_code, 200)
        self.assertEqual(self.get("/admin/reports").status_code, 403)
        self.assertEqual(self.post(f"/admin/reports/{rid}/resolve", {"decision": "ban", "note": "Evidence reviewed and confirmed"}).status_code, 403)
        result = self.post(f"/admin/reports/{rid}/resolve", {"decision": "ban", "note": "Evidence reviewed and confirmed"}, self.admin)
        self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(self.get("/me", self.donor).status_code, 403)
        self.assertEqual(self.get("/me", {**self.donor, "X-Country": "AU"}).status_code, 403)
        self.assertEqual(self.post(f"/admin/reports/{rid}/resolve", {"decision": "dismiss", "note": "Another review"}, self.admin).status_code, 409)
        with self.app.state.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM audit").fetchone()[0], 1)
            with self.assertRaises(Exception):
                db.execute("DELETE FROM audit")

    def test_no_privilege_assignment_and_profile_bounds(self):
        current = self.get("/me").json()
        fields = {key: current[key] for key in ("display_name", "blood_type", "height_cm", "weight_kg", "city", "latitude", "longitude", "available")}
        for changes in ({"role": "admin"}, {"height_cm": 0}, {"weight_kg": 500}, {"eligible_after": "2000-01-01"}):
            response = self.client.put("/api/v1/me", json={**fields, **changes}, headers=self.seeker)
            self.assertEqual(response.status_code, 422, response.text)
        saved = self.client.put("/api/v1/me", json={**fields, "height_cm": 180, "weight_kg": 81}, headers=self.seeker)
        self.assertEqual(saved.status_code, 200, saved.text)
        self.assertEqual(saved.json()["bmi"], 25)

    def test_account_export_delete_and_countries(self):
        self.assertGreater(len(self.get("/countries").json()["items"]), 240)
        self.assertEqual(self.get("/me", {**self.seeker, "X-Country": ".."}).status_code, 400)
        exported = self.get("/me/export")
        self.assertEqual(exported.status_code, 200, exported.text)
        self.assertEqual(exported.json()["profile"]["id"], "seeker")
        self.assertEqual(self.client.delete("/api/v1/me", headers=self.seeker).status_code, 200)
        self.assertEqual(self.get("/me").status_code, 403)
        with self.app.state.store.connect("BD") as db:
            self.assertIsNone(db.execute("SELECT 1 FROM region.profiles WHERE id='seeker'").fetchone())

    def test_interrupted_erasure_remains_queued_after_access_revocation(self):
        with patch("backend.app.scrub_deleted_accounts", side_effect=OSError("Temporary filesystem failure")):
            result = self.client.delete("/api/v1/me", headers=self.seeker)
        self.assertEqual(result.json(), {"status": "deleted", "erasure_pending": True})
        self.assertEqual(self.get("/me").status_code, 403)
        scrub_deleted_accounts(self.app.state.store)
        with self.app.state.store.connect("BD") as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM deletion_jobs").fetchone()[0], 0)
            self.assertIsNone(db.execute("SELECT 1 FROM region.profiles WHERE id='seeker'").fetchone())

    def test_calls_require_service_and_callee_acceptance(self):
        response = self.post("/conversations/demo-conversation/calls", {})
        self.assertEqual(response.status_code, 503)
        self.settings.livekit_url = "wss://media.example.invalid"
        self.settings.livekit_key = "test-key"
        self.settings.livekit_secret = "test-secret-that-is-long-enough-for-hmac"
        response = self.post("/conversations/demo-conversation/calls", {})
        self.assertEqual(response.status_code, 200, response.text)
        cid = response.json()["id"]
        self.assertNotIn("token", self.get(f"/calls/{cid}").json())
        self.assertEqual(self.post(f"/calls/{cid}/accept", {}).status_code, 403)
        self.assertEqual(self.get(f"/calls/{cid}", self.admin).status_code, 404)
        accepted = self.post(f"/calls/{cid}/accept", {}, self.donor)
        self.assertEqual(accepted.status_code, 200, accepted.text)
        claims = jwt.decode(accepted.json()["token"], self.settings.livekit_secret, algorithms=["HS256"])
        self.assertEqual(claims["sub"], "donor")
        self.assertEqual(claims["video"]["room"], f"blood-{cid}")
        self.assertEqual(claims["video"]["canPublishSources"], ["microphone"])
        with patch("backend.app.httpx.post") as media_request:
            media_request.return_value.status_code = 200
            self.assertEqual(self.post(f"/calls/{cid}/end", {}).json()["status"], "ended")
            self.assertEqual(media_request.call_count, 3)
        self.assertNotIn("token", self.get(f"/calls/{cid}").json())

    def test_cooldown_suppresses_calls(self):
        self.settings.livekit_url = "wss://media.example.invalid"
        self.settings.livekit_key = "test-key"
        self.settings.livekit_secret = "test-secret"
        call = self.post("/conversations/demo-conversation/calls", {})
        self.assertEqual(call.status_code, 200)
        self.post("/donations", {"donated_at": utcnow().date().isoformat()}, self.donor)
        self.assertEqual(self.get("/calls", self.donor).json()["items"], [])
        self.assertEqual(self.post(f"/calls/{call.json()['id']}/accept", {}, self.donor).status_code, 409)

    def test_abandoned_call_expiry_and_media_retry(self):
        self.settings.livekit_url = "wss://media.example.invalid"
        self.settings.livekit_key = "test-key"
        self.settings.livekit_secret = "test-secret-that-is-long-enough-for-hmac"
        cid = self.post("/conversations/demo-conversation/calls", {}).json()["id"]
        self.post(f"/calls/{cid}/accept", {}, self.donor)
        with self.app.state.store.connect("BD") as db:
            db.execute("UPDATE region.calls SET expires_at='2000-01-01' WHERE id=?", (cid,))
        with patch("backend.app.httpx.post") as media:
            media.return_value.status_code = 503
            cleanup_media(self.app.state.store, self.settings)
            with self.app.state.store.connect() as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM media_cleanup").fetchone()[0], 1)
            media.return_value.status_code = 200
            cleanup_media(self.app.state.store, self.settings)
        self.assertEqual(self.get(f"/calls/{cid}").json()["status"], "ended")
        with self.app.state.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM media_cleanup").fetchone()[0], 0)
        self.assertEqual(self.post("/conversations/demo-conversation/calls", {}).status_code, 200)

    def test_contact_cannot_bypass_distance_or_nonmoney_ban_rule(self):
        with self.app.state.store.connect("BD") as db:
            db.execute("UPDATE region.profiles SET latitude=0,longitude=0 WHERE id='donor'")
        self.assertEqual(self.post("/conversations", {"donor_id": "donor"}).status_code, 404)
        reported = self.post("/reports", {"conversation_id": "demo-conversation", "reason": "other", "details": "Please review this unrelated issue"})
        rid = reported.json()["id"]
        self.assertEqual(self.post(f"/admin/reports/{rid}/resolve", {"decision": "ban", "note": "This is not a money report"}, self.admin).status_code, 422)
        self.assertEqual(self.post(f"/admin/reports/{rid}/resolve", {"decision": "dismiss", "note": "Reviewed and no violation found"}, self.admin).status_code, 200)

    def test_config_rejects_secret_keys_and_allows_auth_origin(self):
        for secret in ("sb_secret_not-public", jwt.encode({"role": "service_role"}, "not-a-real-secret-but-at-least-thirty-two-bytes", algorithm="HS256")):
            with self.assertRaises(RuntimeError):
                create_app(Settings(data_dir=Path(self.temp.name) / "bad-config", demo=False, supabase_key=secret))
        configured = create_app(Settings(data_dir=Path(self.temp.name) / "good-config", demo=False, supabase_url="https://auth.example.invalid", supabase_key="public-anon-key"))
        with TestClient(configured) as client:
            result = client.get("/api/v1/auth/config")
            self.assertIn("connect-src 'self' https://auth.example.invalid", result.headers["Content-Security-Policy"])
            self.assertEqual(result.json()["supabase_anon_key"], "public-anon-key")

    def test_demo_rejects_nonloopback_peer(self):
        with TestClient(self.app, client=("192.0.2.1", 12345)) as client:
            self.assertEqual(client.get("/api/v1/health").status_code, 403)

    def test_demo_rejects_remote_hosts_and_large_requests(self):
        response = self.client.get("/api/v1/health", headers={"Host": "public.example.com"})
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self.client.post("/api/v1/reports", content=b"x" * 33000, headers=self.seeker).status_code, 413)
        response = self.client.post("/api/v1/reports", content=(chunk for chunk in [b"x" * 16000, b"x" * 17000]), headers=self.seeker)
        self.assertEqual(response.status_code, 413)

    def test_production_rejects_demo_and_unapproved_provider(self):
        production = create_app(Settings(data_dir=Path(self.temp.name) / "prod", demo=False, countries={"BD"}, supabase_url="https://auth.example.invalid", supabase_key="public-key"))
        with TestClient(production) as client:
            with patch("backend.app.httpx.get") as check:
                check.return_value.status_code = 401
                response = client.get("/api/v1/me", headers=self.seeker)
                self.assertEqual(response.status_code, 401)
                check.return_value.status_code = 200
                check.return_value.json.return_value = {"id": "evil", "app_metadata": {"provider": "email"}, "user_metadata": {"role": "admin", "provider": "google"}}
                self.assertEqual(client.get("/api/v1/me", headers=self.seeker).status_code, 403)
                check.return_value.json.return_value = {"id": "real-member", "app_metadata": {"provider": "google"}, "user_metadata": {"role": "admin"}}
                result = client.get("/api/v1/me", headers=self.seeker)
                self.assertEqual(result.status_code, 200, result.text)
                self.assertEqual(result.json()["role"], "member")
                self.assertEqual(client.get("/api/v1/admin/reports", headers=self.seeker).status_code, 403)
                self.assertEqual(client.get("/api/v1/me", headers={**self.seeker, "X-Country": "AU"}).json()["country"], "BD")
                self.assertEqual(client.get("/api/v1/conversations", headers={**self.seeker, "X-Country": "AU"}).status_code, 409)

    def test_location_moves_incomplete_profile_and_preserves_global_state(self):
        cooldown = self.post("/donations", {"donated_at": utcnow().date().isoformat()}, self.donor).json()["eligible_after"]
        with self.app.state.store.connect("BD") as db:
            db.execute("UPDATE region.profiles SET blood_type=NULL,height_cm=NULL,weight_kg=NULL WHERE id='donor'")
            db.execute("UPDATE accounts SET available=0 WHERE id='donor'")
        with self.app.state.store.connect("AU") as db:
            # An obsolete destination row must not win over the latest source identity fields.
            db.execute("INSERT INTO region.profiles VALUES('donor','Stale name','AB-',190,100,'Old city',0,0)")
        moved = self.post("/location", {"country": "AU", "city": "Sydney", "latitude": -33.8688, "longitude": 151.2093, "mode": "automatic"}, self.donor)
        self.assertEqual(moved.status_code, 200, moved.text)
        profile = moved.json()
        self.assertEqual(profile["country"], "AU")
        self.assertEqual(profile["display_name"], "Nadia (demo)")
        self.assertEqual(profile["location_mode"], "automatic")
        self.assertEqual(profile["eligible_after"], cooldown)
        self.assertFalse(profile["available"])
        self.assertIsNone(profile["blood_type"])
        self.assertIsNone(profile["bmi"])
        self.assertEqual(self.get("/me", {"Authorization": "Bearer demo-donor"}).json()["country"], "AU")
        with self.app.state.store.connect("BD") as db:
            self.assertIsNone(db.execute("SELECT 1 FROM region.profiles WHERE id='donor'").fetchone())
            self.assertIsNotNone(db.execute("SELECT 1 FROM region.messages WHERE id='demo-message'").fetchone())
        # A resumed client with an obsolete header moves from the stored active country, not BD.
        again = self.post("/location", {"country": "NZ", "city": "Auckland", "latitude": -36.85, "longitude": 174.76, "mode": "manual"}, self.donor)
        self.assertEqual(again.status_code, 200, again.text)
        self.assertEqual(again.json()["location_mode"], "manual")
        self.assertEqual(again.json()["eligible_after"], cooldown)
        with self.app.state.store.connect("AU") as db:
            self.assertIsNone(db.execute("SELECT 1 FROM region.profiles WHERE id='donor'").fetchone())

    def test_location_duplicates_are_noops_and_changed_readings_are_limited(self):
        with self.app.state.store.connect("BD") as db:
            db.execute("CREATE TABLE region.location_write_count(n INTEGER)")
            db.execute("INSERT INTO region.location_write_count VALUES(0)")
            db.execute("CREATE TRIGGER region.count_location_write AFTER UPDATE OF city,latitude,longitude ON profiles BEGIN UPDATE location_write_count SET n=n+1; END")
        body = {"country": "BD", "city": "Dhaka", "latitude": 23.82, "longitude": 90.42, "mode": "automatic"}
        self.assertEqual(self.post("/location", body).status_code, 200)
        for _ in range(65):
            self.assertEqual(self.post("/location", body).status_code, 200)
        with self.app.state.store.connect("BD") as db:
            self.assertEqual(db.execute("SELECT n FROM region.location_write_count").fetchone()[0], 1)
        for number in range(1, 60):
            self.assertEqual(self.post("/location", {**body, "latitude": 23.82 + number / 10000}).status_code, 200)
        self.assertEqual(self.post("/location", {**body, "latitude": 23.84}).status_code, 429)
        same = {**body, "latitude": 23.82 + 59 / 10000, "mode": "manual"}
        self.assertEqual(self.post("/location", same).json()["location_mode"], "manual")

    def test_location_validation_and_stale_profile_guard(self):
        body = {"country": "BD", "city": "Dhaka", "latitude": 23.82, "longitude": 90.42, "mode": "automatic"}
        for changes in ({"city": "  "}, {"latitude": 91}, {"mode": "gps-verified"}, {"country": "ZZ"}, {"role": "admin"}):
            self.assertIn(self.post("/location", {**body, **changes}).status_code, (400, 422))
        original = self.get("/me").json()
        stale = {key: original[key] for key in ("display_name", "blood_type", "height_cm", "weight_kg", "city", "latitude", "longitude", "available")}
        for mode in ("automatic", "manual"):
            self.assertEqual(self.post("/location", {**body, "mode": mode}).status_code, 200)
            self.assertEqual(self.client.put("/api/v1/me", json=stale, headers=self.seeker).status_code, 409)
        fresh = {**stale, "city": body["city"], "latitude": body["latitude"], "longitude": body["longitude"]}
        self.assertEqual(self.client.put("/api/v1/me", json=fresh, headers=self.seeker).status_code, 200)

    def test_failed_country_transfer_rolls_back_profile_and_registry(self):
        with self.app.state.store.connect("BD") as db:
            db.execute("CREATE TRIGGER region.fail_profile_delete BEFORE DELETE ON profiles BEGIN SELECT RAISE(ABORT,'simulated failure'); END")
        with self.app.state.store.connect("AU") as db:
            db.execute("INSERT INTO region.profiles VALUES('seeker','Old copy','AB-',190,100,'Old city',0,0)")
        with self.assertRaises(sqlite3.IntegrityError):
            self.post("/location", {"country": "AU", "city": "Sydney", "latitude": -33.8688, "longitude": 151.2093, "mode": "manual"})
        self.assertEqual(self.get("/me").json()["country"], "BD")
        self.assertEqual(self.get("/me").json()["location_mode"], "automatic")
        with self.app.state.store.connect("AU") as db:
            self.assertEqual(db.execute("SELECT display_name FROM region.profiles WHERE id='seeker'").fetchone()[0], "Old copy")

    def test_browser_members_denied_and_native_admin_access_preserved(self):
        root = self.client.get("/", follow_redirects=False)
        self.assertEqual(root.status_code, 307)
        self.assertEqual(root.headers["location"], "/admin/")
        for browser in ({"Origin": "http://testserver"}, {"Sec-Fetch-Site": "same-origin"}, {"Sec-Fetch-Mode": "cors", "X-Client": "native"}):
            for path in ("/me", "/conversations", "/admin/reports"):
                response = self.get(path, {**self.seeker, **browser})
                self.assertEqual(response.status_code, 403, response.text)
            self.assertEqual(self.get("/me", {**self.admin, **browser}).status_code, 200)
            self.assertEqual(self.get("/admin/reports", {**self.admin, **browser}).status_code, 200)
        self.assertEqual(self.get("/me").status_code, 200)
        self.assertEqual(self.get("/me", self.admin).status_code, 200)

    def test_location_bootstrap_requires_country_only_for_new_members(self):
        production = create_app(Settings(data_dir=Path(self.temp.name) / "bootstrap", demo=False, countries={"AU", "NZ"}, admins={"admin-id"}, supabase_url="https://auth.example.invalid", supabase_key="public-key"))
        headers = {"Authorization": "Bearer test-token"}
        with TestClient(production) as client, patch("backend.app.httpx.get") as check:
            check.return_value.status_code = 200
            check.return_value.json.return_value = {"id": "new-user", "app_metadata": {"provider": "google"}}
            missing = client.get("/api/v1/me", headers=headers)
            self.assertEqual(missing.status_code, 409)
            self.assertIn("Location required", missing.json()["detail"])
            with production.state.store.connect() as db:
                self.assertIsNone(db.execute("SELECT 1 FROM accounts WHERE id='new-user'").fetchone())
            body = {"country": "AU", "city": "Sydney", "latitude": -33.8688, "longitude": 151.2093, "mode": "automatic"}
            created = client.post("/api/v1/location", json=body, headers={**headers, "X-Country": "AU"})
            self.assertEqual(created.status_code, 200, created.text)
            self.assertIsNone(created.json()["blood_type"])
            self.assertEqual(client.get("/api/v1/me", headers=headers).json()["country"], "AU")
            check.return_value.json.return_value = {"id": "admin-id", "app_metadata": {"provider": "google"}}
            admin = client.get("/api/v1/me", headers={**headers, "Origin": "http://testserver"})
            self.assertEqual(admin.status_code, 200, admin.text)
            self.assertEqual(admin.json()["country"], "AU")
            self.assertEqual(admin.json()["role"], "admin")

    def test_location_mode_migrates_existing_registry_without_resetting_state(self):
        legacy = Path(self.temp.name) / "legacy"
        legacy.mkdir()
        db = sqlite3.connect(legacy / "registry.sqlite3")
        try:
            db.execute("CREATE TABLE accounts(id TEXT PRIMARY KEY,country TEXT NOT NULL,available INTEGER NOT NULL DEFAULT 0,eligible_after TEXT,role TEXT NOT NULL DEFAULT 'member',banned INTEGER NOT NULL DEFAULT 0,deleted INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL)")
            db.execute("INSERT INTO accounts VALUES('legacy-donor','AU',0,'2028-01-01','member',1,0,'2026-01-01')")
            db.execute("CREATE TABLE donations(id TEXT PRIMARY KEY,user_id TEXT NOT NULL,donated_at TEXT NOT NULL,created_at TEXT NOT NULL)")
            db.execute("INSERT INTO donations VALUES('legacy-log','legacy-donor','2026-01-01','2026-01-02')")
            db.commit()
        finally:
            db.close()
        settings = Settings(data_dir=legacy, demo=False, countries={"AU"})
        for _ in range(2):
            migrated = create_app(settings)
            with migrated.state.store.connect() as connection:
                account = connection.execute("SELECT * FROM accounts WHERE id='legacy-donor'").fetchone()
                self.assertEqual(account["location_mode"], "automatic")
                self.assertEqual(account["eligible_after"], "2028-01-01")
                self.assertEqual(account["banned"], 1)
                self.assertEqual(account["available"], 0)
                history = connection.execute("SELECT * FROM donations WHERE id='legacy-log'").fetchone()
                self.assertEqual(history["donated_at"], "2026-01-01")
                for field in ("facility_name", "location_name", "country", "request_id", "idempotency_key"):
                    self.assertIsNone(history[field])
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM donation_confirmations").fetchone()[0], 0)

    def request_body(self, donors=None):
        """Use an explicitly chosen fictional meeting place, separate from every donor's GPS."""
        body = {"blood_type": "O+", "radius_km": 39, "destination_name": "Demo Hospital main entrance", "destination_latitude": 23.8, "destination_longitude": 90.4}
        if donors:
            body["donor_ids"] = donors
        return body

    def photo_bytes(self):
        image = Image.new("RGB", (1000, 500), "red")
        exif = image.getexif()
        exif[270], exif[274] = "Private camera metadata", 6
        output = BytesIO()
        image.save(output, "JPEG", exif=exif)
        return output.getvalue()

    def test_reports_from_both_matched_participants_survive_completion_and_block(self):
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.post(f"/requests/{rid}/complete", {})
        self.post("/blocks", {"user_id": "donor"})
        self.assertTrue(self.get(f"/requests/{rid}", self.donor).json()["can_report"])
        self.assertTrue(next(row for row in self.get("/conversations").json()["items"] if row["peer_id"] == "donor")["is_blocked"])
        body = {"request_id": rid, "reason": "no_show", "details": "The agreed meeting did not happen.", "idempotency_key": "stable-report-intent-key"}
        with ThreadPoolExecutor(max_workers=2) as pool:
            reports = list(pool.map(lambda _: self.post("/reports", body), range(2)))
        self.assertEqual([report.status_code for report in reports], [200, 200])
        self.assertEqual(reports[0].json()["id"], reports[1].json()["id"])
        self.assertEqual(self.post("/reports", {**body, "details": "Changed details."}).status_code, 409)
        reverse = self.post("/reports", {"request_id": rid, "reason": "misleading_information", "details": "The agreed information was wrong."}, self.donor)
        self.assertEqual(reverse.status_code, 200)
        self.assertEqual(self.post("/reports", body, self.admin).status_code, 404)
        for invalid in ({**body, "conversation_id": "demo-conversation"}, {"reason": "other", "details": "No relationship supplied"}):
            self.assertEqual(self.post("/reports", invalid).status_code, 422)
        with self.app.state.store.connect("BD") as db:
            self.assertEqual(db.execute("SELECT reported_id FROM region.reports WHERE id=?", (reports[0].json()["id"],)).fetchone()[0], "donor")
            self.assertEqual(db.execute("SELECT reported_id FROM region.reports WHERE id=?", (reverse.json()["id"],)).fetchone()[0], "seeker")
        # A general allegation cannot silently invoke the existing lifetime money-request ban policy.
        self.assertEqual(self.post(f"/admin/reports/{reverse.json()['id']}/resolve", {"decision": "ban", "note": "Reviewed the allegation"}, self.admin).status_code, 422)

    def test_report_image_evidence_authorization_sanitization_retry_limits_and_review(self):
        matched = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.post(f"/requests/{matched}/accept", {}, self.donor)
        report = self.post("/reports", {"conversation_id": "demo-conversation", "reason": "harassment", "details": "Private screenshot evidence follows."}).json()["id"]
        path = f"/api/v1/reports/{report}/evidence"
        def upload(raw, headers=None, content_type="image/jpeg"):
            return self.client.post(path, content=raw, headers={**(headers or self.seeker), "Content-Type": content_type})
        raw = self.photo_bytes()
        self.assertEqual(upload(raw, self.donor).status_code, 404)
        self.assertEqual(upload(raw, self.admin).status_code, 404)
        self.assertEqual(upload(b"bad image").status_code, 422)
        self.assertEqual(upload(b"<svg></svg>", content_type="image/svg+xml").status_code, 415)
        self.assertEqual(upload(b"x" * (5 * 1024 * 1024 + 1)).status_code, 413)
        with ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(lambda _: upload(raw), range(2)))
        self.assertEqual([r.status_code for r in responses], [200, 200])
        self.assertEqual(responses[0].json(), responses[1].json())
        aid = responses[0].json()["id"]
        own_path = f"/reports/{report}/evidence/{aid}"
        admin_path = f"/admin/reports/{report}/evidence/{aid}"
        photo = self.get(own_path)
        self.assertEqual(photo.status_code, 200)
        self.assertEqual(photo.headers["cache-control"], "no-store")
        with Image.open(BytesIO(photo.content)) as image:
            self.assertEqual(image.format, "JPEG")
            self.assertEqual(image.size, (500, 1000))
            self.assertEqual(len(image.getexif()), 0)
        self.assertEqual(self.get(own_path, self.donor).status_code, 404)
        self.assertEqual(self.get(own_path, self.admin).status_code, 404)
        self.assertEqual(self.get(admin_path, self.seeker).status_code, 403)
        self.assertEqual(self.get(admin_path, self.admin).content, photo.content)
        self.post(f"/requests/{matched}/complete", {})
        self.post("/blocks", {"user_id": "donor"})
        self.assertEqual(self.get(own_path).content, photo.content)
        self.assertEqual(self.get(admin_path, self.admin).content, photo.content)
        self.assertEqual(self.get(admin_path, {**self.admin, "X-Country": "AU"}).status_code, 404)
        self.assertEqual(self.client.get(f"/api/v1{own_path}").status_code, 401)
        self.assertEqual(self.get(f"/reports/demo-report/evidence/{aid}").status_code, 404)
        for color in ("green", "blue"):
            output = BytesIO()
            Image.new("RGB", (30, 30), color).save(output, "PNG")
            self.assertEqual(upload(output.getvalue(), content_type="image/png").status_code, 200)
        output = BytesIO()
        Image.new("RGB", (30, 30), "yellow").save(output, "PNG")
        self.assertEqual(upload(output.getvalue(), content_type="image/png").status_code, 409)
        self.assertEqual(upload(raw).status_code, 200)  # a retry does not consume a fourth slot
        listed = next(row for row in self.get("/admin/reports", self.admin).json()["items"] if row["id"] == report)
        self.assertEqual(len(listed["attachments"]), 3)
        self.assertEqual(set(listed["attachments"][0]), {"id", "content_type", "created_at"})
        exported = self.get("/me/export").json()
        own_report = next(row for region in exported["regions"] for row in region["reports"] if row["id"] == report)
        self.assertEqual(len(own_report["attachments"]), 3)
        self.assertEqual(self.post(f"/admin/reports/{report}/resolve", {"decision": "dismiss", "note": "Reviewed the supplied evidence"}, self.admin).status_code, 200)
        self.assertEqual(upload(raw).status_code, 409)
        self.assertEqual(self.get(admin_path, self.admin).status_code, 200)

    def test_report_outcome_is_private_and_delivered_despite_cooldown_block_and_travel(self):
        key, auth, device = self.push_subscription()
        self.post("/devices", device, self.donor)
        rid = self.post("/reports", {"conversation_id": "demo-conversation", "reason": "harassment", "details": "Private allegation from the donor."}, self.donor).json()["id"]
        attachment = self.client.post(f"/api/v1/reports/{rid}/evidence", content=self.photo_bytes(), headers={**self.donor, "Content-Type": "image/jpeg"}).json()["id"]
        pending = self.get(f"/reports/{rid}", self.donor).json()
        self.assertEqual(pending["status"], "pending")
        self.assertIsNone(pending["reviewed_at"])
        self.assertIsNone(pending["outcome"])
        self.assertEqual(pending["attachments"][0]["id"], attachment)
        self.assertEqual(self.get(f"/reports/{rid}").status_code, 404)
        self.assertEqual(self.get(f"/reports/{rid}", self.admin).status_code, 404)
        self.assertNotIn(rid, {row["id"] for row in self.get("/reports").json()["items"]})
        self.post("/donations", {"donated_at": utcnow().date().isoformat()}, self.donor)
        self.post("/blocks", {"user_id": "seeker"}, self.donor)
        with self.app.state.store.connect() as db:
            db.execute("UPDATE accounts SET available=0 WHERE id='donor'")
        self.post("/location", {"country": "AU", "city": "Sydney", "latitude": -33.86, "longitude": 151.2, "mode": "manual"}, self.donor)
        au = {**self.donor, "X-Country": "AU"}
        deadline = self.get("/me", au).json()["eligible_after_utc"]
        secret_note = "Confidential reviewer discussion and private audit reasoning"
        reviewed = self.post(f"/admin/reports/{rid}/resolve", {"decision": "dismiss", "note": secret_note}, self.admin)
        self.assertEqual(reviewed.status_code, 200)
        detail = self.get(f"/reports/{rid}", au, params={"country": "BD"}).json()
        self.assertEqual(detail["status"], "reviewed")
        self.assertEqual(detail["outcome"], "dismissed")
        self.assertIsNotNone(detail["reviewed_at"])
        self.assertEqual(detail["submitted_at"], pending["submitted_at"])
        self.assertNotIn(secret_note, json.dumps(detail))
        self.assertNotIn("evidence", detail)
        self.assertNotIn("note", detail)
        self.assertEqual(self.get("/reports", au).json()["items"], [detail])
        self.assertEqual(self.get(f"/reports/{rid}", au).status_code, 404)
        self.assertEqual(self.get(f"/reports/{rid}/evidence/{attachment}", au, params={"country": "BD"}).status_code, 200)
        self.assertEqual(self.get(f"/reports/{rid}/evidence/{attachment}", self.seeker, params={"country": "BD"}).status_code, 404)
        # Travel again after the event is queued; its original country remains a private routing key.
        self.post("/location", {"country": "GB", "city": "London", "latitude": 51.5, "longitude": -.1, "mode": "manual"}, au)
        gb = {**self.donor, "X-Country": "GB"}
        event = self.get("/events", gb).json()["items"][0]
        self.assertEqual(event["kind"], "report_reviewed")
        self.assertIsNone(event["request_id"])
        self.assertEqual((event["country"], event["report_country"], event["report_id"]), ("BD", "BD", rid))
        self.assertNotIn(secret_note, json.dumps(event))
        self.assertEqual(self.get("/events", gb, params={"country": "BD", "after": 0}).json()["items"], [event])
        self.assertEqual(self.post(f"/events/{event['id']}/read?country=BD", {}, gb).status_code, 200)
        self.assertTrue(self.get("/events", gb).json()["items"][0]["read"])
        self.assertEqual(self.post(f"/events/{event['id']}/read?country=BD", {}).status_code, 404)
        with patch("backend.push.httpx.post") as transport:
            transport.return_value.status_code = 201
            process_push(self.app.state.store, self.settings)
            self.assertEqual(transport.call_count, 1)
            decoded = json.loads(http_ece.decrypt(transport.call_args.kwargs["content"], private_key=key, auth_secret=auth, version="aes128gcm"))
            self.assertEqual(decoded, {"event_id": event["id"], "kind": "report_reviewed", "country": "BD", "report_id": rid, "report_country": "BD"})
            self.assertNotIn("harassment", json.dumps(decoded))
        self.assertEqual(self.get("/me", gb).json()["eligible_after_utc"], deadline)

    def test_report_review_resolution_is_atomic_once_and_ban_outcome_is_safe(self):
        _, _, device = self.push_subscription()
        self.post("/devices", device)
        body = {"decision": "ban", "note": "Secret internal money-request finding"}
        # A failed event write must roll back even the global ban and append-only audit insertion.
        with patch("backend.app.emit_event", side_effect=RuntimeError("simulated outbox failure")):
            with self.assertRaises(RuntimeError):
                self.post("/admin/reports/demo-report/resolve", body, self.admin)
        with self.app.state.store.connect("BD") as db:
            self.assertEqual(db.execute("SELECT banned FROM accounts WHERE id='reported'").fetchone()[0], 0)
            row = db.execute("SELECT status,reviewed_at FROM region.reports WHERE id='demo-report'").fetchone()
            self.assertEqual(tuple(row), ("pending", None))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM audit WHERE report_id='demo-report'").fetchone()[0], 0)
        with ThreadPoolExecutor(max_workers=2) as pool:
            reviews = list(pool.map(lambda _: self.post("/admin/reports/demo-report/resolve", body, self.admin), range(2)))
        self.assertEqual(sorted(review.status_code for review in reviews), [200, 409])
        outcome = self.get("/reports/demo-report").json()
        self.assertEqual(outcome["status"], "reviewed")
        self.assertEqual(outcome["outcome"], "banned")
        self.assertIn("Action was taken", outcome["outcome_explanation"])
        self.assertNotIn(body["note"], json.dumps(outcome))
        self.assertEqual(self.get("/reports/demo-report", self.donor).status_code, 404)
        with self.app.state.store.connect("BD") as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM region.events WHERE report_id='demo-report'").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM region.push_outbox").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM audit WHERE report_id='demo-report'").fetchone()[0], 1)
            db.execute("UPDATE accounts SET banned=1 WHERE id='seeker'")
        with patch("backend.push.httpx.post") as transport:
            process_push(self.app.state.store, self.settings)
            transport.assert_not_called()
        self.assertEqual(self.get("/reports").status_code, 403)

    def test_owner_reports_are_bounded_and_legacy_review_dates_are_not_invented(self):
        for code in ("BD", "AU"):
            with self.app.state.store.connect(code) as db:
                for number in range(75):
                    db.execute("INSERT INTO region.reports(id,reporter_id,reported_id,conversation_id,reason,details,status,evidence,created_at) VALUES(?,?,?,?,?,?,?,?,?)", (f"{code}-{number:03}", "donor", "seeker", "demo-conversation", "other", "Historical private report", "dismissed", "[]", f"2026-01-{1 + number // 3:02}T00:00:00+00:00"))
        rows = self.get("/reports", self.donor).json()["items"]
        self.assertEqual(len(rows), 100)
        self.assertEqual({row["country"] for row in rows}, {"AU", "BD"})
        self.assertEqual(rows, sorted(rows, key=lambda row: (row["submitted_at"], row["country"], row["id"]), reverse=True))
        self.assertTrue(all(row["reviewed_at"] is None for row in rows))
        self.assertNotIn("demo-report", {row["id"] for row in rows})
        self.assertEqual(self.get("/reports/BD-000", self.donor, params={"country": "../"}).status_code, 422)
        self.assertEqual(self.get("/reports/BD-000", self.donor, params={"country": "ZZ"}).status_code, 404)
        self.assertEqual(self.client.get("/api/v1/reports").status_code, 401)

    def test_accused_admin_cannot_view_own_report_or_evidence(self):
        self.enable_admin_donor()
        rid = self.post("/requests", self.request_body(["admin"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.admin)
        report = self.post("/reports", {"request_id": rid, "reason": "other", "details": "An allegation about the administrator."}).json()["id"]
        image = self.client.post(f"/api/v1/reports/{report}/evidence", content=self.photo_bytes(), headers={**self.seeker, "Content-Type": "image/jpeg"}).json()["id"]
        self.assertNotIn(report, {row["id"] for row in self.get("/admin/reports", self.admin).json()["items"]})
        self.assertEqual(self.get(f"/admin/reports/{report}/evidence/{image}", self.admin).status_code, 404)
        self.assertEqual(self.post(f"/admin/reports/{report}/resolve", {"decision": "dismiss", "note": "Cannot review my own report"}, self.admin).status_code, 403)

    def enable_admin_donor(self):
        with self.app.state.store.connect("BD") as db:
            db.execute("UPDATE accounts SET available=1 WHERE id='admin'")
            db.execute("UPDATE region.profiles SET blood_type='O+' WHERE id='admin'")

    def push_subscription(self):
        key = ec.generate_private_key(ec.SECP256R1())
        public = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        auth = b"0123456789abcdef"
        self.settings.push_origins = {"http://127.0.0.1:8090"}
        body = {"provider": "unifiedpush", "token": "http://127.0.0.1:8090/up-device-token", "pub_key": base64.urlsafe_b64encode(public).decode().rstrip("="), "auth": base64.urlsafe_b64encode(auth).decode().rstrip("=")}
        return key, auth, body

    def test_private_photo_is_sanitized_and_only_visible_during_accepted_match(self):
        upload = self.client.put("/api/v1/me/photo", content=self.photo_bytes(), headers={**self.seeker, "Content-Type": "image/jpeg"})
        self.assertEqual(upload.status_code, 200, upload.text)
        self.assertTrue(self.get("/me").json()["has_photo"])
        self.assertEqual(self.get("/profiles/seeker/photo", self.donor).status_code, 404)
        owned = self.get("/profiles/seeker/photo")
        self.assertEqual(owned.headers["cache-control"], "no-store")
        self.assertEqual(base64.b64decode(self.get("/me/export").json()["photo_jpeg_base64"]), owned.content)
        with Image.open(BytesIO(owned.content)) as image:
            self.assertEqual(image.size, (256, 512))
            self.assertEqual(len(image.getexif()), 0)
        created = self.post("/requests", self.request_body(["donor"]))
        self.assertEqual(created.status_code, 200, created.text)
        rid = created.json()["id"]
        pending = self.get(f"/requests/{rid}", self.donor).json()
        self.assertNotIn("destination_latitude", pending)
        self.assertIsNone(pending["peer_id"])
        accepted = self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.assertEqual(accepted.status_code, 200, accepted.text)
        self.assertEqual(accepted.json()["destination_latitude"], 23.8)
        self.assertTrue(accepted.json()["peer_has_photo"])
        self.assertEqual(self.get("/profiles/seeker/photo", self.donor).status_code, 200)
        self.assertEqual(self.get("/profiles/seeker/photo", self.admin).status_code, 404)
        self.assertEqual(self.post(f"/requests/{rid}/complete", {}).status_code, 200)
        self.assertEqual(self.get("/profiles/seeker/photo", self.donor).status_code, 404)

    def test_deleted_owner_removes_photo_destination_and_device(self):
        self.client.put("/api/v1/me/photo", content=self.photo_bytes(), headers={**self.seeker, "Content-Type": "image/jpeg"})
        _, _, device = self.push_subscription()
        self.post("/devices", device)
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.assertEqual(self.client.delete("/api/v1/me", headers=self.seeker).status_code, 200)
        self.assertEqual(self.get("/profiles/seeker/photo", self.donor).status_code, 404)
        with self.app.state.store.connect("BD") as db:
            self.assertEqual(db.execute("SELECT destination_name FROM region.donation_requests WHERE id=?", (rid,)).fetchone()[0], "[Removed]")
            self.assertEqual(db.execute("SELECT COUNT(*) FROM devices WHERE user_id='seeker'").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM region.profile_photos").fetchone()[0], 0)

    def test_photo_limits_block_travel_and_ban_revoke_access(self):
        self.assertEqual(self.client.put("/api/v1/me/photo", content=b"not an image", headers={**self.seeker, "Content-Type": "image/jpeg"}).status_code, 422)
        self.assertEqual(self.client.put("/api/v1/me/photo", content=b"x" * (5 * 1024 * 1024 + 1), headers={**self.seeker, "Content-Type": "image/jpeg"}).status_code, 413)
        self.client.put("/api/v1/me/photo", content=self.photo_bytes(), headers={**self.seeker, "Content-Type": "image/jpeg"})
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.post("/blocks", {"user_id": "donor"})
        self.assertEqual(self.get("/profiles/seeker/photo", self.donor).status_code, 404)
        moved = self.post("/location", {"country": "AU", "city": "Sydney", "latitude": -33.86, "longitude": 151.2, "mode": "automatic"})
        self.assertTrue(moved.json()["has_photo"])
        au = {**self.seeker, "X-Country": "AU"}
        self.assertEqual(self.get("/profiles/seeker/photo", au).status_code, 200)
        with self.app.state.store.connect("BD") as db:
            self.assertIsNone(db.execute("SELECT 1 FROM region.profile_photos WHERE user_id='seeker'").fetchone())
            self.assertEqual(db.execute("SELECT COUNT(*) FROM active_matches").fetchone()[0], 0)
            db.execute("UPDATE accounts SET banned=1 WHERE id='donor'")
        self.assertEqual(self.get("/requests", self.donor).status_code, 403)

    def test_concurrent_request_acceptance_has_one_winner_and_personalized_thanks(self):
        self.enable_admin_donor()
        rid = self.post("/requests", self.request_body(["donor", "admin"])).json()["id"]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda headers: self.post(f"/requests/{rid}/accept", {}, headers), [self.donor, self.admin]))
        self.assertEqual(sorted(result.status_code for result in results), [200, 409])
        winner = self.donor if results[0].status_code == 200 else self.admin
        loser = self.admin if results[0].status_code == 200 else self.donor
        self.assertEqual(self.post(f"/requests/{rid}/accept", {}, winner).status_code, 200)
        loser_request = self.get(f"/requests/{rid}", loser).json()
        self.assertNotIn("destination_latitude", loser_request)
        self.assertIsNone(loser_request["peer_id"])
        self.post(f"/requests/{rid}/complete", {})
        thanks = self.get("/events", loser).json()["items"]
        self.assertEqual(len(thanks), 1)
        self.assertEqual(thanks[0]["kind"], "thank_you")
        self.assertIn(self.get("/me", loser).json()["display_name"], thanks[0]["body"])
        with self.app.state.store.connect("BD") as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM region.events WHERE kind='request_accepted'").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM active_matches").fetchone()[0], 0)

    def test_request_radius_cooldown_decline_and_object_authorization(self):
        self.assertEqual(self.post("/requests", {**self.request_body(), "radius_km": 40}).status_code, 422)
        self.assertEqual(self.post("/requests", self.request_body(["donor-three"])).status_code, 409)
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.assertEqual(self.post("/requests", self.request_body(["donor"])).status_code, 409)
        self.assertEqual(self.get(f"/requests/{rid}", self.admin).status_code, 404)
        self.assertEqual(self.post(f"/requests/{rid}/accept", {}, self.admin).status_code, 404)
        self.post("/donations", {"donated_at": utcnow().date().isoformat()}, self.donor)
        self.assertEqual(self.post(f"/requests/{rid}/accept", {}, self.donor).status_code, 409)
        self.assertEqual(self.get("/events", self.donor).json()["items"], [])
        self.assertEqual(self.post(f"/requests/{rid}/decline", {}, self.donor).status_code, 200)
        self.assertEqual(self.post(f"/requests/{rid}/accept", {}, self.donor).status_code, 409)
        self.assertEqual(self.post(f"/requests/{rid}/cancel", {}).status_code, 200)

    def test_encrypted_push_delivery_retry_suppression_and_token_removal(self):
        key, auth, device = self.push_subscription()
        registered = self.post("/devices", device, self.donor)
        self.assertEqual(registered.status_code, 200, registered.text)
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        with patch("backend.push.httpx.post") as transport:
            transport.return_value.status_code = 503
            process_push(self.app.state.store, self.settings)
            with self.app.state.store.connect("BD") as db:
                job = db.execute("SELECT * FROM region.push_outbox").fetchone()
                self.assertEqual(job["status"], "pending")
                self.assertEqual(job["attempts"], 1)
                db.execute("UPDATE region.push_outbox SET next_attempt='2000-01-01'")
            transport.return_value.status_code = 201
            process_push(self.app.state.store, self.settings)
            encrypted = transport.call_args.kwargs["content"]
            decoded = http_ece.decrypt(encrypted, private_key=key, auth_secret=auth, version="aes128gcm").decode()
            self.assertIn(rid, decoded)
            self.assertNotIn("Nadia", decoded)
            self.assertNotIn("Hospital", decoded)
            self.assertFalse(transport.call_args.kwargs["follow_redirects"])
            with self.app.state.store.connect("BD") as db:
                self.assertEqual(db.execute("SELECT status FROM region.push_outbox").fetchone()[0], "sent")
        self.post(f"/requests/{rid}/cancel", {})
        rid2 = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.post("/donations", {"donated_at": utcnow().date().isoformat()}, self.donor)
        with patch("backend.push.httpx.post") as transport:
            process_push(self.app.state.store, self.settings)
            transport.assert_not_called()
        removed = self.client.request("DELETE", "/api/v1/devices", json={"token": device["token"]}, headers=self.donor)
        self.assertEqual(removed.status_code, 200)
        with self.app.state.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM devices").fetchone()[0], 0)

    def test_push_ssrf_keys_and_account_isolation(self):
        _, _, device = self.push_subscription()
        for token in ("https://attacker.example/push", "http://169.254.169.254/latest/meta-data", "http://127.0.0.1:8090@attacker.example/push"):
            self.assertEqual(self.post("/devices", {**device, "token": token}, self.donor).status_code, 422)
        self.assertEqual(self.post("/devices", {**device, "auth": "bad"}, self.donor).status_code, 422)
        self.assertEqual(self.post("/devices", device, self.donor).status_code, 200)
        self.assertEqual(self.post("/devices", device).status_code, 409)
        self.client.request("DELETE", "/api/v1/devices", json={"token": device["token"]}, headers=self.seeker)
        with self.app.state.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM devices").fetchone()[0], 1)

    def test_signout_removal_suppresses_queued_push_and_invalid_endpoints_are_removed(self):
        _, _, device = self.push_subscription()
        self.post("/devices", device, self.donor)
        rid = self.post("/requests", self.request_body(["donor"])).json()["id"]
        self.client.request("DELETE", "/api/v1/devices", json={"token": device["token"]}, headers=self.donor)
        with patch("backend.push.httpx.post") as transport:
            process_push(self.app.state.store, self.settings)
            transport.assert_not_called()
        self.post(f"/requests/{rid}/cancel", {})
        self.post("/devices", device, self.donor)
        self.post("/requests", self.request_body(["donor"]))
        with patch("backend.push.httpx.post") as transport:
            transport.return_value.status_code = 410
            process_push(self.app.state.store, self.settings)
        with self.app.state.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM devices").fetchone()[0], 0)

    def test_inbox_newest_default_and_cursor_skip_obsolete_history(self):
        self.enable_admin_donor()
        rid = self.post("/requests", self.request_body(["donor", "admin"])).json()["id"]
        self.post(f"/requests/{rid}/accept", {}, self.donor)
        self.post(f"/requests/{rid}/complete", {})
        with self.app.state.store.connect("BD") as db:
            for number in range(110):
                db.execute("INSERT INTO region.events(user_id,kind,title,body,request_id,created_at,read) VALUES('admin','thank_you','Past thanks',?,?,?,1)", (f"Old message {number}", rid, utcnow().isoformat()))
            newest = db.execute("INSERT INTO region.events(user_id,kind,title,body,request_id,created_at) VALUES('admin','thank_you','Latest thanks','Latest unread message',?,?)", (rid, utcnow().isoformat())).lastrowid
        default = self.get("/events", self.admin).json()
        self.assertEqual(default["items"][0]["id"], str(newest))
        self.assertFalse(default["items"][0]["read"])
        self.assertEqual(len(default["items"]), 100)
        incremental = self.get("/events", self.admin, params={"after": newest - 1}).json()
        self.assertEqual([item["id"] for item in incremental["items"]], [str(newest)])
        self.assertEqual(incremental["next_after"], str(newest))
        self.assertEqual(self.post(f"/events/{newest}/read", {}, self.donor).status_code, 404)

    def test_apns_adapter_uses_safe_watch_category_and_no_private_content(self):
        key = ec.generate_private_key(ec.SECP256R1())
        path = Path(self.temp.name) / "test-apns-key.p8"
        path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.settings.apns_key_path = str(path)
        self.settings.apns_key_id = "KEYID"
        self.settings.apns_team_id = "TEAMID"
        self.settings.apns_topic = "org.bindubashini.bloodconnection"
        event = {"id": 17, "kind": "thank_you", "request_id": "request-id", "country": "BD", "body": "Private personalized thanks"}
        device = {"provider": "apns", "token": "ab" * 32}
        with patch("backend.push.httpx.Client") as client:
            transport = client.return_value.__enter__.return_value
            transport.post.return_value.status_code = 200
            self.assertEqual(send_push(self.settings, device, event), "sent")
            body = transport.post.call_args.kwargs["json"]
            self.assertEqual(body["aps"]["category"], "PRIVATE_UPDATE")
            self.assertEqual(body["aps"]["alert"]["body"], "You have a private update. Open the app to view it.")
            self.assertNotIn("Private personalized thanks", str(body))
            bearer = transport.post.call_args.kwargs["headers"]["authorization"].split(" ", 1)[1]
            self.assertEqual(jwt.decode(bearer, key.public_key(), algorithms=["ES256"])["iss"], "TEAMID")
            report_event = {"id": 18, "kind": "report_reviewed", "report_id": "private-report-id", "report_country": "BD", "country": "BD", "body": "Private report outcome"}
            self.assertEqual(send_push(self.settings, device, report_event), "sent")
            report_payload = transport.post.call_args.kwargs["json"]
            self.assertNotIn("request_id", report_payload)
            self.assertNotIn("Private report outcome", str(report_payload))
            self.assertEqual(report_payload["report_id"], "private-report-id")
            self.assertEqual(report_payload["aps"]["category"], "PRIVATE_UPDATE")
        self.settings.apns_key_path = ""
        self.assertEqual(send_push(self.settings, device, event), "unconfigured")


if __name__ == "__main__":
    unittest.main()
