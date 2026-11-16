#!/system/bin/sh
# Generic native KOReader session orchestrator.
#
# A device profile (profiles/<id>/profile.env, generated from profile.json)
# supplies the hardware/host data; the host and Wi-Fi drivers supply the
# platform behaviour. This file contains no device-specific paths.
#
# Usage:
#   session.sh [--profile ID] [--profile-dir DIR] [--no-stop] [--dry-run] [start]
#   session.sh --profile ID wifi-up|wifi-down|wifi-dhcp|restore
#
# Run as root. On exit (including SIGTERM/INT) the Android host services, the
# CPU governor, Wi-Fi and the framebuffer are restored.

set -u

# `dirname` is not available in the Android 4.4 toolbox; use the shell built-in.
_native_dir="${0%/*}"
[ "$_native_dir" = "$0" ] && _native_dir="."
NATIVE_DIR="${KO_NATIVE_DIR:-$_native_dir}"
KO_HOME="${KO_HOME:-/data/data/org.koreader.launcher/files}"
PROFILE_ID="${KO_NATIVE_PROFILE_ID:-notesl}"
PROFILE_DIR=""
ACTION="start"
DRY_RUN=0
STOP_FRAMEWORK=1
BB="${KO_BUSYBOX:-busybox}"

usage() {
    cat >&2 <<EOF
usage: $0 [--profile ID] [--profile-dir DIR] [--no-stop] [--dry-run] [ACTION]
actions: start (default), wifi-up, wifi-down, wifi-dhcp, wifi-release,
         wifi-load, wifi-unload, wifi-suspend, restore
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE_ID="$2"; shift 2 ;;
        --profile-dir) PROFILE_DIR="$2"; shift 2 ;;
        --no-stop) STOP_FRAMEWORK=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        start|wifi-up|wifi-down|wifi-dhcp|wifi-release|wifi-load|wifi-unload|wifi-suspend|restore) ACTION="$1"; shift ;;
        *) echo "session.sh: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$PROFILE_DIR" ] || PROFILE_DIR="$NATIVE_DIR/profiles/$PROFILE_ID"
PROFILE_ENV="$PROFILE_DIR/profile.env"
PROFILE_LUA="$PROFILE_DIR/profile.lua"
if [ ! -f "$PROFILE_ENV" ]; then
    echo "session.sh: missing profile $PROFILE_ENV" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$PROFILE_ENV"

# Helper command used for shell bits the old Android toolbox lacks.  The
# profile supplies it (busybox on most ROMs, toybox on others); fall back to
# whichever is actually present on this device.
BB="${KO_BUSYBOX:-${TOOL_BUSYBOX:-}}"
if [ -z "$BB" ]; then
    if [ -x /system/bin/busybox ]; then
        BB=/system/bin/busybox
    elif [ -x /system/bin/toybox ]; then
        BB=/system/bin/toybox
    else
        BB=busybox
    fi
fi

# Make the session wake lock unique per session: the previous session's
# trap (pm_stop) must not release a lock acquired by a newer session.
KO_NATIVE_WAKE_LOCK="${PWR_WAKE_LOCK_NAME:-nativeko}-$$"
export KO_NATIVE_WAKE_LOCK

BIN="${KO_NATIVE_BIN:-${KO_T65A_BIN:-$NATIVE_DIR/koreader-native}}"
JOURNAL="$NATIVE_DIR/session.journal"
GOV_SAVE="$NATIVE_DIR/original_governors"

# Shared user data (settings/plugins/patches), like the Android KOReader.
KO_DATA_DIR="${KO_DATA_DIR:-$DATA_DIR}"
if [ -n "$KO_DATA_DIR" ] && mkdir -p "$KO_DATA_DIR/plugins" "$KO_DATA_DIR/patches" 2>/dev/null; then
    :
else
    KO_DATA_DIR="$KO_HOME"
fi
export KO_HOME KO_DATA_DIR
export KO_NATIVE_DIR="$NATIVE_DIR"
export KO_NATIVE_PROFILE="$PROFILE_LUA"
export KO_NATIVE_PROFILE_ID="$PROFILE_ID"

# Native libraries and Lua search paths. The self-contained layout keeps the
# libraries in KO_HOME/libs; the dev layout falls back to the installed
# Android app's native library directory.
if [ -f "$KO_HOME/libs/libluajit.so" ]; then
    LIB_DIR="$KO_HOME/libs"
else
    LIB_DIR="/data/data/org.koreader.launcher/lib"
    if [ ! -d "$LIB_DIR" ]; then
        LIB_DIR=""
        for d in /data/app-lib/org.koreader.launcher-*; do
            [ -d "$d" ] && LIB_DIR="$d" && break
        done
    fi
    if [ -z "$LIB_DIR" ]; then
        echo "session.sh: cannot locate KOReader native libraries" >&2
        exit 1
    fi
    if [ ! -e "$KO_HOME/libs" ]; then
        ln -s ../lib "$KO_HOME/libs" 2>/dev/null || ln -s "$LIB_DIR" "$KO_HOME/libs" 2>/dev/null
    fi
fi
export LD_LIBRARY_PATH="$LIB_DIR:$KO_HOME/libs:$KO_HOME/common:${LD_LIBRARY_PATH:-}"
export LUA_PATH="./?.lua;common/?.lua;frontend/?.lua;plugins/?.lua;;"
export LUA_CPATH="./?.so;common/?.so;$NATIVE_DIR/?.so;;"

HOST_STOPPED=0
HOST_DRIVER="$NATIVE_DIR/drivers/host/$HOST_BACKEND.sh"
if [ ! -f "$HOST_DRIVER" ]; then
    echo "session.sh: missing host backend $HOST_DRIVER" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$HOST_DRIVER"

WIFI_DRIVER=""
if [ "$NET_MANAGE" = "1" ] && [ -n "$NET_BACKEND" ]; then
    WIFI_DRIVER="$NATIVE_DIR/drivers/wifi/$NET_BACKEND.sh"
    if [ ! -f "$WIFI_DRIVER" ]; then
        echo "session.sh: missing wifi backend $WIFI_DRIVER" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$WIFI_DRIVER"
fi

# Power-management model (session side): wakelock/early-suspend handshake,
# session wake lock, or a no-op for hosts that manage this themselves.
pm_start() { :; }
pm_stop() { :; }
PM_DRIVER=""
if [ -n "${PWR_MODEL:-}" ]; then
    PM_DRIVER="$NATIVE_DIR/drivers/pm/$PWR_MODEL.sh"
    if [ -f "$PM_DRIVER" ]; then
        # shellcheck disable=SC1090
        . "$PM_DRIVER"
    else
        echo "session.sh: no pm driver for $PWR_MODEL (continuing)" >&2
    fi
fi

# --- dry run -------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
    echo "profile:        $PROFILE_ID ($PROFILE_DIR)"
    echo "KO_HOME:        $KO_HOME"
    echo "KO_DATA_DIR:    $KO_DATA_DIR"
    echo "launcher:       $BIN"
    echo "host backend:   $HOST_BACKEND"
    echo "stop services:  $HOST_STOP_SERVICES"
    echo "start services: $HOST_START_SERVICES"
    echo "governor:       $HOST_GOV_NATIVE (restore $HOST_GOV_FALLBACK)"
    echo "display:        $DISP_FB pan=$DISP_PAN_VALUE blank=$DISP_BLANK"
    echo "wifi:           $NET_BACKEND iface=$NET_IFACE ctrl=${NET_CTRL_INTERFACE:-$NET_CTRL_DIR/$NET_IFACE}"
    echo "wifi autostart: $NET_START_ON_BOOT"
    echo "pm model:       ${PWR_MODEL:-none}"
    echo "pm wake lock:   ${PWR_WAKE_LOCK_NAME:-none}"
    echo "wakeup mask:    ${PWR_WAKEUP_DISABLE:-none}"
    exit 0
fi

# --- generic helpers -----------------------------------------------------
set_native_governor() {
    if [ -f "$GOV_SAVE" ]; then
        $BB sed -i -e "s/ performance$/ $HOST_GOV_FALLBACK/" \
            -e "s/ interactive$/ $HOST_GOV_FALLBACK/" "$GOV_SAVE" 2>/dev/null
    fi
    : > "$GOV_SAVE.new"
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -w "$cpu/cpufreq/scaling_governor" ] || continue
        cur=$(cat "$cpu/cpufreq/scaling_governor")
        case "$cur" in
            performance|interactive)
                saved=$($BB grep "^$cpu " "$GOV_SAVE" 2>/dev/null | $BB sed -e 's/^[^ ]* //' -e 's/ .*//')
                [ -n "$saved" ] || saved="$HOST_GOV_FALLBACK"
                ;;
            *) saved="$cur" ;;
        esac
        echo "$cpu $saved" >> "$GOV_SAVE.new"
        echo "$HOST_GOV_NATIVE" > "$cpu/cpufreq/scaling_governor" 2>/dev/null
    done
    mv "$GOV_SAVE.new" "$GOV_SAVE"
}

restore_governor() {
    [ -f "$GOV_SAVE" ] || return 0
    while read -r cpu gov; do
        case "$gov" in
            performance|interactive) gov="$HOST_GOV_FALLBACK" ;;
        esac
        if [ -n "$cpu" ] && [ -w "$cpu/cpufreq/scaling_governor" ]; then
            echo "$gov" > "$cpu/cpufreq/scaling_governor" 2>/dev/null
        fi
    done < "$GOV_SAVE"
}

prepare_display() {
    [ -n "$DISP_BLANK" ] && [ -w "$DISP_BLANK" ] && echo 0 > "$DISP_BLANK" 2>/dev/null
    [ -n "$DISP_PAN" ] && [ -w "$DISP_PAN" ] && echo "$DISP_PAN_VALUE" > "$DISP_PAN" 2>/dev/null
}

unblank_display() {
    [ -n "$DISP_BLANK" ] && [ -w "$DISP_BLANK" ] && echo 0 > "$DISP_BLANK" 2>/dev/null
}

full_restore() {
    restore_governor
    [ -n "$WIFI_DRIVER" ] && wifi_down
    unblank_display
    HOST_STOPPED=1
    host_post_exit
    # If suspend unloaded the Wi-Fi driver, leave it loaded for the Android
    # framework that is about to come back.
    [ -n "$WIFI_DRIVER" ] && wifi_load
    pm_stop
    rm -f "$JOURNAL"
}

cleanup() {
    trap - 0 2 15
    full_restore
}

# --- non-session actions -------------------------------------------------
case "$ACTION" in
    restore)
        echo "session.sh: manual restore (profile=$PROFILE_ID)" >&2
        full_restore
        exit 0
        ;;
    wifi-up)   wifi_up; exit $? ;;
    wifi-down) wifi_down; exit $? ;;
    wifi-load)   wifi_load; exit $? ;;
    wifi-unload) wifi_unload; exit $? ;;
    wifi-suspend) wifi_suspend; exit $? ;;
    wifi-dhcp) wifi_dhcp; exit $? ;;
    wifi-release) wifi_release; exit $? ;;
esac

# --- start ---------------------------------------------------------------
# NOTE: the Android 4.4 toolbox 'id' has no -u.
if ! id 2>/dev/null | grep "uid=0" >/dev/null 2>&1; then
    echo "session.sh: must run as root (su -c ...)" >&2
    exit 1
fi
if [ ! -f "$BIN" ]; then
    echo "session.sh: missing launcher $BIN" >&2
    exit 1
fi
if [ ! -f "$KO_HOME/reader.lua" ]; then
    echo "session.sh: missing KOReader module at $KO_HOME" >&2
    exit 1
fi

# Recover from a previous session that died without running its trap.
if [ -f "$JOURNAL" ]; then
    echo "session.sh: stale journal found, restoring previous session first" >&2
    full_restore
fi

trap cleanup 0 2 15
echo "$PROFILE_ID $$" > "$JOURNAL"

# Take over power management before stopping the framework: the last
# framework wake lock may be released as it stops.
pm_start
host_pre_start
prepare_display
set_native_governor
if [ "$NET_MANAGE" = "1" ] && [ "$NET_START_ON_BOOT" = "1" ]; then
    wifi_up
fi

cd "$KO_HOME" || exit 1
echo "session.sh: starting $BIN (profile=$PROFILE_ID KO_HOME=$KO_HOME KO_DATA_DIR=$KO_DATA_DIR)" >&2
"$BIN"
