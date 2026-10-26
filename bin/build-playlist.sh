#!/bin/sh
# Write an m3u of every video and image in DIR, in natural sort order.
# Exits non-zero when there is nothing to play.
set -eu
dir=${1:-/mnt/videos}
out=${2:-/run/playlist.m3u}

list=$(find "$dir" -maxdepth 1 -type f \
  \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.webm' \
     -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' \) \
  | LC_ALL=C sort -fV)

[ -n "$list" ] || { echo "no media in $dir" >&2; exit 1; }
{ echo '#EXTM3U'; echo "$list"; } > "$out"
