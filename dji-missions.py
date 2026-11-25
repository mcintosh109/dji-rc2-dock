#!/usr/bin/env python3
"""dji-missions - put planned routes from DJI Flight Map on the DJI RC 2.

DJI Fly has no import button. A route planned on DJI Flight Map is put on
the RC 2 IN PLACE OF a "placeholder" waypoint mission made in DJI Fly
(DJI Fly keeps each mission in
  Android/data/dji.go.v5/files/waypoint/<UUID>/<UUID>.kmz).

  dji-missions --link            set up (or change) the link to the map: asks
                                 for the map's address and its dock key
                                 (installed as: sudo dji-map-link)
  dji-missions --docked <mount> [<FlightRecord folder>]
                                 run by dji-sync.sh while the RC 2 is mounted
                                 (every time it is plugged in)
  dji-missions --check           run every 2 minutes by dji-missions.timer: if
                                 the RC 2 is plugged in AND the map has
                                 something for it, mount it and do the work

What it does, each time:
  1. asks the map (GET /api/dock/queue, with the dock key) what to send
  2. for each route to send:
       - checks the placeholder on the RC 2 is EXACTLY the file the owner
         picked on the map (its SHA-256 fingerprint). If it changed (edited
         in DJI Fly since), nothing is written.
       - downloads the new route and checks its fingerprint
       - backs the placeholder's file up: on the Pi (always) and on the NAS
         (when mounted). Without the Pi backup, nothing is written.
       - writes the new file, reads it back and compares. If that fails, the
         old file is put back.
       - tells the map how it went (POST /api/dock/result/<id>)
  3. reports the RC 2's missions to the map (PUT /api/dock/missions), so the
     owner can pick a placeholder: on every plug-in, after sending, and
     when the map asks for a new list.

It never touches anything else on the RC 2, never makes or deletes
missions, and never stops the flight log sync: any problem is logged and
the log sync carries on.

Settings: /etc/dji-map-link.conf (made by dji-map-link, readable by root only).
The DJI_* environment variables are only for the tests (tests/test-missions.py).
Research: "MTP", "SHA-256 checksum", "bearer token".
"""
import base64
import fcntl
import getpass
import glob
import hashlib
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

CONF = os.environ.get("DJI_MAP_CONF", "/etc/dji-map-link.conf")
CA_FILE = os.environ.get("DJI_MAP_CA", "/etc/dji-map-ca.pem")
MNT = os.environ.get("DJI_MNT", "/mnt/rc2")
BASE = os.environ.get("DJI_BASE", "/srv/dji")                 # the NAS share
STATE = os.environ.get("DJI_STATE", "/var/lib/dji-dock")       # on the Pi's SD card
LOG = os.environ.get("DJI_LOG", "/var/log/dji-sync.log")
LOCK = os.environ.get("DJI_LOCK", "/run/dji-sync.lock")
USB_DIR = os.environ.get("DJI_USB_DIR", "/sys/bus/usb/devices")
JMTPFS = os.environ.get("DJI_JMTPFS", "jmtpfs")
FUSERMOUNT = os.environ.get("DJI_FUSERMOUNT", "fusermount")
REQUIRE_MOUNT = os.environ.get("DJI_REQUIRE_MOUNT", "1") == "1"
RC2_USB = ("2ca3", "1021")      # DJI RC 2 (the same as 99-dji-rc2.rules)
UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
SEND_ID_RE = re.compile(r"^[0-9a-f]{12}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_KMZ = 2 * 1024 * 1024
MAX_PREVIEW = 512 * 1024
MAX_MISSIONS = 100
KEEP_BACKUPS = 200
TIMEOUT = 20


def log(message):
    line = f"{time.strftime('%a %b %d %H:%M:%S %Z %Y')} - missions: {message}"   # like `date` in dji-sync.sh
    try:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass
    print(line, flush=True)


def sha256(body):
    return hashlib.sha256(body).hexdigest()


# ---- the link to the map ----------------------------------------------------------
def read_conf():
    conf = {}
    try:
        with open(CONF, encoding="utf-8") as fh:
            for line in fh:
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    conf[k.strip()] = v.strip()
    except FileNotFoundError:
        return None
    if not conf.get("MAP_URL") or not conf.get("DOCK_KEY"):
        return None
    return conf


class Map:
    """Talks to DJI Flight Map's dock addresses (/api/dock/...)."""

    def __init__(self, url, key, cafile=None):
        self.url = url.rstrip("/")
        self.key = key
        self.ctx = ssl.create_default_context(cafile=cafile) if cafile else ssl.create_default_context()

    def call(self, path, method="GET", data=None, raw=False):
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(self.url + path, data=body, method=method, headers={
            "Authorization": f"Bearer {self.key}", "Content-Type": "application/json",
            "User-Agent": "dji-rc2-dock"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT, context=self.ctx) as res:
                answer = res.read()
        except urllib.error.HTTPError as err:
            with err:
                detail = err.read()[:300].decode("utf-8", "replace")
            try:
                detail = json.loads(detail).get("error", detail)
            except ValueError:
                pass
            raise MapError(f"the map answered {err.code}: {detail}") from err
        except (urllib.error.URLError, OSError) as err:
            raise MapError(f"can't reach the map at {self.url}: {getattr(err, 'reason', err)}") from err
        return answer if raw else json.loads(answer or b"{}")


class MapError(Exception):
    pass


def open_map():
    conf = read_conf()
    if conf is None:
        return None
    cafile = conf.get("MAP_CA") or None
    if cafile and not os.path.exists(cafile):
        log(f"the map's certificate file {cafile} is missing: run sudo dji-map-link again")
        cafile = None
    return Map(conf["MAP_URL"], conf["DOCK_KEY"], cafile)


def link():
    """sudo dji-map-link: ask for the map's address and dock key, test them, save them."""
    if os.geteuid() != 0 and CONF.startswith("/etc/"):
        sys.exit("Run with sudo:  sudo dji-map-link")
    print("Link this dock to DJI Flight Map, so it can put planned routes on the RC 2.")
    print("On the map: Settings -> RC 2 dock -> Make a dock key. It shows the key and the address.\n")
    url = input("The map's address (e.g. https://flightmap.home): ").strip().rstrip("/")
    if not re.fullmatch(r"https?://[A-Za-z0-9.\-\[\]:]+(/[^\s]*)?", url):
        sys.exit("That doesn't look like an address. It starts with https:// - nothing was changed.")
    key = getpass.getpass("The dock key (paste it; nothing shows while you paste): ").strip()
    if not key.startswith("dock_"):
        sys.exit("A dock key starts with dock_ - nothing was changed.")
    cafile = None
    try:
        hello = Map(url, key).call("/api/dock/hello")
    except MapError as err:
        if "CERTIFICATE_VERIFY_FAILED" not in str(err):
            sys.exit(f"Could not connect: {err}\nNothing was changed.")
        # The map uses its own private certificate (Settings -> Secure connection).
        cafile = trust_private_certificate(url)
        try:
            hello = Map(url, key, cafile).call("/api/dock/hello")
        except MapError as err2:
            sys.exit(f"Could not connect: {err2}\nNothing was changed.")
    if not hello.get("ok"):
        sys.exit("The map answered, but not as expected. Nothing was changed.")
    old = os.umask(0o077)
    try:
        with open(CONF + ".tmp", "w", encoding="utf-8") as fh:
            fh.write("# Made by dji-map-link. The dock key works like a password: keep this file private.\n")
            fh.write(f"MAP_URL={url}\nDOCK_KEY={key}\n")
            if cafile:
                fh.write(f"MAP_CA={cafile}\n")
        os.replace(CONF + ".tmp", CONF)
    finally:
        os.umask(old)
    print(f"\nConnected to DJI Flight Map {hello.get('version', '')} at {url}")
    print("Plug the RC 2 in and unlock it: the map gets its list of missions within about 2 minutes.")


def trust_private_certificate(url):
    """Fetch the map's private certificate (from its plain-http port) and keep it, after asking."""
    host = re.sub(r"^https?://", "", url).split("/")[0]
    hostname = host.rsplit(":", 1)[0] if host.count(":") == 1 else host
    ca_url = f"http://{hostname}:8080/flightmap-ca.crt"
    print("\nThe map uses its own private certificate (Settings -> Secure connection: Private certificate).")
    try:
        with urllib.request.urlopen(ca_url, timeout=TIMEOUT) as res:
            pem = res.read(65536)
    except (urllib.error.URLError, OSError) as err:
        sys.exit(f"Could not download it from {ca_url}: {err}\nNothing was changed.")
    if b"BEGIN CERTIFICATE" not in pem:
        sys.exit(f"{ca_url} didn't send a certificate. Nothing was changed.")
    der = ssl.PEM_cert_to_DER_cert(pem.decode("ascii", "replace"))
    print(f"Its fingerprint (SHA-256): {sha256(der)}")
    if input("Trust it for talking to the map? [y/N] ").strip().lower() not in ("y", "yes"):
        sys.exit("Nothing was changed.")
    old = os.umask(0o022)
    try:
        with open(CA_FILE, "wb") as fh:
            fh.write(pem)
    finally:
        os.umask(old)
    return CA_FILE


# ---- the RC 2 ---------------------------------------------------------------------------
def rc2_plugged_in():
    for dev in glob.glob(os.path.join(USB_DIR, "*")):
        try:
            with open(os.path.join(dev, "idVendor")) as v, open(os.path.join(dev, "idProduct")) as p:
                if (v.read().strip(), p.read().strip()) == RC2_USB:
                    return True
        except OSError:
            continue
    return False


DJI_FILES = os.path.join("Android", "data", "dji.go.v5", "files")


def find_waypoint_dir(root, flight_record=None):
    """DJI Fly's waypoint folder on the mounted RC 2 (next to FlightRecord), or None.

    Every folder looked at is a question to the RC 2 over USB, so the usual
    places are tried first.
    """
    if flight_record:
        candidate = os.path.join(os.path.dirname(flight_record.rstrip("/")), "waypoint")
        if os.path.isdir(candidate):
            return candidate
    for storage in sorted(glob.glob(os.path.join(root, "*"))):
        candidate = os.path.join(storage, DJI_FILES, "waypoint")
        if os.path.isdir(candidate):
            return candidate
    # Somewhere else: look for FlightRecord, like dji-sync.sh does.
    for dirpath, dirnames, _ in os.walk(root):
        if "FlightRecord" in dirnames and os.path.isdir(os.path.join(dirpath, "waypoint")):
            return os.path.join(dirpath, "waypoint")
        if dirpath[len(root):].count(os.sep) >= 6:
            dirnames[:] = []
    return None


def mission_path(waypoints, uuid):
    return os.path.join(waypoints, uuid, f"{uuid}.kmz")


def list_missions(waypoints):
    """Every DJI Fly mission on the RC 2, as the map wants them."""
    missions = []
    for folder in sorted(os.listdir(waypoints)):
        if not UUID_RE.match(folder):
            continue
        path = mission_path(waypoints, folder)
        try:
            size = os.path.getsize(path)
            if size > MAX_KMZ:
                continue
            with open(path, "rb") as fh:
                body = fh.read()
            modified = datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M")
        except OSError:
            continue
        item = {"uuid": folder, "kmz": base64.b64encode(body).decode(), "modified": modified}
        picture = find_preview(os.path.join(waypoints, folder))
        if picture:
            item["preview"] = base64.b64encode(picture).decode()
        missions.append(item)
        if len(missions) >= MAX_MISSIONS:
            break
    return missions


def find_preview(folder):
    """DJI Fly's small picture of the route (in map_preview/), or None."""
    for path in sorted(glob.glob(os.path.join(folder, "map_preview", "*"))):
        if path.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
            try:
                if os.path.getsize(path) <= MAX_PREVIEW:
                    with open(path, "rb") as fh:
                        return fh.read()
            except OSError:
                continue
    return None


# ---- backups --------------------------------------------------------------------------------
def nas_mounted():
    if not REQUIRE_MOUNT:
        return os.path.isdir(BASE)
    try:
        os.listdir(BASE)       # wakes an automount
        with open("/proc/mounts") as fh:
            return any(line.split()[1] == BASE and line.split()[2] != "autofs" for line in fh if len(line.split()) > 2)
    except OSError:
        return False


def write_new(path, body):
    """Write body to path under a hidden name, then rename it (never half-written)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".part")
    with open(tmp, "wb") as fh:
        fh.write(body)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def back_up(uuid, body):
    """Keep a copy of a placeholder before it is replaced. Returns where (for the map), or raises OSError."""
    name = f"{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}_{uuid}.kmz"
    local = os.path.join(STATE, "mission-backups", name)
    write_new(local, body)                     # must work: otherwise nothing is written
    with open(local, "rb") as fh:
        if sha256(fh.read()) != sha256(body):
            raise OSError("the backup on the Pi doesn't match")
    where = f"the Pi: {local}"
    if nas_mounted():
        try:
            write_new(os.path.join(BASE, "mission-backups", name), body)
            where += f", and the NAS: mission-backups/{name}"
        except OSError as exc:
            log(f"could not also back up to the NAS ({exc}); the backup on the Pi is kept")
    old = sorted(glob.glob(os.path.join(STATE, "mission-backups", "*.kmz")))
    for path in old[:-KEEP_BACKUPS]:
        os.remove(path)
    return where


# ---- sending ----------------------------------------------------------------------------------
def write_to_rc2(path, body):
    """Replace the file on the RC 2 (over MTP), then read it back."""
    try:
        with open(path, "wb") as fh:
            fh.write(body)
    except OSError:
        # Some MTP connections can't overwrite in place: remove, then write.
        os.remove(path)
        with open(path, "wb") as fh:
            fh.write(body)
    with open(path, "rb") as fh:
        return sha256(fh.read()) == sha256(body)


def send_one(m, waypoints, send):
    """Do one send from the queue. Returns (ok, message, backup)."""
    uuid = send.get("uuid", "")
    if not (UUID_RE.match(uuid) and SEND_ID_RE.match(send.get("id", "")) and SHA_RE.match(send.get("sha256", ""))):
        return False, "The map sent something odd: nothing was changed.", ""
    path = mission_path(waypoints, uuid)
    try:
        with open(path, "rb") as fh:
            current = fh.read(MAX_KMZ + 1)
    except OSError:
        return False, "That mission isn't on the RC 2 any more (deleted in DJI Fly?). Nothing was changed.", ""
    if sha256(current) == send["sha256"]:
        return True, "The RC 2 already had exactly this route.", ""
    if sha256(current) != send.get("expectSha256"):
        return False, ("The mission changed on the RC 2 since its list was sent (edited or saved in DJI Fly?). "
                       "Nothing was changed. Refresh the list on the map and send again."), ""
    try:
        new = m.call(f"/api/dock/kmz/{send['id']}", raw=True)
    except MapError as err:
        return False, f"Could not download the route from the map: {err}", ""
    if sha256(new) != send["sha256"] or not new.startswith(b"PK"):
        return False, "The route downloaded from the map was damaged: nothing was changed.", ""
    try:
        backup = back_up(uuid, current)
    except OSError as exc:
        return False, f"Could not back the old mission up on the Pi ({exc}): nothing was changed.", ""
    try:
        if write_to_rc2(path, new):
            return True, "Written to the RC 2 and checked.", backup
        problem = "the file read back from the RC 2 was different"
    except OSError as exc:
        problem = str(exc)
    # Put the old file back.
    try:
        restored = write_to_rc2(path, current)
    except OSError:
        restored = False
    return False, (f"Writing to the RC 2 failed ({problem}). "
                   + ("The old mission was put back." if restored else f"The old mission is backed up on {backup}.")), backup


def work(m, waypoints, report_always):
    """Send what the map has waiting, then report the missions if needed."""
    queue = m.call("/api/dock/queue")
    sent = 0
    for send in queue.get("send", [])[:20]:
        ok, message, backup = send_one(m, waypoints, send)
        log(f"{'sent' if ok else 'NOT sent'} \"{send.get('planName', '')}\" to mission {send.get('uuid')}: {message}")
        try:
            m.call(f"/api/dock/result/{send['id']}", "POST", {"ok": ok, "message": message, "backup": backup})
        except MapError as err:
            log(f"could not tell the map: {err}")
        sent += 1
    if report_always or sent or queue.get("wantList"):
        missions = list_missions(waypoints)
        answer = m.call("/api/dock/missions", "PUT", {"missions": missions})
        log(f"told the map about {answer.get('missions', len(missions))} mission(s) on the RC 2")


# ---- the three ways to run ---------------------------------------------------------------------
def docked(mount, flight_record=None):
    """From dji-sync.sh, with the RC 2 already mounted (and the sync lock held)."""
    m = open_map()
    if m is None:
        return 0                    # not linked to a map: nothing to do
    waypoints = find_waypoint_dir(mount, flight_record)
    if waypoints is None:
        log("DJI Fly's waypoint folder isn't on the RC 2 yet (make one waypoint mission in DJI Fly first)")
        return 0
    try:
        work(m, waypoints, report_always=True)
    except MapError as err:
        log(str(err))
    return 0


def check():
    """Every 2 minutes: only if the RC 2 is plugged in and the map has something for it."""
    m = open_map()
    if m is None or not rc2_plugged_in():
        return 0
    lock = open(LOCK, "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0                    # a log sync is running; it does this itself
    try:
        queue = m.call("/api/dock/queue")
    except MapError as err:
        print(err)                  # journal only: this runs every 2 minutes
        return 0
    if not queue.get("send") and not queue.get("wantList"):
        return 0
    os.makedirs(MNT, exist_ok=True)
    if subprocess.run([JMTPFS, MNT], capture_output=True).returncode != 0:
        print("the RC 2 is plugged in but can't be opened (locked?)")
        return 0
    try:
        waypoints = find_waypoint_dir(MNT)
        if waypoints is None:
            print("DJI Fly's waypoint folder not found (RC 2 locked, or no missions yet)")
            return 0
        work(m, waypoints, report_always=False)
    except MapError as err:
        log(str(err))
    finally:
        if subprocess.run([FUSERMOUNT, "-u", MNT], capture_output=True).returncode != 0:
            subprocess.run([FUSERMOUNT, "-uz", MNT], capture_output=True)   # a "lazy" unmount
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--link":
        return link()
    if len(argv) >= 3 and argv[1] == "--docked":
        return docked(argv[2], argv[3] if len(argv) > 3 else None)
    if len(argv) >= 2 and argv[1] == "--check":
        return check()
    print(__doc__.split("What it does")[0].strip())
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(1)
    except Exception as exc:       # never leave the log sync with a crash
        log(f"unexpected problem: {exc}")
        sys.exit(0)
