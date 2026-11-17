#!/usr/bin/env bash
# Build libnativeko-dns.so, the LD_PRELOAD resolver used by native sessions
# when the Android framework (and therefore netd's DNS proxy) is stopped.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
NDK="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT:-}/ndk/23.2.8568313}"
API="${API:-23}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi${API}-clang"
[ -x "$CC" ] || { echo "compiler not found: $CC" >&2; exit 1; }
"$CC" -O2 -Wall -Wextra -fPIC -shared -ldl \
    -o "$ROOT/platform/native-harness/libnativeko-dns.so" \
    "$ROOT/platform/native/common/dns-resolver.c"
echo "built: $ROOT/platform/native-harness/libnativeko-dns.so"
