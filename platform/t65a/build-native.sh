#!/usr/bin/env bash
# Build the native T65A KOReader launcher (bionic, armeabi-v7a, API 19).
#
# Requires an Android NDK. The launcher itself needs no NDK headers; it
# dlopen()s the libluajit.so shipped with the KOReader APK/module.
#
#   export ANDROID_SDK_ROOT=/path/to/android-sdk
#   export ANDROID_NDK_HOME=$ANDROID_SDK_ROOT/ndk/23.2.8568313
#   ./build-native.sh
set -euo pipefail

cd "$(dirname "$0")"

NDK="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT:-}/ndk/23.2.8568313}"
if [[ ! -d "$NDK" ]]; then
    echo "NDK not found at: $NDK" >&2
    echo "Set ANDROID_NDK_HOME or install with: sdkmanager 'ndk;23.2.8568313'" >&2
    exit 1
fi

CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi19-clang"
if [[ ! -x "$CC" ]]; then
    echo "Compiler not found: $CC" >&2
    exit 1
fi

"$CC" -O2 -Wall -Wextra -fPIE -pie -o koreader-t65a main.c -ldl
echo "built: $(pwd)/koreader-t65a"
