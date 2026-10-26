#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

DIR="/mnt/videos"
STATE="/run/videos.atime_count"   # "MAX_ATIME:COUNT"

# Share mounted?
if command -v mountpoint >/dev/null 2>&1; then
  mountpoint -q "$DIR" || exit 0
else
  [[ -d "$DIR" ]] || exit 0
fi

VIDEO_EXPR=( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.webm' -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' )

MAX_ATIME=$(LC_ALL=C find "$DIR" -type f \( "${VIDEO_EXPR[@]}" \) -printf '%A@\n' 2>/dev/null | sort -n | tail -1)
MAX_ATIME=${MAX_ATIME:-0}
COUNT=$(find "$DIR" -type f \( "${VIDEO_EXPR[@]}" \) 2>/dev/null | wc -l | tr -d '[:space:]')
COUNT=${COUNT:-0}
NEW="${MAX_ATIME}:${COUNT}"

OLD="0:0"
if [[ -r "$STATE" ]]; then
  IFS= read -r OLD < "$STATE" || OLD="0:0"
fi

if [[ "$NEW" != "$OLD" ]]; then
  printf '%s\n' "$NEW" > "$STATE"
  echo "Change detected (atime/count: $OLD -> $NEW). Restarting video-looper.service"
  systemctl --no-block try-restart video-looper.service || true
else
  echo "Nothing changed (${NEW})."
fi
