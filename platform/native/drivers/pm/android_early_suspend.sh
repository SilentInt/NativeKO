#!/system/bin/sh
# Android legacy wakelock / early-suspend model (session side).
#
# - Holds a session wake lock while the native session owns the screen, so the
#   framework's own locks being released as it stops do not trigger early
#   suspend before KOReader is ready.
# - Runs the wait_for_fb_sleep/wait_for_fb_wake readers that system_server
#   normally provides (see fb_ack.sh).
#
# Sourced by core/session.sh; profile.env provides PWR_WAKE_LOCK_NAME.

FB_ACK="$NATIVE_DIR/drivers/pm/fb_ack.sh"
FB_ACK_PIDS=""

pm_start() {
    LOCK="${KO_NATIVE_WAKE_LOCK:-${PWR_WAKE_LOCK_NAME:-nativeko}}"

    # Verbose PM traces for suspend debugging. The suspend driver snapshots
    # dmesg into suspend-trace.log before dropping the last wake lock,
    # because this kernel has no /proc/last_kmsg or pstore.
    echo 31 > /sys/module/wakelock/parameters/debug_mask 2>/dev/null
    echo 15 > /sys/module/earlysuspend/parameters/debug_mask 2>/dev/null
    echo 15 > /sys/module/alarm/parameters/debug_mask 2>/dev/null
    echo 15 > /sys/module/alarm_dev/parameters/debug_mask 2>/dev/null

    # Acquire the session lock before touching anything else, so setup cannot
    # accidentally autosuspend.
    if [ -n "$LOCK" ]; then
        echo "$LOCK" > /sys/power/wake_lock 2>/dev/null
    fi

    # Kill an old acker first: when "on" unblocks its wait_for_fb_wake read it
    # would re-acquire the old session lock, and nothing would release it.
    "$BB" pkill -9 -f "$FB_ACK" 2>/dev/null

    # Clear a stale early-suspend request left by a previous session/crash.
    # This runs late_resume and unblanks the display.
    echo on > /sys/power/state 2>/dev/null

    if [ -r /sys/power/wait_for_fb_sleep ]; then
        # One sequential reader handles sleep -> ack/resume -> loop.
        KO_NATIVE_WAKE_LOCK="$LOCK" sh "$FB_ACK" &
        FB_ACK_PIDS="$FB_ACK_PIDS $!"
    fi

    # Fast resume lock keeper: fb_ack.sh re-acquires the session lock as soon
    # as wait_for_fb_wake returns, before the kernel's short timeout locks
    # expire and the system immediately re-suspends.
    rm -f "$NATIVE_DIR/suspend-armed"

    # A stale AlarmManager alarm (set before the framework was stopped) keeps
    # the alarm_rtc wake lock active and makes late suspend fail with -EAGAIN.
    if [ -n "${PWR_RTC_ALARM:-}" ] && [ -w "$PWR_RTC_ALARM" ]; then
        echo 0 > "$PWR_RTC_ALARM" 2>/dev/null
    fi

    if [ -n "$LOCK" ]; then
        # Release stale framework locks and session locks leaked by a previous
        # core; our new session lock keeps the system awake.
        base="${PWR_WAKE_LOCK_NAME:-nativeko}"
        for name in $(cat /sys/power/wake_lock 2>/dev/null); do
            case "$name" in
                "$LOCK") ;;
                PowerManagerService.*|"$base"|"$base"-*)
                    echo "$name" > /sys/power/wake_unlock 2>/dev/null ;;
            esac
        done
    fi
    echo "$(date) pm_start: lock=$LOCK alarm=${PWR_RTC_ALARM:-none}" \
        >> "$NATIVE_DIR/suspend.log" 2>/dev/null
}

pm_stop() {
    LOCK="${KO_NATIVE_WAKE_LOCK:-${PWR_WAKE_LOCK_NAME:-nativeko}}"
    # Leave the early-suspend state machine in wakeup mode for the framework.
    echo on > /sys/power/state 2>/dev/null
    # Keep the session lock until the framework has acquired its own wake
    # locks (system_server start). Releasing it earlier can sleep the device
    # in the middle of the Android boot/restore.
    if [ -n "$LOCK" ]; then
        i=0
        while [ $i -lt 30 ]; do
            locks=$(cat /sys/power/wake_lock 2>/dev/null)
            case "$locks" in
                *PowerManagerService*|*KeyEvents*) break ;;
            esac
            sleep 1
            i=$((i+1))
        done
        echo "$LOCK" > /sys/power/wake_unlock 2>/dev/null
    fi

    for p in $FB_ACK_PIDS; do
        kill -9 "$p" 2>/dev/null
    done
    FB_ACK_PIDS=""
    "$BB" pkill -9 -f "$FB_ACK" 2>/dev/null
    rm -f "$NATIVE_DIR/suspend-armed"
}
