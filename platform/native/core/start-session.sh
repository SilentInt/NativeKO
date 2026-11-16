#!/system/bin/sh
# Detached launcher for a native session.
#
# Starts session.sh in a new session with no controlling terminal, redirects
# stdio, and returns immediately. This is what keeps KOReader alive when the
# shell that launched it goes away (adb USB unplug, terminal close, NativeKO
# Activity being killed when zygote stops, ...).
#
# Usage: start-session.sh [PROFILE]
#   PROFILE defaults to KO_NATIVE_PROFILE_ID or notesl.
#   KO_SESSION_LOG overrides the log path (default: <native>/session.log).

set -u

_native_dir="${0%/*}"
[ "$_native_dir" = "$0" ] && _native_dir="."
NATIVE_DIR="${KO_NATIVE_DIR:-$_native_dir}"
PROFILE="${1:-${KO_NATIVE_PROFILE_ID:-notesl}}"
LOG="${KO_SESSION_LOG:-$NATIVE_DIR/session.log}"

# Resolve a setsid-capable helper without assuming busybox: some Android 6
# ROMs only ship toybox, and others only busybox.
BB="${KO_BUSYBOX:-}"
if [ -z "$BB" ]; then
    if [ -x /system/bin/busybox ]; then
        BB=/system/bin/busybox
    elif [ -x /system/bin/toybox ]; then
        BB=/system/bin/toybox
    else
        BB=busybox
    fi
fi

if [ ! -f "$NATIVE_DIR/session.sh" ]; then
    echo "start-session.sh: missing $NATIVE_DIR/session.sh" >&2
    exit 1
fi

# Prefer the bundled double-fork helper: a plain setsid can still be torn
# down when the adb/SuperSU session exits.  Fall back to setsid when the
# helper is not installed (older deployments).
DETACH="$NATIVE_DIR/detach"
if [ -x "$DETACH" ]; then
    "$DETACH" sh "$NATIVE_DIR/session.sh" --profile "$PROFILE" \
        >"$LOG" 2>&1 </dev/null
else
    "$BB" setsid sh "$NATIVE_DIR/session.sh" --profile "$PROFILE" \
        >"$LOG" 2>&1 </dev/null &
fi

echo "session started (profile=$PROFILE, log=$LOG)"
