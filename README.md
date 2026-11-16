# NativeKO

Source tree for **NativeKO**, a self-contained Android launcher that runs
KOReader natively on the Boyue Likebook T65A: it stops
`zygote`/`SurfaceFlinger` and drives the i.MX6 EPDC framebuffer and evdev
input directly.

This repository is the NativeKO subproject extracted from the KOReader
`native-t65a` branch.  It contains only the files needed to build and run the
APK; the full KOReader tree, submodules and suspend experiments remain in the
parent branch.

## Current behaviour

- Screensaver-only: the power key shows/closes the KOReader screensaver.
  There is **no hardware suspend**, wake lock, early-suspend acknowledgement
  or RTC watchdog (`power.model = none`).
- Touch taps do not close the screensaver.
- The frontlight is dimmed while the screensaver is shown and restored when
  the power key closes it.
- Wi-Fi is off during the screensaver and restored on power-key resume if it
  was on.  Wi-Fi is not started automatically at session start
  (`network.start_on_boot = false`); use KOReader's network menu.
- KOReader's **Exit → Power off** runs `sync` then
  `/system/bin/reboot -p` as root (fallback: `setprop sys.powerctl shutdown`).

## Layout

```
platform/android/nativeko/   APK build, Java launcher, asset zips
platform/native/             generic profile/session/driver framework
platform/t65a/               bionic launcher and T65A dev harness
frontend/device.lua          KOReader device probe
frontend/device/native/      profile-driven KOReader device backend
base/ffi/                    i.MX6 EPDC fb overlays
base/input/                  Linux evdev input module source
datastorage.lua              KO_DATA_DIR (/sdcard/koreader) support
COPYING                      AGPL-3.0
```

The APK build expects this exact layout: `build.sh` computes the repository
root and overlays these files into a KOReader module pulled from the device.

## Build

Requirements:

- WSL/Linux host with `adb`, `python3`, `javac`, `java`, `tar`, `keytool`,
  `wslpath`;
- Android SDK (`$ANDROID_SDK_ROOT`, default `/mnt/c/tools/android-sdk`) with
  `aapt2`, `d8`, `apksigner`;
- Android NDK (`$ANDROID_NDK_HOME`, default
  `$HOME/Android/Sdk/ndk/23.2.8568313`);
- root adb access to the device;
- the original KOReader module installed as **org.koreader.launcher** on the
  device (the build pulls the Lua module from it).

```sh
ADB=/mnt/c/tools/android-sdk/platform-tools/adb.exe \
  bash platform/android/nativeko/build.sh
```

The Android monolibtic does not include KOReader's Linux evdev input module;
`platform/t65a/libkoreader-input.so` is built once with
`platform/t65a/build-input.sh` and included in `ko/libs/`.  The build stops
with an error if it is missing.

The output is `platform/android/nativeko/NativeKO.apk` (ignored by git).
Bump `ASSET_VERSION` in
`platform/android/nativeko/src/com/nativeko/MainActivity.java` whenever the
embedded assets change, then install:

```sh
adb push NativeKO.apk /data/local/tmp/NativeKO.apk
adb shell su -c 'pm install -r /data/local/tmp/NativeKO.apk'
```

Exit a running native session and start NativeKO again after an update so the
new assets are extracted.  See
[`platform/android/nativeko/README.md`](platform/android/nativeko/README.md)
for runtime layout, Wi-Fi/session details and troubleshooting, and
[`platform/native/PORTING.md`](platform/native/PORTING.md) for porting to
another device.

## Development

The device-specific dev harness is in `platform/t65a/`.  The generic
profile/session/driver framework is documented in
[`platform/native/README.md`](platform/native/README.md).  The T65A device
profile is `platform/native/profiles/t65a/profile.json`.

The APK build intentionally does not ship `frontend/device/native/suspend/*`
or the suspend PM driver/acker; this subproject is screensaver-only.  The
full suspend experiments can be found in the parent KOReader `native-t65a`
branch.

## License

KOReader is licensed under the GNU Affero General Public License v3.0; see
[`COPYING`](COPYING).
