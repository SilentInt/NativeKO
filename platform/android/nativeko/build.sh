#!/usr/bin/env bash
# Build NativeKO.apk: a self-contained one-tap launcher for the native
# (framebuffer/evdev) KOReader build on the Boyue Likebook T65A.
#
# The APK embeds:
#   - the complete KOReader Lua module (pulled from the installed KOReader app
#     on the connected device, with user data stripped),
#   - the native libraries (libluajit, libkoreader-monolibtic, libsdcv,
#     libioctl, libkoreader-input),
#   - the native launcher (koreader-t65a) and its shell scripts.
#
# Requires: adb + root on the device, an Android SDK (build-tools + a
# platform android.jar), a JDK, and a Linux (WSL) host for the zip step.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$PROJECT/../../.." && pwd)"
ADB="${ADB:-adb}"
SDK="${ANDROID_SDK_ROOT:-/mnt/c/tools/android-sdk}"
BT="${BUILD_TOOLS:-$SDK/build-tools/35.0.0}"
ANDROID_JAR="$SDK/platforms/android-36/android.jar"
NDK="${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/23.2.8568313}"
PKG=com.nativeko

BUILD="$PROJECT/.build"
STAGE="$BUILD/stage"
UNSIGNED="$BUILD/unsigned.apk"
ALIGNED="$BUILD/aligned.apk"
APK="$PROJECT/NativeKO.apk"
KEYSTORE="$PROJECT/nativeko.keystore"
KS_PASS=nativeko

for tool in javac java python3 tar keytool wslpath; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -f "$ANDROID_JAR" ] || { echo "missing $ANDROID_JAR" >&2; exit 1; }
[ -f "$BT/lib/d8.jar" ] || { echo "missing $BT/lib/d8.jar" >&2; exit 1; }

echo "== building native launcher =="
( cd "$ROOT/platform/t65a" && ANDROID_NDK_HOME="$NDK" ./build-native.sh )

echo "== staging KOReader module from device =="
rm -rf "$BUILD"
mkdir -p "$STAGE" "$BUILD/classes" "$BUILD/dex"

$ADB shell "su -c '
  rm -rf /data/local/tmp/nativeko-stage /data/local/tmp/nativeko-stage.tar
  mkdir -p /data/local/tmp/nativeko-stage/ko /data/local/tmp/nativeko-stage/libs
  cp -a /data/data/org.koreader.launcher/files/. /data/local/tmp/nativeko-stage/ko/ 2>/dev/null
  rm -f /data/local/tmp/nativeko-stage/ko/libs
  LIBDIR=/data/app-lib/org.koreader.launcher-1
  [ -d \"\$LIBDIR\" ] || LIBDIR=/data/data/org.koreader.launcher/lib
  for f in libkoreader-monolibtic.so libluajit.so libsdcv.so libioctl.so; do
      [ -f \"\$LIBDIR/\$f\" ] && cp -a \"\$LIBDIR/\$f\" /data/local/tmp/nativeko-stage/libs/
  done
  cd /data/local/tmp/nativeko-stage && /system/bin/busybox tar cf /data/local/tmp/nativeko-stage.tar ko libs
  chmod 644 /data/local/tmp/nativeko-stage.tar
'"
$ADB pull /data/local/tmp/nativeko-stage.tar "$BUILD/stage.tar" >/dev/null
tar xf "$BUILD/stage.tar" -C "$STAGE"

echo "== stripping user data and staging native files =="
rm -rf "$STAGE/ko/cache" "$STAGE/ko/screenshots" "$STAGE/ko/clipboard" \
       "$STAGE/ko/settings" "$STAGE/ko/data/tessdata" "$STAGE/ko/data/dict"
rm -f "$STAGE/ko/settings.reader.lua" "$STAGE/ko/settings.reader.lua.old" \
      "$STAGE/ko/history.lua" "$STAGE/ko/defaults.custom.lua" \
      "$STAGE/ko/defaults.custom.lua.old" "$STAGE/ko/update_once.marker"
# NOTE: keep git-rev: reader.lua exits on startup if Version:getCurrentRevision() returns nil.
rm -rf "$STAGE/ko/libs"
mkdir -p "$STAGE/ko/libs"
mv "$STAGE/libs"/* "$STAGE/ko/libs/"
rmdir "$STAGE/libs"

# The Android monolibtic does not contain the Linux evdev input module; the
# native backend loads it as libs/libkoreader-input.so.  It must be built once
# with platform/t65a/build-input.sh (see that script's header for the LuaJIT
# headers/libluajit prerequisites).  Do not silently produce an APK without
# it: KOReader would exit at startup.
INPUT_LIB="$ROOT/platform/t65a/libkoreader-input.so"
if [ ! -f "$INPUT_LIB" ]; then
    echo "missing $INPUT_LIB" >&2
    echo "build it with platform/t65a/build-input.sh first" >&2
    exit 1
fi
cp -f "$INPUT_LIB" "$STAGE/ko/libs/libkoreader-input.so"
find "$STAGE/ko" -name "*.native-bak" -delete 2>/dev/null || true

# Overlay the repository's current T65A code (the pulled module already has
# most of it, but the repo is authoritative).
cp -f "$ROOT/frontend/device.lua" "$STAGE/ko/frontend/device.lua"
# KO_DATA_DIR support: settings/plugins/patches live on /sdcard/koreader.
cp -f "$ROOT/datastorage.lua" "$STAGE/ko/datastorage.lua"
# Drop a legacy per-device backend left in the pulled module by old dev
# deployments; the profile-driven backend is authoritative.
rm -rf "$STAGE/ko/frontend/device/t65a"
rm -rf "$STAGE/ko/frontend/device/native/suspend"
cp -f "$ROOT/frontend/device/native/device.lua" "$ROOT/frontend/device/native/powerd.lua" \
      "$STAGE/ko/frontend/device/native/"
cp -f "$ROOT/base/ffi/framebuffer_mxcfb.lua" "$ROOT/base/ffi/mxcfb_t65a_h.lua" "$STAGE/ko/ffi/"
mkdir -p "$STAGE/ko/common/lj-wpaclient"
cp -f "$ROOT/platform/native/common/lj-wpaclient/"*.lua "$STAGE/ko/common/lj-wpaclient/"

mkdir -p "$STAGE/native"
cp -f "$ROOT/platform/t65a/koreader-t65a" "$STAGE/native/"
for s in run-native.sh restore-android.sh; do
    cp -f "$ROOT/platform/t65a/$s" "$STAGE/native/"
done

# Generic session core, host/wifi drivers and the generated device profile.
mkdir -p "$STAGE/native/drivers/host" "$STAGE/native/drivers/wifi" \
         "$STAGE/native/drivers/pm" "$STAGE/native/profiles/t65a"
cp -f "$ROOT/platform/native/core/session.sh" "$STAGE/native/session.sh"
cp -f "$ROOT/platform/native/core/start-session.sh" "$STAGE/native/start-session.sh"
cp -f "$ROOT/platform/native/drivers/host/"*.sh "$STAGE/native/drivers/host/"
cp -f "$ROOT/platform/native/drivers/wifi/"*.sh "$STAGE/native/drivers/wifi/"
cp -f "$ROOT/platform/native/drivers/pm/"*.sh "$STAGE/native/drivers/pm/"
# Screensaver-only build: do not ship the hardware-suspend PM driver/acker.
rm -f "$STAGE/native/drivers/pm/android_early_suspend.sh" \
      "$STAGE/native/drivers/pm/fb_ack.sh"
python3 "$ROOT/platform/native/tools/profilegen.py" \
    "$ROOT/platform/native/profiles/t65a/profile.json" "$STAGE/native/profiles/t65a"

echo "== assembling assets =="
mkdir -p "$BUILD/assets"
# One deflated archive per tree: the APK stays compressed (Android-sized)
# while first-run extraction is a single streaming pass.
python3 "$PROJECT/tools/makezip.py" "$BUILD/assets/ko.zip" "$STAGE/ko"
python3 "$PROJECT/tools/makezip.py" "$BUILD/assets/native.zip" "$STAGE/native"

echo "== building APK =="
cd "$BUILD"
AAPT2="$BT/aapt2.exe"
if [ -x "$AAPT2" ]; then
    # Windows build-tools on WSL: pass Windows paths and run from a Windows
    # directory (a UNC CWD confuses some Windows tooling).
    MAN="$PROJECT/AndroidManifest.xml"
    OUT="$UNSIGNED"
    ( cd /mnt/c && "$AAPT2" link -o "$(wslpath -w "$OUT")" \
        -I "$(wslpath -w "$ANDROID_JAR")" \
        --manifest "$(wslpath -w "$MAN")" \
        --min-sdk-version 19 --target-sdk-version 19 )
else
    "$BT/aapt2" link -o "$UNSIGNED" -I "$ANDROID_JAR" \
        --manifest "$PROJECT/AndroidManifest.xml" \
        --min-sdk-version 19 --target-sdk-version 19
fi

javac --release 8 -classpath "$ANDROID_JAR" -d "$BUILD/classes" \
      "$PROJECT/src/com/nativeko/MainActivity.java"
java -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 --min-api 19 \
     --output "$BUILD/dex" "$BUILD"/classes/com/nativeko/*.class

python3 "$PROJECT/tools/zipadd.py" "$UNSIGNED" \
    "$BUILD/assets:assets" "$BUILD/dex/classes.dex:classes.dex"

if [ -x "$BT/zipalign.exe" ]; then
    ( cd /mnt/c && "$BT/zipalign.exe" -p 4 \
        "$(wslpath -w "$UNSIGNED")" "$(wslpath -w "$ALIGNED")" )
elif [ -x "$BT/zipalign" ]; then
    "$BT/zipalign" -p 4 "$UNSIGNED" "$ALIGNED"
else
    cp -f "$UNSIGNED" "$ALIGNED"
fi

if [ ! -f "$KEYSTORE" ]; then
    echo "== creating signing key =="
    keytool -genkeypair -keystore "$KEYSTORE" -alias nativeko \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass "$KS_PASS" -keypass "$KS_PASS" \
        -dname "CN=NativeKO, OU=NativeKO, O=NativeKO, L=NA, ST=NA, C=CN" >/dev/null
fi

java -jar "$BT/lib/apksigner.jar" sign \
    --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
    --min-sdk-version 19 --out "$APK" "$ALIGNED"

echo
echo "built: $APK"
ls -lh "$APK"
echo
echo "install:"
echo "  $ADB install -r '$APK'"
