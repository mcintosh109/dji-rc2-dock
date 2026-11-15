#!/bin/bash
# DJI RC 2 flight log sync: copies new logs to storage, parses them,
# and archives each dock session's raw + parsed files.
#
# Exit codes (shown by `systemctl status dji-sync.service`):
#   0 = success, or nothing to do. A failed parse still counts as
#       success, because it is retried on the next dock.
#   1 = the controller or storage could not be reached, the copy
#       failed, or the sync was stopped before finishing.
set -u
MNT=/mnt/rc2
BASE=/srv/dji
RAW=$BASE/raw
PARSED=$BASE/parsed
ARCHIVE=$BASE/archive
LOG=/var/log/dji-sync.log
APIKEY_FILE=/etc/dji-api-key
UNLOCK_WAIT=120   # seconds to keep waiting for the controller to be unlocked
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
DEST="$ARCHIVE/$STAMP"
NEWLIST=$(mktemp)

log() { echo "$(date) - $*" >> "$LOG"; }

# True if the controller is mounted. This reads the kernel's list of
# mounts directly, which still works when a mount is broken.
rc_mounted() { grep -qs " $MNT " /proc/mounts; }

# Unmount the controller if it is mounted. If a normal unmount fails,
# fall back to a "lazy" unmount (-z), which detaches it anyway.
unmount_rc() {
  if rc_mounted; then
    fusermount -u "$MNT" 2>/dev/null || fusermount -uz "$MNT"
  fi
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

# Check the storage is usable before touching the controller
if ! mkdir -p "$RAW" "$PARSED" "$ARCHIVE" "$MNT" 2>> "$LOG"; then
  log "cannot create folders in $BASE - is the storage mounted?"
  exit 1
fi

# A mount left behind by an interrupted run would block a new one
if rc_mounted; then
  log "removing leftover mount at $MNT"
  unmount_rc
fi

# Mount the controller and look for its FlightRecord folder. The storage
# is only visible once the controller is unlocked, so keep retrying
# every 10 seconds until UNLOCK_WAIT runs out.
SRC=""
WAITED=0
while true; do
  if MOUNT_ERR=$(jmtpfs "$MNT" 2>&1); then
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
  sleep 10
  WAITED=$((WAITED + 10))
done

# Copy new logs, recording which files are new. rsync's exit code is
# saved straight away, because the next command would overwrite $?.
rsync -rt --ignore-existing --exclude 'si_cache' --out-format='%n' \
  "$SRC"/ "$RAW"/ > "$NEWLIST" 2>> "$LOG"
RSYNC_STATUS=$?
unmount_rc   # finished with the controller
if [ "$RSYNC_STATUS" -ne 0 ]; then
  log "copy failed (rsync exit code $RSYNC_STATUS) - logs fully copied before the error are kept"
fi

# Archive this dock's new raw logs
NEWCOUNT=$(grep -c '\.txt$' "$NEWLIST" || true)
if [ "$NEWCOUNT" -gt 0 ]; then
  log "$NEWCOUNT new flight(s)"
  mkdir -p "$DEST/raw"
  grep '\.txt$' "$NEWLIST" | while IFS= read -r rel; do
    cp "$RAW/$rel" "$DEST/raw/"
  done
else
  log "no new flights"
fi

# Print the archive session folder that holds a given raw log, so its
# parsed files can be stored next to it. Prints nothing if not found.
session_for() {
  local d
  for d in "$ARCHIVE"/*/; do
    if [ -f "$d/raw/$1.txt" ]; then
      echo "${d%/}"
      return
    fi
  done
}

# Make a list of every raw log that has no CSV yet. That is this dock's
# new logs, plus any that failed to parse on an earlier dock (for
# example because the internet was down).
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
      if dji-log --api-key "$KEY" --csv "$PARSED/$base.csv" \
           --geojson "$PARSED/$base.geojson" "$f" > /dev/null 2>> "$LOG"; then
        log "parsed: $base"
        session=$(session_for "$base")
        if [ -n "$session" ]; then
          mkdir -p "$session/parsed"
          cp "$PARSED/$base.csv" "$PARSED/$base.geojson" "$session/parsed/"
        fi
      else
        # Delete any half-written output, so the log counts as
        # unparsed and is retried on the next dock
        rm -f "$PARSED/$base.csv" "$PARSED/$base.geojson"
        log "parse failed: $base (will retry on next dock)"
      fi
    done
  fi
fi

if [ "$RSYNC_STATUS" -ne 0 ]; then
  log "done, with copy errors (see above)"
  exit 1
elif [ "$NEWCOUNT" -gt 0 ]; then
  log "done - archived to archive/$STAMP"
else
  log "done"
fi
