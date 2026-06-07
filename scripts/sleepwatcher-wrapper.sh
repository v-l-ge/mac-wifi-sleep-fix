#!/bin/sh
#
# Wrapper around sleepwatcher.
#
# Responsibilities:
#   1. Retry sleepwatcher start on early-boot crashes
#      (IOServiceGetMatchingService failed if IOPM service is not yet ready).
#   2. Keep wrapper alive while sleepwatcher runs, so launchd's KeepAlive
#      doesn't respawn it in a loop.
#
# Note on poll vs wait:
#   sleepwatcher is started inside $() command substitution, which means it
#   becomes a child of the subshell, not of this script. Its parent PID is
#   1 (launchd), not us. As a result, `wait "$PID"` returns immediately,
#   causing rapid respawn flapping. We use a poll loop instead.
#
# This wrapper is the entry point referenced by the LaunchDaemon plist.
# {{HOME}} is replaced by install.sh with the target user's home directory.

LOG=/var/log/sleepwatcher.log
TS() { date '+%F %T'; }

# Wait briefly on cold boot for IOPowerManagement to be ready.
BOOT_SEC=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/awk '{print $4}' | /usr/bin/tr -d ',')
NOW_SEC=$(/bin/date +%s)
UPTIME_SEC=$((NOW_SEC - BOOT_SEC))
if [ "$UPTIME_SEC" -lt 60 ]; then
    echo "$(TS) wrapper: early boot (uptime ${UPTIME_SEC}s), waiting 5s for IOPM" >> "$LOG"
    sleep 5
fi

start_sleepwatcher() {
    /usr/local/sbin/sleepwatcher -V -s {{HOME}}/.sleep -w {{HOME}}/.wakeup >> "$LOG" 2>&1 &
    echo $!
}

# Retry on early crash. Delays grow: 2s, 5s, 10s, 20s, 30s.
RETRY_DELAYS="2 5 10 20 30"
PID=""

for delay in $RETRY_DELAYS final; do
    echo "$(TS) wrapper: starting sleepwatcher" >> "$LOG"
    PID=$(start_sleepwatcher)
    sleep 5
    if kill -0 "$PID" 2>/dev/null; then
        echo "$(TS) wrapper: sleepwatcher PID $PID alive after 5s, OK" >> "$LOG"
        break
    fi
    if [ "$delay" = "final" ]; then
        echo "$(TS) wrapper: all retries exhausted, giving up; launchd will respawn" >> "$LOG"
        exit 1
    fi
    echo "$(TS) wrapper: sleepwatcher died early, retry in ${delay}s" >> "$LOG"
    sleep "$delay"
done

# Keep wrapper alive while sleepwatcher runs. wait() doesn't work here
# (subshell child, PPID=1), so we poll once per minute. If sleepwatcher
# dies, this loop exits, wrapper exits, and launchd KeepAlive respawns
# the entire wrapper.
while kill -0 "$PID" 2>/dev/null; do
    sleep 60
done
echo "$(TS) wrapper: sleepwatcher (PID $PID) exited — launchd will respawn" >> "$LOG"
exit 0
