# Native e-ink device framework

Generic, profile-driven orchestration for running KOReader natively on an
e-ink device (its own framebuffer/evdev, with the Android framework stopped).

For the self-contained NativeKO APK (build, install, screensaver/Wi-Fi
behaviour and troubleshooting), see
[`../android/nativeko/README.md`](../android/nativeko/README.md).

```
profiles/<id>/profile.json     single source of truth (hardware + host data)
        |
        v  tools/profilegen.py
profiles/<id>/{profile.env, profile.lua}
        |                            |
        v                            v
core/session.sh                  KOReader device/native/device.lua
  |  drivers/host/<backend>.sh     (profile-driven)
  |  drivers/wifi/<backend>.sh
  v
koreader-t65a (bionic LuaJIT launcher)
```

## Runtime layout (NativeKO APK / dev deploy)

```
native/
  session.sh                 core orchestrator
  start-session.sh           detached launcher (survives adb/terminal close)
  run-native.sh              compatibility wrapper -> session.sh
  restore-android.sh         wrapper -> session.sh restore
  drivers/host/*.sh          android_init, none (service manager)
  drivers/pm/*.sh            none (NativeKO ships only the no-op PM model)
  drivers/wifi/*.sh          wpa_supplicant_android
  profiles/<id>/profile.env  generated
  profiles/<id>/profile.lua  generated
  koreader-t65a              launcher
  session.journal            present while a session owns the screen
  original_governors         saved CPU governor per CPU
ko/                          KOReader module
  frontend/device/native/{device,powerd}.lua
  libs/                      libluajit, monolibcore, input, sdcv, ioctl
```

User data (settings, plugins, patches) lives outside the program tree, at
`paths.data_dir` (default `/sdcard/koreader`), through `KO_DATA_DIR`.

## Session lifecycle

`session.sh --profile <id> [start]`

1. Load `profile.env`, export `KO_HOME`, `KO_NATIVE_DIR`,
   `KO_NATIVE_PROFILE`, `KO_DATA_DIR`.
2. Source `drivers/host/<host.backend>.sh` and
   `drivers/wifi/<network.backend>.sh`.
3. Recover a stale `session.journal` (a previous session that skipped its trap).
4. `host_pre_start` (stop framework services), prepare the framebuffer,
   save + set the CPU governor, and bring Wi-Fi up **only if**
   `network.start_on_boot` is true (NativeKO sets it to false; Wi-Fi is then
   controlled from KOReader's network menu).
5. `exec koreader-t65a` from `KO_HOME`.
6. On exit (0/2/15): restore governor, Wi-Fi, framebuffer and host services;
   remove the journal.

Other actions: `wifi-up`, `wifi-down`, `wifi-dhcp` (lease + routes/DNS),
`wifi-release` (drop the lease only), `restore`. `--dry-run` prints the plan
without touching anything; `--no-stop` keeps the Android framework running.

## Profile fields

See `profiles/t65a/profile.json`. Main sections:

- `display`: framebuffer node/backend/rotation/portrait/dpi, pan and blank nodes.
  `backend` is currently `mxcfb` (i.MX6 EPDC via `ffi/framebuffer_mxcfb.lua`).
- `input`: evdev nodes, key map, quirks (`power_down_only`,
  `mt_a_touch_up`).
- `power`: battery sysfs, frontlight node/range and `model`.  NativeKO uses
  `model: "none"`: there is no session wake lock, no early-suspend acker, no
  RTC watchdog and no hardware suspend request.
- `network`: interface, supplicant control dir, init service and its
  `service_prop` (for status), DHCP command, optional in-kernel driver module,
  Android property integration, and `start_on_boot` (false for NativeKO).
- `host`: backend name, services to stop/start, governor policy.
- `tools`: paths for `ip`, `ping`, `setsid`, `getprop`, `busybox` (Android
  profiles point at `/system/bin/...`; desktop Linux profiles can omit them).
- `paths`: shared data dir and book home.

## Power model and screensaver

NativeKO's profile uses `power.model = "none"`.  The session requests no
hardware suspend: no session wake lock, no `wait_for_fb_sleep`/`wake` acker,
no RTC watchdog and no `mem` write to `/sys/power/state`.

The power key is handled entirely in
`frontend/device/native/device.lua`:

- show the KOReader screensaver, force a repaint, turn Wi-Fi off and dim the
  frontlight;
- on the next power press, close the screensaver, restore the frontlight and
  restore Wi-Fi if it was on before;
- touch taps do not close the screensaver (`ScreenSaverWidget.onTap` is
  replaced with a no-op);
- `canSuspend = no`; `Device:suspend()` only logs that suspend is disabled;
- `canPowerOff = yes`; `Device:powerOff()` runs `sync` then
  `/system/bin/reboot -p`, with `setprop sys.powerctl shutdown` as fallback.

Historical PM models (`drivers/pm/android_early_suspend.sh` and the
corresponding `frontend/device/native/suspend/*.lua`) live in the parent
KOReader `native-t65a` branch, not in this subproject.  This repository ships
only `none`, and the T65A profile does not select a suspend model.

## Wi-Fi

`session.sh --profile <id> wifi-up|wifi-down|wifi-dhcp|wifi-release` is
invoked from KOReader through `sh`, not by relying on the executable bit:

```
sh <native>/session.sh --profile t65a wifi-down
```

This matters for the APK: `session.sh` is extracted from an asset zip and its
mode may otherwise be non-executable.  `MainActivity` also explicitly sets
the executable bit on `session.sh` and `start-session.sh` after extraction.
The Android network menu uses `init.svc.wpa_supplicant` as the source of
truth (`network.service_prop`), so enabling/disabling Wi-Fi updates the UI
correctly.

## Adding a device

1. Copy `profiles/t65a/profile.json`, adjust the hardware/host fields.
2. If the display SoC is not i.MX6, add a display backend (or extend
   `ffi/framebuffer_mxcfb.lua`) and select it with `display.backend`.
3. If the host is not Android init, add `drivers/host/<name>.sh` implementing
   `host_pre_start`/`host_post_exit`.  The Android backend only stops/starts
   init services; suspend mechanics belong to a PM driver.
4. If the Wi-Fi stack differs, add `drivers/wifi/<name>.sh` implementing
   `wifi_up`/`wifi_down`/`wifi_dhcp`/`wifi_release`.
5. If the power model differs, add `drivers/pm/<name>.sh` and
   `frontend/device/native/suspend/<name>.lua` and set `power.model`.
   NativeKO does not use this hook (`model: "none"`).
6. `python3 tools/profilegen.py profiles/<id>/profile.json <out>` and run
   `session.sh --profile <id> --dry-run` on the device.

## Testing

```sh
# Host side: generated profile syntax
python3 platform/native/tools/profilegen.py \
    platform/native/profiles/t65a/profile.json /tmp/profile-out

# Device side (dev deploy)
NATIVE=/data/local/tmp/t65a-native
adb shell su -c "sh $NATIVE/session.sh --profile t65a --dry-run"
# Start detached (safe to unplug USB / close the terminal afterwards)
adb shell su -c "sh $NATIVE/start-session.sh t65a"

# NativeKO APK layout (app private data)
APP=/data/data/com.nativeko/files/native
adb shell su -c "sh $APP/session.sh --profile t65a --dry-run"
# Launcher/KOReader output: $APP/run.log
```

The KOReader log (`device/native: profile <id>`) confirms that the
profile-driven backend was selected; `native/run.log` contains the full
launcher output when started through the APK.

When calling session actions from KOReader or a script, prefer
`sh <session.sh>`; the APK asset extraction does not guarantee an executable
bit, and a direct invocation then fails with
`can't execute: Permission denied`.
