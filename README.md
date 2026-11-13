# pi-video-looper

Turns a Raspberry Pi into a headless digital-signage player: it loops videos and
images full-screen over HDMI during work hours and blanks the screen at night and
at weekends. No desktop, no X/Wayland: `mpv` draws straight to KMS/DRM on tty1.

Content comes from the upload page in [`server/`](server/): people upload a file
there, pick the screens and a "show from" / "show until" window, and each Pi
mirrors whatever is active for it. Nothing has to be deleted by hand; a file
drops off the screens when its window ends.

Runs on `bermon01`, `bermon02` and `bermon03` (Raspberry Pi 5, Raspberry Pi OS Lite, bookworm);
the upload server runs on espocrm2, port 8300.

**Museum mode** (`install.sh --museum`) is the same player for a screen with no
server and no schedule: it plays the videos from a USB stick, with sound, whenever
the Pi is on. See [Museum mode](#museum-mode).

## How it works

| Piece | What it does |
|---|---|
| `sync-media.timer` | Every 2 min, day and night: `sync-media.sh` fetches this screen's manifest from the server and mirrors the active files into `/var/lib/pi-video-looper/media` (downloads new ids, deletes what is no longer listed). Server unreachable → nothing is touched. |
| `work-hours.target` / `night-hours.target` | The two modes. They conflict, so starting one stops the other. |
| `work-hours-on.timer` | Mon-Fri 06:30 → `work-hours.target`. |
| `work-hours-off.timer` | Mon-Fri 17:30 → `night-hours.target`. |
| `select-hours-target.service` | At boot, picks the mode for the current time (window in `/etc/default/pi-video-looper`). |
| `video-looper.service` | Builds `/run/playlist.m3u` from the media directory and plays it with `mpv` (`play-loop.sh`) in an endless loop. Part of work hours. |
| `scan-video-folder.timer` | Every 2 min: if the media directory changed, restarts the looper so the playlist is rebuilt. |
| `screen-blank.service` | Keeps `kmsblank` running all night, so the TV gets no signal and drops into standby. |

Media: `mp4 mkv mov webm jpg jpeg png gif`, played in natural filename order
(prefix files with a date or number to order them). Still images stay on screen for
the number of seconds set under "Einstellungen" on the upload page (default 240);
`sync-media.sh` writes it to `image_display_duration_sec.txt` next to the media.

The upload page has no login: anyone on the office LAN can change what the
screens show (decided 2026-10-28). Set `AUTH_USER`/`AUTH_PASS` in the server's
`.env` to turn HTTP basic auth back on. The page follows the alre design system
(CI manual 11/2023 tokens: orange `#eb7300`, grey `#373a3b`, silver, sharp
corners, hairlines, the 8° Farbbalken); the logo is `public/alre-logo.svg`.

An upload reaches the screen within about 4 minutes: up to 2 min until the sync
timer fetches it, up to 2 more until the scan timer restarts the looper.

## The upload server

`server/` is a small Node app (express + multer, Node ≥ 18): a German upload page
with HTTP basic auth, a JSON list of items (`items.json`) and the files under
`DATA_DIR/files`. Per item: screens, `showFrom`, `showUntil`, `enabled` (Deaktivieren
parks a file without deleting it). The Pis poll
`GET /api/screens/<name>/manifest` (plain text, one `id<TAB>name` line per active
file, plus `#IMAGE_DISPLAY_DURATION=`) and download `/media/<id>`; those two routes
need no auth. Expired items stay in the list for `PURGE_DAYS` (30) so the window
can be extended, then file and entry are deleted.

Deploy (from a box that can reach the host; ships `node_modules`, so the host
needs no npm):

```sh
cd server && ./deploy.sh espo@<server-host>
```

It rsyncs to `~/bermon-upload`, creates `~/bermon-upload/.env` on first run (port,
`SCREENS` = the Pis' hostnames, `SCREEN_LABELS` = the names people see
(`bermon01=Eingang,…`), `AUTH_USER`/`AUTH_PASS`, `DATA_DIR=~/bermon-upload-data`) and installs
`bermon-upload.service` as a rootless user unit (needs linger). Password: see that
`.env`. Data is only in `~/bermon-upload-data`; it is not backed up anywhere.

## Install

On a fresh Raspberry Pi OS Lite with a user `tv`:

```sh
git clone <this repo> && cd pi-video-looper
sudo ./install.sh --server http://<server-host>:8300
sudo reboot
```

The screen name sent to the server is the Pi's short hostname (`bermon01`), so it
must match one of the server's `SCREENS`. Re-running `install.sh` on a Pi that
still has the old SMB mount disables and removes it.

If the work window changes, edit both the `OnCalendar=` lines in
`systemd/work-hours-*.timer` and `/etc/default/pi-video-looper`.

## Museum mode

```sh
git clone <this repo> && cd pi-video-looper
sudo ./install.sh --museum
sudo reboot
```

`--museum` is short for `--usb-direct --audio --always-on`; each can also be given on
its own. They set three lines in `/etc/default/pi-video-looper`. Options not given
keep the value that is already there, and a config without the lines means the
office behaviour (server, silent, work hours), so re-running `install.sh` on the
office Pis changes nothing.

| Setting | Office (default) | Museum |
|---|---|---|
| `MEDIA_SOURCE` | `server`: mirror the upload page | `usb-direct`: play straight from a USB stick |
| `AUDIO` | `no` | `yes`, on `AUDIO_DEVICE` (default `auto`) |
| `SCHEDULE` | `work-hours`: Mon-Fri 06:30-17:30 | `always`: plays whenever the Pi is on |

**Changing the videos:** put the files on a USB stick (top level, no folders;
the same formats and natural filename order as above) and plug it in.
`mount-usb.sh` mounts it read-only at `/media/pi-video-looper-usb` and restarts
the looper, which plays straight from the stick. A udev rule
(`90-pi-video-looper.rules`) runs it as soon as a USB disk is plugged in or
pulled, and `sync-media.timer` every 2 minutes as a fallback, so a new stick is
on screen within seconds. The stick has to stay in: pulled, it is unmounted and
the screen stays black until a stick is back. Disks that have something mounted
are never taken for the stick, so a Pi that boots from USB is fine.

`--usb` instead copies the stick to `/var/lib/pi-video-looper/media` every 2
minutes (`sync-usb.sh`) and plays the copy, so the stick can be pulled; a stick
without media files changes nothing. That needs a writable Pi.

Mounting needs root, so in both USB modes `install.sh` adds
`/etc/systemd/system/sync-media.service.d/usb.conf` with `User=root`; the server
sync stays unprivileged.

**Read-only Pi:** with `--usb-direct` nothing is written to the Pi, so it can run
with Raspberry Pi OS's overlay file system (`sudo raspi-config nonint
enable_overlayfs`, reboot): every boot starts from the same state and pulling the
plug cannot damage anything. Logs are lost at reboot. To change the Pi (updates,
re-running `install.sh`), `sudo raspi-config nonint disable_overlayfs`, reboot,
change, enable again, reboot.

**Sound** goes out over HDMI to the TV; set the volume on the TV. If there is no
sound, list the devices with `mpv --audio-device=help` and set e.g.
`AUDIO_DEVICE=alsa/hdmi:CARD=vc4hdmi0,DEV=0` (the HDMI port next to the USB-C
power socket on a Pi 5) in `/etc/default/pi-video-looper`, then
`sudo systemctl restart video-looper`.

**Always on** disables `work-hours-on/-off.timer`, and `select-hours-target`
starts `work-hours.target` at every boot. Switching the TV off and on is all
that is needed; the Pi keeps playing in between.

## Operating it

```sh
systemctl is-active work-hours.target night-hours.target video-looper.service
systemctl list-timers 'work-hours-*'
journalctl -b -u video-looper -u select-hours-target -u scan-video-folder -u sync-media
sudo systemctl start sync-media.service    # fetch (or copy from the stick) now instead of waiting 2 min
ls -la /var/lib/pi-video-looper/media      # what this screen currently has
sudo systemctl start night-hours.target   # screen off now
sudo systemctl start work-hours.target    # screen on now
```

## Hardening on the ALRE Pis

Not done by `install.sh`, set up by hand:

- `/boot/firmware` is mounted `ro` in `/etc/fstab`. For a kernel/firmware upgrade:
  `sudo mount -o remount,rw /boot/firmware`, upgrade, reboot.
- No internet. Updates go through the apt proxy, which is commented out in
  `/etc/apt/apt.conf`, `/etc/apt/apt.conf.d/01proxy` and `/etc/profile.d/proxy.sh`.
  Uncomment those lines to update, then comment them out again.

## Pitfalls already hit

- **Never add `OnBootSec=` to `work-hours-on.timer`.** When 17:30 stops
  `work-hours.target`, systemd re-arms the timer and a boot timer already in the past
  fires at once: the screen went off and straight back on every evening and stayed on
  all weekend (fixed 2026-10-26).
- `select-hours-target.sh` must use `systemctl --no-block start`. It runs during
  `multi-user.target`, the looper is ordered after `multi-user.target`, and a blocking
  start deadlocks the boot.
- Restarting `work-hours-*.timer` by hand can fire them. After editing, `daemon-reload` is
  enough.
- `kmsblank` blanks only while it is running: it waits for Enter and unblanks when it
  exits. `screen-blank.service` feeds it a stdin that never ends; a plain oneshot exits at
  once and the screen comes straight back.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE).
