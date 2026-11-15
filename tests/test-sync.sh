#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-sync.sh - tests for dji-sync.sh, with a fake controller and parser.
#
#   bash tests/test-sync.sh
#
# Nothing real is touched: the "controller", "storage" and "dji-log" are all
# fakes in a temporary folder. Needs rsync, flock and findmnt (util-linux).
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/dji-sync.sh"
T=$(mktemp -d /tmp/dji-sync-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILED=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then echo "  PASS  $name"; PASSED=$((PASSED+1)); else echo "  FAIL  $name"; FAILED=$((FAILED+1)); fi; }

# ---- fakes -------------------------------------------------------------------
mkdir -p "$T/bin" "$T/rc2-files" "$T/mnt" "$T/storage"
cat > "$T/bin/jmtpfs" <<EOF
#!/bin/bash
# fake controller: "mount" = copy the fake controller's files into place.
# While $T/locked exists it acts like a locked controller and fails.
[ -e "$T/locked" ] && { echo "no MTP device found" >&2; exit 1; }
mkdir -p "\$1/Internal shared storage/DJI/dji.go.v5/FlightRecord"
cp -p "$T/rc2-files/"* "\$1/Internal shared storage/DJI/dji.go.v5/FlightRecord/" 2>/dev/null
echo mounted >> "$T/mounts"
EOF
cat > "$T/bin/fusermount" <<EOF
#!/bin/bash
rm -rf "$T/mnt/Internal shared storage"; echo unmounted >> "$T/mounts"
EOF
cat > "$T/bin/dji-log" <<'EOF'
#!/bin/bash
# fake parser: --api-key K --csv C --geojson G FILE. Writes slowly (so the
# test can look for half-written files) and fails for files named *BROKEN*,
# or for every file when FAKE_OFFLINE is set (like having no internet).
while [ $# -gt 1 ]; do case "$1" in --csv) csv=$2; shift;; --geojson) geo=$2; shift;; esac; shift; done
file=$1
echo "partial" > "$csv"
sleep "${FAKE_PARSE_SECONDS:-0}"
case "$file" in *BROKEN*) exit 1;; esac
[ -n "${FAKE_OFFLINE:-}" ] && { echo "network error" >&2; exit 1; }
echo "csv for $(basename "$file") END" > "$csv"
echo "geojson END" > "$geo"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export DJI_MNT="$T/mnt" DJI_BASE="$T/storage" DJI_LOG="$T/sync.log" DJI_LOCK="$T/sync.lock" \
       DJI_APIKEY_FILE="$T/apikey" DJI_REQUIRE_MOUNT=0 DJI_STATE="$T/state"
echo "TESTKEY" > "$T/apikey"
flight() { echo "raw $1" > "$T/rc2-files/$1.txt"; }
sessions() { find "$T/storage/archive" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | wc -l; }
hidden_left() { find "$T/storage" -name '.*' -not -name '.' | grep -q .; }

echo "Storage not mounted"
DJI_REQUIRE_MOUNT=1 bash "$SYNC"; code=$?
check "exits 0 (any logs wait safely in the cache)" [ "$code" -eq 0 ]
check "  ...and writes nothing to the storage" bash -c "[ -z \"\$(ls -A '$T/storage')\" ]"
check "  ...and says why in the log" grep -q "storage is not mounted" "$T/sync.log"

echo "First dock"
flight FlightRecord_2026-01-10_A; flight FlightRecord_2026-01-10_B
bash "$SYNC"
check "one archive session made" [ "$(sessions)" -eq 1 ]
check "raw logs archived" bash -c "ls '$T'/storage/archive/*/raw/FlightRecord_2026-01-10_A.txt"
check "parsed CSV + GeoJSON archived" bash -c "ls '$T'/storage/archive/*/parsed/FlightRecord_2026-01-10_B.csv '$T'/storage/archive/*/parsed/FlightRecord_2026-01-10_B.geojson"
check "no half-written or hidden leftovers" bash -c "! find '$T/storage' -name '.*' | grep -q ."
check "controller unmounted" bash -c "[ \"\$(grep -c unmounted '$T/mounts')\" -ge 1 ]"

echo "Dock again with nothing new"
bash "$SYNC"
check "no extra session" [ "$(sessions)" -eq 1 ]
check "log says no new flights" grep -q "no new flights" "$T/sync.log"

echo "A flight that fails to parse"
flight FlightRecord_2026-01-11_BROKEN; flight FlightRecord_2026-01-11_C
bash "$SYNC"
check "failure is logged" grep -q "parse failed: FlightRecord_2026-01-11_BROKEN" "$T/sync.log"
check "no broken CSV left anywhere" bash -c "! find '$T/storage' -name '*BROKEN*.csv' | grep -q ."
check "the other flight still parsed" bash -c "ls '$T'/storage/parsed/FlightRecord_2026-01-11_C.csv"

echo "Map reading while the dock writes"
flight FlightRecord_2026-01-12_D
( FAKE_PARSE_SECONDS=2 bash "$SYNC" ) & pid=$!
bad=0
while kill -0 "$pid" 2>/dev/null; do
  # What the map can see: CSVs not inside hidden folders/names.
  while IFS= read -r f; do grep -q END "$f" || bad=1; done < <(find "$T/storage" -name '*.csv' -not -path '*/.*')
  sleep 0.1
done
check "the map never sees a half-written CSV" [ "$bad" -eq 0 ]

echo "Same second: archive folder already exists"
flight FlightRecord_2026-01-13_E
for i in 0 1 2 3; do mkdir -p "$T/storage/archive/$(date -d "+$i sec" +%Y-%m-%d_%H-%M-%S)/raw"; echo keep > "$T/storage/archive/$(date -d "+$i sec" +%Y-%m-%d_%H-%M-%S)/raw/keep.txt"; done
bash "$SYNC"
check "new session got another name (-2)" bash -c "ls -d '$T'/storage/archive/*-2"
check "the existing folder was not touched" bash -c "for f in '$T'/storage/archive/*/raw/keep.txt; do grep -qx keep \"\$f\" || exit 1; done"

echo "Raw folder cleared, then docked again"
echo "MARK" >> "$T/storage/parsed/FlightRecord_2026-01-10_A.csv"
rm -rf "$T/storage/raw"
# The Pi remembers which logs it already uploaded; forget that too, so
# everything is copied from the controller again.
rm -f "$T/state/uploaded.list"
bash "$SYNC"
check "already-parsed flights are not parsed again" grep -q "already parsed: FlightRecord_2026-01-10_A" "$T/sync.log"
check "their parsed files are not replaced" grep -q MARK "$T/storage/parsed/FlightRecord_2026-01-10_A.csv"
check "  ...but they are in the new session, so the map sees them" bash -c "grep -l MARK '$T'/storage/archive/[0-9]*/parsed/FlightRecord_2026-01-10_A.csv | grep -q ."

echo "Two syncs at once"
flight FlightRecord_2026-01-14_F
( flock 9; sleep 2 ) 9>"$T/sync.lock" & holder=$!
sleep 0.3
DJI_LOCK_WAIT=0 bash "$SYNC"
check "second sync is skipped" grep -q "another sync is already running" "$T/sync.log"
check "  ...and changed nothing" bash -c "! ls '$T'/storage/raw/FlightRecord_2026-01-14_F.txt"
wait "$holder"

echo "Parse fails (no internet), then is retried on the next dock"
flight FlightRecord_2026-01-15_G
FAKE_OFFLINE=1 bash "$SYNC"; code=$?
check "a failed parse still counts as success (exit 0)" [ "$code" -eq 0 ]
check "the log says it will retry" grep -q "parse failed: FlightRecord_2026-01-15_G (will retry on next dock)" "$T/sync.log"
check "no CSV yet" bash -c "! ls '$T'/storage/parsed/FlightRecord_2026-01-15_G.csv"
bash "$SYNC"
check "parsed on the next dock, with nothing new to copy" grep -q "parsed: FlightRecord_2026-01-15_G" "$T/sync.log"
check "  ...and its parsed files went into the session holding its raw log" \
  bash -c "ls '$T'/storage/archive/[0-9]*/parsed/FlightRecord_2026-01-15_G.csv"
check "  ...with no hidden leftovers" bash -c "! find '$T/storage' -name '.*' | grep -q ."

echo "Controller locked at first, then unlocked"
touch "$T/locked"
( sleep 1; rm -f "$T/locked" ) &
DJI_UNLOCK_WAIT=10 DJI_RETRY_EVERY=1 bash "$SYNC"; code=$?
wait
check "waited for the controller to be unlocked" grep -q "waiting for the controller to be unlocked" "$T/sync.log"
check "  ...then synced normally (exit 0)" [ "$code" -eq 0 ]

echo "Controller never unlocked"
touch "$T/locked"
DJI_UNLOCK_WAIT=1 DJI_RETRY_EVERY=1 bash "$SYNC"; code=$?
rm -f "$T/locked"
check "gives up with exit code 1" [ "$code" -eq 1 ]
check "  ...and says why in the log" grep -q "FlightRecord folder not found after 1s" "$T/sync.log"
check "  ...including the last mount error" grep -q "last mount error: no MTP device found" "$T/sync.log"

echo "Copy fails partway"
printf '#!/bin/bash\necho "rsync: connection unexpectedly closed" >&2\nexit 12\n' > "$T/bin/rsync"
chmod +x "$T/bin/rsync"
bash "$SYNC"; code=$?
rm -f "$T/bin/rsync"
check "exit code 1" [ "$code" -eq 1 ]
check "the log says the copy failed" grep -q "copy from the controller failed (rsync exit code 12)" "$T/sync.log"

echo "Stopped partway (e.g. the 30 minute time limit)"
printf '#!/bin/bash\nsleep 5\n' > "$T/bin/rsync"
chmod +x "$T/bin/rsync"
bash "$SYNC" & pid=$!
sleep 1
# systemd stops every process of the service, so stop the fake rsync too
pkill -TERM -f "$T/bin/rsync"; kill -TERM "$pid"
wait "$pid"; code=$?
rm -f "$T/bin/rsync"
check "exit code 1" [ "$code" -eq 1 ]
check "the log says it was stopped" grep -q "stopped before finishing" "$T/sync.log"
check "  ...and the controller was unmounted" bash -c "[ \"\$(tail -n1 '$T/mounts')\" = unmounted ]"

cached() { find "$T/state/cache" -type f | wc -l; }

echo "NAS down when docking: logs wait in the cache on the Pi"
flight "DJIFlightRecord_2026-02-01_[10-00-00]"; flight FlightRecord_2026-02-01_H
DJI_REQUIRE_MOUNT=1 bash "$SYNC"; code=$?
check "exit 0 (the logs are safe)" [ "$code" -eq 0 ]
check "both logs are in the cache" bash -c "ls '$T/state/cache/DJIFlightRecord_2026-02-01_[10-00-00].txt' '$T/state/cache/FlightRecord_2026-02-01_H.txt'"
check "  ...and not on the NAS yet" bash -c "! ls '$T'/storage/raw/FlightRecord_2026-02-01_H.txt"
check "  ...and the controller was unmounted" bash -c "[ \"\$(tail -n1 '$T/mounts')\" = unmounted ]"
check "the log says they are kept in the cache" grep -q "log(s) kept in the cache on the Pi" "$T/sync.log"

echo "15 minute flush while the NAS is still down"
before=$(grep -c "storage is not mounted" "$T/sync.log")
DJI_REQUIRE_MOUNT=1 bash "$SYNC" --flush; code=$?
DJI_REQUIRE_MOUNT=1 bash "$SYNC" --flush
check "exit 0" [ "$code" -eq 0 ]
check "the logs stay in the cache" [ "$(cached)" -eq 2 ]
check "the NAS being down isn't logged again every 15 minutes" [ "$(grep -c "storage is not mounted" "$T/sync.log")" -eq "$before" ]

echo "15 minute flush once the NAS is back"
bash "$SYNC" --flush; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "the log says the storage is back" grep -q "storage is back - pushing 2 cached log(s)" "$T/sync.log"
check "both logs are on the NAS" bash -c "ls '$T/storage/raw/DJIFlightRecord_2026-02-01_[10-00-00].txt' '$T/storage/raw/FlightRecord_2026-02-01_H.txt'"
check "  ...archived as a session" bash -c "ls '$T'/storage/archive/[0-9]*/raw/FlightRecord_2026-02-01_H.txt"
check "  ...and parsed" bash -c "ls '$T'/storage/parsed/FlightRecord_2026-02-01_H.csv"
check "the cache is now empty" [ "$(cached)" -eq 0 ]
check "uploaded.list remembers them (brackets and all)" grep -qxF "DJIFlightRecord_2026-02-01_[10-00-00].txt" "$T/state/uploaded.list"

echo "Dock again: uploaded logs are not copied from the controller again"
bash "$SYNC"
check "the cache stays empty" [ "$(cached)" -eq 0 ]
check "the log says 0 logs in the cache" bash -c "tail -n 5 '$T/sync.log' | grep -q '0 log(s) in the cache'"

echo "15 minute flush with nothing waiting"
size=$(wc -c < "$T/sync.log")
bash "$SYNC" --flush; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "  ...and writes nothing to the log" [ "$(wc -c < "$T/sync.log")" -eq "$size" ]

echo "A cached log that differs from the NAS copy is kept"
mkdir -p "$T/state/cache"
echo "pi version" > "$T/state/cache/FlightRecord_2026-02-02_K.txt"
echo "nas version" > "$T/storage/raw/FlightRecord_2026-02-02_K.txt"
bash "$SYNC" --flush
check "kept in the cache" bash -c "grep -qx 'pi version' '$T/state/cache/FlightRecord_2026-02-02_K.txt'"
check "  ...the NAS copy is not overwritten" bash -c "grep -qx 'nas version' '$T/storage/raw/FlightRecord_2026-02-02_K.txt'"
check "  ...and the log says why" grep -q "not confirmed on the NAS yet, kept in the cache: FlightRecord_2026-02-02_K.txt" "$T/sync.log"
rm -f "$T/state/cache/FlightRecord_2026-02-02_K.txt"

echo "Docking while a flush is running: the dock waits, then syncs"
flight FlightRecord_2026-02-03_I
( flock 9; sleep 2 ) 9>"$T/sync.lock" & holder=$!
sleep 0.3
DJI_LOCK_WAIT=10 bash "$SYNC"; code=$?
wait "$holder"
check "the dock waited, then synced (exit 0)" [ "$code" -eq 0 ]
check "  ...and the new log is on the NAS" bash -c "ls '$T'/storage/raw/FlightRecord_2026-02-03_I.txt"

echo "A flush while another sync is running skips its turn"
echo "raw J" > "$T/state/cache/FlightRecord_2026-02-04_J.txt"
( flock 9; sleep 2 ) 9>"$T/sync.lock" & holder=$!
sleep 0.3
bash "$SYNC" --flush; code=$?
check "exit 0 straight away" [ "$code" -eq 0 ]
check "  ...and leaves the cache alone" bash -c "ls '$T'/state/cache/FlightRecord_2026-02-04_J.txt"
wait "$holder"
bash "$SYNC" --flush
check "the next flush pushes it" bash -c "ls '$T'/storage/raw/FlightRecord_2026-02-04_J.txt"

echo "First dock after updating from a version without the cache"
# Simulate the update: the Pi has no cache or uploaded.list yet, but the
# NAS already has every log on the controller.
rm -rf "$T/state"
s_before=$(sessions)
bash "$SYNC"; code=$?
check "exit 0" [ "$code" -eq 0 ]
check "logs already on the NAS are not archived again" [ "$(sessions)" -eq "$s_before" ]
check "  ...the cache is empty again afterwards" [ "$(cached)" -eq 0 ]
check "  ...and they are remembered as uploaded" grep -qxF "FlightRecord_2026-01-10_A.txt" "$T/state/uploaded.list"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
