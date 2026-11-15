#!/bin/bash
# Removes the DJI RC 2 auto-sync dock. Run with: sudo ./uninstall.sh
# Your flight logs in /srv/dji are NOT touched.

set -e
if [ "$EUID" -ne 0 ]; then echo "Run with sudo"; exit 1; fi

echo "Removing installed files..."
# rm -f does not complain if a file is already gone
rm -f /usr/local/bin/dji-sync.sh \
      /etc/systemd/system/dji-sync.service \
      /etc/udev/rules.d/99-dji-rc2.rules \
      /etc/logrotate.d/dji-sync

# Tell systemd and udev the files are gone
systemctl daemon-reload
udevadm control --reload-rules

echo "Done. These were kept, delete them yourself if you no longer need them:"
echo "  /srv/dji               your flight logs"
echo "  /etc/dji-api-key       your DJI API key"
echo "  /var/log/dji-sync.log  the sync log"
echo "  /etc/fstab line and /etc/smb-dji.cred, if you set up a network share"
echo "Packages (jmtpfs, rsync, fuse3, cifs-utils, logrotate) were left installed."
