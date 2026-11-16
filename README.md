# NativeKO

**一个“原生 KOReader 移植框架 + 参考机型实现”的项目。**

NativeKO 不是给某一台设备写死的 App：核心是一套 profile/driver 驱动的移植
框架，`platform/native/profiles/` 里的每个 profile 描述一台设备。当前带两个
参考实现：

- **Onyx NoteS / 超星 NoteSL**（默认，直接控制 Rockchip EBC，实现硬件
  suspend）；
- **Likebook T65A**（i.MX6 EPDC，screensaver-only 示例）。

你可以保留框架，替换 profile 和少量平台驱动，把它移植到其他电子墨水设备；
具体步骤见 [`platform/native/PORTING.md`](platform/native/PORTING.md)，
Rockchip EBC 设备另见 [`platform/native/RK_EBC.md`](platform/native/RK_EBC.md)。

English one-liner: a profile/driver-based porting framework for running
KOReader natively on e-ink devices, shipping an Onyx NoteS/NoteSL reference
(direct Rockchip EBC + hardware suspend) and a Likebook T65A example.

---

## 1. 项目架构

```
┌─────────────────────────────────────────────────────────────┐
│ NativeKO APK（示例打包层，platform/android/nativeko）        │
│  - MainActivity: 解压 assets、su 启动、chmod 脚本             │
│  - assets/ko.zip: KOReader 模块 + 输入模块 + 原生库           │
│  - assets/native.zip: session/drivers/profile/launcher       │
└───────────────────────────┬─────────────────────────────────┘
                            │ detach + su
┌───────────────────────────▼─────────────────────────────────┐
│ 通用移植框架（platform/native）                              │
│  - core/session.sh: 会话生命周期、停止/恢复 framework         │
│  - drivers/host:    Android init / none 等服务管理            │
│  - drivers/wifi:    wpa_supplicant/Android 等 Wi-Fi 后端      │
│  - drivers/pm:      android_wakeup_count / none 等电源模型    │
│  - profiles/<id>:   设备数据（唯一事实来源）                  │
│  - tools/profilegen.py: JSON -> profile.env + profile.lua    │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│ KOReader 侧设备后端（frontend/device/native）                 │
│  - device.lua: profile -> 屏幕/输入/电源/网络/屏保             │
│  - powerd.lua: 电池/前光                                      │
│  - suspend/*:  suspend 驱动（NoteSL 用 android_wakeup_count） │
│  - base/ffi/framebuffer_*: 显示后端（mxcfb / rk_ebc / linux） │
│  - base/input/input.c -> libkoreader-input.so                │
└─────────────────────────────────────────────────────────────┘
```

### 框架部分（可复用）

- `platform/native/core/`：会话编排和 detached 启动；
- `platform/native/drivers/`：host / Wi-Fi / PM 驱动接口；
- `platform/native/profiles/`：profile 规范与生成器；
- `platform/native/tools/`：`profilegen.py`、Rockchip EBC 探针；
- `frontend/device/native/`：profile 驱动的 KOReader 设备后端；
- `base/ffi/framebuffer_mxcfb.lua` / `framebuffer_rk_ebc.lua` 等显示后端；
- `platform/native-harness/`：bionic LuaJIT launcher、`detach` 和输入模块；
- `platform/android/nativeko/`：自包含 APK 打包层。

### 参考实现

- **NoteSL**：`platform/native/profiles/notesl/profile.json`，Rockchip EBC
  直显（`/dev/ebc`，1200×825，32bpp）、触摸交换/镜像 quirk、
  `android_wakeup_count` 硬件 suspend、mmc1 unbind；
- **T65A**：`platform/native/profiles/t65a/profile.json`，i.MX6 EPDC，
  `power.model = "none"`，screensaver-only。

换机型时通常只改 profile；如果显示控制器、host、Wi-Fi 栈或电源模型不同，
再加对应的 driver 或显示后端。**不需要重写整个 KOReader。**

---

## 2. 能达到的效果

在 NoteSL（默认 profile）上：

- **一键启动**：安装 NativeKO APK，点一下即可；
- **绕过 Android framework**：停止 `zygote`/`SurfaceFlinger` 等，KOReader
  直接 mmap `/dev/ebc` 并提交 `SEND_BUFFER`/`SEND_UPDATE`，显示完全不经过
  SurfaceFlinger/hwcomposer；
- **自包含**：APK 内含 KOReader Lua 模块、原生库、native 启动器、
  session/driver/profile；运行时不需要 Android KOReader App；
- **设置/插件/补丁共享**：使用 `/sdcard/koreader`（`KO_DATA_DIR`），
  和 Android KOReader 一样；
- **真实硬件 suspend**：电源键屏保后写 `mem` 进入 suspend，再按电源键唤醒
  并全刷；session wake lock、旧 framework 锁清理、RTC 旧 alarm 清理和
  mmc1 unbind 都已处理；
- **前光省电**：屏保显示时前光降到最低，唤醒时恢复；
- **Wi-Fi 控制**：启动时默认不自动开 Wi-Fi；屏保/suspend 时关闭，唤醒时
  如果之前是开的会恢复；菜单里可以手动开/关；
- **关机选项**：KOReader 退出菜单里的 Power off 会执行 `sync` +
  `/system/bin/reboot -p`；
- **稳定切换**：suspend/resume 进行中忽略新的电源键事件，避免连按导致
  二次休眠或卡死。

在 T65A 上为 screensaver-only：屏保、前光、Wi-Fi 和关机可用，不进入硬件
suspend，因此屏保期间系统保持 awake，会持续耗电。

---

## 3. 操作引导

### 3.1 安装/更新

```sh
adb push NativeKO.apk /data/local/tmp/NativeKO.apk
adb shell su -c 'pm install -r /data/local/tmp/NativeKO.apk'
```

也可以在 Android 文件管理器里点击 APK 安装（需要允许未知来源）。

### 3.2 第一次启动

1. 点击桌面上的 **NativeKO**；
2. 首次启动会解压资源（约 1 分钟），屏幕可能短暂显示进度；
3. 解压完成后会停止 Android framework，启动原生 KOReader；
4. NativeKO 的 Activity 被结束是**正常现象**：原生进程接管屏幕。

### 3.3 日常操作

- **电源键（NoteSL）**：显示屏保；约 2 秒后停止 Wi-Fi 并进入 suspend；
  再按电源键唤醒，关闭屏保、恢复 Wi-Fi/前光并全刷；
- **电源键（T65A）**：只显示/关闭屏保，不进入硬件 suspend；
- **触摸**：不会关闭屏保；屏保只由电源键关闭；
- **连按电源键**：suspend/resume 和恢复全刷完成前的按键会被忽略；
- **前光**：屏保/suspend 时变暗，唤醒时恢复；
- **Wi-Fi**：KOReader 网络菜单；启动默认关闭，可手动开启；屏保/suspend
  时关闭，唤醒时如果之前是开的会恢复；
- **退出 KOReader**：退出菜单 → Exit；session 会恢复 Android framework；
- **关机**：退出菜单 → Power off（需要 root，NativeKO 以 root 运行）。

### 3.4 更新后

如果新 APK 的 `ASSET_VERSION` 变大：

1. 先退出正在运行的原生 KOReader；
2. 重新打开 NativeKO；
3. 新版本会重新解压资源。仅安装 APK 不会自动替换已解压的旧资源。

### 3.5 日志与恢复

- 原生 session 日志：
  `/data/data/com.nativeko/files/native/run.log`
- suspend 日志：同一目录下的 `suspend.log`
- 用户数据/设置/插件：`/sdcard/koreader`
- 如果启动失败、黑屏或卡住：
  - 退出/重启设备，或长按电源键强制重启；
  - 查看 `run.log` / `suspend.log`；
  - 确认 `ko/libs/libkoreader-input.so` 存在（Android monolibtic 不含
    Linux evdev 输入模块）。

---

## 4. 构建

前置条件：

- WSL/Linux 主机：`adb`、`python3`、`javac`/`java`、`tar`、`keytool`、
  `wslpath`；
- Android SDK（`$ANDROID_SDK_ROOT`，默认 `/mnt/c/tools/android-sdk`）；
- Android NDK（`$ANDROID_NDK_HOME`，默认
  `$HOME/Android/Sdk/ndk/23.2.8568313`）；
- 设备已 root，且已安装 `org.koreader.launcher`（构建时从中提取 KOReader
  Lua 模块）；
- `platform/native-harness/libkoreader-input.so`（仓库已带预编译版本；也
  可以用 `platform/native-harness/build-input.sh` 重新构建）。

```sh
ADB=/mnt/c/tools/android-sdk/platform-tools/adb.exe \
  PROFILE_ID=notesl bash platform/android/nativeko/build.sh
```

`PROFILE_ID` 默认就是 `notesl`；T65A 用 `PROFILE_ID=t65a`。

输出：`platform/android/nativeko/NativeKO.apk`。

构建脚本会：

1. 编译 `koreader-native` 和 `detach`；
2. 从设备提取 KOReader 模块并清理用户数据；
3. 覆盖仓库中的 KOReader 后端/输入模块/ffi/数据目录支持；
4. 生成所选 profile，写入 `native/profile.id`；
5. 把 `ko.zip`、`native.zip` 打包进 APK；
6. 确认 `libkoreader-input.so` 存在，缺失则报错（避免生成启动即退出的 APK）。

详细构建/运行时布局见
[`platform/android/nativeko/README.md`](platform/android/nativeko/README.md)。

---

## 5. 移植到其他设备

这是本项目的重点：NativeKO 是“框架 + 参考实现”，不是某一台设备的专用
代码。

移植时需要：

1. 采集目标设备信息（fb/EBC/输入/电池/前光/Wi-Fi/init 服务/`/sys/power`）；
2. 新建 `platform/native/profiles/<id>/profile.json`；
3. 显示控制器不同：选择/新增 `base/ffi/framebuffer_*`，并在
   `frontend/device/native/device.lua` 按 `display.backend` 选择；Rockchip
   EBC 设备用 `rk_ebc`，并用 `tools/rk-ebc-probe.c` 标定 bpp/stride/方向；
4. host/Wi-Fi 栈不同：新增 `drivers/host/<name>.sh`、
   `drivers/wifi/<name>.sh`；
5. 重新构建 `libkoreader-input.so` 和 launcher（目标 ABI/API）；
6. 如需硬件 suspend，实现/选择 PM driver 和 Lua 驱动；NoteSL 的
   `android_wakeup_count` 可作为 Android 6 wakelock/`mem` 模型的参考。

完整的前置条件、移植内容、步骤、信息源、测试/恢复、常见坑和检查清单见：

- [`platform/native/PORTING.md`](platform/native/PORTING.md)（中文）
- [`platform/native/RK_EBC.md`](platform/native/RK_EBC.md)（Rockchip EBC）

框架本身的说明：

- [`platform/native/README.md`](platform/native/README.md)
- [`platform/native-harness/README.md`](platform/native-harness/README.md)

---

## 6. 目录

```
platform/android/nativeko/   APK 构建、Java launcher、assets 工具
platform/native/             通用框架：core/drivers/profiles/tools
platform/native-harness/     bionic launcher、detach、输入模块、dev harness
frontend/device.lua          KOReader 设备探测
frontend/device/native/      profile 驱动的 KOReader 后端
base/ffi/                    EPDC / Rockchip EBC / framebuffer 覆盖
base/input/                  Linux evdev 输入模块源码
datastorage.lua              KO_DATA_DIR 支持
COPYING                      AGPL-3.0
```

## 7. 当前限制

- 当前验证过 NoteSL（Rockchip EBC + 硬件 suspend）和 T65A（i.MX6 EPDC，
  screensaver-only）；其他设备需要按 PORTING.md 添加 profile/driver/显示
  后端；
- framework 停止后没有 netd，域名解析可能不可用；驱动会配置默认路由和
  `net.dns1` 保证 IP 连通，但不要依赖 `ndc` 等平台工具；
- Android 打包层假定可 `su` 并能停止 init 服务；非 Android 设备可直接用
  `session.sh`/systemd，不需要 APK；
- 构建 APK 仍需要设备上有 `org.koreader.launcher` 作为 KOReader 模块来源；
  运行时不需要它。

## License

KOReader 使用 AGPL-3.0，详见 [`COPYING`](COPYING)。
