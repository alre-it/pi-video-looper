#!/bin/sh
# Mirror this screen's current playlist from the upload server into MEDIA_DIR.
#
# The server answers GET $SIGNAGE_SERVER/api/screens/<screen>/manifest with
#   #IMAGE_DISPLAY_DURATION=<seconds>
#   <id>TAB<file name>        (one line per file that is active right now)
# A file's id never changes, so an id mismatch means "download again". Files
# that are no longer listed are deleted; that is how "show until" takes effect.
# If the server cannot be reached, nothing is touched and the current media
# keeps playing.
set -eu

# The media can come from a USB stick instead: copied (usb) or played in place (usb-direct).
case ${MEDIA_SOURCE:-server} in
  usb) exec /usr/local/bin/sync-usb.sh ;;
  usb-direct) exec /usr/local/bin/mount-usb.sh ;;
esac

: "${SIGNAGE_SERVER:?SIGNAGE_SERVER is not set (see /etc/default/pi-video-looper)}"
MEDIA_DIR=${MEDIA_DIR:-/var/lib/pi-video-looper/media}
SCREEN=${SCREEN:-$(hostname -s)}
ids="$MEDIA_DIR/.ids"      # one file per media file, holding the server id
part="$MEDIA_DIR/.part"    # downloads in progress
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$MEDIA_DIR" "$ids" "$part"
rm -f "$part"/*

if ! curl -fsS --max-time 30 "$SIGNAGE_SERVER/api/screens/$SCREEN/manifest" -o "$tmp/manifest"; then
  echo "cannot fetch manifest from $SIGNAGE_SERVER, keeping current media" >&2
  exit 1
fi

changed=0
: > "$tmp/keep"

# Settings lines.
dur=$(sed -n 's/^#IMAGE_DISPLAY_DURATION=\([0-9]*\)$/IMAGE_DISPLAY_DURATION=\1/p' "$tmp/manifest" | head -1)
if [ -n "$dur" ]; then
  if [ "$(cat "$MEDIA_DIR/image_display_duration_sec.txt" 2>/dev/null)" != "$dur" ]; then
    printf '%s\n' "$dur" > "$MEDIA_DIR/image_display_duration_sec.txt"
    changed=1
  fi
fi

# Media lines.
grep -v '^#' "$tmp/manifest" | while IFS="$(printf '\t')" read -r id name; do
  [ -n "$id" ] && [ -n "$name" ] || continue
  case $name in */*|.*) echo "skipping suspicious name: $name" >&2; continue ;; esac
  printf '%s\n' "$name" >> "$tmp/keep"
  if [ "$(cat "$ids/$name" 2>/dev/null)" = "$id" ] && [ -f "$MEDIA_DIR/$name" ]; then
    continue
  fi
  echo "downloading $name ($id)"
  if curl -fsS --max-time 1800 "$SIGNAGE_SERVER/media/$id" -o "$part/$name"; then
    mv -f "$part/$name" "$MEDIA_DIR/$name"
    printf '%s\n' "$id" > "$ids/$name"
    echo changed >> "$tmp/changed"
  else
    echo "download of $name failed" >&2
    rm -f "$part/$name"
  fi
done

# Delete what the server no longer lists.
for f in "$MEDIA_DIR"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  [ "$name" = image_display_duration_sec.txt ] && continue
  if ! grep -qxF "$name" "$tmp/keep"; then
    echo "removing $name"
    rm -f "$f" "$ids/$name"
    echo changed >> "$tmp/changed"
  fi
done
for f in "$ids"/*; do
  [ -f "$f" ] && [ ! -f "$MEDIA_DIR/$(basename "$f")" ] && rm -f "$f"
done

if [ "$changed" = 1 ] || [ -s "$tmp/changed" ]; then
  echo "media changed"
else
  echo "up to date ($(grep -c . "$tmp/keep") files)"
fi
