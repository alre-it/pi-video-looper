#!/bin/sh
# Turn a Raspberry Pi OS Lite install into a headless video/image looper.
# Run as root on the Pi:
#   sudo ./install.sh --server http://<server-host>:8300   # office: upload page, work hours, silent
#   sudo ./install.sh --museum                             # plays from a USB stick, sound, always on
# Re-running is safe; it overwrites the installed units and scripts. Options
# not given keep the value already in /etc/default/pi-video-looper.
set -eu

usage() {
  cat >&2 <<EOF
usage: $0 (--server URL | --usb | --usb-direct) [--audio | --no-audio] [--always-on | --work-hours]
          [--cec-wake | --no-cec-wake] [--user tv]
       $0 --museum [--user tv]        same as --usb-direct --audio --always-on --cec-wake
  --usb         copy the media from a USB stick to the Pi
  --usb-direct  play straight from the USB stick (mounted read-only)
  --cec-wake    keep the screen on over HDMI-CEC while the looper runs
EOF
  exit 2
}

server="" source="" audio="" schedule="" cec=""
user=tv
while [ $# -gt 0 ]; do
  case $1 in
    --server)     [ $# -ge 2 ] || usage; server=$2; source=server; shift 2 ;;
    --usb)        source=usb; shift ;;
    --usb-direct) source=usb-direct; shift ;;
    --audio)      audio=yes; shift ;;
    --no-audio)   audio=no; shift ;;
    --always-on)  schedule=always; shift ;;
    --work-hours) schedule=work-hours; shift ;;
    --cec-wake)   cec=yes; shift ;;
    --no-cec-wake) cec=no; shift ;;
    --museum)     source=usb-direct audio=yes schedule=always cec=yes; shift ;;
    --user)       [ $# -ge 2 ] || usage; user=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
id "$user" >/dev/null 2>&1 || { echo "user $user does not exist" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
conf=/etc/default/pi-video-looper
media=/var/lib/pi-video-looper/media
usb_mount=/media/pi-video-looper-usb

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
[ -n "$cec" ] && set_conf CEC_WAKE "$cec"
source=$(get_conf MEDIA_SOURCE)
source=${source:-server}
case $source in
  server | usb | usb-direct) ;;
  *) echo "MEDIA_SOURCE=$source in $conf is not server, usb or usb-direct" >&2; exit 2 ;;
esac
# The looper plays from the local mirror, or with usb-direct from the stick itself.
if [ "$source" = usb-direct ]; then
  set_conf MEDIA_DIR "$usb_mount"
elif [ "$(get_conf MEDIA_DIR)" = "$usb_mount" ] || ! grep -q '^MEDIA_DIR=' "$conf"; then
  set_conf MEDIA_DIR "$media"
fi
schedule=$(get_conf SCHEDULE)
schedule=${schedule:-work-hours}
if [ "$source" = server ]; then
  case $(get_conf SIGNAGE_SERVER) in
    '' | *'<server-host>'*) echo "--server is required (or --usb / --usb-direct / --museum)" >&2; exit 2 ;;
  esac
fi

# v4l-utils: cec-ctl for CEC_WAKE.
apt-get install -y mpv kms++-utils curl v4l-utils

install -m 755 "$here"/bin/*.sh /usr/local/bin/
for f in "$here"/systemd/*; do
  sed "s/^User=tv$/User=$user/" "$f" > "/etc/systemd/system/$(basename "$f")"
done
install -d -o "$user" -g "$user" -m 755 "$media"
# mpv plays the sound through ALSA.
usermod -aG audio "$user"

# USB modes: mounting the stick needs root (the server sync stays
# unprivileged), and udev looks at the stick as soon as one is plugged in.
dropin=/etc/systemd/system/sync-media.service.d
rule=/etc/udev/rules.d/90-pi-video-looper.rules
if [ "$source" = usb ] || [ "$source" = usb-direct ]; then
  mkdir -p "$dropin"
  printf '[Service]\n# MEDIA_SOURCE=usb/usb-direct: mounting the stick needs root.\nUser=root\n' > "$dropin/usb.conf"
  install -D -m 644 "$here/udev/90-pi-video-looper.rules" "$rule"
else
  rm -f "$dropin/usb.conf" "$rule"
  rmdir "$dropin" 2>/dev/null || true
fi
udevadm control --reload 2>/dev/null || true

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
systemctl enable video-looper.service scan-video-folder.timer screen-blank.service cec-wake.service

# Fetch the media now, and if the screen is on, restart the looper on it.
systemctl start sync-media.service || echo "WARNING: first sync failed (source: $source)" >&2
if systemctl is-active -q work-hours.target; then
  systemctl --no-block restart video-looper.service cec-wake.service
fi

echo "Installed: media from $source, sound $(get_conf AUDIO), schedule $schedule, CEC wake $(get_conf CEC_WAKE)."
echo "The looper plays from $(get_conf MEDIA_DIR); reboot to start in the right mode."
