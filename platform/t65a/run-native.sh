#!/system/bin/sh
# Compatibility wrapper. The real orchestration lives in
# platform/native/core/session.sh, deployed next to this script, and is
# driven by platform/native/profiles/<id>/profile.env.

# `dirname` is not available in the Android 4.4 toolbox; use the shell built-in.
_native_dir="${0%/*}"
[ "$_native_dir" = "$0" ] && _native_dir="."
NATIVE_DIR="${KO_NATIVE_DIR:-$_native_dir}"
exec sh "$NATIVE_DIR/session.sh" --profile "${KO_NATIVE_PROFILE_ID:-t65a}" "$@"
