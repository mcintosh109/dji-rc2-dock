#!/bin/bash
# Installs the DJI RC 2 auto-sync dock. Run with: sudo ./install.sh
set -e
if [ "$EUID" -ne 0 ]; then echo "Run with sudo"; exit 1; fi
cd "$(dirname "$0")"

echo "Installing packages..."
apt-get install -y jmtpfs rsync fuse3 cifs-utils

echo "Installing files..."
install -m 755 dji-sync.sh /usr/local/bin/dji-sync.sh
install -m 644 dji-sync.service /etc/systemd/system/dji-sync.service
install -m 644 99-dji-rc2.rules /etc/udev/rules.d/99-dji-rc2.rules
mkdir -p /mnt/rc2 /srv/dji

systemctl daemon-reload
udevadm control --reload-rules

if [ ! -f /etc/dji-api-key ]; then
  read -rp "DJI API key (Enter to skip): " KEY
  if [ -n "$KEY" ]; then
    echo "$KEY" > /etc/dji-api-key
    chmod 600 /etc/dji-api-key
  fi
fi

command -v dji-log >/dev/null || echo "Note: dji-log not found. Install it to /usr/local/bin to enable parsing."
echo "Done. Mount your storage at /srv/dji (see examples/fstab.example), then dock the controller."
