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
# fake controller: "mount" = copy the fake controller's files into place
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
# test can look for half-written files) and fails for files named *BROKEN*.
while [ $# -gt 1 ]; do case "$1" in --csv) csv=$2; shift;; --geojson) geo=$2; shift;; esac; shift; done
file=$1
echo "partial" > "$csv"
sleep "${FAKE_PARSE_SECONDS:-0}"
case "$file" in *BROKEN*) exit 1;; esac
echo "csv for $(basename "$file") END" > "$csv"
echo "geojson END" > "$geo"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export DJI_MNT="$T/mnt" DJI_BASE="$T/storage" DJI_LOG="$T/sync.log" DJI_LOCK="$T/sync.lock" \
       DJI_APIKEY_FILE="$T/apikey" DJI_REQUIRE_MOUNT=0
echo "TESTKEY" > "$T/apikey"
flight() { echo "raw $1" > "$T/rc2-files/$1.txt"; }
sessions() { find "$T/storage/archive" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | wc -l; }
hidden_left() { find "$T/storage" -name '.*' -not -name '.' | grep -q .; }

echo "Storage not mounted"
DJI_REQUIRE_MOUNT=1 bash "$SYNC"; code=$?
check "refuses when the storage isn't mounted" [ "$code" -eq 1 ]
check "  ...and writes nothing" bash -c "[ -z \"\$(ls -A '$T/storage')\" ]"
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
bash "$SYNC"
check "already-parsed flights are not parsed again" grep -q "already parsed: FlightRecord_2026-01-10_A" "$T/sync.log"
check "their parsed files are not replaced" grep -q MARK "$T/storage/parsed/FlightRecord_2026-01-10_A.csv"
check "  ...but they are in the new session, so the map sees them" bash -c "grep -l MARK '$T'/storage/archive/[0-9]*/parsed/FlightRecord_2026-01-10_A.csv | grep -q ."

echo "Two syncs at once"
flight FlightRecord_2026-01-14_F
( flock 9; sleep 2 ) 9>"$T/sync.lock" & holder=$!
sleep 0.3
bash "$SYNC"
check "second sync is skipped" grep -q "another sync is already running" "$T/sync.log"
check "  ...and changed nothing" bash -c "! ls '$T'/storage/raw/FlightRecord_2026-01-14_F.txt"
wait "$holder"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
