#!/system/bin/sh
# Android 6 wakelock / wakeup_count PM model (RK3288 and similar).
#
# This kernel has no legacy earlysuspend (no wait_for_fb_* and no
# /sys/module/earlysuspend); suspend is requested with /sys/power/state and
# guarded by the wakelock interface.  The suspend driver in Lua releases the
# session lock just before writing "mem"; this shell side only manages the
# session lock and stale framework locks around the session lifetime.
#
# Sourced by core/session.sh; profile.env provides PWR_WAKE_LOCK_NAME.

pm_start() {
    LOCK="${KO_NATIVE_WAKE_LOCK:-${PWR_WAKE_LOCK_NAME:-nativeko}}"

    # Hold a session lock while KOReader owns the screen.  Android's locks
    # disappear when system_server exits, which would otherwise let the
    # kernel suspend before the UI is ready.
    [ -n "$LOCK" ] && echo "$LOCK" > /sys/power/wake_lock 2>/dev/null

    # Drop stale framework locks left behind by a stopped system_server, and
    # session locks leaked by a previous core that exited without pm_stop.
    base="${PWR_WAKE_LOCK_NAME:-nativeko}"
    for name in $(cat /sys/power/wake_lock 2>/dev/null); do
        case "$name" in
            "$LOCK") ;;
            "$base"|"$base"-*)
                echo "$name" > /sys/power/wake_unlock 2>/dev/null ;;
            PowerManagerService.*|KeyEvents)
                echo "$name" > /sys/power/wake_unlock 2>/dev/null ;;
        esac
    done

    # A stale RTC alarm keeps an alarm wake lock and can abort suspend.
    [ -n "${PWR_RTC_ALARM:-}" ] && [ -w "$PWR_RTC_ALARM" ] && \
        echo 0 > "$PWR_RTC_ALARM" 2>/dev/null

    echo "$(date) pm_start lock=$LOCK" >> "$NATIVE_DIR/suspend.log" 2>/dev/null
}

pm_stop() {
    LOCK="${KO_NATIVE_WAKE_LOCK:-${PWR_WAKE_LOCK_NAME:-nativeko}}"

    # Keep the session lock until system_server has taken its own locks
    # again; releasing it too early can suspend during the Android restore.
    i=0
    while [ $i -lt 30 ]; do
        locks=$(cat /sys/power/wake_lock 2>/dev/null)
        case "$locks" in
            *PowerManagerService*) break ;;
        esac
        sleep 1
        i=$((i + 1))
    done

    # Release session locks leaked by an earlier core that was killed without
    # running its trap, then release our own lock unconditionally.  The loop
    # deliberately skips $LOCK, so it must be released explicitly afterwards;
    # otherwise Android is left unable to suspend after the session exits.
    base="${PWR_WAKE_LOCK_NAME:-nativeko}"
    for name in $(cat /sys/power/wake_lock 2>/dev/null); do
        case "$name" in
            "$LOCK") ;;
            "$base"|"$base"-*)
                echo "$name" > /sys/power/wake_unlock 2>/dev/null ;;
        esac
    done
    [ -n "$LOCK" ] && echo "$LOCK" > /sys/power/wake_unlock 2>/dev/null
    # Do not touch the RTC here: the framework has already been restored and
    # may have armed its own AlarmManager wakeup.
    echo "$(date) pm_stop" >> "$NATIVE_DIR/suspend.log" 2>/dev/null
}
