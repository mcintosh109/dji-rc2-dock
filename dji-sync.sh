#!/bin/bash
# DJI RC 2 flight log sync: copies new logs to storage, parses them,
# and archives each dock session's raw + parsed files.
set -u
MNT=/mnt/rc2
BASE=/srv/dji
RAW=$BASE/raw
PARSED=$BASE/parsed
ARCHIVE=$BASE/archive
LOG=/var/log/dji-sync.log
APIKEY_FILE=/etc/dji-api-key
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
NEWLIST=$(mktemp)

log() { echo "$(date) - $*" >> "$LOG"; }

log "RC 2 detected"
mkdir -p "$RAW" "$PARSED" "$ARCHIVE" "$MNT"

# Mount the controller
if ! jmtpfs "$MNT" >> "$LOG" 2>&1; then
  log "mount failed - is the controller plugged in and unlocked?"
  exit 0
fi

# Copy new logs, recording which files are new
SRC=$(find "$MNT" -maxdepth 6 -type d -name FlightRecord 2>/dev/null | head -n1)
if [ -n "$SRC" ]; then
  rsync -rt --ignore-existing --exclude 'si_cache' --out-format='%n' \
    "$SRC"/ "$RAW"/ > "$NEWLIST" 2>> "$LOG"
else
  log "FlightRecord folder not found"
fi
fusermount -u "$MNT"

NEWCOUNT=$(grep -c '\.txt$' "$NEWLIST" || true)
if [ "$NEWCOUNT" -eq 0 ]; then
  log "no new flights"
  rm -f "$NEWLIST"
  log "done"
  exit 0
fi

log "$NEWCOUNT new flight(s)"
DEST="$ARCHIVE/$STAMP"
mkdir -p "$DEST/raw" "$DEST/parsed"

KEY=""
[ -f "$APIKEY_FILE" ] && KEY=$(cat "$APIKEY_FILE")

# Archive each new raw log, parse it, archive the parsed output
grep '\.txt$' "$NEWLIST" | while IFS= read -r rel; do
  f="$RAW/$rel"
  base=$(basename "$rel" .txt)
  cp "$f" "$DEST/raw/"

  if [ -n "$KEY" ] && command -v dji-log >/dev/null; then
    if dji-log --api-key "$KEY" --csv "$PARSED/$base.csv" \
         --geojson "$PARSED/$base.geojson" "$f" > /dev/null 2>> "$LOG"; then
      cp "$PARSED/$base.csv" "$PARSED/$base.geojson" "$DEST/parsed/"
    else
      log "parse failed: $base"
    fi
  else
    log "parser or API key missing - skipped parsing $base"
  fi
done

rm -f "$NEWLIST"
log "done - archived to archive/$STAMP"
