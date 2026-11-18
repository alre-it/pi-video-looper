#!/bin/sh
# Start work-hours.target inside the work window, night-hours.target outside.
# SCHEDULE=always: the looper runs whenever the Pi is on.
# --no-block: this runs while multi-user.target is starting, and the looper is
# ordered after multi-user.target, so waiting for the job would deadlock.
if [ "${SCHEDULE:-work-hours}" = always ]; then
  exec systemctl --no-block start work-hours.target
fi

WORK_DAYS_MAX=${WORK_DAYS_MAX:-5}
WORK_START=${WORK_START:-0630}
WORK_END=${WORK_END:-1730}

# A value that is not a plain number (a trailing comment in the EnvironmentFile,
# a typo) used to fail the test below and blank the screen all day. Say so in
# the journal and fall back to the default instead.
numeric() {
  case $2 in
    '' | *[!0-9]*)
      echo "select-hours-target: $1='$2' is not a number, using $3" >&2
      echo "$3"
      ;;
    *) echo "$2" ;;
  esac
}
WORK_DAYS_MAX=$(numeric WORK_DAYS_MAX "$WORK_DAYS_MAX" 5)
WORK_START=$(numeric WORK_START "$WORK_START" 0630)
WORK_END=$(numeric WORK_END "$WORK_END" 1730)

dow=$(date +%u)
now=$(date +%H%M)
if [ "$dow" -le "$WORK_DAYS_MAX" ] && [ "$now" -ge "$WORK_START" ] && [ "$now" -lt "$WORK_END" ]; then
  exec systemctl --no-block start work-hours.target
fi
exec systemctl --no-block start night-hours.target
