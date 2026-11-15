#!/bin/bash
# DJI RC 2 flight log sync: copies new logs to storage, parses them,
# and archives each dock session's raw + parsed files.
#
# Safeguards, so nothing other tools read (like DJI Flight Map, which reads
# archive/) is ever overwritten or seen half-written:
#   - stops if the storage isn't really mounted at /srv/dji, instead of
#     silently filling the Pi's SD card
#   - only one sync runs at a time (a lock)
#   - never overwrites: raw logs are copied with --ignore-existing, a new
#     archive folder gets another name if one already exists, and copies
#     never replace an existing file
#   - files are written under a hidden name and renamed when complete, and
#     each dock session is built in a hidden folder (archive/.incoming-...)
#     that is renamed into archive/ only when everything is finished
#   - flights that already have a parsed CSV are not parsed again
#   - the controller is always unmounted, even if something goes wrong
set -u

# The DJI_* variables are only for the tests (tests/test-sync.sh).
MNT=${DJI_MNT:-/mnt/rc2}
BASE=${DJI_BASE:-/srv/dji}
RAW=$BASE/raw
PARSED=$BASE/parsed
ARCHIVE=$BASE/archive
LOG=${DJI_LOG:-/var/log/dji-sync.log}
APIKEY_FILE=${DJI_APIKEY_FILE:-/etc/dji-api-key}
LOCK=${DJI_LOCK:-/run/dji-sync.lock}
REQUIRE_MOUNT=${DJI_REQUIRE_MOUNT:-1}   # 0 = /srv/dji is a plain local folder on purpose
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
NEWLIST=$(mktemp)

log() { echo "$(date) - $*" >> "$LOG"; }

# ---- Only one sync at a time -------------------------------------------------
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another sync is already running - skipped"
  rm -f "$NEWLIST"
  exit 0
fi

MOUNTED=no
cleanup() {
  if [ "$MOUNTED" = yes ]; then fusermount -u "$MNT" 2>/dev/null; fi
  rm -f "$NEWLIST"
}
trap cleanup EXIT

log "RC 2 detected"

# ---- Is the storage really there? --------------------------------------------
# Looking inside the folder connects an automount share. If /srv/dji still
# isn't its own mount afterwards (or is only the empty automount point), the
# share isn't connected: stop, rather than writing to the SD card.
ls "$BASE" >/dev/null 2>&1
if [ "$REQUIRE_MOUNT" = 1 ]; then
  target=$(findmnt -n -o TARGET -T "$BASE" 2>/dev/null | tail -1)
  fstype=$(findmnt -n -o FSTYPE -T "$BASE" 2>/dev/null | tail -1)
  if [ "$target" != "$BASE" ] || [ "$fstype" = autofs ]; then
    log "storage is not mounted at $BASE - nothing copied (is the NAS on? try: sudo mount -a)"
    exit 1
  fi
fi

mkdir -p "$RAW" "$PARSED" "$ARCHIVE" "$MNT"
for left in "$ARCHIVE"/.incoming-*; do
  [ -e "$left" ] && log "note: an earlier sync didn't finish: $left (left as it is - check it)"
done

# ---- Mount the controller and copy new logs -----------------------------------
if ! jmtpfs "$MNT" >> "$LOG" 2>&1; then
  log "mount failed - is the controller plugged in and unlocked?"
  exit 0
fi
MOUNTED=yes

# rsync writes each file under a temporary name and renames it when done,
# and --ignore-existing never replaces a raw log that is already there.
SRC=$(find "$MNT" -maxdepth 6 -type d -name FlightRecord 2>/dev/null | head -n1)
if [ -n "$SRC" ]; then
  rsync -rt --ignore-existing --exclude 'si_cache' --out-format='%n' \
    "$SRC"/ "$RAW"/ > "$NEWLIST" 2>> "$LOG"
else
  log "FlightRecord folder not found"
fi
fusermount -u "$MNT"
MOUNTED=no

NEWCOUNT=$(grep -c '\.txt$' "$NEWLIST" || true)
if [ "$NEWCOUNT" -eq 0 ]; then
  log "no new flights"
  log "done"
  exit 0
fi
log "$NEWCOUNT new flight(s)"

# ---- Build this dock session in a hidden folder ---------------------------------
NAME=$STAMP
n=2
while [ -e "$ARCHIVE/$NAME" ] || [ -e "$ARCHIVE/.incoming-$NAME" ]; do
  NAME="$STAMP-$n"          # never reuse a folder name
  n=$((n + 1))
done
WORK="$ARCHIVE/.incoming-$NAME"
mkdir -p "$WORK/raw" "$WORK/parsed"

KEY=""
[ -f "$APIKEY_FILE" ] && KEY=$(cat "$APIKEY_FILE")

# Copy $1 to $2 under a hidden name, then rename it. Never replaces $2.
safe_copy() {
  local src=$1 dest=$2 tmp
  if [ -e "$dest" ]; then
    log "kept the existing $dest (not overwritten)"
    return 0
  fi
  tmp="$(dirname "$dest")/.$(basename "$dest").part"
  cp "$src" "$tmp" && mv -n "$tmp" "$dest"
  rm -f "$tmp"
}

grep '\.txt$' "$NEWLIST" | while IFS= read -r rel; do
  f="$RAW/$rel"
  base=$(basename "$rel" .txt)
  safe_copy "$f" "$WORK/raw/$base.txt"

  if [ -f "$PARSED/$base.csv" ]; then
    # Parsed before (perhaps by a sync that didn't finish): don't parse
    # again, but do put the parsed files in this session, so the map sees them.
    log "already parsed: $base (not parsed again; its parsed files are archived)"
    safe_copy "$PARSED/$base.csv" "$WORK/parsed/$base.csv"
    [ -f "$PARSED/$base.geojson" ] && safe_copy "$PARSED/$base.geojson" "$WORK/parsed/$base.geojson"
    continue
  fi
  if [ -z "$KEY" ] || ! command -v dji-log >/dev/null; then
    log "parser or API key missing - skipped parsing $base"
    continue
  fi
  # Parse into a hidden folder; move the results into place only if it worked.
  tmpdir=$(mktemp -d "$PARSED/.parsing-XXXXXX")
  if dji-log --api-key "$KEY" --csv "$tmpdir/$base.csv" \
       --geojson "$tmpdir/$base.geojson" "$f" > /dev/null 2>> "$LOG" && [ -s "$tmpdir/$base.csv" ]; then
    mv -n "$tmpdir/$base.csv" "$PARSED/$base.csv"
    [ -s "$tmpdir/$base.geojson" ] && mv -n "$tmpdir/$base.geojson" "$PARSED/$base.geojson"
    safe_copy "$PARSED/$base.csv" "$WORK/parsed/$base.csv"
    [ -f "$PARSED/$base.geojson" ] && safe_copy "$PARSED/$base.geojson" "$WORK/parsed/$base.geojson"
  else
    log "parse failed: $base"
  fi
  rm -rf "$tmpdir"
done

# ---- Publish the session: one rename, so readers see all of it or none ------------
if [ -z "$(ls -A "$WORK/raw" "$WORK/parsed" 2>/dev/null)" ]; then
  rmdir "$WORK/raw" "$WORK/parsed" "$WORK" 2>/dev/null
  log "nothing to archive"
elif mv -n -T "$WORK" "$ARCHIVE/$NAME" && [ ! -e "$WORK" ]; then
  log "done - archived to archive/$NAME"
else
  log "could not publish $WORK as archive/$NAME - left as it is"
  exit 1
fi
