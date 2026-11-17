#!/usr/bin/env bash
# Development deployment helper for the native KOReader build.
#
# This patches the already-extracted KOReader module that lives in the
# installed Android app's private data directory, so that the native launcher
# can use it. It is intentionally a *dev* helper: for a standalone native
# build, use platform/android/nativeko/build.sh.
#
# Select the device profile with PROFILE_ID (default: notesl).
#
# Requires: adb, root on the device, the device connected.
set -euo pipefail

cd "$(dirname "$0")"

ROOT="$(cd ../.. && pwd)"
ADB="${ADB:-adb}"
TMP=/data/local/tmp/nativeko
MODULE="${KO_MODULE:-/data/data/org.koreader.launcher/files}"
PROFILE_ID="${PROFILE_ID:-notesl}"
PROFILE_JSON="$ROOT/platform/native/profiles/$PROFILE_ID/profile.json"

[ -f "$PROFILE_JSON" ] || { echo "missing profile $PROFILE_JSON" >&2; exit 1; }

./build-native.sh

# One JSON profile -> profile.env (session/drivers) + profile.lua (KOReader).
PROFILE_OUT="$(mktemp -d)"
trap 'rm -rf "$PROFILE_OUT"' EXIT
python3 "$ROOT/platform/native/tools/profilegen.py" \
    "$PROFILE_JSON" "$PROFILE_OUT"

$ADB shell "mkdir -p $TMP" >/dev/null
$ADB shell "mkdir -p $TMP/libs" >/dev/null
$ADB push koreader-native "$TMP/koreader-native" >/dev/null
$ADB push detach "$TMP/detach" >/dev/null
if [ -f libnativeko-dns.so ]; then
    $ADB push libnativeko-dns.so "$TMP/libnativeko-dns.so" >/dev/null
fi

# Generic session core + host/wifi drivers + generated profile.
$ADB shell "mkdir -p $TMP/drivers/host $TMP/drivers/wifi $TMP/drivers/pm $TMP/profiles/$PROFILE_ID" >/dev/null
$ADB push "$ROOT/platform/native/core/session.sh" "$TMP/session.sh" >/dev/null
$ADB push "$ROOT/platform/native/core/start-session.sh" "$TMP/start-session.sh" >/dev/null
$ADB push "$ROOT/platform/native/drivers/host/." "$TMP/drivers/host/" >/dev/null
$ADB push "$ROOT/platform/native/drivers/wifi/." "$TMP/drivers/wifi/" >/dev/null
$ADB push "$ROOT/platform/native/drivers/pm/." "$TMP/drivers/pm/" >/dev/null
$ADB push "$PROFILE_OUT/profile.env" "$TMP/profiles/$PROFILE_ID/profile.env" >/dev/null
$ADB push "$PROFILE_OUT/profile.lua" "$TMP/profiles/$PROFILE_ID/profile.lua" >/dev/null
$ADB push "$PROFILE_OUT/profile.lua" "$TMP/profile.lua" >/dev/null
$ADB shell "echo '$PROFILE_ID' > $TMP/profile.id" >/dev/null

# Shared pure-Lua wpa_supplicant control client.
$ADB shell "mkdir -p $TMP/lj-wpaclient" >/dev/null
$ADB push "$ROOT/platform/native/common/lj-wpaclient/." "$TMP/lj-wpaclient/" >/dev/null

# The Android monolibtic does not include the Linux evdev input module;
# build and ship it separately when the prerequisites are available.
LUAJIT_SRC="${LUAJIT_SRC:-/tmp/nativeko/LuaJIT-2.1/src}"
LIBLUAJIT_DIR="${LIBLUAJIT_DIR:-/tmp/nativeko/libluajit}"
if [[ -f "$LUAJIT_SRC/lua.h" && -f "$LIBLUAJIT_DIR/libluajit.so" ]]; then
    LUAJIT_SRC="$LUAJIT_SRC" LIBLUAJIT_DIR="$LIBLUAJIT_DIR" ./build-input.sh
    $ADB push libkoreader-input.so "$TMP/libs/libkoreader-input.so" >/dev/null
elif [[ -f libkoreader-input.so ]]; then
    $ADB push libkoreader-input.so "$TMP/libs/libkoreader-input.so" >/dev/null
else
    echo "NOTE: libkoreader-input.so not built; KOReader will fail to load its input module" >&2
fi
$ADB push run-native.sh restore-android.sh "$TMP/" >/dev/null
$ADB shell "mkdir -p $TMP/device_native" >/dev/null
$ADB push "$ROOT/frontend/device/native/." "$TMP/device_native/" >/dev/null
$ADB push "$ROOT/frontend/device.lua" "$TMP/device.lua" >/dev/null
$ADB push "$ROOT/datastorage.lua" "$TMP/datastorage.lua" >/dev/null
$ADB push "$ROOT/base/ffi/mxcfb_t65a_h.lua" "$TMP/mxcfb_t65a_h.lua" >/dev/null
$ADB push "$ROOT/base/ffi/framebuffer_mxcfb.lua" "$TMP/framebuffer_mxcfb.lua" >/dev/null
$ADB push "$ROOT/base/ffi/framebuffer_rk_ebc.lua" "$TMP/framebuffer_rk_ebc.lua" >/dev/null
$ADB push "$ROOT/base/ffi/framebuffer_onyx.lua" "$TMP/framebuffer_onyx.lua" >/dev/null

$ADB shell "su -c '
  set -e
  rm -rf $MODULE/frontend/device/t65a
  mkdir -p $MODULE/frontend/device/native $MODULE/frontend/device/native/suspend
  [ -f $MODULE/frontend/device.lua.native-bak ] || cp -a $MODULE/frontend/device.lua $MODULE/frontend/device.lua.native-bak
  [ -f $MODULE/ffi/framebuffer_mxcfb.lua.native-bak ] || cp -a $MODULE/ffi/framebuffer_mxcfb.lua $MODULE/ffi/framebuffer_mxcfb.lua.native-bak
  [ -f $MODULE/datastorage.lua.native-bak ] || cp -a $MODULE/datastorage.lua $MODULE/datastorage.lua.native-bak
  cp -f $TMP/device_native/device.lua $MODULE/frontend/device/native/device.lua
  cp -f $TMP/device_native/powerd.lua $MODULE/frontend/device/native/powerd.lua
  cp -f $TMP/device_native/suspend/*.lua $MODULE/frontend/device/native/suspend/ 2>/dev/null || true
  cp -f $TMP/device.lua $MODULE/frontend/device.lua
  cp -f $TMP/datastorage.lua $MODULE/datastorage.lua
  cp -f $TMP/mxcfb_t65a_h.lua $MODULE/ffi/mxcfb_t65a_h.lua
  cp -f $TMP/framebuffer_mxcfb.lua $MODULE/ffi/framebuffer_mxcfb.lua
  cp -f $TMP/framebuffer_rk_ebc.lua $MODULE/ffi/framebuffer_rk_ebc.lua
  cp -f $TMP/framebuffer_onyx.lua $MODULE/ffi/framebuffer_onyx.lua
  mkdir -p $MODULE/common/lj-wpaclient
  cp -f $TMP/lj-wpaclient/*.lua $MODULE/common/lj-wpaclient/
  chmod 644 $MODULE/common/lj-wpaclient/*.lua $MODULE/frontend/device/native/*.lua $MODULE/frontend/device/native/suspend/*.lua $MODULE/ffi/framebuffer_rk_ebc.lua $MODULE/ffi/framebuffer_onyx.lua
  [ -e $MODULE/libs ] || ln -s ../lib $MODULE/libs
  chmod 755 $TMP/koreader-native $TMP/detach
  chmod 755 $TMP/session.sh $TMP/start-session.sh $TMP/drivers/host/*.sh $TMP/drivers/wifi/*.sh $TMP/drivers/pm/*.sh
  chmod 755 $TMP/run-native.sh $TMP/restore-android.sh
'"

cat <<EOF
Deployed profile '$PROFILE_ID' to $TMP and patched $MODULE.

Run detached (survives adb/USB disconnect; logs to $TMP/session.log):
  $ADB shell su -c 'sh $TMP/start-session.sh $PROFILE_ID'

Foreground (debug only; dies with the adb shell):
  $ADB shell su -c 'sh $TMP/session.sh --profile $PROFILE_ID'

Dry run (prints the profile plan without touching anything):
  $ADB shell su -c 'sh $TMP/session.sh --profile $PROFILE_ID --dry-run'

Quick test without stopping the framework:
  $ADB shell su -c 'sh $TMP/session.sh --profile $PROFILE_ID --no-stop'

Legacy wrappers (same session core):
  $TMP/run-native.sh, $TMP/restore-android.sh

Backups of the patched module files:
  $MODULE/frontend/device.lua.native-bak
  $MODULE/ffi/framebuffer_mxcfb.lua.native-bak
  $MODULE/ffi/framebuffer_rk_ebc.lua (overwritten, no backup)
  $MODULE/ffi/framebuffer_onyx.lua (compatibility alias, no backup)
EOF
