#!/bin/sh
# CEC_WAKE=yes: keep the screen on over HDMI-CEC while the looper runs.
#
# Every CEC_WAKE_INTERVAL seconds (default 60) this sends the screen "Image
# View On" and announces the Pi as "Active Source". A screen with its own
# auto-standby is woken again (or never falls asleep: some reset their timer on
# it), and it switches to the Pi's input at boot. Only HDMI ports with a screen
# (a valid physical address) are used, so hot-plugging the cable is fine.
#
# Runs as cec-wake.service, part of work-hours.target, so it never fights the
# night blanking. Needs cec-ctl (v4l-utils). The screen must have CEC enabled
# (Anynet+, SimpLink, Bravia Sync, EasyLink, ... in its menu).
set -u

interval=${CEC_WAKE_INTERVAL:-60}
case $interval in '' | *[!0-9]* | 0) interval=60 ;; esac
name=$(hostname -s | cut -c1-14)   # CEC OSD names are at most 14 characters

while :; do
  for dev in /dev/cec*; do
    [ -c "$dev" ] || continue
    # Registering is idempotent; it also re-reads the physical address after a replug.
    cec-ctl -d "$dev" --playback --osd-name "$name" >/dev/null 2>&1 || continue
    pa=$(cec-ctl -d "$dev" 2>/dev/null | sed -n 's/^[[:space:]]*Physical Address[[:space:]]*: //p' | head -1)
    case $pa in '' | f.f.f.f) continue ;; esac
    if cec-ctl -d "$dev" -t0 --image-view-on 2>&1 | grep -qE 'Not Acknowledged|Error'; then
      echo "$dev: screen did not acknowledge Image View On (CEC off on the screen?)"
      continue
    fi
    cec-ctl -d "$dev" --active-source phys-addr="$pa" >/dev/null 2>&1
  done
  sleep "$interval"
done
