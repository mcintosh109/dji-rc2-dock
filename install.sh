#!/bin/bash
# Installs the DJI RC 2 auto-sync dock. Run with: sudo ./install.sh
# Safe to run again, e.g. after updating this repo.

# Stop at the first command that fails
set -e

# Must run as root (sudo), because it writes to system folders
if [ "$EUID" -ne 0 ]; then echo "Run with sudo"; exit 1; fi

# Work from the folder this script is in, so the files below are found
cd "$(dirname "$0")"

echo "Installing packages..."
# jmtpfs: mounts the controller over USB (MTP)
# rsync: copies the logs
# fuse3: needed by jmtpfs, and provides fusermount for unmounting
# cifs-utils: mounts SMB/Windows network shares
# logrotate: keeps the log file from growing forever
apt-get install -y jmtpfs rsync fuse3 cifs-utils logrotate

echo "Installing files..."
# install copies a file and sets its permissions in one step
install -m 755 dji-sync.sh /usr/local/bin/dji-sync.sh
install -m 644 dji-sync.service /etc/systemd/system/dji-sync.service
install -m 644 99-dji-rc2.rules /etc/udev/rules.d/99-dji-rc2.rules
install -m 644 dji-sync.logrotate /etc/logrotate.d/dji-sync
mkdir -p /mnt/rc2 /srv/dji

# Tell systemd and udev to load the new files
systemctl daemon-reload
udevadm control --reload-rules

if [ ! -f /etc/dji-api-key ]; then
  # [ -t 0 ] is true when someone is typing at a terminal
  if [ -t 0 ]; then
    read -rp "DJI API key (Enter to skip): " KEY
    if [ -n "$KEY" ]; then
      # umask 077 makes the file readable by root only from the moment
      # it is created. The ( ) keeps that setting inside this one line.
      (umask 077; printf '%s\n' "$KEY" > /etc/dji-api-key)
    fi
  else
    echo "Note: no terminal, so not asking for the DJI API key. To add it later:"
    echo "  sudo sh -c 'umask 077; echo YOUR_KEY > /etc/dji-api-key'"
  fi
fi

command -v dji-log >/dev/null || echo "Note: dji-log not found. Install it to /usr/local/bin to enable parsing."
echo "Done. Mount your storage at /srv/dji (see examples/fstab.example), then dock the controller."
