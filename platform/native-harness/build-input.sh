#!/usr/bin/env bash
# Build libkoreader-input.so (the Linux evdev input module) for the native
# KOReader backend. The Android APK's libkoreader-monolibtic.so does NOT include
# this module, because the Android launcher uses JNI input instead.
#
# Requirements:
#   * NDK 23.2 (same as build-native.sh)
#   * LuaJIT 2.1 headers (e.g. /tmp/nativeko/LuaJIT-2.1/src)
#   * a host copy of the device's ARM libluajit.so for linking, e.g.:
#       adb exec-out su -c 'cat /data/data/org.koreader.launcher/lib/libluajit.so' \
#           > /tmp/nativeko/libluajit/libluajit.so
#
#   LUAJIT_SRC=/path/to/LuaJIT-2.1/src \
#   LIBLUAJIT_DIR=/tmp/nativeko/libluajit \
#   ./build-input.sh
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

NDK="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT:-}/ndk/23.2.8568313}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi19-clang"
LUAJIT_SRC="${LUAJIT_SRC:-/tmp/nativeko/LuaJIT-2.1/src}"
LIBLUAJIT_DIR="${LIBLUAJIT_DIR:-/tmp/nativeko/libluajit}"

if [[ ! -x "$CC" ]]; then
    echo "NDK compiler not found: $CC" >&2
    exit 1
fi
if [[ ! -f "$LUAJIT_SRC/lua.h" ]]; then
    echo "LuaJIT headers not found at $LUAJIT_SRC" >&2
    echo "Get them with:" >&2
    echo "  curl -L https://github.com/LuaJIT/LuaJIT/archive/refs/heads/v2.1.tar.gz | tar xz -C /tmp/nativeko" >&2
    exit 1
fi
if [[ ! -f "$LIBLUAJIT_DIR/libluajit.so" ]]; then
    echo "libluajit.so not found at $LIBLUAJIT_DIR" >&2
    echo "Pull it from the device/APK (see the header of this script)." >&2
    exit 1
fi

"$CC" -shared -fPIC -O2 -DNATIVE_KO \
    -I "$LUAJIT_SRC" -I "$ROOT/base/input" \
    -L "$LIBLUAJIT_DIR" -Wl,-soname,libkoreader-input.so \
    -o "$ROOT/platform/native-harness/libkoreader-input.so" \
    "$ROOT/base/input/input.c" -lluajit

echo "built: $ROOT/platform/native-harness/libkoreader-input.so"
