#!/bin/sh
# MEDIA_SOURCE=usb-direct: keep the USB stick mounted read-only at MEDIA_DIR,
# so the looper plays straight from it and nothing is written to the Pi.
#
# Run by sync-media.service: every 2 minutes, and at once when a USB disk is
# plugged in or pulled (90-pi-video-looper.rules). A stick that is gone is
# unmounted; a new one is mounted. Either way the looper is restarted, so the
# playlist follows the stick within seconds.
#
# Needs root for mount. USB_DEV=<device> skips the detection (for testing).
set -eu

MNT=${MEDIA_DIR:-/media/pi-video-looper-usb}
mkdir -p "$MNT"

restart_looper() {
  systemctl --no-block try-restart video-looper.service || true
}

if mountpoint -q "$MNT"; then
  src=$(findmnt -no SOURCE "$MNT")
  # A pulled stick loses its device node; a card reader with the card pulled
  # keeps the node but its size drops to 0.
  size=$(blockdev --getsize64 "$src" 2>/dev/null || echo 0)
  if [ -b "$src" ] && [ "$size" -gt 0 ]; then
    echo "stick $src is mounted"
    exit 0
  fi
  echo "stick $src is gone, unmounting"
  umount -l "$MNT"
  restart_looper
  exit 0
fi

dev=${USB_DEV:-$(/usr/local/bin/find-usb-stick.sh)}
if [ -z "$dev" ]; then
  echo "no USB stick"
  exit 0
fi

opts=ro,nosuid,nodev,noexec
case $(lsblk -no FSTYPE "$dev" 2>/dev/null) in
  vfat | exfat) opts=$opts,umask=0022 ;;   # readable for the looper user
esac
if ! mount -o "$opts" "$dev" "$MNT"; then
  echo "cannot mount $dev" >&2
  exit 1
fi
echo "mounted $dev read-only at $MNT"
restart_looper
