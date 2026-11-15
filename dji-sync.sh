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
#   - flights that failed to parse (e.g. no internet) are retried on every
#     dock until they succeed
#   - waits up to UNLOCK_WAIT seconds for the controller to be unlocked
#   - the controller is always unmounted, even if something goes wrong or
#     the sync is stopped, and a mount left by an interrupted run is removed
#
# Exit codes (shown by `systemctl status dji-sync.service`):
#   0 = success, or nothing to do. A failed parse still counts as
#       success, because it is retried on the next dock.
#   1 = the storage or controller could not be reached, the copy failed,
#       the session could not be archived, or the sync was stopped.
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
UNLOCK_WAIT=${DJI_UNLOCK_WAIT:-120}     # seconds to wait for the controller to be unlocked
RETRY_EVERY=${DJI_RETRY_EVERY:-10}      # seconds between tries while waiting
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

# True if the controller is mounted. This reads the kernel's list of
# mounts directly, which still works when a mount is broken.
rc_mounted() { grep -qs " $MNT " /proc/mounts; }

# Unmount the controller if we mounted it, or if it is still mounted.
# If a normal unmount fails, fall back to a "lazy" unmount (-z).
MOUNTED=no
unmount_rc() {
  if [ "$MOUNTED" = yes ] || rc_mounted; then
    fusermount -u "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null
  fi
  MOUNTED=no
}

# cleanup runs whenever the script ends, however it ends.
cleanup() {
  unmount_rc
  rm -f "$NEWLIST"
}
trap cleanup EXIT
# If systemd stops the script (e.g. the time limit is hit), exit normally
# so that cleanup still runs.
trap 'log "stopped before finishing (time limit or shutdown)"; exit 1' TERM INT

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

if ! mkdir -p "$RAW" "$PARSED" "$ARCHIVE" "$MNT" 2>> "$LOG"; then
  log "cannot create folders in $BASE - is the storage mounted?"
  exit 1
fi
for left in "$ARCHIVE"/.incoming-*; do
  [ -e "$left" ] && log "note: an earlier sync didn't finish: $left (left as it is - check it)"
done

# A mount left behind by an interrupted run would block a new one
if rc_mounted; then
  log "removing leftover mount at $MNT"
  unmount_rc
fi

# ---- Mount the controller and find its logs -------------------------------------
# The storage is only visible once the controller is unlocked, so keep
# retrying every RETRY_EVERY seconds until UNLOCK_WAIT runs out.
SRC=""
WAITED=0
while true; do
  if MOUNT_ERR=$(jmtpfs "$MNT" 2>&1); then
    MOUNTED=yes
    SRC=$(find "$MNT" -maxdepth 6 -type d -name FlightRecord 2>/dev/null | head -n1)
    [ -n "$SRC" ] && break
    unmount_rc
  fi
  if [ "$WAITED" -ge "$UNLOCK_WAIT" ]; then
    [ -n "$MOUNT_ERR" ] && log "last mount error: $MOUNT_ERR"
    log "FlightRecord folder not found after ${UNLOCK_WAIT}s - is the controller plugged in and unlocked?"
    exit 1
  fi
  [ "$WAITED" -eq 0 ] && log "waiting for the controller to be unlocked..."
  sleep "$RETRY_EVERY"
  WAITED=$((WAITED + RETRY_EVERY))
done

# ---- Copy new logs -----------------------------------------------------------
# rsync writes each file under a temporary name and renames it when done,
# and --ignore-existing never replaces a raw log that is already there.
# Its exit code is saved straight away, because the next command would
# overwrite $?.
rsync -rt --ignore-existing --exclude 'si_cache' --out-format='%n' \
  "$SRC"/ "$RAW"/ > "$NEWLIST" 2>> "$LOG"
RSYNC_STATUS=$?
unmount_rc   # finished with the controller
if [ "$RSYNC_STATUS" -ne 0 ]; then
  log "copy failed (rsync exit code $RSYNC_STATUS) - logs fully copied before the error are kept"
fi

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

# Put a flight's parsed files into every session folder that holds its raw
# log but not yet its CSV: this dock's hidden session, and any earlier
# sessions (for flights whose parsing failed back then).
WORK=""
archive_parsed() {
  local base=$1 d
  for d in "$WORK" "$ARCHIVE"/*/; do
    d=${d%/}
    [ -n "$d" ] && [ -f "$d/raw/$base.txt" ] || continue
    [ -e "$d/parsed/$base.csv" ] && continue
    mkdir -p "$d/parsed"
    safe_copy "$PARSED/$base.csv" "$d/parsed/$base.csv"
    [ -f "$PARSED/$base.geojson" ] && safe_copy "$PARSED/$base.geojson" "$d/parsed/$base.geojson"
  done
}

# ---- Build this dock session in a hidden folder ---------------------------------
NEWCOUNT=$(grep -c '\.txt$' "$NEWLIST" || true)
if [ "$NEWCOUNT" -gt 0 ]; then
  log "$NEWCOUNT new flight(s)"
  NAME=$STAMP
  n=2
  while [ -e "$ARCHIVE/$NAME" ] || [ -e "$ARCHIVE/.incoming-$NAME" ]; do
    NAME="$STAMP-$n"          # never reuse a folder name
    n=$((n + 1))
  done
  WORK="$ARCHIVE/.incoming-$NAME"
  mkdir -p "$WORK/raw" "$WORK/parsed"

  while IFS= read -r rel; do
    base=$(basename "$rel" .txt)
    safe_copy "$RAW/$rel" "$WORK/raw/$base.txt"
    if [ -f "$PARSED/$base.csv" ]; then
      # Parsed before (perhaps by a sync that didn't finish): don't parse
      # again, but do put the parsed files in this session, so the map sees them.
      log "already parsed: $base (not parsed again; its parsed files are archived)"
      archive_parsed "$base"
    fi
  done < <(grep '\.txt$' "$NEWLIST")
else
  log "no new flights"
fi

# ---- Parse every raw log that has no CSV yet ------------------------------------
# That is this dock's new logs, plus any that failed on an earlier dock.
TODO=()
while IFS= read -r f; do
  base=$(basename "$f" .txt)
  [ -f "$PARSED/$base.csv" ] || TODO+=("$f")
done < <(find "$RAW" -type f -name '*.txt' | sort)

KEY=""
[ -f "$APIKEY_FILE" ] && KEY=$(cat "$APIKEY_FILE")

if [ "${#TODO[@]}" -gt 0 ]; then
  if [ -z "$KEY" ] || ! command -v dji-log >/dev/null; then
    log "parser or API key missing - ${#TODO[@]} log(s) waiting to be parsed"
  else
    for f in "${TODO[@]}"; do
      base=$(basename "$f" .txt)
      # Parse into a hidden folder; move the results into place only if it worked.
      tmpdir=$(mktemp -d "$PARSED/.parsing-XXXXXX")
      if dji-log --api-key "$KEY" --csv "$tmpdir/$base.csv" \
           --geojson "$tmpdir/$base.geojson" "$f" > /dev/null 2>> "$LOG" && [ -s "$tmpdir/$base.csv" ]; then
        mv -n "$tmpdir/$base.csv" "$PARSED/$base.csv"
        [ -s "$tmpdir/$base.geojson" ] && mv -n "$tmpdir/$base.geojson" "$PARSED/$base.geojson"
        log "parsed: $base"
        archive_parsed "$base"
      else
        log "parse failed: $base (will retry on next dock)"
      fi
      rm -rf "$tmpdir"
    done
  fi
fi

# ---- Publish the session: one rename, so readers see all of it or none ------------
if [ -n "$WORK" ]; then
  if [ -z "$(ls -A "$WORK/raw" "$WORK/parsed" 2>/dev/null)" ]; then
    rmdir "$WORK/raw" "$WORK/parsed" "$WORK" 2>/dev/null
    log "nothing to archive"
  elif mv -n -T "$WORK" "$ARCHIVE/$NAME" && [ ! -e "$WORK" ]; then
    log "archived to archive/$NAME"
  else
    log "could not publish $WORK as archive/$NAME - left as it is"
    exit 1
  fi
fi

if [ "$RSYNC_STATUS" -ne 0 ]; then
  log "done, with copy errors (see above)"
  exit 1
fi
log "done"
