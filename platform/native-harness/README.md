# Native KOReader harness (development)

The generic orchestration lives in `platform/native/`:

- `profiles/<id>/profile.json` — device data, single source of truth
  (`t65a` and `notesl` are the reference profiles)
- `core/session.sh`, `core/start-session.sh` — lifecycle + detached launch
- `drivers/host/*.sh` — Android init service backend (or `none`)
- `drivers/pm/*.sh` — session-side power model (`notesl` ships
  `android_wakeup_count`; profiles with `model = "none"` stay
  screensaver-only)
- `drivers/wifi/*.sh` — Wi-Fi backend
- `common/lj-wpaclient/` — shared pure-Lua wpa_supplicant client
- `tools/rk-ebc-probe.c`, `tools/build-rk-ebc-probe.sh` — Rockchip EBC
  buffer/refresh probe and calibration tool
- `RK_EBC.md` — Rockchip EBC direct-buffer porting guide
- `frontend/device/native/` (in the KOReader tree) — profile-driven device
  backend and suspend drivers

This directory only holds the device-independent dev harness:

- `main.c`, `build-native.sh` — bionic LuaJIT launcher (`koreader-native`)
- `detach.c` — double-fork/setsid helper so a session survives adb/USB teardown
- `build-input.sh` — Linux evdev input module for the monolibtic build
- `run-native.sh`, `restore-android.sh` — compatibility wrappers around
  `core/session.sh`
- `deploy-dev.sh` — builds and deploys the framework + generated profile to an
  already-installed KOReader module for adb-based development

`koreader-native` is a historical name in the scripts only in the sense that
it was originally built for the Likebook T65A; the binary is device-neutral
and works on any armv7a Android e-ink device with the same LuaJIT ABI.

Architecture, profile fields and how to add another device are documented in
[`platform/native/README.md`](../native/README.md).  The self-contained APK
(build, install, hardware suspend/screensaver, Wi-Fi control and
troubleshooting) is documented in
[`platform/android/nativeko/README.md`](../android/nativeko/README.md).

## Deploy and run

```sh
ADB=/path/to/adb ./deploy-dev.sh              # profile: notesl
PROFILE_ID=t65a ADB=/path/to/adb ./deploy-dev.sh

adb shell su -c 'sh /data/local/tmp/nativeko/start-session.sh notesl'
```

`start-session.sh` detaches the session with the bundled `detach` helper
(double fork + `setsid`, no controlling tty), so unplugging USB or closing
the adb shell does not kill KOReader.  If `detach` is missing it falls back
to `setsid ... &`, which some toybox builds do not keep alive across an adb
shell exit.
