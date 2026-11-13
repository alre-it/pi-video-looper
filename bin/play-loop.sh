#!/bin/sh
# Play a playlist full-screen on KMS/DRM in an endless loop.
# AUDIO=yes plays the sound on AUDIO_DEVICE (mpv name, default: auto);
# anything else plays silently. IMAGE_DISPLAY_DURATION: seconds per image.
set -eu

audio=--no-audio
case ${AUDIO:-no} in
  yes) audio=--audio-device=${AUDIO_DEVICE:-auto} ;;
  no) ;;
  *) echo "play-loop: AUDIO='$AUDIO' is neither yes nor no, playing silently" >&2 ;;
esac

exec /usr/bin/mpv \
  --no-resume-playback --playlist-start=0 --start=0 \
  "$audio" --fs --loop-playlist=inf --no-osd-bar \
  --image-display-duration="${IMAGE_DISPLAY_DURATION:-240}" \
  --no-terminal \
  --gpu-context=drm --drm-mode=preferred \
  --hwdec=auto-safe \
  "$@"
