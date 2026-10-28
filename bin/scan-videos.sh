#!/bin/sh
# Restart the looper when the media directory changed since the last run, so
# the playlist is rebuilt. Compares a fingerprint of name, size and mtime of
# every file (including image_display_duration_sec.txt).
set -eu
export LC_ALL=C

DIR=${MEDIA_DIR:-/var/lib/pi-video-looper/media}
STATE=/run/videos.fingerprint

[ -d "$DIR" ] || exit 0

NEW=$(find "$DIR" -maxdepth 1 -type f -printf '%f %s %T@\n' | sort | md5sum | cut -d' ' -f1)
OLD=$(cat "$STATE" 2>/dev/null || echo none)

if [ "$NEW" != "$OLD" ]; then
  printf '%s\n' "$NEW" > "$STATE"
  echo "Change detected, restarting video-looper.service"
  systemctl --no-block try-restart video-looper.service || true
else
  echo "Nothing changed."
fi
