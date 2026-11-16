# T65A native build (development harness)

The generic orchestration lives in `platform/native/`:

- `profiles/<id>/profile.json` — device data, single source of truth
- `core/session.sh`, `core/start-session.sh` — lifecycle + detached launch
- `drivers/host/*.sh` — Android init service backend (or `none`)
- `drivers/pm/*.sh` — session-side power model (this subproject ships only
  `none`; suspend drivers live in the parent branch)
- `drivers/wifi/*.sh` — Wi-Fi backend
- `common/lj-wpaclient/` — shared pure-Lua wpa_supplicant client
- `frontend/device/native/` (in the KOReader tree) — profile-driven device
  backend (optional suspend drivers live in the parent branch)

This directory only holds the T65A-specific dev harness:

- `main.c`, `build-native.sh` — bionic LuaJIT launcher (`koreader-t65a`)
- `build-input.sh` — Linux evdev input module for the monolibtic build
- `run-native.sh`, `restore-android.sh` — compatibility wrappers around
  `core/session.sh`
- `deploy-dev.sh` — builds and deploys the framework + generated profile to an
  already-installed KOReader module for adb-based development

Architecture, profile fields and how to add another device are documented in
[`platform/native/README.md`](../native/README.md).  The self-contained APK
(build, install, screensaver-only behaviour, Wi-Fi control and
troubleshooting) is documented in
[`platform/android/nativeko/README.md`](../android/nativeko/README.md).

## Deploy and run

```sh
ADB=/path/to/adb ./deploy-dev.sh
adb shell su -c 'sh /data/local/tmp/t65a-native/start-session.sh t65a'
```

`start-session.sh` detaches the session (`setsid`, no controlling tty), so
unplugging USB or closing the adb shell does not kill KOReader.
