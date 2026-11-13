# DJI RC 2 Flight Log Dock

Turns a Raspberry Pi into a dock for the DJI RC 2 controller. Plug the controller in and the Pi automatically copies new flight logs to network storage, decodes them to CSV and GeoJSON, and archives each session.

## How it works

1. A udev rule detects the RC 2 when it's plugged in over USB.
2. It starts a systemd service, which runs `dji-sync.sh`.
3. The script mounts the controller over MTP, copies new logs with rsync (never overwriting or deleting), parses them with [dji-log-parser](https://github.com/lvauvillier/dji-log-parser), and archives the session.

## Output layout

```
/srv/dji/
├── raw/        every raw flight log
├── parsed/     every decoded CSV and GeoJSON
└── archive/
    └── YYYY-MM-DD_HH-MM-SS/
        ├── raw/      new logs from that dock
        └── parsed/   their decoded versions
```

## Hardware

- Raspberry Pi (tested on 64-bit Raspberry Pi OS)
- Official Pi power supply (undervoltage causes unreliable writes)
- Powered USB hub, so the controller charges while syncing
- USB-C data cable, and a desk stand for the RC 2

## Install

1. Update the Pi: `sudo apt update && sudo apt full-upgrade -y`
2. Mount your storage at `/srv/dji`. For an SMB share, copy `examples/smb-dji.cred.example` to `/etc/smb-dji.cred` (fill it in, then `chmod 600`), and add the line from `examples/fstab.example` to `/etc/fstab`. Then run `sudo mount -a`.
3. Run the installer: `sudo ./install.sh`
4. Optional, for parsing: install `dji-log` to `/usr/local/bin` (from the dji-log-parser releases, or build it with `cargo build --release -p dji-log-cli`). Get a free API key by creating an **Open API** app at DJI Developer; the key is labelled "SDK key".

If your controller's USB IDs differ, check `lsusb` and edit `99-dji-rc2.rules`.

## Usage

Plug in and unlock the controller. Watch progress with:

```bash
tail -f /var/log/dji-sync.log
```

Run a sync manually with `sudo systemctl start dji-sync.service`.

## Notes

- The controller must be unlocked for its storage to be visible over MTP.
- Parsing needs internet access: the parser fetches each log's decryption key from DJI. The logs themselves stay local.
- Only flights that are new since the last dock are parsed and archived.
