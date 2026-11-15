#!/bin/bash
# Cleans up the installed dock, then installs it again from this folder.
# Run with: sudo ./redeploy.sh
#
# KEPT - this script never changes these:
#   /etc/dji-api-key                   your DJI API key
#   /etc/smb-dji.cred                  your network share username and password
#   /etc/fstab                         where your storage is mounted (the upload location)
#   /etc/systemd/system/dji-sync.service.d/   your own service settings, if any
#   /srv/dji                           your flight logs (raw, parsed, archive)
#   /var/log/dji-sync.log              the sync log
#
# CLEANED UP:
#   1. a sync that is running is stopped
#   2. the controller is unmounted, if a crashed sync left it mounted
#   3. the old lock file is removed
#   4. the installed script, service, udev rule and log rotation file are
#      removed (uninstall.sh) ...
#   5. ... and installed fresh (install.sh)
#   6. then everything is checked, including that the KEPT files are unchanged

# Stop at the first command that fails
set -e

# Must run as root (sudo), because it changes system folders
if [ "$EUID" -ne 0 ]; then echo "Run with sudo"; exit 1; fi

# Work from the folder this script is in, so the files below are found
cd "$(dirname "$0")"

KEEP=(/etc/dji-api-key /etc/smb-dji.cred /etc/fstab)
MNT=/mnt/rc2
BASE=/srv/dji

# A fingerprint (sha256 checksum) of each KEPT file. If a single character
# in a file changed, its fingerprint would be different. The fingerprints
# are only compared, never printed.
fingerprint() {
  local f
  for f in "${KEEP[@]}"; do
    if [ -e "$f" ]; then sha256sum "$f"; else echo "(not present) $f"; fi
  done
}

# ---- Before removing anything, make sure the reinstall can work -------------
echo "== Checking this folder has everything needed..."
for f in install.sh uninstall.sh dji-sync.sh dji-sync.service 99-dji-rc2.rules dji-sync.logrotate; do
  if [ ! -f "$f" ]; then
    echo "Missing $f - nothing was changed. Run this from the dji-rc2-dock folder."
    exit 1
  fi
done

# Install the packages first: if this fails (e.g. no internet), stop now,
# while the current install is still in place.
echo "== Checking packages (this needs the internet)..."
if ! apt-get install -y jmtpfs rsync fuse3 cifs-utils logrotate; then
  echo "Could not install packages - nothing was changed. Check the internet connection and try again."
  exit 1
fi

BEFORE=$(fingerprint)

# ---- 1. Stop a sync that is running ------------------------------------------
echo "== 1. Stopping any running sync..."
if systemctl is-active --quiet dji-sync.service; then
  systemctl stop dji-sync.service
  echo "   A sync was running and has been stopped. Dock again afterwards to finish it."
else
  echo "   No sync running."
fi
# Forget an earlier "failed" result, so `systemctl status` starts clean
systemctl reset-failed dji-sync.service 2>/dev/null || true

# ---- 2. Unmount the controller if it was left mounted ------------------------
echo "== 2. Checking for a leftover controller mount..."
if grep -qs " $MNT " /proc/mounts; then
  # Try a normal unmount, then a "lazy" one (-z), then the general umount
  fusermount -u "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || umount -l "$MNT"
  echo "   Unmounted $MNT."
else
  echo "   None found."
fi

# ---- 3. Remove the old lock file ---------------------------------------------
echo "== 3. Removing the old lock file..."
rm -f /run/dji-sync.lock

# ---- 4 and 5. Remove the installed files, then install them fresh ----------------
echo "== 4. Removing the installed files..."
bash ./uninstall.sh > /dev/null
echo "== 5. Installing fresh..."
bash ./install.sh

# ---- 6. Check the result -------------------------------------------------------
echo
echo "== 6. Checking the result..."
PROBLEMS=0

AFTER=$(fingerprint)
if [ "$BEFORE" = "$AFTER" ]; then
  echo "   OK   API key, share credentials and fstab are unchanged"
else
  echo "   !!   One of these files changed: ${KEEP[*]}"
  PROBLEMS=1
fi

for f in /usr/local/bin/dji-sync.sh /etc/systemd/system/dji-sync.service \
         /etc/udev/rules.d/99-dji-rc2.rules /etc/logrotate.d/dji-sync; do
  if [ -f "$f" ]; then
    echo "   OK   installed $f"
  else
    echo "   !!   missing $f"
    PROBLEMS=1
  fi
done

if [ "$(systemctl show -p LoadState --value dji-sync.service)" = loaded ]; then
  echo "   OK   systemd has loaded dji-sync.service"
else
  echo "   !!   systemd could not load dji-sync.service"
  PROBLEMS=1
fi

# Report on the storage, without changing it. Looking inside connects an
# automount share.
ls "$BASE" >/dev/null 2>&1 || true
FSTYPE=$(findmnt -n -o FSTYPE -T "$BASE" 2>/dev/null | tail -1)
TARGET=$(findmnt -n -o TARGET -T "$BASE" 2>/dev/null | tail -1)
if [ "$TARGET" = "$BASE" ] && [ "$FSTYPE" != autofs ]; then
  echo "   OK   storage is mounted at $BASE ($FSTYPE)"
else
  echo "   !!   storage is not mounted at $BASE - the sync won't run until it is (try: sudo mount -a)"
  PROBLEMS=1
fi

# Unfinished archive folders are reported, never deleted
LEFT=$(find "$BASE/archive" -maxdepth 1 -name '.incoming-*' 2>/dev/null | wc -l)
if [ "$LEFT" -gt 0 ]; then
  echo "   note $LEFT unfinished archive folder(s) in $BASE/archive/.incoming-* (left as they are - check them)"
fi

echo
if [ "$PROBLEMS" -eq 0 ]; then
  echo "Redeploy finished. Dock the controller and watch: tail -f /var/log/dji-sync.log"
else
  echo "Redeploy finished with problems - see the !! lines above."
  exit 1
fi
