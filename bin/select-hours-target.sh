#!/bin/sh
# Start work-hours.target inside the work window, night-hours.target outside.
# --no-block: this runs while multi-user.target is starting, and the looper is
# ordered after multi-user.target, so waiting for the job would deadlock.
WORK_DAYS_MAX=${WORK_DAYS_MAX:-5}
WORK_START=${WORK_START:-0630}
WORK_END=${WORK_END:-1800}

dow=$(date +%u)
now=$(date +%H%M)
if [ "$dow" -le "$WORK_DAYS_MAX" ] && [ "$now" -ge "$WORK_START" ] && [ "$now" -lt "$WORK_END" ]; then
  exec systemctl --no-block start work-hours.target
fi
exec systemctl --no-block start night-hours.target
