#!/usr/bin/env python3
"""Tests for dji-missions.py, with a pretend map and a pretend RC 2.

    python3 tests/test-missions.py

Nothing real is touched: the "map" is a small web server in this test, the
"RC 2" is a folder laid out like DJI Fly's, and every place the program
writes to is in a temporary folder. The missions are made up (Central
Park), never real flights.
"""
import base64
import hashlib
import http.server
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROGRAM = os.path.join(ROOT, "dji-missions.py")
KEY = "dock_TESTKEY_not_a_real_one"
UUID_A = "0A1B2C3D-0000-4000-8000-00000000000A"
UUID_B = "0A1B2C3D-0000-4000-8000-00000000000B"
JPG = b"\xff\xd8\xff\xe0fake picture"


def kmz(label):
    """A small pretend DJI Fly mission file (a zip, like the real ones)."""
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as zf:
        zf.writestr("wpmz/template.kml", f"<kml><!-- {label} --></kml>")
        zf.writestr("wpmz/waylines.wpml", "<kml><Placemark><Point><coordinates>-73.9665,40.7812</coordinates></Point></Placemark></kml>")
    return out.getvalue()


def sha(body):
    return hashlib.sha256(body).hexdigest()


class FakeMap:
    """Answers like DJI Flight Map's /api/dock/... addresses, and remembers what it was asked."""

    def __init__(self):
        self.queue = []          # sends waiting: {"id", "uuid", "expectSha256", "sha256", "planName"}
        self.files = {}          # send id -> bytes
        self.want_list = False
        self.results = {}        # send id -> what the dock reported
        self.reports = []        # each mission list the dock sent
        self.calls = []
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def answer(self, status, data, raw=False):
                body = data if raw else json.dumps(data).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def body(self):
                return json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")

            def handle_any(self):
                fake.calls.append((self.command, self.path))
                if self.headers.get("Authorization") != f"Bearer {KEY}":
                    return self.answer(401, {"error": "wrong dock key"})
                if self.path == "/api/dock/hello":
                    return self.answer(200, {"ok": True, "version": "9.9.9"})
                if self.path == "/api/dock/queue":
                    sends = [dict(s, url=f"/api/dock/kmz/{s['id']}") for s in fake.queue if s["id"] not in fake.results]
                    return self.answer(200, {"send": sends, "wantList": fake.want_list})
                if self.path.startswith("/api/dock/kmz/"):
                    return self.answer(200, fake.files[self.path.rsplit("/", 1)[1]], raw=True)
                if self.path.startswith("/api/dock/result/"):
                    fake.results[self.path.rsplit("/", 1)[1]] = self.body()
                    return self.answer(200, {"ok": True})
                if self.path == "/api/dock/missions":
                    fake.reports.append(self.body()["missions"])
                    fake.want_list = False
                    return self.answer(200, {"ok": True, "missions": len(fake.reports[-1])})
                return self.answer(404, {"error": "unknown"})

            do_GET = do_POST = do_PUT = handle_any

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def add_send(self, send_id, uuid, new, expect):
        self.files[send_id] = new
        self.queue.append({"id": send_id, "uuid": uuid, "expectSha256": expect, "sha256": sha(new),
                           "size": len(new), "planName": "Park loop"})


class Missions(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="dji-missions-test-")
        self.map = FakeMap()
        self.mnt = os.path.join(self.t, "mnt")
        self.files = os.path.join(self.mnt, "Internal shared storage", "Android", "data", "dji.go.v5", "files")
        self.waypoints = os.path.join(self.files, "waypoint")
        os.makedirs(os.path.join(self.files, "FlightRecord"))
        self.a, self.b = kmz("placeholder A"), kmz("mission B")
        self.put_mission(UUID_A, self.a, preview=True)
        self.put_mission(UUID_B, self.b)
        os.makedirs(os.path.join(self.waypoints, "capability"))          # DJI Fly's own folders are left alone
        self.conf = os.path.join(self.t, "map-link.conf")
        with open(self.conf, "w") as fh:
            fh.write(f"MAP_URL={self.map.url}\nDOCK_KEY={KEY}\n")
        self.usb = os.path.join(self.t, "usb")
        os.makedirs(self.usb)
        bin_dir = os.path.join(self.t, "bin")
        os.makedirs(bin_dir)
        for name in ("jmtpfs", "fusermount"):
            with open(os.path.join(bin_dir, name), "w") as fh:
                fh.write(f"#!/bin/bash\necho \"{name} $*\" >> '{self.t}/mounts'\n")
            os.chmod(os.path.join(bin_dir, name), 0o755)
        self.env = dict(os.environ, DJI_MAP_CONF=self.conf, DJI_MNT=self.mnt, DJI_BASE=os.path.join(self.t, "nas"),
                        DJI_STATE=os.path.join(self.t, "state"), DJI_LOG=os.path.join(self.t, "sync.log"),
                        DJI_LOCK=os.path.join(self.t, "sync.lock"), DJI_USB_DIR=self.usb, DJI_REQUIRE_MOUNT="0",
                        DJI_JMTPFS=os.path.join(bin_dir, "jmtpfs"), DJI_FUSERMOUNT=os.path.join(bin_dir, "fusermount"))
        os.makedirs(self.env["DJI_BASE"])

    def tearDown(self):
        self.map.server.shutdown()
        self.map.server.server_close()
        shutil.rmtree(self.t, ignore_errors=True)

    def put_mission(self, uuid, body, preview=False):
        os.makedirs(os.path.join(self.waypoints, uuid, "map_preview"), exist_ok=True)
        with open(os.path.join(self.waypoints, uuid, f"{uuid}.kmz"), "wb") as fh:
            fh.write(body)
        if preview:
            with open(os.path.join(self.waypoints, uuid, "map_preview", "preview.jpg"), "wb") as fh:
                fh.write(JPG)

    def on_rc2(self, uuid):
        with open(os.path.join(self.waypoints, uuid, f"{uuid}.kmz"), "rb") as fh:
            return fh.read()

    def run_it(self, *args, **env):
        return subprocess.run([sys.executable, PROGRAM, *args], env=dict(self.env, **env),
                              capture_output=True, text=True, timeout=60)

    def docked(self):
        flight_record = os.path.join(self.files, "FlightRecord")
        result = self.run_it("--docked", self.mnt, flight_record)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def log(self):
        with open(self.env["DJI_LOG"]) as fh:
            return fh.read()

    # ---- plugged in (from dji-sync.sh) ---------------------------------------------
    def test_not_linked_does_nothing(self):
        os.remove(self.conf)
        self.docked()
        self.assertEqual(self.map.calls, [])

    def test_reports_the_missions(self):
        self.docked()
        self.assertEqual(len(self.map.reports), 1, "every plug-in tells the map what is on the RC 2")
        listed = {m["uuid"]: m for m in self.map.reports[0]}
        self.assertEqual(set(listed), {UUID_A, UUID_B}, "only mission folders, not DJI Fly's own")
        self.assertEqual(base64.b64decode(listed[UUID_A]["kmz"]), self.a)
        self.assertEqual(base64.b64decode(listed[UUID_A]["preview"]), JPG)
        self.assertNotIn("preview", listed[UUID_B])

    def test_sends_a_route(self):
        new = kmz("the planned route")
        self.map.add_send("0123456789ab", UUID_A, new, expect=sha(self.a))
        self.docked()
        self.assertEqual(self.on_rc2(UUID_A), new, "the placeholder now holds the route")
        self.assertEqual(self.on_rc2(UUID_B), self.b, "the other mission is untouched")
        result = self.map.results["0123456789ab"]
        self.assertTrue(result["ok"], result)
        self.assertIn("checked", result["message"])
        backups = os.listdir(os.path.join(self.env["DJI_STATE"], "mission-backups"))
        self.assertEqual(len(backups), 1)
        with open(os.path.join(self.env["DJI_STATE"], "mission-backups", backups[0]), "rb") as fh:
            self.assertEqual(fh.read(), self.a, "the old placeholder is backed up on the Pi")
        with open(os.path.join(self.env["DJI_BASE"], "mission-backups", backups[0]), "rb") as fh:
            self.assertEqual(fh.read(), self.a, "...and on the NAS")
        self.assertIn("NAS", result["backup"])
        listed = {m["uuid"]: m for m in self.map.reports[-1]}
        self.assertEqual(base64.b64decode(listed[UUID_A]["kmz"]), new, "then the map gets the new list")
        self.assertIn('sent "Park loop"', self.log())
        leftovers = [n for _, _, names in os.walk(self.t) for n in names if n.endswith(".part")]
        self.assertEqual(leftovers, [], "no half-written files")

    def test_never_overwrites_a_mission_that_changed(self):
        self.map.add_send("0123456789ab", UUID_A, kmz("route"), expect=sha(kmz("what the map saw before")))
        self.docked()
        self.assertEqual(self.on_rc2(UUID_A), self.a, "nothing written")
        result = self.map.results["0123456789ab"]
        self.assertFalse(result["ok"])
        self.assertIn("changed on the RC 2", result["message"])
        self.assertFalse(os.path.exists(os.path.join(self.env["DJI_STATE"], "mission-backups")), "no backup needed")

    def test_a_damaged_download_is_not_written(self):
        new = kmz("route")
        self.map.add_send("0123456789ab", UUID_A, new, expect=sha(self.a))
        self.map.files["0123456789ab"] = new[:-10]          # cut short on the way
        self.docked()
        self.assertEqual(self.on_rc2(UUID_A), self.a)
        self.assertIn("damaged", self.map.results["0123456789ab"]["message"])

    def test_a_deleted_mission(self):
        self.map.add_send("0123456789ab", "0A1B2C3D-0000-4000-8000-0000000000FF", kmz("route"), expect=sha(self.a))
        self.docked()
        self.assertIn("isn't on the RC 2", self.map.results["0123456789ab"]["message"])

    def test_no_backup_no_write(self):
        blocker = os.path.join(self.t, "not-a-folder")
        with open(blocker, "w") as fh:
            fh.write("x")
        self.map.add_send("0123456789ab", UUID_A, kmz("route"), expect=sha(self.a))
        result = subprocess.run([sys.executable, PROGRAM, "--docked", self.mnt], timeout=60, capture_output=True,
                                env=dict(self.env, DJI_STATE=blocker))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.on_rc2(UUID_A), self.a, "the Pi backup failed, so nothing was written")
        self.assertIn("Could not back the old mission up", self.map.results["0123456789ab"]["message"])

    def test_wrong_key(self):
        with open(self.conf, "w") as fh:
            fh.write(f"MAP_URL={self.map.url}\nDOCK_KEY=dock_old\n")
        self.docked()
        self.assertIn("wrong dock key", self.log())

    def test_map_unreachable(self):
        with open(self.conf, "w") as fh:
            fh.write(f"MAP_URL=http://127.0.0.1:1\nDOCK_KEY={KEY}\n")
        self.docked()
        self.assertIn("can't reach the map", self.log())

    def test_writing_fails_and_the_old_file_goes_back(self):
        # In this same Python, so writing to the "RC 2" can be made to fail once.
        spec = importlib.util.spec_from_file_location("dji_missions", PROGRAM)
        old_env = dict(os.environ)
        os.environ.update(self.env)
        try:
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            real = mod.write_to_rc2
            calls = []

            def flaky(path, body):
                calls.append(body)
                if len(calls) == 1:
                    with open(path, "wb") as fh:
                        fh.write(body[:5])            # half-written, then the USB cable is pulled
                    raise OSError("USB connection lost")
                return real(path, body)

            mod.write_to_rc2 = flaky
            self.map.add_send("0123456789ab", UUID_A, kmz("route"), expect=sha(self.a))
            mod.docked(self.mnt)
        finally:
            os.environ.clear()
            os.environ.update(old_env)
        self.assertEqual(self.on_rc2(UUID_A), self.a, "the old mission was put back")
        result = self.map.results["0123456789ab"]
        self.assertFalse(result["ok"])
        self.assertIn("USB connection lost", result["message"])
        self.assertIn("put back", result["message"])

    def test_sending_twice_is_harmless(self):
        new = kmz("route")
        self.put_mission(UUID_A, new)
        self.map.add_send("0123456789ab", UUID_A, new, expect=sha(self.a))
        self.docked()
        self.assertTrue(self.map.results["0123456789ab"]["ok"])
        self.assertIn("already had exactly this route", self.map.results["0123456789ab"]["message"])

    # ---- every 2 minutes (dji-missions.timer) --------------------------------------
    def plug_in(self):
        dev = os.path.join(self.usb, "1-1")
        os.makedirs(dev)
        for name, value in (("idVendor", "2ca3"), ("idProduct", "1021")):
            with open(os.path.join(dev, name), "w") as fh:
                fh.write(value + "\n")

    def mounts(self):
        try:
            with open(os.path.join(self.t, "mounts")) as fh:
                return fh.read()
        except FileNotFoundError:
            return ""

    def test_check_does_nothing_without_the_rc2(self):
        self.map.add_send("0123456789ab", UUID_A, kmz("route"), expect=sha(self.a))
        self.assertEqual(self.run_it("--check").returncode, 0)
        self.assertEqual(self.map.calls, [], "the RC 2 isn't plugged in: the map isn't even asked")

    def test_check_only_mounts_when_there_is_work(self):
        self.plug_in()
        self.run_it("--check")
        self.assertEqual(len(self.map.calls), 1, "asks the map")
        self.assertEqual(self.mounts(), "", "nothing to do: the RC 2 isn't opened")
        self.map.want_list = True
        self.run_it("--check")
        self.assertEqual(len(self.map.reports), 1, "the map asked for a new list")
        self.assertIn("jmtpfs", self.mounts())
        self.assertIn("fusermount -u", self.mounts(), "and the RC 2 is closed again")

    def test_check_sends_while_docked(self):
        self.plug_in()
        new = kmz("route")
        self.map.add_send("0123456789ab", UUID_A, new, expect=sha(self.a))
        self.run_it("--check")
        self.assertEqual(self.on_rc2(UUID_A), new)
        self.assertTrue(self.map.results["0123456789ab"]["ok"])

    def test_check_waits_for_a_running_sync(self):
        self.plug_in()
        self.map.add_send("0123456789ab", UUID_A, kmz("route"), expect=sha(self.a))
        holder = subprocess.Popen(["flock", self.env["DJI_LOCK"], "sleep", "3"])
        try:
            import time
            time.sleep(0.5)
            self.run_it("--check")
        finally:
            holder.wait()
        self.assertEqual(self.map.calls, [], "a log sync is running (it does the routes itself)")
        self.assertEqual(self.on_rc2(UUID_A), self.a)

    # ---- sudo dji-map-link -----------------------------------------------------------------
    def link(self, answers, key):
        spec = importlib.util.spec_from_file_location("dji_missions_link", PROGRAM)
        old_env = dict(os.environ)
        os.environ.update(self.env, DJI_MAP_CONF=os.path.join(self.t, "new.conf"))
        try:
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            mod.input = lambda prompt="": answers.pop(0)
            mod.getpass.getpass = lambda prompt="": key
            out = io.StringIO()
            real_stdout, sys.stdout = sys.stdout, out
            try:
                mod.link()
                code = 0
            except SystemExit as exc:
                code = exc.code
            finally:
                sys.stdout = real_stdout
        finally:
            os.environ.clear()
            os.environ.update(old_env)
        return code, out.getvalue()

    def test_link(self):
        code, out = self.link([self.map.url], KEY)
        self.assertEqual(code, 0, out)
        self.assertIn("Connected to DJI Flight Map 9.9.9", out)
        path = os.path.join(self.t, "new.conf")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600, "the key is readable by root only")
        with open(path) as fh:
            self.assertIn(f"DOCK_KEY={KEY}", fh.read())

    def test_link_refuses_a_wrong_key(self):
        code, _ = self.link([self.map.url], "dock_wrong")
        self.assertIn("401", str(code))
        self.assertFalse(os.path.exists(os.path.join(self.t, "new.conf")), "nothing saved")
        code, _ = self.link(["not an address"], KEY)
        self.assertIn("doesn't look like an address", str(code))


if __name__ == "__main__":
    unittest.main(verbosity=2)
