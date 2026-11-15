# DJI RC 2 Flight Log Dock

Turns a Raspberry Pi into a dock for the DJI RC 2 controller. Plug the controller in and the Pi automatically copies new flight logs to network storage, decodes them to CSV and GeoJSON, and archives each session.

## How it works

1. A udev rule detects the RC 2 when it's plugged in over USB.
2. It starts a systemd service, which runs `dji-sync.sh`.
3. The script mounts the controller over MTP and copies new logs with rsync into a **cache on the Pi's SD card** (`/var/lib/dji-dock/cache`). This works even if the NAS is down. Then it unmounts the controller.
4. If the NAS is mounted, it pushes the cache to the NAS, deletes each cached log once it's confirmed identical on the NAS, parses new logs with [dji-log-parser](https://github.com/lvauvillier/dji-log-parser), and archives the session.
5. If the NAS is down, the logs wait in the cache. A timer (`dji-sync-flush.timer`) checks every 15 minutes and pushes them as soon as the NAS is back, without re-docking.

Nothing is ever overwritten or deleted on the controller or the NAS.

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
2. Mount your storage at `/srv/dji`. For an SMB share:
   1. Copy `examples/smb-dji.cred.example` to `/etc/smb-dji.cred`, fill it in, then run `sudo chmod 600 /etc/smb-dji.cred`.
   2. Add the line from `examples/fstab.example` to `/etc/fstab`.
   3. Run `sudo systemctl daemon-reload` (systemd reads `/etc/fstab` only when told to), then `sudo mount -a`.
3. Run the installer: `sudo ./install.sh`
4. Optional, for parsing: install `dji-log` to `/usr/local/bin` (from the dji-log-parser releases, or build it with `cargo build --release -p dji-log-cli`). Get a free API key by creating an **Open API** app at DJI Developer; the key is labelled "SDK key".

The udev rule matches USB ID `2ca3:1021` (the RC 2). If `lsusb` shows a different ID for your controller, edit `99-dji-rc2.rules`.

## Usage

Plug in and unlock the controller. You have about 2 minutes to unlock it; the sync waits and retries until then. Watch progress with:

```bash
tail -f /var/log/dji-sync.log
```

Run a sync manually with `sudo systemctl start dji-sync.service`.

## Updating

After pulling a new version of this repo, run the installer again to install the new files. It won't ask for your API key again if one is saved.

```bash
sudo ./install.sh
```

### Clean redeploy

To clean up and reinstall from scratch, for example after an update or when something seems stuck, run:

```bash
sudo ./redeploy.sh
```

It does these steps:
1. Stops a sync that is running.
2. Unmounts the controller if a crashed sync left it mounted.
3. Removes the old lock file.
4. Removes the installed files.
5. Installs everything fresh.
6. Checks the result.

**It never changes** your API key (`/etc/dji-api-key`), share credentials (`/etc/smb-dji.cred`), storage settings (`/etc/fstab`), your own service settings, your flight logs in `/srv/dji`, the cache on the Pi (`/var/lib/dji-dock`), or the log file. It compares the key, credentials and fstab before and after, and warns with `!!` if any of them changed. If the packages can't be installed (for example, with no internet), it stops before removing anything.

## Uninstall

```bash
sudo ./uninstall.sh
```

This stops the 15 minute timer and removes the installed script, services, timer, udev rule and log rotation settings. Your flight logs, the cache on the Pi, API key and log file are kept; the uninstaller lists where they are, and warns if logs in the cache were never pushed to the NAS.

## Tests

The tests run `dji-sync.sh` against a fake controller, fake storage and a fake parser, so nothing real is touched. They need `rsync`. GitHub runs them, and ShellCheck, on every pull request.

```bash
bash tests/test-sync.sh
```

## Troubleshooting

Each problem below shows the message you'll see in `/var/log/dji-sync.log`, or what happens instead.

**Nothing appears in the log after plugging in**
- Check the Pi sees the controller: `lsusb` should list `2ca3:1021`.
- Check the service: `systemctl status dji-sync.service`.
- Full service messages: `journalctl -u dji-sync.service`

**`FlightRecord folder not found after 120s`**
- Unlock the controller, then unplug and replug it.
- Make sure the USB cable carries data, not just charge.

**`copy from the controller failed`**
- The USB connection dropped. Check the cable and hub, then dock again. Logs fully copied before the error are kept.

**`storage is not mounted at /srv/dji - N log(s) kept in the cache on the Pi`**
- Your logs are safe on the Pi. They're pushed automatically within 15 minutes of the NAS coming back, and the log then says `storage is back - pushing N cached log(s)`.
- To see what's waiting: `ls /var/lib/dji-dock/cache`
- Check the storage with `findmnt /srv/dji`. If nothing is shown, run `sudo mount -a` and look for an error.
- If you keep logs on the Pi's own SD card on purpose (no separate storage), allow that for both services. Run `sudo systemctl edit dji-sync.service`, then `sudo systemctl edit dji-sync-flush.service`, adding these two lines in each:
  ```ini
  [Service]
  Environment=DJI_REQUIRE_MOUNT=0
  ```

**`push to the NAS failed`**
- The NAS connection dropped during the push. The logs stay in the cache and are pushed again within 15 minutes.

**`not confirmed on the NAS yet, kept in the cache: ...`**
- The NAS already has a different file with the same name, so it was not overwritten, and the cached copy is kept. Compare the two files (in `/var/lib/dji-dock/cache` and `/srv/dji/raw`), keep the right one, and delete the other.

**`cannot create folders in /srv/dji`**
- The storage is mounted but can't be written to. Check the share's permissions, and that the NAS isn't full.

**Checking the 15 minute timer**
- `systemctl list-timers dji-sync-flush.timer` shows when it last ran and when it runs next.

**`another sync is already running - skipped`**
- Only one sync runs at a time. Wait for the first one to finish (`tail -f /var/log/dji-sync.log`), then dock again if needed.

**`note: an earlier sync didn't finish: /srv/dji/archive/.incoming-...`**
- A sync was interrupted while building its archive folder. That hidden folder is left as it is so nothing is lost. Look inside it, and move or delete it yourself.

**`parse failed`**
- Usually no internet, or a wrong API key. The log is retried automatically on the next dock.

**`parser or API key missing`**
- Install `dji-log` (Install step 4), or save your key with:
  `sudo sh -c 'umask 077; echo YOUR_KEY > /etc/dji-api-key'`

`systemctl status dji-sync.service` shows **failed** when the controller or storage couldn't be reached, the copy failed, the archive folder couldn't be finished, or the sync was stopped by its 30 minute time limit. A failed parse doesn't count as a failure, because it is retried.

## Notes

- The controller must be unlocked for its storage to be visible over MTP.
- Parsing needs internet access: the parser fetches each log's decryption key from DJI. The logs themselves stay local.
- Only flights that are new since the last dock are copied and archived. The Pi remembers which logs it already uploaded in `/var/lib/dji-dock/uploaded.list`, so they aren't copied from the controller again even after they leave the cache. To upload everything on the controller again, delete that file.
- The first dock after updating from a version without the cache copies every log on the controller into the cache once. Logs already on the NAS are recognised and not duplicated.
- Any log without a CSV yet is parsed on every dock, so a log that failed to parse (for example with no internet) is retried next time. Its parsed files go into the archive folder that holds its raw log.
- Nothing is ever overwritten, and nothing appears half-written to programs that read `archive/` (like DJI Flight Map): each dock's session is built in a hidden `archive/.incoming-...` folder and renamed into place only when complete, and single files are written under a hidden name and renamed when complete.
- The log file is rotated monthly, and the last 12 months are kept (`/etc/logrotate.d/dji-sync`).
- While a log is being parsed, the API key is visible to anyone logged in to the Pi (for example with `ps`), because `dji-log` only accepts the key on its command line. This is fine on a Pi only you log in to.
