#!/usr/bin/env bash
# Development deployment helper for the native T65A build.
#
# This patches the already-extracted KOReader module that lives in the
# installed Android app's private data directory, so that the native launcher
# can use it. It is intentionally a *dev* helper: for a standalone native
# build, build koreader-base with a proper T65A target and ship its own module.
#
# Requires: adb, root on the device, the device connected.
set -euo pipefail

cd "$(dirname "$0")"

ROOT="$(cd ../.. && pwd)"
ADB="${ADB:-adb}"
TMP=/data/local/tmp/t65a-native
MODULE="${KO_MODULE:-/data/data/org.koreader.launcher/files}"

./build-native.sh

# One JSON profile -> profile.env (session/drivers) + profile.lua (KOReader).
PROFILE_OUT="$(mktemp -d)"
trap 'rm -rf "$PROFILE_OUT"' EXIT
python3 "$ROOT/platform/native/tools/profilegen.py" \
    "$ROOT/platform/native/profiles/t65a/profile.json" "$PROFILE_OUT"

$ADB shell "mkdir -p $TMP" >/dev/null
$ADB shell "mkdir -p $TMP/libs" >/dev/null
$ADB push koreader-t65a "$TMP/koreader-t65a" >/dev/null

# Generic session core + host/wifi drivers + generated profile.
$ADB shell "mkdir -p $TMP/drivers/host $TMP/drivers/wifi $TMP/drivers/pm $TMP/profiles/t65a" >/dev/null
$ADB push "$ROOT/platform/native/core/session.sh" "$TMP/session.sh" >/dev/null
$ADB push "$ROOT/platform/native/core/start-session.sh" "$TMP/start-session.sh" >/dev/null
$ADB push "$ROOT/platform/native/drivers/host/." "$TMP/drivers/host/" >/dev/null
$ADB push "$ROOT/platform/native/drivers/wifi/." "$TMP/drivers/wifi/" >/dev/null
$ADB push "$ROOT/platform/native/drivers/pm/." "$TMP/drivers/pm/" >/dev/null
$ADB shell "su -c 'rm -f $TMP/drivers/host/fb_ack.sh'" >/dev/null
$ADB push "$PROFILE_OUT/profile.env" "$TMP/profiles/t65a/profile.env" >/dev/null
$ADB push "$PROFILE_OUT/profile.lua" "$TMP/profiles/t65a/profile.lua" >/dev/null

# Shared pure-Lua wpa_supplicant control client.
$ADB shell "mkdir -p $TMP/lj-wpaclient" >/dev/null
$ADB push "$ROOT/platform/native/common/lj-wpaclient/." "$TMP/lj-wpaclient/" >/dev/null

# The Android monolibtic does not include the Linux evdev input module;
# build and ship it separately when the prerequisites are available.
LUAJIT_SRC="${LUAJIT_SRC:-/tmp/t65a/LuaJIT-2.1/src}"
LIBLUAJIT_DIR="${LIBLUAJIT_DIR:-/tmp/t65a/libluajit}"
if [[ -f "$LUAJIT_SRC/lua.h" && -f "$LIBLUAJIT_DIR/libluajit.so" ]]; then
    LUAJIT_SRC="$LUAJIT_SRC" LIBLUAJIT_DIR="$LIBLUAJIT_DIR" ./build-input.sh
    $ADB push libkoreader-input.so "$TMP/libs/libkoreader-input.so" >/dev/null
else
    echo "NOTE: libkoreader-input.so not built; set LUAJIT_SRC and LIBLUAJIT_DIR and run build-input.sh" >&2
fi
$ADB push run-native.sh restore-android.sh "$TMP/" >/dev/null
$ADB shell "mkdir -p $TMP/device_native" >/dev/null
$ADB push "$ROOT/frontend/device/native/." "$TMP/device_native/" >/dev/null
$ADB push "$ROOT/frontend/device.lua" "$TMP/device.lua" >/dev/null
$ADB push "$ROOT/datastorage.lua" "$TMP/datastorage.lua" >/dev/null
$ADB push "$ROOT/base/ffi/mxcfb_t65a_h.lua" "$TMP/mxcfb_t65a_h.lua" >/dev/null
$ADB push "$ROOT/base/ffi/framebuffer_mxcfb.lua" "$TMP/framebuffer_mxcfb.lua" >/dev/null

$ADB shell "su -c '
  set -e
  rm -rf $MODULE/frontend/device/t65a
  mkdir -p $MODULE/frontend/device/native
  [ -f $MODULE/frontend/device.lua.native-bak ] || cp -a $MODULE/frontend/device.lua $MODULE/frontend/device.lua.native-bak
  [ -f $MODULE/ffi/framebuffer_mxcfb.lua.native-bak ] || cp -a $MODULE/ffi/framebuffer_mxcfb.lua $MODULE/ffi/framebuffer_mxcfb.lua.native-bak
  [ -f $MODULE/datastorage.lua.native-bak ] || cp -a $MODULE/datastorage.lua $MODULE/datastorage.lua.native-bak
  cp -f $TMP/device_native/device.lua $MODULE/frontend/device/native/device.lua
  cp -f $TMP/device_native/powerd.lua $MODULE/frontend/device/native/powerd.lua
  if [ -d $TMP/device_native/suspend ]; then
    mkdir -p $MODULE/frontend/device/native/suspend
    cp -f $TMP/device_native/suspend/*.lua $MODULE/frontend/device/native/suspend/
  fi
  cp -f $TMP/device.lua $MODULE/frontend/device.lua
  cp -f $TMP/datastorage.lua $MODULE/datastorage.lua
  cp -f $TMP/mxcfb_t65a_h.lua $MODULE/ffi/mxcfb_t65a_h.lua
  cp -f $TMP/framebuffer_mxcfb.lua $MODULE/ffi/framebuffer_mxcfb.lua
  mkdir -p $MODULE/common/lj-wpaclient
  cp -f $TMP/lj-wpaclient/*.lua $MODULE/common/lj-wpaclient/
  chmod 644 $MODULE/common/lj-wpaclient/*.lua $MODULE/frontend/device/native/*.lua
  if [ -d $MODULE/frontend/device/native/suspend ]; then
    chmod 644 $MODULE/frontend/device/native/suspend/*.lua
  fi
  [ -e $MODULE/libs ] || ln -s ../lib $MODULE/libs
  chmod 755 $TMP/koreader-t65a
  chmod 755 $TMP/session.sh $TMP/start-session.sh $TMP/drivers/host/*.sh $TMP/drivers/wifi/*.sh $TMP/drivers/pm/*.sh
  chmod 755 $TMP/run-native.sh $TMP/restore-android.sh
'"

cat <<EOF
Deployed to $TMP and patched $MODULE.

Run detached (survives adb/USB disconnect; logs to $TMP/session.log):
  $ADB shell su -c 'sh $TMP/start-session.sh t65a'

Foreground (debug only; dies with the adb shell):
  $ADB shell su -c 'sh $TMP/session.sh --profile t65a'

Dry run (prints the profile plan without touching anything):
  $ADB shell su -c 'sh $TMP/session.sh --profile t65a --dry-run'

Quick test without stopping the framework:
  $ADB shell su -c 'sh $TMP/session.sh --profile t65a --no-stop'

Legacy wrappers (same session core):
  $TMP/run-native.sh, $TMP/restore-android.sh

Backups of the patched module files:
  $MODULE/frontend/device.lua.native-bak
  $MODULE/ffi/framebuffer_mxcfb.lua.native-bak
EOF
