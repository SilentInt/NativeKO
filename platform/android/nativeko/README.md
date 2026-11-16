# NativeKO

NativeKO is a self-contained Android APK that launches KOReader on the
Boyue Likebook T65A **without the Android framework**: it stops
`zygote`/`SurfaceFlinger` and runs KOReader directly on the i.MX6 EPDC
framebuffer and evdev input.

The APK contains everything it needs:

- the complete KOReader Lua module (from the installed
  `org.koreader.launcher` module, with user data stripped),
- the native libraries (`libluajit`, `libkoreader-monolibtic`, `libsdcv`,
  `libioctl`, `libkoreader-input`),
- `koreader-t65a`, the bionic LuaJIT launcher,
- the generic native session framework (`platform/native`),
- the generated T65A profile.

On first start (and whenever `ASSET_VERSION` changes), the assets are
extracted into the app's private data directory.  Every start then runs
`run-native.sh` as root via `su`.

## Current behaviour

NativeKO is a **screensaver-only** build.  It deliberately does not perform
hardware suspend:

- pressing the power key shows the KOReader screensaver;
- pressing the power key again closes it;
- touch taps do **not** close the screensaver;
- the frontlight is dimmed while the screensaver is shown and restored when
  the screensaver is closed with the power key;
- Wi-Fi is turned off while the screensaver is shown and, if it was on before,
  brought back when the screensaver is closed with the power key;
- Wi-Fi is not started automatically at session start
  (`network.start_on_boot = false`); use KOReader's network menu to turn it on
  or off;
- **Exit → Power off** is available in KOReader.  It runs `sync` and
  `/system/bin/reboot -p` as root (falling back to
  `setprop sys.powerctl shutdown`).

The session runs inside a wakelock/session lock-free configuration: there is
no `mem` request, no early-suspend acknowledgement thread, no RTC watchdog and
no session wake lock.  `power.model` is `none`.

## Build

Requirements:

- WSL/Linux host with `adb`, `python3`, `javac`, `java`, `tar`, `keytool`,
  `wslpath`;
- Android SDK at `$ANDROID_SDK_ROOT` (default
  `/mnt/c/tools/android-sdk`), build-tools with `aapt2`, `d8` and
  `apksigner`;
- Android NDK (`$ANDROID_NDK_HOME`, default
  `$HOME/Android/Sdk/ndk/23.2.8568313`);
- root adb access to the device;
- the original KOReader module installed as `org.koreader.launcher` on the
  device (the build pulls the module from there).

```sh
ADB=/mnt/c/tools/android-sdk/platform-tools/adb.exe \
  bash platform/android/nativeko/build.sh
```

The script:

1. builds `koreader-t65a` with `platform/t65a/build-native.sh`;
2. pulls `/data/data/org.koreader.launcher/files` from the device and strips
   cache/settings/user data;
3. overlays the authoritative repository files
   (`frontend/device.lua`, `frontend/device/native/*`, `common/lj-wpaclient`,
   `base/ffi/*`, `datastorage.lua`);
4. stages `platform/native/{core,drivers,profiles,tools}` and generates the
   profile;
5. removes suspend-only files from the staged trees;
6. creates `assets/ko.zip` and `assets/native.zip`;
7. links, dexes, aligns and signs `NativeKO.apk`.

APK assets are versioned with `ASSET_VERSION` in
`src/com/nativeko/MainActivity.java`.  Bump it whenever the packaged files
change so an installed app re-extracts them.

## Install / update

The package can be installed while the Android framework is stopped, using
root `pm`:

```sh
adb push NativeKO.apk /data/local/tmp/NativeKO.apk
adb shell su -c 'pm install -r /data/local/tmp/NativeKO.apk'
```

After an update with a new `ASSET_VERSION`, exit the running native session
and start NativeKO again.  The launcher re-extracts the assets and applies
the executable bits.

The build intentionally does **not** ship the suspend PM driver,
`fb_ack.sh`, or `frontend/device/native/suspend/*`.

## Runtime layout

Inside the app's private data directory:

```
files/
  .asset_version
  ko/                         KOReader module
    frontend/device/native/{device,powerd}.lua
    libs/                     native libraries
  native/
    session.sh                session orchestrator
    start-session.sh          detached launcher
    run-native.sh             compatibility wrapper -> session.sh
    restore-android.sh        wrapper -> session.sh restore
    koreader-t65a             native launcher
    drivers/host/             android_init, none
    drivers/pm/               none (the only PM model shipped)
    drivers/wifi/             wpa_supplicant_android
    profiles/t65a/            generated profile.env + profile.lua
    run.log                   launcher/KOReader stdout/stderr
    session.journal           present while a session owns the screen
```

User settings, plugins and patches live in `/sdcard/koreader`
(`KO_DATA_DIR`), not in the app data directory.

## Wi-Fi

The native `NetworkMgr` runs session actions from
`frontend/device/native/device.lua`:

```
sh <native>/session.sh --profile t65a wifi-up|wifi-down|wifi-dhcp|wifi-release
```

Two details matter on Android 4.4 / this device:

1. `session.sh` is invoked through `sh`, so it works even if the APK
   extraction did not preserve an executable bit.
2. `MainActivity` explicitly sets the executable bit on `session.sh` and
   `start-session.sh` after extraction.  Missing this bit caused
   `can't execute: Permission denied` and made every Wi-Fi toggle fail.

`network.start_on_boot = false` prevents the session core from calling
`wifi_up` before KOReader starts.  If `wifi_was_on`/`auto_restore_wifi` are
set in KOReader's settings, KOReader itself may still restore Wi-Fi on
startup; the current T65A settings have `wifi_was_on = false`.

`isWifiOn()` reads `init.svc.wpa_supplicant` (`network.service_prop`), so the
UI follows the real supplicant state.  `wifi-down` stops the supplicant,
stops dhcpcd and sets `wlan0` down; `wifi-up` restarts the supplicant and
renews DHCP.

## Screensaver and power

`Device:onPowerEvent()` is overridden in
`frontend/device/native/device.lua`:

- first power press: `Screensaver:setup()/show()`, force a repaint, turn
  Wi-Fi off, call `PowerD:beforeSuspend()` (frontlight dim);
- second power press: close the screensaver, restore the frontlight, and
  restore Wi-Fi if it was on before;
- `ScreenSaverWidget.onTap` is replaced with a no-op, so touch cannot dismiss
  the screensaver;
- no `rescheduleSuspend()` and no `Device:suspend()` hardware path.

`canSuspend = no`; `Device:suspend()` only logs that suspend is disabled.
`canPowerOff = yes`; `Device:powerOff()` is implemented as above.

## Troubleshooting

- **Wi-Fi turns on by itself**: check
  `native/profiles/t65a/profile.env` (`NET_START_ON_BOOT`) and KOReader's
  `wifi_was_on` / `auto_restore_wifi` settings.
- **Wi-Fi cannot be turned off**: inspect `native/run.log` for
  `session.sh: can't execute: Permission denied`; verify that
  `session.sh` is invoked via `sh` and that the APK set its executable bit.
- **No suspend**: intentional; `power.model = none`.  The old
  `android_early_suspend`/RTC watchdog experiments are not part of this build.
- **Logs**: `native/run.log` in the app data directory; `logcat` is not
  available once the framework is stopped.
- **App data extraction**: `.asset_version` records the last extracted
  `ASSET_VERSION`; delete the app data or bump the version to force a fresh
  extraction.

## References

- `platform/native/README.md` — profile/session/driver framework
- `platform/t65a/README.md` — T65A dev harness and native launcher
- AOSP `system/core/libsuspend` — the Android suspend enable/disable
  mechanism (not used by this screensaver-only build)
