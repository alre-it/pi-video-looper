#!/bin/sh
# Mirror the media files on a USB stick into MEDIA_DIR (MEDIA_SOURCE=usb).
#
# The stick is mounted read-only only for the copy and unmounted again, so it
# can be pulled at any time; the looper always plays the local copy. Media
# files are taken from the top level of the stick. Files that are no longer on
# the stick are deleted, which is how a swapped stick replaces the playlist.
# No stick, or a stick without any media files, leaves the current media alone:
# plugging in the wrong stick must not blank the screen.
#
# Needs root for mount (sync-media.service gets User=root from install.sh).
# USB_DIR=<dir> skips the mount and reads that directory instead (for testing).
set -eu
export LC_ALL=C

MEDIA_DIR=${MEDIA_DIR:-/var/lib/pi-video-looper/media}
part="$MEDIA_DIR/.part"
tmp=$(mktemp -d)
mnt=""
cleanup() {
  if [ -n "$mnt" ]; then umount "$mnt" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

is_media() {
  case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
    *.mp4 | *.mkv | *.mov | *.webm | *.jpg | *.jpeg | *.png | *.gif) return 0 ;;
  esac
  return 1
}

if [ -n "${USB_DIR:-}" ]; then
  src=$USB_DIR
else
  dev=$(/usr/local/bin/find-usb-stick.sh)
  if [ -z "$dev" ]; then
    echo "no USB stick, keeping current media"
    exit 0
  fi
  mkdir "$tmp/mnt"
  if ! mount -o ro,nosuid,nodev,noexec "$dev" "$tmp/mnt"; then
    echo "cannot mount $dev, keeping current media" >&2
    exit 1
  fi
  mnt="$tmp/mnt"
  src=$mnt
fi

: > "$tmp/keep"
for f in "$src"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  case $name in .*) continue ;; esac
  is_media "$name" && printf '%s\n' "$name" >> "$tmp/keep"
done
if [ ! -s "$tmp/keep" ]; then
  echo "no media files on the USB stick, keeping current media"
  exit 0
fi

mkdir -p "$MEDIA_DIR" "$part"
rm -f "$part"/*
changed=0

# Copy new and changed files (same name but other size or time = changed).
while IFS= read -r name; do
  if [ -f "$MEDIA_DIR/$name" ] &&
     [ "$(stat -c '%s %Y' "$src/$name")" = "$(stat -c '%s %Y' "$MEDIA_DIR/$name")" ]; then
    continue
  fi
  echo "copying $name"
  if cp -p "$src/$name" "$part/$name"; then
    mv -f "$part/$name" "$MEDIA_DIR/$name"
    changed=1
  else
    echo "copy of $name failed" >&2
    rm -f "$part/$name"
  fi
done < "$tmp/keep"

# Delete what is no longer on the stick.
for f in "$MEDIA_DIR"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  [ "$name" = image_display_duration_sec.txt ] && continue
  if ! grep -qxF "$name" "$tmp/keep"; then
    echo "removing $name"
    rm -f "$f"
    changed=1
  fi
done

if [ "$changed" = 1 ]; then
  echo "media changed"
else
  echo "up to date ($(grep -c . "$tmp/keep") files)"
fi
