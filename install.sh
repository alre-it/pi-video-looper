#!/bin/sh
# Turn a Raspberry Pi OS Lite install into a headless video/image looper.
# Run as root on the Pi:  sudo ./install.sh --share //server/share/path
# Re-running is safe; it overwrites the installed units and scripts.
set -eu

share=""
user=tv
while [ $# -gt 0 ]; do
  case $1 in
    --share) share=$2; shift 2 ;;
    --user)  user=$2; shift 2 ;;
    *) echo "usage: $0 --share //server/share/path [--user tv]" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -n "$share" ] || { echo "--share is required" >&2; exit 2; }
id "$user" >/dev/null 2>&1 || { echo "user $user does not exist" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)

apt-get install -y mpv cifs-utils kms++-utils

install -m 755 "$here"/bin/*.sh /usr/local/bin/
for f in "$here"/systemd/*; do
  sed "s/^User=tv$/User=$user/" "$f" > "/etc/systemd/system/$(basename "$f")"
done
sed "s|@SHARE@|$share|" "$here/config/mnt-videos.mount.template" > /etc/systemd/system/mnt-videos.mount
[ -e /etc/default/pi-video-looper ] || install -m 644 "$here/config/pi-video-looper.default" /etc/default/pi-video-looper
mkdir -p /mnt/videos

if [ ! -e /etc/smbcredentials ]; then
  printf 'username=\npassword=\ndomain=\n' > /etc/smbcredentials
  chmod 600 /etc/smbcredentials
  echo "NOTE: fill in /etc/smbcredentials, then reboot." >&2
fi

# The looper owns tty1; a login prompt there would fight it for the screen.
systemctl mask getty@tty1.service

systemctl daemon-reload
systemctl enable mnt-videos.mount select-hours-target.service \
  work-hours-on.timer work-hours-off.timer
systemctl enable video-looper.service scan-video-folder.timer screen-blank.service

echo "Installed. Reboot to start in the right mode for the time of day."
