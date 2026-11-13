#!/bin/sh
# Play a playlist full-screen on KMS/DRM in an endless loop.
# AUDIO=yes plays the sound on AUDIO_DEVICE (mpv name, default: auto);
# anything else plays silently. IMAGE_DISPLAY_DURATION: seconds per image.
#
# Settings kept next to the media (MEDIA_DIR), so they survive a read-only
# system and travel with the stick:
#   .playorder  random-start (begin at a random entry, then in order) or
#               shuffle (random order); anything else plays in order
#   .volume     level of the sound card's PCM control in dB, e.g. -4
# mpv listens on $IPC_SOCKET, e.g. for {"command": ["playlist-next"]}.
set -eu
playlist=$1
settings=${MEDIA_DIR:-/var/lib/pi-video-looper/media}
IPC_SOCKET=${IPC_SOCKET:-/run/pi-video-looper/mpv.sock}

setting() { head -n 1 "$settings/$1" 2>/dev/null | tr -d ' \r' || true; }

audio=--no-audio
case ${AUDIO:-no} in
  yes) audio=--audio-device=${AUDIO_DEVICE:-auto} ;;
  no) ;;
  *) echo "play-loop: AUDIO='$AUDIO' is neither yes nor no, playing silently" >&2 ;;
esac

order=--playlist-start=0
case $(setting .playorder) in
  shuffle) order=--shuffle ;;
  random-start)
    n=$(grep -vc '^#' "$playlist" || true)
    if [ "${n:-0}" -gt 1 ]; then
      r=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
      order=--playlist-start=$((r % n))
    fi ;;
esac

# the card of AUDIO_DEVICE, e.g. alsa/plughw:CARD=Headphones,DEV=0
volume=$(setting .volume)
card=$(echo "${AUDIO_DEVICE:-}" | sed -n 's/.*CARD=\([^,]*\).*/\1/p')
case $volume in
  ''|*[!0-9.-]*) ;;
  *) amixer -q -c "${card:-0}" sset PCM -- "${volume}dB" ||
       echo "play-loop: cannot set the volume to ${volume} dB" >&2 ;;
esac

exec /usr/bin/mpv \
  --no-resume-playback "$order" --start=0 \
  "$audio" --fs --loop-playlist=inf --no-osd-bar \
  --input-ipc-server="$IPC_SOCKET" \
  --image-display-duration="${IMAGE_DISPLAY_DURATION:-240}" \
  --no-terminal \
  --gpu-context=drm --drm-mode=preferred \
  --hwdec=auto-safe \
  "$@"
