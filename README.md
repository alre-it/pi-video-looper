# pi-video-looper

Turns a Raspberry Pi into a headless digital-signage player: it loops every video
and image on an SMB share full-screen over HDMI during work hours and blanks the
screen at night and at weekends. No desktop, no X/Wayland: `mpv` draws straight to
KMS/DRM on tty1.

Runs on `bermon01` and `bermon02` (Raspberry Pi 5, Raspberry Pi OS Lite, bookworm).

## How it works

| Piece | What it does |
|---|---|
| `mnt-videos.mount` | Mounts the SMB share read-only at `/mnt/videos` (credentials in `/etc/smbcredentials`). |
| `work-hours.target` / `night-hours.target` | The two modes. They conflict, so starting one stops the other. |
| `work-hours-on.timer` | Mon-Fri 06:30 → `work-hours.target`. |
| `work-hours-off.timer` | Mon-Fri 17:30 → `night-hours.target`. |
| `select-hours-target.service` | At boot, picks the mode for the current time (window in `/etc/default/pi-video-looper`). |
| `video-looper.service` | Builds `/run/playlist.m3u` from the share and plays it with `mpv` in an endless loop. Part of work hours. |
| `scan-video-folder.timer` | Every 2 min: if files on the share changed, restarts the looper so the playlist is rebuilt. |
| `screen-blank.service` | Keeps `kmsblank` running all night, so the TV gets no signal and drops into standby. |

Media: any `mp4 mkv mov webm jpg jpeg png gif` in the share's top level, played in
natural filename order (prefix files with a date or number to order them). Still
images stay on screen for `IMAGE_DISPLAY_DURATION` seconds (default 240); put a file
`image_display_duration_sec.txt` containing `IMAGE_DISPLAY_DURATION=300` on the share
to change it without touching the Pi.

## Install

On a fresh Raspberry Pi OS Lite with a user `tv`:

```sh
git clone <this repo> && cd pi-video-looper
sudo ./install.sh --share //SERVER/Share/Path
sudoedit /etc/smbcredentials   # username=, password=, domain=
sudo reboot
```

If the work window changes, edit both the `OnCalendar=` lines in
`systemd/work-hours-*.timer` and `/etc/default/pi-video-looper`.

## Operating it

```sh
systemctl is-active work-hours.target night-hours.target video-looper.service
systemctl list-timers 'work-hours-*'
journalctl -b -u video-looper -u select-hours-target -u scan-video-folder
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
