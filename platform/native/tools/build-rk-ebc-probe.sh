#!/usr/bin/env bash
# Build rk-ebc-probe for Android/armv7 (bionic), using the same NDK as the
# native launcher.  Run the result as root on the device:
#
#   adb push rk-ebc-probe /data/local/tmp/
#   adb shell su -c 'chmod 755 /data/local/tmp/rk-ebc-probe'
#   adb shell su -c '/data/local/tmp/rk-ebc-probe info'
#
# Set ANDROID_NDK_HOME or ANDROID_SDK_ROOT.  The default API is 23; lower it
# with API=19 if the target device is older (the probe needs no newer APIs).
set -euo pipefail

cd "$(dirname "$0")"

NDK="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT:-}/ndk/23.2.8568313}"
API="${API:-23}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi${API}-clang"

if [[ ! -x "$CC" ]]; then
    echo "compiler not found: $CC" >&2
    echo "set ANDROID_NDK_HOME (NDK 23.2 is known to work)" >&2
    exit 1
fi

"$CC" -O2 -Wall -Wextra -fPIE -pie -o rk-ebc-probe rk-ebc-probe.c
echo "built: $(pwd)/rk-ebc-probe"
