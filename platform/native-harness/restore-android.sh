#!/system/bin/sh
# Compatibility wrapper. Restores the Android framework/governor/Wi-Fi after a
# native session through platform/native/core/session.sh.

# `dirname` is not available in the Android 4.4 toolbox; use the shell built-in.
_native_dir="${0%/*}"
[ "$_native_dir" = "$0" ] && _native_dir="."
NATIVE_DIR="${KO_NATIVE_DIR:-$_native_dir}"
exec sh "$NATIVE_DIR/session.sh" --profile "${KO_NATIVE_PROFILE_ID:-notesl}" restore
