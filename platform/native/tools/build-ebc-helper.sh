#!/usr/bin/env bash
# Build libnativeko-ebc.so, the bounded-time EBC ioctl helper.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../../.. && pwd)"
NDK="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT:-}/ndk/23.2.8568313}"
API="${API:-19}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi${API}-clang"
[ -x "$CC" ] || { echo "compiler not found: $CC" >&2; exit 1; }
"$CC" -O2 -Wall -Wextra -fPIC -shared \
    -o "$ROOT/platform/native-harness/libnativeko-ebc.so" \
    "$ROOT/platform/native/common/ebc-helper.c"
echo "built: $ROOT/platform/native-harness/libnativeko-ebc.so"
