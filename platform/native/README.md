# Native e-ink device framework

Generic, profile-driven orchestration for running KOReader natively on an
e-ink device (its own framebuffer/evdev, with the Android framework stopped).

For the self-contained NativeKO APK (build, install, screensaver/Wi-Fi
behaviour and troubleshooting), see
[`../android/nativeko/README.md`](../android/nativeko/README.md).

To port the framework to another device, see
[`PORTING.md`](PORTING.md) (Chinese).

This directory is the **generic framework**.  The NoteS/NoteSL profile
(`profiles/notesl`, Onyx EBC) and the T65A profile (`profiles/t65a`, i.MX6
mxcfb) are the reference examples, together with the Android host/Wi-Fi
drivers and the APK packaging in `platform/android/nativeko`.  Porting to
another device normally means replacing the profile and, if needed, the
display backend / host driver / Wi-Fi driver.


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
koreader-native (bionic LuaJIT launcher)
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
  koreader-native              launcher
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
5. `exec koreader-native` from `KO_HOME`.
6. On exit (0/2/15): restore governor, Wi-Fi, framebuffer and host services;
   remove the journal.

Other actions: `wifi-up`, `wifi-down`, `wifi-dhcp` (lease + routes/DNS),
`wifi-release` (drop the lease only), `restore`. `--dry-run` prints the plan
without touching anything; `--no-stop` keeps the Android framework running.

## Profile fields

Reference profiles: `profiles/notesl/profile.json` (Onyx NoteS / 超星
NoteSL, Rockchip EBC direct buffer) and `profiles/t65a/profile.json` (Likebook
T65A, i.MX6 mxcfb).  Main sections:

- `display`: framebuffer node/backend/rotation/portrait/dpi, pan and blank
  nodes.  `backend` selects the display module:
  `mxcfb` (i.MX6 EPDC, `ffi/framebuffer_mxcfb.lua`),
  `rk_ebc` (Rockchip EBC direct `/dev/ebc` buffer,
  `ffi/framebuffer_rk_ebc.lua`; `onyx_ebc` is a compatibility alias), or
  `linux`/`fbdev` (`ffi/framebuffer_linux.lua`).  RK EBC profiles also set
  `ebc_device`, `ebc_width`, `ebc_height`, `ebc_bpp`, `ebc_stride`,
  `ebc_rect_order` and the refresh/waveform fields; see
  [`RK_EBC.md`](RK_EBC.md).
- `input`: evdev nodes, key map, quirks (`power_down_only`,
  `mt_a_touch_up`, `touch_swap_xy`, `touch_invert_x`, `touch_invert_y`) and
  optional `touch_max_x`/`touch_max_y` for raw-axis inversion.
- `power`: battery sysfs, frontlight node/range and the suspend model.
  `model: "android_wakeup_count"` selects the wakelock/`mem` driver;
  `none` is screensaver-only.  The driver also reads `suspend_state`,
  `suspend_fallback`, `suspend_wait_timeout`, `suspend_unbind`,
  `wake_lock_name`, `wake_unlock` and `rtc_alarm` (stale alarms are cleared).
- `network`: interface, supplicant control dir and optional full
  `ctrl_interface` path, global-socket flags (`wpa_global`/`wpa_ifname`), init
  service and its `service_prop` (for status), DHCP command, optional
  in-kernel driver module, Android property integration, and `start_on_boot`
  (false for NativeKO).
- `host`: backend name, services to stop/start, governor policy.
- `tools`: paths for `ip`, `ping`, `setsid`, `getprop`, `busybox` (Android
  profiles point at `/system/bin/...`; desktop Linux profiles can omit them).
  `busybox` may point at toybox on ROMs without BusyBox; `session.sh` also
  falls back to `/system/bin/toybox` when the field is empty.
- `paths`: shared data dir and book home.

## Rockchip EBC direct display

Some RK e-ink devices scan out a buffer exposed by `/dev/ebc` rather than
`/dev/fb0`.  `backend: "rk_ebc"` maps that buffer directly, so KOReader fully
owns the panel and no SurfaceFlinger/hwcomposer is involved.  The backend
supports 32/16/8/4 bpp, configurable stride/offset, rect order, waveform and
update modes.

The reference device (NoteS/NoteSL, RK3288, 1200x825) uses **32bpp, stride
4800**, `SEND_BUFFER` + `SEND_UPDATE`, and a 90-degree buffer→panel rotation
(`portrait: true`, `ebc_rotate: 0`).  Its touch controller reports raw axes
transposed and X mirrored, so the profile uses `touch_rotation: 0` with
`touch_swap_xy` + `touch_invert_x`.  A 4bpp buffer only covers a narrow strip
on that panel.

Probe a new model with:

```
# zero-build read-only environment dump
adb push tools/rk-ebc-env.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/rk-ebc-env.sh'

# ioctl/buffer/refresh probe
bash tools/build-rk-ebc-probe.sh
adb push tools/rk-ebc-probe /data/local/tmp/
adb shell su -c '/data/local/tmp/rk-ebc-probe info'
# stop framework, then calibrate:
adb shell su -c '/data/local/tmp/rk-ebc-probe pattern 32 4800 stripes'
adb shell su -c '/data/local/tmp/rk-ebc-probe pattern 32 4800 corner 0'
```

See [`RK_EBC.md`](RK_EBC.md) for hardware details, the ioctl/struct reference,
bpp/stride/rotation calibration, troubleshooting and a porting checklist.

## Power model and suspend

The `power.model` profile field selects the session-side PM driver
(`drivers/pm/<model>.sh`) and the Lua suspend driver
(`frontend/device/native/suspend/<model>.lua`).  `none` keeps the
screensaver-only behaviour.

The shipped NoteSL profile uses `model: "android_wakeup_count"` — Android 6's
wakelock/wakeup_count model on this RK3288 kernel (no legacy
`wait_for_fb_*`/earlysuspend):

- the session takes a `nativeko-<pid>` wake lock while KOReader owns the
  screen; `pm_start` / `pm_stop` release stale framework/session locks;
- the power key shows the screensaver, force-repaints, turns Wi-Fi off and
  dims the frontlight, then (after `suspend_wait_timeout`) the suspend driver
  stops Wi-Fi, clears stale RTC alarms, releases non-session lock and writes
  `mem` to `/sys/power/state`;
- the state write blocks until wakeup; on wake the driver re-binds any
  `suspend_unbind` devices (e.g. NoteSL's unused mmc1 SD controller, whose
  resume timeouts otherwise cost ~10s), re-takes the session lock and the UI
  closes the screensaver with a full repaint;
- `canSuspend = yes` when the profile selects a suspend model; the resume
  busy-state ignores further power keys until the repaint completes, so rapid
  presses do not queue additional suspends;
- `canPowerOff = yes`; `Device:powerOff()` runs `sync` then
  `/system/bin/reboot -p`, with `setprop sys.powerctl shutdown` as fallback.

The T65A profile keeps `power.model = "none"`.  The legacy
`android_early_suspend`/`fb_ack` files remain for reference but are not
shipped in the APK; `linux_mem` is the plain Linux model.

## Wi-Fi

`session.sh --profile <id> wifi-up|wifi-down|wifi-dhcp|wifi-release` is
invoked from KOReader through `sh`, not by relying on the executable bit:

```
sh <native>/session.sh --profile notesl wifi-down
```

This matters for the APK: `session.sh` is extracted from an asset zip and its
mode may otherwise be non-executable.  `MainActivity` also explicitly sets
the executable bit on `session.sh` and `start-session.sh` after extraction.
The Android network menu uses `init.svc.wpa_supplicant` as the source of
truth (`network.service_prop`), so enabling/disabling Wi-Fi updates the UI
correctly.

Some Android 6 ROMs expose **only a global supplicant socket** from init
(`-g@android:wpa_wlan0`, path `/dev/socket/wpa_wlan0`) and no per-interface
`<ctrl_dir>/<iface>` socket.  Such profiles set:

```
"ctrl_dir": "/dev/socket",
"ctrl_interface": "/dev/socket/wpa_wlan0",
"wpa_global": true,
"wpa_ifname": "wlan0"
```

The native backend then sets `WpaClient.ifname`, and every
interface-specific control command is prefixed with `IFNAME=wlan0 `.

The ROM's dhcpcd may not set the `dhcp.<iface>.{gateway,dns1}` properties
(the hook scripts can fail under a mismatched system/kernel).  The Wi-Fi
driver therefore falls back to deriving the gateway from the interface
address's `.1` (then the ARP table) and uses it for the default route and
`net.dns1`.  Internet IP connectivity works in that mode; **hostname
resolution requires netd/framework DNS configuration**, which is outside the
framework-off session.  Do not rely on `ndc` from the session.

## Adding a device

1. Copy `profiles/notesl/profile.json` (or `profiles/t65a/profile.json`),
   adjust the hardware/host fields.
2. If the display controller is not Rockchip EBC or i.MX6 mxcfb, add a display
   backend (or extend `ffi/framebuffer_linux.lua`) and select it with
   `display.backend`.  For RK EBC direct-buffer devices, use
   `backend: "rk_ebc"` and calibrate with
   [`tools/rk-ebc-probe.c`](tools/rk-ebc-probe.c); the full procedure and
   hardware notes are in [`RK_EBC.md`](RK_EBC.md).
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
    platform/native/profiles/notesl/profile.json /tmp/profile-out

# Device side (dev deploy)
NATIVE=/data/local/tmp/nativeko
adb shell su -c "sh $NATIVE/session.sh --profile notesl --dry-run"
# Start detached (safe to unplug USB / close the terminal afterwards)
adb shell su -c "sh $NATIVE/start-session.sh notesl"

# NativeKO APK layout (app private data)
APP=/data/data/com.nativeko/files/native
adb shell su -c "sh $APP/session.sh --profile notesl --dry-run"
# Launcher/KOReader output: $APP/run.log
```

The KOReader log (`device/native: profile <id>`) confirms that the
profile-driven backend was selected; `native/run.log` contains the full
launcher output when started through the APK.

When calling session actions from KOReader or a script, prefer
`sh <session.sh>`; the APK asset extraction does not guarantee an executable
bit, and a direct invocation then fails with
`can't execute: Permission denied`.
