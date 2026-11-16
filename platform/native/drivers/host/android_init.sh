#!/system/bin/sh
# Android init host backend: stop/start services through setprop ctl.*.
# Sourced by core/session.sh; profile.env provides the service lists.
#
# Power management is a separate driver (drivers/pm/<power.model>.sh); this
# file only deals with the Android service manager.

host_pre_start() {
    if [ "${STOP_FRAMEWORK:-1}" != "1" ]; then
        return 0
    fi
    echo "session.sh: stopping Android services: $HOST_STOP_SERVICES" >&2
    for s in $HOST_STOP_SERVICES; do
        setprop ctl.stop "$s" 2>/dev/null
    done
    # Give SurfaceFlinger a moment to release /dev/fb0.
    sleep 1

    HOST_STOPPED=1
}

host_post_exit() {
    if [ "${HOST_STOPPED:-0}" != "1" ]; then
        return 0
    fi
    echo "session.sh: restoring Android framework" >&2
    for s in $HOST_START_SERVICES; do
        setprop ctl.start "$s" 2>/dev/null
    done
    HOST_STOPPED=0
}
