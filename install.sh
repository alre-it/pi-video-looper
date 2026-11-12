#!/bin/sh
# Turn a Raspberry Pi OS Lite install into a headless video/image looper.
# Run as root on the Pi:
#   sudo ./install.sh --server http://<server-host>:8300   # office: upload page, work hours, silent
#   sudo ./install.sh --museum                             # USB stick, sound, always on
# Re-running is safe; it overwrites the installed units and scripts. Options
# not given keep the value already in /etc/default/pi-video-looper.
set -eu

usage() {
  cat >&2 <<EOF
usage: $0 (--server URL | --usb) [--audio | --no-audio] [--always-on | --work-hours] [--user tv]
       $0 --museum [--user tv]        same as --usb --audio --always-on
EOF
  exit 2
}

server="" source="" audio="" schedule=""
user=tv
while [ $# -gt 0 ]; do
  case $1 in
    --server)     [ $# -ge 2 ] || usage; server=$2; source=server; shift 2 ;;
    --usb)        source=usb; shift ;;
    --audio)      audio=yes; shift ;;
    --no-audio)   audio=no; shift ;;
    --always-on)  schedule=always; shift ;;
    --work-hours) schedule=work-hours; shift ;;
    --museum)     source=usb audio=yes schedule=always; shift ;;
    --user)       [ $# -ge 2 ] || usage; user=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
id "$user" >/dev/null 2>&1 || { echo "user $user does not exist" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
conf=/etc/default/pi-video-looper
media=/var/lib/pi-video-looper/media

# Set KEY=VALUE in the config, replacing an existing line or appending one.
set_conf() {
  if grep -q "^$1=" "$conf"; then
    sed -i "s|^$1=.*|$1=$2|" "$conf"
  else
    printf '%s=%s\n' "$1" "$2" >> "$conf"
  fi
}
get_conf() {
  sed -n "s/^$1=//p" "$conf" | tail -1
}

[ -e "$conf" ] || install -m 644 "$here/config/pi-video-looper.default" "$conf"
[ -n "$source" ] && set_conf MEDIA_SOURCE "$source"
[ -n "$server" ] && set_conf SIGNAGE_SERVER "$server"
[ -n "$audio" ] && set_conf AUDIO "$audio"
[ -n "$schedule" ] && set_conf SCHEDULE "$schedule"
grep -q '^MEDIA_DIR=' "$conf" || set_conf MEDIA_DIR "$media"
source=$(get_conf MEDIA_SOURCE)
source=${source:-server}
schedule=$(get_conf SCHEDULE)
schedule=${schedule:-work-hours}
if [ "$source" = server ]; then
  case $(get_conf SIGNAGE_SERVER) in
    '' | *'<server-host>'*) echo "--server is required (or --usb / --museum)" >&2; exit 2 ;;
  esac
fi

apt-get install -y mpv kms++-utils curl

install -m 755 "$here"/bin/*.sh /usr/local/bin/
for f in "$here"/systemd/*; do
  sed "s/^User=tv$/User=$user/" "$f" > "/etc/systemd/system/$(basename "$f")"
done
install -d -o "$user" -g "$user" -m 755 "$media"
# mpv plays the sound through ALSA.
usermod -aG audio "$user"

# Mounting the USB stick needs root; the server sync stays unprivileged.
dropin=/etc/systemd/system/sync-media.service.d
if [ "$source" = usb ]; then
  mkdir -p "$dropin"
  printf '[Service]\n# MEDIA_SOURCE=usb: mounting the stick needs root.\nUser=root\n' > "$dropin/usb.conf"
else
  rm -f "$dropin/usb.conf"
  rmdir "$dropin" 2>/dev/null || true
fi

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
systemctl enable select-hours-target.service
if [ "$schedule" = always ]; then
  # No 17:30 switch-off; disable, not stop: stopping a timer is harmless, starting can fire it.
  systemctl disable work-hours-on.timer work-hours-off.timer 2>/dev/null || true
  systemctl stop work-hours-on.timer work-hours-off.timer 2>/dev/null || true
else
  systemctl enable work-hours-on.timer work-hours-off.timer
fi
systemctl enable --now sync-media.timer
systemctl enable video-looper.service scan-video-folder.timer screen-blank.service

# Fetch the media now, and if the screen is on, restart the looper on it.
systemctl start sync-media.service || echo "WARNING: first sync failed (source: $source)" >&2
if systemctl is-active -q work-hours.target; then
  systemctl --no-block restart video-looper.service
fi

echo "Installed: media from $source, sound $(get_conf AUDIO), schedule $schedule."
echo "Media is mirrored to $media; reboot to start in the right mode."
