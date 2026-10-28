#!/bin/sh
# Turn a Raspberry Pi OS Lite install into a headless video/image looper.
# Run as root on the Pi:  sudo ./install.sh --server http://upload-server:8300
# Re-running is safe; it overwrites the installed units and scripts.
set -eu

server=""
user=tv
while [ $# -gt 0 ]; do
  case $1 in
    --server) server=$2; shift 2 ;;
    --user)   user=$2; shift 2 ;;
    *) echo "usage: $0 --server http://host:port [--user tv]" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -n "$server" ] || { echo "--server is required" >&2; exit 2; }
id "$user" >/dev/null 2>&1 || { echo "user $user does not exist" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
media=/var/lib/pi-video-looper/media

apt-get install -y mpv kms++-utils curl

install -m 755 "$here"/bin/*.sh /usr/local/bin/
for f in "$here"/systemd/*; do
  sed "s/^User=tv$/User=$user/" "$f" > "/etc/systemd/system/$(basename "$f")"
done
[ -e /etc/default/pi-video-looper ] || install -m 644 "$here/config/pi-video-looper.default" /etc/default/pi-video-looper
if grep -q '^SIGNAGE_SERVER=' /etc/default/pi-video-looper; then
  sed -i "s|^SIGNAGE_SERVER=.*|SIGNAGE_SERVER=$server|" /etc/default/pi-video-looper
else
  printf 'SIGNAGE_SERVER=%s\nMEDIA_DIR=%s\n' "$server" "$media" >> /etc/default/pi-video-looper
fi
install -d -o "$user" -g "$user" -m 755 "$media"

# Earlier versions played an SMB share mounted at /mnt/videos.
if [ -e /etc/systemd/system/mnt-videos.mount ]; then
  systemctl disable mnt-videos.mount 2>/dev/null || true
  umount -l /mnt/videos 2>/dev/null || true   # lazy: the old looper still has it as cwd
  rm -f /etc/systemd/system/mnt-videos.mount
  echo "NOTE: the SMB mount is gone; /etc/smbcredentials can be deleted." >&2
fi

# The looper owns tty1; a login prompt there would fight it for the screen.
systemctl mask getty@tty1.service

systemctl daemon-reload
systemctl reset-failed mnt-videos.mount 2>/dev/null || true
systemctl enable select-hours-target.service work-hours-on.timer work-hours-off.timer
systemctl enable --now sync-media.timer
systemctl enable video-looper.service scan-video-folder.timer screen-blank.service

# Fetch the media now, and if the screen is on, restart the looper on it.
systemctl start sync-media.service || echo "WARNING: first sync failed, is $server reachable?" >&2
if systemctl is-active -q work-hours.target; then
  systemctl --no-block restart video-looper.service
fi

echo "Installed. Media is mirrored from $server to $media; reboot to start in the right mode for the time of day."
