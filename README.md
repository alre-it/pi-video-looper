# pi-video-looper

Turns a Raspberry Pi into a headless digital-signage player: it loops videos and
images full-screen over HDMI during work hours and blanks the screen at night and
at weekends. No desktop, no X/Wayland: `mpv` draws straight to KMS/DRM on tty1.

Content comes from the upload page in [`server/`](server/): people upload a file
there, pick the screens and a "show from" / "show until" window, and each Pi
mirrors whatever is active for it. Nothing has to be deleted by hand; a file
drops off the screens when its window ends.

Runs on `bermon01` and `bermon02` (Raspberry Pi 5, Raspberry Pi OS Lite, bookworm);
the server runs on espocrm2 (`http://upload-server:8300`).

## How it works

| Piece | What it does |
|---|---|
| `sync-media.timer` | Every 2 min, day and night: `sync-media.sh` fetches this screen's manifest from the server and mirrors the active files into `/var/lib/pi-video-looper/media` (downloads new ids, deletes what is no longer listed). Server unreachable → nothing is touched. |
| `work-hours.target` / `night-hours.target` | The two modes. They conflict, so starting one stops the other. |
| `work-hours-on.timer` | Mon-Fri 06:30 → `work-hours.target`. |
| `work-hours-off.timer` | Mon-Fri 17:30 → `night-hours.target`. |
| `select-hours-target.service` | At boot, picks the mode for the current time (window in `/etc/default/pi-video-looper`). |
| `video-looper.service` | Builds `/run/playlist.m3u` from the media directory and plays it with `mpv` in an endless loop. Part of work hours. |
| `scan-video-folder.timer` | Every 2 min: if the media directory changed, restarts the looper so the playlist is rebuilt. |
| `screen-blank.service` | Keeps `kmsblank` running all night, so the TV gets no signal and drops into standby. |

Media: `mp4 mkv mov webm jpg jpeg png gif`, played in natural filename order
(prefix files with a date or number to order them). Still images stay on screen for
the number of seconds set under "Einstellungen" on the upload page (default 240);
`sync-media.sh` writes it to `image_display_duration_sec.txt` next to the media.

An upload reaches the screen within about 4 minutes: up to 2 min until the sync
timer fetches it, up to 2 more until the scan timer restarts the looper.

## The upload server

`server/` is a small Node app (express + multer, Node ≥ 18): a German upload page
with HTTP basic auth, a JSON list of items (`items.json`) and the files under
`DATA_DIR/files`. Per item: screens, `showFrom`, `showUntil`. The Pis poll
`GET /api/screens/<name>/manifest` (plain text, one `id<TAB>name` line per active
file, plus `#IMAGE_DISPLAY_DURATION=`) and download `/media/<id>`; those two routes
need no auth. Expired items stay in the list for `PURGE_DAYS` (30) so the window
can be extended, then file and entry are deleted.

Deploy (from a box that can reach the host; ships `node_modules`, so the host
needs no npm):

```sh
cd server && ./deploy.sh espo@upload-server
```

It rsyncs to `~/bermon-upload`, creates `~/bermon-upload/.env` on first run (port,
screens, `AUTH_USER`/`AUTH_PASS`, `DATA_DIR=~/bermon-upload-data`) and installs
`bermon-upload.service` as a rootless user unit (needs linger). Password: see that
`.env`. Data is only in `~/bermon-upload-data`; it is not backed up anywhere.

## Install

On a fresh Raspberry Pi OS Lite with a user `tv`:

```sh
git clone <this repo> && cd pi-video-looper
sudo ./install.sh --server http://upload-server:8300
sudo reboot
```

The screen name sent to the server is the Pi's short hostname (`bermon01`), so it
must match one of the server's `SCREENS`. Re-running `install.sh` on a Pi that
still has the old SMB mount disables and removes it.

If the work window changes, edit both the `OnCalendar=` lines in
`systemd/work-hours-*.timer` and `/etc/default/pi-video-looper`.

## Operating it

```sh
systemctl is-active work-hours.target night-hours.target video-looper.service
systemctl list-timers 'work-hours-*'
journalctl -b -u video-looper -u select-hours-target -u scan-video-folder -u sync-media
sudo systemctl start sync-media.service    # fetch now instead of waiting 2 min
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
