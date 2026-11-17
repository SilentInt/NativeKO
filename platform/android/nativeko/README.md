# NativeKO

NativeKO is a self-contained Android APK that launches KOReader natively
**without the Android framework**: it stops `zygote`/`SurfaceFlinger` and
runs KOReader directly on the device's e-ink framebuffer and evdev input.

The reference profiles are **博阅 Likebook Alita (K103)** (RK3368,
1872×1404 direct `/dev/ebc`, 8bpp + 5-bit grayscale, dual frontlight,
hardware suspend, native Wi-Fi/DNS) and **Onyx NoteS / 超星 NoteSL**
(RK3288, 1200×825 EBC).  The build selects one with `PROFILE_ID` (`alita`,
`notesl`, `t65a`); K103 and NoteSL are different machines.  RK EBC ports use
the `rk_ebc` display backend and the probe / calibration procedure in
`platform/native/RK_EBC.md`; the full K103 adaptation log is in
`platform/native/K103_ALITA.md`.

The APK contains everything it needs:

- the complete KOReader Lua module (from the installed
  `org.koreader.launcher` module, with user data stripped),
- the native libraries (`libluajit`, `libkoreader-monolibtic`, `libsdcv`,
  `libioctl`, `libkoreader-input`),
- `koreader-native`, the bionic LuaJIT launcher,
- the generic native session framework (`platform/native`),
- the generated device profile (`native/profiles/<id>` + `profile.id`).

On first start (and whenever `ASSET_VERSION` changes), the assets are
extracted into the app's private data directory.  Every start then runs
`run-native.sh` as root via `su`.

## Current behaviour

The K103/Alita profile (`alita`) drives `/dev/ebc` with the vendor POST path
(8bpp, 5-bit codes, original gamma LUT), maps KOReader refresh types to
EPD_FULL/REGLA/FORCE_FULL/FAST/A2, exposes dual cold/warm frontlight, and uses
Android 8 `mem` suspend.  Wi-Fi uses the ROM's `wpa_supplicant` service plus
Magisk busybox `udhcpc`; an `LD_PRELOAD` resolver shim provides DNS while the
framework (and netd's DNS proxy) is stopped.  See
[`../native/K103_ALITA.md`](../native/K103_ALITA.md) for the full record.

The shipped NoteSL profile performs real hardware suspend through
`power.model = "android_wakeup_count"` (Android 6 wakelock/wakeup_count):

- pressing the power key shows the KOReader screensaver and, after a short
  delay, stops Wi-Fi and writes `mem` to `/sys/power/state`;
- pressing the power key again wakes the device and closes the screensaver;
  the resume path restores Wi-Fi if it was on before and forces a full repaint;
- touch taps do **not** close the screensaver;
- the frontlight is dimmed while the screensaver/suspend is active and restored
  on wake (when the profile has a frontlight node);
- Wi-Fi is not started automatically at session start
  (`network.start_on_boot = false`); use KOReader's network menu to turn it on
  or off;
- **Exit → Power off** is available in KOReader.  It runs `sync` and
  `/system/bin/reboot -p` as root (falling back to
  `setprop sys.powerctl shutdown`).

The session holds a `nativeko-<pid>` wake lock, releases stale framework
locks, and releases the session lock only for the `mem` transition.  Rapid
power presses during a suspend/resume are ignored until the transition and
its repaint have completed.  NoteSL's unused mmc1 SD controller is unbound for
suspend and rebound on resume; otherwise its resume timeouts add ~10 seconds.
Profiles that keep `power.model = "none"` (e.g. T65A) remain
screensaver-only.

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
  PROFILE_ID=alita bash platform/android/nativeko/build.sh
```

`PROFILE_ID` defaults to `notesl`; K103/Alita uses `alita`, T65A uses `t65a`.
The launcher icon is line-art **NKO** (`platform/android/nativeko/res/mipmap-*`).

The script:

1. builds `koreader-native` with `platform/native-harness/build-native.sh`;
2. pulls `/data/data/org.koreader.launcher/files` from the device and strips
   cache/settings/user data;
3. overlays the authoritative repository files
   (`frontend/device.lua`, `frontend/device/native/*`, `common/lj-wpaclient`,
   `base/ffi/*`, `datastorage.lua`);
4. stages `platform/native/{core,drivers,profiles,tools}` and generates the
   selected profile, plus `native/profile.id` for `MainActivity`;
5. removes the legacy early-suspend acker from the staged trees
   (`android_wakeup_count` and the Lua suspend driver are shipped);
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

The build ships `drivers/pm/android_wakeup_count.sh` and
`frontend/device/native/suspend/android_wakeup_count.lua`.  The legacy
`android_early_suspend`/`fb_ack` files are not shipped.

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
    koreader-native             native launcher
    drivers/host/             android_init, none
    drivers/pm/               android_wakeup_count, none
    drivers/wifi/             wpa_supplicant_android
    profiles/<id>/            generated profile.env + profile.lua
    profile.id                selected profile id (read by MainActivity)
    detach                    double-fork session detacher
    run.log                   launcher/KOReader stdout/stderr
    session.journal           present while a session owns the screen
```

User settings, plugins and patches live in `/sdcard/koreader`
(`KO_DATA_DIR`), not in the app data directory.

## Wi-Fi

The native `NetworkMgr` runs session actions from
`frontend/device/native/device.lua`:

```
sh <native>/session.sh --profile notesl wifi-up|wifi-down|wifi-dhcp|wifi-release
```

Two details matter on Android 4.4 / Android 6 ROMs:

1. `session.sh` is invoked through `sh`, so it works even if the APK
   extraction did not preserve an executable bit.
2. `MainActivity` explicitly sets the executable bit on `session.sh` and
   `start-session.sh` after extraction.  Missing this bit caused
   `can't execute: Permission denied` and made every Wi-Fi toggle fail.

`network.start_on_boot = false` prevents the session core from calling
`wifi_up` before KOReader starts.  If `wifi_was_on`/`auto_restore_wifi` are
set in KOReader's settings, KOReader itself may still restore Wi-Fi on
startup; the shipped NoteSL profile has `wifi_was_on = false`.

`isWifiOn()` reads `init.svc.wpa_supplicant` (`network.service_prop`), so the
UI follows the real supplicant state.  `wifi-down` stops the supplicant,
stops dhcpcd and sets `wlan0` down; `wifi-up` restarts the supplicant and
renews DHCP.

## Screensaver and power

`Device:onPowerEvent()` is overridden in
`frontend/device/native/device.lua`:

- first power press: `Screensaver:setup()/show()`, force a repaint, turn
  Wi-Fi off, call `PowerD:beforeSuspend()` (frontlight dim), then schedule
  `Device:suspend()` after `suspend_wait_timeout`;
- `Device:suspend()` (profile PM driver) stops Wi-Fi, clears stale RTC
  alarms, unbinds `suspend_unbind` devices, drops the session wake lock and
  writes `mem`; the write returns on wake;
- on wake the driver rebinds devices and re-takes the session lock; the power
  key that woke the device closes the screensaver, restores the frontlight and
  Wi-Fi, and forces a full repaint;
- `ScreenSaverWidget.onTap` is replaced with a no-op, so touch cannot dismiss
  the screensaver;
- while `_suspend_in_progress` / `_resume_in_progress` is set, new Power /
  Suspend events are ignored; the busy state clears after the resume repaint,
  so rapid presses cannot queue a second suspend.

`canSuspend = yes` when the profile selects a suspend model.
`canPowerOff = yes`; `Device:powerOff()` is implemented as above.

## Troubleshooting

- **Wi-Fi turns on by itself**: check
  `native/profiles/notesl/profile.env` (`NET_START_ON_BOOT`) and KOReader's
  `wifi_was_on` / `auto_restore_wifi` settings.
- **Wi-Fi cannot be turned off**: inspect `native/run.log` for
  `session.sh: can't execute: Permission denied`; verify that
  `session.sh` is invoked via `sh` and that the APK set its executable bit.
- **Suspend seems stuck / slow resume**: check `native/suspend.log` and
  `dmesg` for `PM: suspend entry/exit`.  NoteSL needs
  `suspend_unbind: ["dwmmc_rockchip:ff0d0000.rksdmmc"]`; without it the
  unused SD controller adds ~10 seconds of mmc resume timeouts.  The legacy
  `android_early_suspend`/`fb_ack` model is not used on this kernel.
- **Rapid power presses**: ignored while a suspend/resume transition and its
  repaint are in progress; wait for the screen to settle.
- **Logs**: `native/run.log` in the app data directory; `logcat` is not
  available once the framework is stopped.
- **App data extraction**: `.asset_version` records the last extracted
  `ASSET_VERSION`; delete the app data or bump the version to force a fresh
  extraction.

## References

- `platform/native/README.md` — profile/session/driver framework
- `platform/native/RK_EBC.md` — Rockchip EBC direct-buffer porting, probe and
  calibration guide
- `platform/native-harness/README.md` — dev harness and native launcher
- AOSP `system/core/libsuspend` — the Android wakelock/wakeup_count/`mem`
  suspend model used by `android_wakeup_count`
