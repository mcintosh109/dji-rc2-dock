#!/bin/bash
# DJI RC 2 flight log sync.
#
#   dji-sync.sh           dock mode: run by udev when the controller is plugged in
#   dji-sync.sh --flush   flush mode: run every 15 minutes by dji-sync-flush.timer
#
# Dock mode copies new logs from the controller into a cache on the Pi's
# SD card (/var/lib/dji-dock/cache), unmounts the controller, then pushes
# the cache to the NAS. If the NAS is down, the logs wait safely in the
# cache, and flush mode pushes them once the NAS is back.
#
# Pushing to the NAS: copies the cached logs into raw/, deletes each cached
# log once it is confirmed identical on the NAS, then parses new logs and
# archives them as a dock session.
#
# Safeguards, so nothing other tools read (like DJI Flight Map, which reads
# archive/) is ever overwritten or seen half-written:
#   - never writes to /srv/dji unless the storage is really mounted there,
#     instead of silently filling the Pi's SD card
#   - only one sync runs at a time (a lock)
#   - never overwrites: raw logs are copied with --ignore-existing, a new
#     archive folder gets another name if one already exists, and copies
#     never replace an existing file
#   - files are written under a hidden name and renamed when complete, and
#     each dock session is built in a hidden folder (archive/.incoming-...)
#     that is renamed into archive/ only when everything is finished
#   - a cached log is only deleted after it is confirmed identical on the NAS
#   - flights that already have a parsed CSV are not parsed again
#   - flights that failed to parse (e.g. no internet) are retried on every
#     dock until they succeed
#   - waits up to UNLOCK_WAIT seconds for the controller to be unlocked
#   - the controller is always unmounted, even if something goes wrong or
#     the sync is stopped, and a mount left by an interrupted run is removed
#
# Exit codes (shown by `systemctl status dji-sync.service`):
#   0 = success, nothing to do, or the NAS is down and the logs are waiting
#       safely in the cache. A failed parse also counts as success, because
#       it is retried.
#   1 = the controller could not be reached, a copy failed, the session
#       could not be archived, or the sync was stopped.
set -u

# The DJI_* variables are only for the tests (tests/test-sync.sh).
MNT=${DJI_MNT:-/mnt/rc2}
BASE=${DJI_BASE:-/srv/dji}
RAW=$BASE/raw
PARSED=$BASE/parsed
ARCHIVE=$BASE/archive
STATE=${DJI_STATE:-/var/lib/dji-dock}  # on the Pi's SD card
CACHE=$STATE/cache                     # logs waiting to be pushed to the NAS
UPLOADED=$STATE/uploaded.list          # logs already pushed: not copied from the controller again
NAS_DOWN=$STATE/nas-down               # exists while the NAS is unreachable (so it is logged once)
LOG=${DJI_LOG:-/var/log/dji-sync.log}
APIKEY_FILE=${DJI_APIKEY_FILE:-/etc/dji-api-key}
LOCK=${DJI_LOCK:-/run/dji-sync.lock}
MISSIONS=${DJI_MISSIONS:-/usr/local/bin/dji-missions}   # routes from DJI Flight Map (dji-missions.py)
MAP_CONF=${DJI_MAP_CONF:-/etc/dji-map-link.conf}        # made by: sudo dji-map-link
LOCK_WAIT=${DJI_LOCK_WAIT:-300}         # dock mode: seconds to wait for a running sync to finish
REQUIRE_MOUNT=${DJI_REQUIRE_MOUNT:-1}   # 0 = /srv/dji is a plain local folder on purpose
UNLOCK_WAIT=${DJI_UNLOCK_WAIT:-120}     # seconds to wait for the controller to be unlocked
RETRY_EVERY=${DJI_RETRY_EVERY:-10}      # seconds between tries while waiting
STAMP=$(date +%Y-%m-%d_%H-%M-%S)

MODE=dock
[ "${1:-}" = "--flush" ] && MODE=flush

log() { echo "$(date) - $*" >> "$LOG"; }

NEWLIST=$(mktemp)
EXCLUDE=$(mktemp)

# ---- Only one sync at a time -------------------------------------------------
# Docking waits for a running sync (such as a 15 minute flush) to finish.
# A flush simply skips its turn if anything else is running.
exec 9>"$LOCK"
if [ "$MODE" = dock ]; then
  flock -w "$LOCK_WAIT" 9; GOT_LOCK=$?
else
  flock -n 9; GOT_LOCK=$?
fi
if [ "$GOT_LOCK" -ne 0 ]; then
  [ "$MODE" = dock ] && log "another sync is already running - skipped"
  rm -f "$NEWLIST" "$EXCLUDE"
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
  rm -f "$NEWLIST" "$EXCLUDE"
}
trap cleanup EXIT
# If systemd stops the script (e.g. the time limit is hit), exit normally
# so that cleanup still runs.
trap 'log "stopped before finishing (time limit or shutdown)"; exit 1' TERM INT

# How many logs are waiting in the cache (hidden temporary files don't count)
cached_count() { find "$CACHE" -type f -not -name '.*' 2>/dev/null | wc -l; }

if ! mkdir -p "$CACHE" 2>> "$LOG"; then
  log "cannot create the cache folder $CACHE"
  exit 1
fi
touch "$UPLOADED"

# ==== Dock mode: controller -> cache ===========================================
if [ "$MODE" = dock ]; then
  log "RC 2 detected"
  mkdir -p "$MNT"

  # A mount left behind by an interrupted run would block a new one
  if rc_mounted; then
    log "removing leftover mount at $MNT"
    unmount_rc
  fi

  # Mount the controller and find its logs. The storage is only visible
  # once the controller is unlocked, so keep retrying every RETRY_EVERY
  # seconds until UNLOCK_WAIT runs out.
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

  # Skip logs that were already pushed to the NAS. uploaded.list holds
  # their names; rsync treats [ ] * ? in names as wildcards, so a
  # backslash is put in front of each, and / anchors each name to the top.
  sed -e 's/[][*?]/\\&/g' -e 's|^|/|' "$UPLOADED" > "$EXCLUDE"

  # Copy new logs into the cache. rsync writes each file under a temporary
  # name and renames it when done. Its exit code is saved straight away,
  # because the next command would overwrite $?.
  rsync -rt --ignore-existing --exclude 'si_cache' --exclude-from="$EXCLUDE" \
    "$SRC"/ "$CACHE"/ 2>> "$LOG"
  RSYNC_STATUS=$?

  # Planned routes from DJI Flight Map, if this dock is linked to it
  # (sudo dji-map-link): put waiting routes on the controller and tell the
  # map which missions are on it. This never affects the log sync: any
  # problem is only logged.
  if [ -x "$MISSIONS" ] && [ -f "$MAP_CONF" ]; then
    timeout 300 "$MISSIONS" --docked "$MNT" "$SRC" > /dev/null 2>> "$LOG" \
      || log "routes from the map stopped with a problem (the log sync is not affected)"
  fi
  unmount_rc   # finished with the controller
  if [ "$RSYNC_STATUS" -ne 0 ]; then
    log "copy from the controller failed (rsync exit code $RSYNC_STATUS) - logs fully copied before the error are kept"
  fi
  log "$(cached_count) log(s) in the cache on the Pi"
  # From here on, a copy error means exit code 1 at the end
  COPY_FAILED=$RSYNC_STATUS
else
  # Flush mode: quietly do nothing if no logs are waiting
  [ "$(cached_count)" -eq 0 ] && exit 0
  COPY_FAILED=0
fi

# ==== Cache -> NAS ===============================================================

# ---- Is the storage really there? --------------------------------------------
# Looking inside the folder connects an automount share. If /srv/dji still
# isn't its own mount afterwards (or is only the empty automount point), the
# share isn't connected: keep the logs in the cache, rather than writing to
# the SD card's /srv/dji folder.
ls "$BASE" >/dev/null 2>&1
if [ "$REQUIRE_MOUNT" = 1 ]; then
  target=$(findmnt -n -o TARGET -T "$BASE" 2>/dev/null | tail -1)
  fstype=$(findmnt -n -o FSTYPE -T "$BASE" 2>/dev/null | tail -1)
  if [ "$target" != "$BASE" ] || [ "$fstype" = autofs ]; then
    # Log this once, not every 15 minutes
    if [ "$MODE" = dock ] || [ ! -e "$NAS_DOWN" ]; then
      log "storage is not mounted at $BASE - $(cached_count) log(s) kept in the cache on the Pi, retrying every 15 minutes (is the NAS on? try: sudo mount -a)"
    fi
    touch "$NAS_DOWN"
    exit "$((COPY_FAILED != 0))"
  fi
fi
if [ -e "$NAS_DOWN" ]; then
  log "storage is back - pushing $(cached_count) cached log(s)"
  rm -f "$NAS_DOWN"
fi

if ! mkdir -p "$RAW" "$PARSED" "$ARCHIVE" 2>> "$LOG"; then
  log "cannot create folders in $BASE - is the storage mounted?"
  exit 1
fi
for left in "$ARCHIVE"/.incoming-*; do
  [ -e "$left" ] && log "note: an earlier sync didn't finish: $left (left as it is - check it)"
done

# ---- Push the cache to the NAS -------------------------------------------------
# --ignore-existing never replaces a raw log that is already there, and
# hidden files (rsync's own unfinished temporary files) are left out.
# --out-format lists each file that was new to the NAS.
rsync -rt --ignore-existing --exclude '.*' --out-format='%n' \
  "$CACHE"/ "$RAW"/ > "$NEWLIST" 2>> "$LOG"
PUSH_STATUS=$?
if [ "$PUSH_STATUS" -ne 0 ]; then
  log "push to the NAS failed (rsync exit code $PUSH_STATUS) - logs stay in the cache"
fi

# Delete each cached log that is now on the NAS, byte for byte the same
# (cmp compares the two files). Its name is added to uploaded.list first,
# so it isn't copied from the controller again.
while IFS= read -r f; do
  rel=${f#"$CACHE"/}
  if [ -f "$RAW/$rel" ] && cmp -s "$f" "$RAW/$rel"; then
    grep -qxF "$rel" "$UPLOADED" || echo "$rel" >> "$UPLOADED"
    rm -f "$f"
  else
    log "not confirmed on the NAS yet, kept in the cache: $rel"
  fi
done < <(find "$CACHE" -type f -not -name '.*')
find "$CACHE" -mindepth 1 -type d -empty -delete 2>/dev/null

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

# ---- Build this session in a hidden folder ---------------------------------------
NEWCOUNT=$(grep -c '\.txt$' "$NEWLIST" || true)
if [ "$NEWCOUNT" -gt 0 ]; then
  log "$NEWCOUNT new flight(s) on the NAS"
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
# That is this sync's new logs, plus any that failed on an earlier one.
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

if [ "$COPY_FAILED" -ne 0 ] || [ "$PUSH_STATUS" -ne 0 ]; then
  log "done, with copy errors (see above)"
  exit 1
fi
log "done"
