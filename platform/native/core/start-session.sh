#!/system/bin/sh
# Detached launcher for a native session.
#
# Starts session.sh in a new session with no controlling terminal, redirects
# stdio, and returns immediately. This is what keeps KOReader alive when the
# shell that launched it goes away (adb USB unplug, terminal close, NativeKO
# Activity being killed when zygote stops, ...).
#
# Usage: start-session.sh [PROFILE]
#   PROFILE defaults to KO_NATIVE_PROFILE_ID or t65a.
#   KO_SESSION_LOG overrides the log path (default: <native>/session.log).

set -u

_native_dir="${0%/*}"
[ "$_native_dir" = "$0" ] && _native_dir="."
NATIVE_DIR="${KO_NATIVE_DIR:-$_native_dir}"
PROFILE="${1:-${KO_NATIVE_PROFILE_ID:-t65a}}"
LOG="${KO_SESSION_LOG:-$NATIVE_DIR/session.log}"
BB="${KO_BUSYBOX:-busybox}"

if [ ! -f "$NATIVE_DIR/session.sh" ]; then
    echo "start-session.sh: missing $NATIVE_DIR/session.sh" >&2
    exit 1
fi

# setsid: new session without a controlling tty, so adb/terminal teardown
# cannot SIGHUP the session or KOReader.
"$BB" setsid sh "$NATIVE_DIR/session.sh" --profile "$PROFILE" \
    >"$LOG" 2>&1 </dev/null &

echo "session started (profile=$PROFILE, log=$LOG)"
