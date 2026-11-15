#!/bin/bash
# Removes the DJI RC 2 auto-sync dock. Run with: sudo ./uninstall.sh
# Your flight logs in /srv/dji and the cache on the Pi are NOT touched.

set -e
if [ "$EUID" -ne 0 ]; then echo "Run with sudo"; exit 1; fi

echo "Stopping the 15 minute timer..."
# || true: carry on if the timer was never installed
systemctl disable --now dji-sync-flush.timer 2>/dev/null || true

echo "Removing installed files..."
# rm -f does not complain if a file is already gone
rm -f /usr/local/bin/dji-sync.sh \
      /etc/systemd/system/dji-sync.service \
      /etc/systemd/system/dji-sync-flush.service \
      /etc/systemd/system/dji-sync-flush.timer \
      /etc/udev/rules.d/99-dji-rc2.rules \
      /etc/logrotate.d/dji-sync

# Tell systemd and udev the files are gone
systemctl daemon-reload
udevadm control --reload-rules

echo "Done. These were kept, delete them yourself if you no longer need them:"
echo "  /srv/dji               your flight logs"
echo "  /var/lib/dji-dock      the cache on the Pi (logs not yet pushed to the NAS)"
echo "  /etc/dji-api-key       your DJI API key"
echo "  /var/log/dji-sync.log  the sync log"
echo "  /etc/fstab line and /etc/smb-dji.cred, if you set up a network share"
echo "Packages (jmtpfs, rsync, fuse3, cifs-utils, logrotate) were left installed."

# Warn if logs are still waiting to be pushed
WAITING=$(find /var/lib/dji-dock/cache -type f -not -name '.*' 2>/dev/null | wc -l)
if [ "$WAITING" -gt 0 ]; then
  echo
  echo "WARNING: $WAITING log(s) in /var/lib/dji-dock/cache were never pushed to the NAS."
  echo "Copy them somewhere safe before deleting that folder."
fi
