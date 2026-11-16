# NativeKO 移植指南

本文说明如何把 NativeKO / `platform/native` 的原生 KOReader 方案移植到
另一台设备。默认目标是 Android 电子墨水设备；非 Android Linux 设备的差异
会在对应章节标注。

本仓库有两个参考 profile：

- `notesl`（Onyx NoteS / 超星 NoteSL）：直接控制 Rockchip EBC，并实现
  Android 6 的 `android_wakeup_count` 硬件 suspend；
- `t65a`（Likebook T65A）：i.MX6 EPDC，`power.model = "none"`，
  screensaver-only，只保留屏保、前光、Wi-Fi 控制和关机。

移植时先做到 **screensaver-only**（`power.model = "none"`）：屏保、前光、
Wi-Fi、电源键、关机。确认这些稳定后，再把硬件 suspend 作为第二阶段
（见 3.12），不要一开始就做。

## 1. 前置条件

### 1.1 设备能力

- **root / native 执行权限**：需要能运行自己的 ELF 程序，并能打开
  `/dev/graphics/fb0`（或 `/dev/fb0`）、`/dev/input/event*`、sysfs 节点。
- **能停止 Android framework**：通常是 `setprop ctl.stop zygote` /
  `surfaceflinger` 等 init 服务；或者设备本身不跑 Android。
- **framebuffer 可用**：framework 停止后，屏幕不能被 SurfaceFlinger 或
  其他显示服务占用；需要确认 fb 的像素格式、stride、旋转、pan/blank 接口。
- **evdev 输入可用**：触摸、电源键、翻页键的 event 节点和 key code 可读；
  最好有 `getevent` 或 `evtest`。
- **可恢复**：能通过 adb、硬件按键、串口或 recovery 恢复 Android；建议先
  准备 `restore-android.sh` 和强制重启手段。
- **屏幕/输入/电源信息**：能读到 fb、背光、电池、Wi-Fi、init 服务等信息
  （见第 5 节）。

### 1.2 构建环境

- Android NDK（T65A 使用 r23c / `23.2.8568313`，API 19）；
- 目标 ABI 的 `libluajit.so` 和 LuaJIT 头文件；
- 一份可用的 KOReader Lua 模块（Android 上通常是
  `org.koreader.launcher` 的 files 目录）；
- `python3`、`adb`、`javac`/`java`、`keytool`、`tar`（APK 构建）；
- 如果要打包 APK：Android SDK build-tools（`aapt2`、`d8`、
  `apksigner`）和 `android.jar`。

### 1.3 需要提前确认的信息

- 内核版本、`/proc/config.gz`、`/proc/cmdline`；
- display controller / EPDC 型号和 ioctl ABI；
- input event 节点、key map、触摸协议（A/B、slot、BTN_TOUCH）；
- 背光、电池、充电器 sysfs；
- Wi-Fi 芯片、驱动、SDIO 总线、wpa_supplicant 控制目录和 init 服务；
- Android init 服务名和停止/启动顺序；
- `/sys/power` 下可用的 suspend 接口（如果以后要做硬件 suspend）。

### 1.4 恢复手段

在改动 framework 之前，先确认：

```sh
adb shell su -c 'sh /path/to/restore-android.sh'
# 或长按电源键 / 串口 / recovery
```

并保留一份能启动 Android 的原始服务列表和脚本。

## 2. 需要移植的内容

| 内容 | 位置 | 说明 |
|---|---|---|
| 设备 profile | `platform/native/profiles/<id>/profile.json` | 硬件、host、Wi-Fi、工具路径 |
| 显示后端 | `base/ffi/framebuffer_*.lua` + `frontend/device/native/device.lua` | T65A 是 i.MX6 EPDC/mxcfb；RK EBC 直显设备用 `rk_ebc`（见 `RK_EBC.md`）；其他按控制器选择或新增 |
| 输入 | profile `input.*`、`base/input/input.c`、`frontend/device/input.lua` | event 节点、key map、触摸 quirk |
| 电源/前光 | profile `power.*`、`frontend/device/native/powerd.lua` | 电池、前光、`model` |
| host 驱动 | `platform/native/drivers/host/<name>.sh` | Android init 服务或 systemd/none |
| Wi-Fi 驱动 | `platform/native/drivers/wifi/<name>.sh` | supplicant/DHCP/接口/权限 |
| PM 驱动（可选） | `platform/native/drivers/pm/<name>.sh`、`frontend/device/native/suspend/*.lua` | `none` 为纯屏保；NoteSL 用 `android_wakeup_count`（见 3.12） |
| 原生启动器 | `platform/native-harness/main.c`、`build-native.sh` | bionic LuaJIT launcher，按目标 ABI/API 调整 |
| 输入模块 | `platform/native-harness/build-input.sh` → `libkoreader-input.so` | Android monolibtic 不含 Linux evdev 输入模块 |
| KOReader 覆盖层 | `frontend/device.lua`、`frontend/device/native/`、`datastorage.lua`、`base/ffi/` | 设备探测、profile backend、数据目录、fb 覆盖 |
| APK（Android） | `platform/android/nativeko/` | 一键启动、assets 解压、`su`、`ASSET_VERSION` |

## 3. 逐步移植

### 3.1 设备侦察

在 Android 上（framework 还在时也可以）：

```sh
cat /proc/version; cat /proc/cmdline
zcat /proc/config.gz 2>/dev/null | head
cat /proc/bus/input/devices
getevent -pl /dev/input/event0
cat /sys/class/input/event0/device/capabilities/key
ls -l /sys/class/graphics /dev/graphics /dev/input
cat /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/stride 2>/dev/null
fbset -i 2>/dev/null || true
ls /sys/class/backlight; cat /sys/class/backlight/*/max_brightness
ls /sys/class/power_supply; cat /sys/class/power_supply/*/type
ls /sys/power; cat /sys/power/state
cat /proc/interrupts
dmesg | grep -iE 'epd|epdc|fb|touch|goodix|wifi|sdio|rtc'
getprop | grep -E 'init.svc|wifi|zygote|surfaceflinger'
```

RK EBC 直显设备再补充：

```sh
ls -l /dev/ebc /dev/graphics/fb0; cat /proc/misc
# 编译并推送 platform/native/tools/rk-ebc-probe.c 后：
/data/local/tmp/rk-ebc-probe info
/data/local/tmp/rk-ebc-probe hist
```

`info`/`hist` 会给出 EBC 驱动版本、buffer 几何、rotate、mmap 各区域直方图；
bpp/stride/方向需要停 framework 后用 `pattern`/`corner` 标定，步骤见
[`RK_EBC.md`](RK_EBC.md)。

Android init 配置可能在 `/init.rc`、`/init.*.rc`、`/system/etc/init/`
（新版本）中；确认要停止的服务名。framework 停止后，`dumpsys` 不可用，
所以要在停止前记录信息。

如果设备没有 `/proc/last_kmsg`/pstore，后续 suspend 调试要在释放最后一把锁
之前把状态写到持久存储；不要假设重启后还能看到内核日志。

### 3.2 先做最小 native 验证

在写 profile 之前，先用一个最小的 fb/evdev 程序确认：

- 能打开 fb 并 mmap；
- 能读到正确的分辨率/stride/像素格式；
- 能打开触摸 event 并读到 ABS_MT_* / BTN_TOUCH；
- 能停止 framework 后仍然操作屏幕和输入；
- 能恢复 Android。

这一步失败的话，不要继续做 KOReader 集成。

### 3.3 创建 profile

复制参考 profile，按设备修改（i.MX6 mxcfb 用 `profiles/t65a`，RK EBC 直显
用 `profiles/notesl`）：

```sh
cp platform/native/profiles/notesl/profile.json \
   platform/native/profiles/<id>/profile.json
python3 platform/native/tools/profilegen.py \
   platform/native/profiles/<id>/profile.json /tmp/profile-out
```

关键字段：

- `display.fb`、`display.blank`、`display.pan`、`display.backend`、
  `display.portrait`、`display.touch_rotation`、`display.dpi`；
- RK EBC：`display.ebc_device`、`ebc_width/height`、`ebc_bpp`、`ebc_stride`、
  `ebc_offset`、`ebc_rect_order`、`ebc_cmd_*`、`ebc_epd_mode`、
  `ebc_waveform_*`/`ebc_update_mode_*`、`ebc_flags`、`ebc_unknown_1c`；
- `input.devices`、`input.keys`、`input.quirks`；
- `power.battery_*`、`power.frontlight`、`power.fl_min/fl_max`、
  `power.model`（先设 `none`；实现硬件 suspend 后换成对应驱动，如
  `android_wakeup_count`）；
- `network.manage`、`iface`、`backend`、`ctrl_dir`、`service`、
  `service_prop`、`dhcp_*`、`driver_module`、`sdio_host_*`；
- `host.backend`、`host.stop/start`、governor；
- `tools`（`ip`/`ping`/`setsid`/`getprop`/`busybox`）和 `paths`。

先用 `--dry-run` 检查生成结果：

```sh
adb shell su -c 'sh <native>/session.sh --profile <id> --dry-run'
```

### 3.4 显示后端

T65A 使用 i.MX6 EPDC：

- `base/ffi/framebuffer_mxcfb.lua`；
- `base/ffi/mxcfb_t65a_h.lua`（ioctl/结构体变体）；
- profile `display.backend: "mxcfb"`、`display.mxcfb_variant: "t65a"`。

其他设备：

1. 先看 KOReader 是否已有对应后端：
   `base/ffi/framebuffer_linux.lua`、`framebuffer_einkfb.lua`、
   `framebuffer_sunxi.lua`、`framebuffer_pocketbook.lua`、
   `framebuffer_android.lua` 等；
2. 在 `frontend/device/native/device.lua` 的 `getFramebufferModule()` 里按
   `disp.backend` 选择对应的 framebuffer 模块；
3. 确认 `FBIOGET_VSCREENINFO`/`FBIOPUT_VSCREENINFO`、pan/blank、旋转、
   stride、像素格式；必要时写新的 `framebuffer_<soc>.lua`；
4. 用 KOReader 的 `Screen`/`blitbuffer` 做一次全屏刷新验证。

#### RK EBC 直显设备

部分 Rockchip 电子墨水设备的面板扫描的是 `/dev/ebc` mmap 出来的缓冲，
而不是 `/dev/graphics/fb0`。这类设备用：

- profile `display.backend: "rk_ebc"`；
- 模块 `base/ffi/framebuffer_rk_ebc.lua`；
- profile 的 `ebc_*` 字段（设备节点、宽高、bpp、stride、offset、矩形顺序、
  `SEND_BUFFER/SEND_UPDATE` 命令号、波形/update_mode、flags 等）。

不要假设是 4bpp：老 Rockchip `software_ebc` 的自动图像是 4bpp，但直显缓冲
可能是 32bpp（NoteSL 就是 1200×825、32bpp、stride 4800）。用
`platform/native/tools/rk-ebc-probe.c` 的 `pattern`/`corner` 标定 bpp、
stride 和方向；完整步骤、ioctl/结构体、已测硬件信息和检查清单见
[`RK_EBC.md`](RK_EBC.md)。

注意：EPDC 的波形/刷新策略、pan 显示、初始全刷都可能和普通 fb 不同；
先保证显示正确，再谈省电/刷新优化。RK EBC 直显模式下必须先停
SurfaceFlinger/zygote，否则 framework 会和 KOReader 争抢面板。

### 3.5 输入

- 在 `input.devices` 中填目标 event 节点；
- 用 `getevent -pl` + `/sys/class/input/event*/device/capabilities/key`
  确认 key code，映射到 `LPgBack`/`RPgFwd`/`Power`/`Back` 等；
- 触摸协议：
  - MT protocol A/B；
  - 是否有 `ABS_MT_TRACKING_ID`；
  - 是否发 `BTN_TOUCH`；
  - 抬起事件是否完整；
- 必要时增加 quirk，例如：
  - `power_down_only`：电源键只转发 down，避免一次按键触发两次 toggle；
  - `mt_a_touch_up`：goodix 的 MT-A 抬起没有 tracking id，需要手动结束 slot；
  - `touch_swap_xy`：raw X/Y 交换（纯交换，标准 rotation 1/3 不适用）；
  - `touch_invert_x`/`touch_invert_y`：在交换后的坐标上反转对应轴；
  - `touch_max_x`/`touch_max_y`：raw 轴最大值，用于反转。
- NoteSL 的触摸是 `touch_swap_xy + touch_invert_x`，`touch_rotation: 0`；
  仅凭显示方向推断不够，必须实际点击验证。

参考 KOReader 现有的 `frontend/device/input.lua` 和各设备 `device.lua` 的
`event_map`/`event_map_adapter`。

### 3.6 host / Android framework

Android host 驱动在 `platform/native/drivers/host/android_init.sh`：

```sh
host_pre_start() {
    for s in $HOST_STOP_SERVICES; do setprop ctl.stop "$s"; done
}
host_post_exit() {
    for s in $HOST_START_SERVICES; do setprop ctl.start "$s"; done
}
```

移植时：

1. 在 Android 停止前记录 `getprop`/`ps`，确认服务名；
2. 停止顺序一般先 `zygote`/`surfaceflinger`/`media` 等；
3. 停止后确认 fb 和 evdev 没有被其他进程占用；
4. 退出时按逆序恢复；保留 `session.journal` 以便崩溃后恢复；
5. CPU governor 的保存/恢复可参考现有 `session.sh`。

非 Android 设备可以用 `drivers/host/none.sh`，由 systemd/init 负责
启动/停止显示服务。

### 3.7 Wi-Fi

Android 参考 `drivers/wifi/wpa_supplicant_android.sh`：

- `network.ctrl_dir`（通常是 `/data/misc/wifi/sockets`）或完整的
  `network.ctrl_interface`；
- 如果 init 只提供 Android 全局 supplicant socket
  （`-g@android:wpa_wlan0`，路径 `/dev/socket/wpa_wlan0`），设
  `ctrl_interface` 为该路径，并设 `wpa_global: true`、`wpa_ifname: "wlan0"`；
  原生后端会给命令加 `IFNAME=wlan0 ` 前缀；
- `network.service`（`wpa_supplicant`）和 `network.service_prop`
  （`init.svc.wpa_supplicant`，用于 UI 判断）；
- `network.dhcp_cmd`/`dhcp_flags`；
- `network.driver_module`/`driver_ko`/`sdio_host_*`（仅在必要时）。

要点：

- KOReader 的 `NetworkMgr` 通过
  `sh <native>/session.sh --profile <id> wifi-up|wifi-down|wifi-dhcp|wifi-release`
  调用；不要依赖 `session.sh` 的可执行位；
- APK 解压后要在 `MainActivity` 里给 `session.sh`/`start-session.sh`
  加可执行位；
- `isWifiOn()` 读取 `network.service_prop`，所以 supplicant 状态要真实；
- 某些 ROM 的 `dhcpcd` 不写 `dhcp.<iface>.gateway/dns1` 属性；Wi-Fi 驱动
  会从接口地址的 `.1`、再退到 ARP 表推断网关，并设置默认路由和
  `net.dns1`。这样 IP 连通性可用；**域名解析仍需要 netd/framework 的 DNS
  配置**，框架停止后不要依赖 `ndc` 之类平台工具；
- `network.start_on_boot: false` 可以避免一启动就开 Wi-Fi；
- 屏保显示时是否关闭 Wi-Fi、退出时是否恢复，由
  `frontend/device/native/device.lua` 的 `onPowerEvent()` 决定。

非 Android 设备可写一个新的 backend（NetworkManager/connman/wpa_cli），
实现同样的 `wifi_up`/`wifi_down`/`wifi_dhcp`/`wifi_release`。

### 3.8 电池与前光

- profile `power.battery_capacity`/`battery_status`；
- profile `power.frontlight`、`fl_min`、`fl_max`；
- 可参考 KOReader 的 `frontend/device/sysfs_light.lua` 和各设备
  `powerd.lua`；
- NativeKO 默认在屏保显示时把前光降到 `fl_min`，电源键关闭屏保时恢复；
  触摸点击不关闭屏保，避免 tap 退出后前光状态不一致。

### 3.9 屏保与电源键

`frontend/device/native/device.lua` 的 `Device:onPowerEvent()` 同时处理
屏保和（如果 profile 选择了 PM model）硬件 suspend：

- 第一次电源键：`Screensaver:setup()/show()`、force repaint、关闭 Wi-Fi、
  `PowerD:beforeSuspend()`，然后 `rescheduleSuspend()` 在
  `suspend_wait_timeout` 后调用 `Device:suspend()`；
- suspend driver 释放 session wake lock、停 Wi-Fi、清旧 RTC alarm、
  unbind `suspend_unbind` 设备，写 `mem`；写操作阻塞到唤醒；
- 唤醒后重新 bind、拿回 session lock；电源键关闭屏保、恢复前光和 Wi-Fi，
  并强制全刷；
- `ScreenSaverWidget.onTap = function() end`：触摸不关闭屏保；
- `_suspend_in_progress` / `_resume_in_progress` 为真时忽略新的
  Power/Suspend 事件，busy 状态持续到 resume 全刷完成，避免连按排队；
- `canSuspend` 由 profile 的 `power.model` 决定；`none` 时是纯屏保；
- `canPowerOff = yes`，`Device:powerOff()` 使用
  `sync` + `/system/bin/reboot -p`，失败回退 `sys.powerctl shutdown`。

移植到其他设备时，确认电源键的 key code、是否只发 down、是否需要
`power_down_only`；确认电源键是内核 wake source；确认关机命令
（`reboot -p`/`poweroff`/`sys.powerctl`）。

### 3.10 KOReader 模块、launcher 与输入模块

Android KOReader 的 `libkoreader-monolibtic.so` **不包含** Linux evdev
输入模块。native 后端需要：

```
ko/libs/libkoreader-input.so
```

由 `platform/native-harness/build-input.sh` 从 `base/input/input.c` 编译；需要：

- 目标 ABI 的 NDK 编译器；
- LuaJIT 头文件；
- 目标设备的 `libluajit.so`（用于链接）。

APK 构建必须显式包含它；缺少时应报错退出，而不是生成一个启动即退出的
APK。T65A 的旧版问题就是清理 `/data/local/tmp` 后该库丢失，导致：

```
frontend/device/input.lua: module 'libs/libkoreader-input' not found
```

`platform/native-harness/main.c` 是 bionic LuaJIT launcher，按目标 API/ABI 调整
`build-native.sh`；如果目标不是 Android，直接用普通 KOReader 启动方式即可。

### 3.11 NativeKO APK（Android）

参考 `platform/android/nativeko/`：

- assets `ko.zip` + `native.zip`；
- `MainActivity` 解压、设置可执行位、`su` 启动 `run-native.sh`；
- `ASSET_VERSION` 在资源变化时递增；
- 安装可以在 framework 停止时用：
  `adb push ...; adb shell su -c 'pm install -r ...'`；
- 更新后退出旧 session，重新打开 NativeKO，才会重新解压新资源。

非 Android 设备不需要 APK，把 `native/` 目录和 `session.sh` 放到
init/systemd 能启动的位置即可。

### 3.12 硬件 suspend：`android_wakeup_count`

NoteSL 已实现 Android 6 的 wakelock/`mem` 模型：profile
`power.model = "android_wakeup_count"`，对应
`drivers/pm/android_wakeup_count.sh` 和
`frontend/device/native/suspend/android_wakeup_count.lua`。

1. 先确认 `/sys/power` 接口：
   - 本机：`state=freeze standby mem`，`wake_lock`/`wake_unlock`，
     没有 legacy `wait_for_fb_*`/earlysuspend 模块；
   - 其他内核可能是 earlysuspend/autosleep/wakeup_count，按实际选择模型；
2. 参考 AOSP `system/core/libsuspend` 的
   `autosuspend_earlysuspend.c` / `autosuspend_autosleep.c` /
   `autosuspend_wakeup_count.c`；
3. host/session 侧：
   - `pm_start` 拿 session wake lock，清理 `PowerManagerService.*` /
     `KeyEvents` / 旧 `nativeko-*` 锁；
   - `pm_stop` 等 framework 拿回 `PowerManagerService` 锁后再释放 session
     锁，并清理泄漏的 session 锁；
4. suspend driver：
   - 停 Wi-Fi（`wifi-suspend`），清旧 RTC alarm；
   - 释放除 session 锁外的锁，最后释放 session 锁；
   - 写 `mem`；写操作返回即已 resume；重新拿 session 锁；
   - 可选 `suspend_unbind`：休眠前 unbind、resume 后 bind 那些
     resume 会超时的未装配硬件（NoteSL 的 mmc1 SD 控制器，省 ~10s）；
   - `rtc_alarm` 只用于**清除旧 alarm**，不设置唤醒 alarm；
5. resume 后由 `onPowerEvent()` 关闭屏保、恢复 Wi-Fi/前光并全刷；
   `_suspend_in_progress`/`_resume_in_progress` 期间忽略新的按键；
6. 调试阶段可手工 `echo devices > /sys/power/pm_test` 做 5 秒自动恢复的
   分段测试，然后 `echo none`；生产 profile 不需要 `pm_test`。

T65A 的历史 suspend 代码在父 KOReader 仓库的 `native-t65a` 分支；T65A
profile 保持 `power.model = "none"`（纯屏保）。

## 4. 参考信息源

### 4.1 设备侧

- `/proc/bus/input/devices`、`getevent -pl`、
  `/sys/class/input/event*/device/capabilities/key`；
- `/sys/class/graphics/fb0/*`、`fbset`、display driver 的 dmesg；
- `/sys/class/backlight/*`、`/sys/class/power_supply/*`；
- `/sys/class/net/*`、`/data/misc/wifi/sockets`、`getprop` 的
  `init.svc.*`；
- `/sys/power/*`、`/sys/kernel/debug/wakeup_sources`、
  `/proc/interrupts`、`/sys/kernel/debug/gpio`；
- `/init.rc`、`/init.*.rc`、`/system/etc/init/`；
- `dmesg`、`/proc/last_kmsg`/pstore/串口（如果可用）。

### 4.2 KOReader

- `frontend/device/*/device.lua`、`powerd.lua`：Kobo、Kindle、
  PocketBook、Cervantes、remarkable、SDL 的显示/输入/电源实现；
- `frontend/device/input.lua`、`base/input/input.c`：evdev 输入；
- `base/ffi/framebuffer_*.lua`：mxcfb/linux/einkfb/sunxi/ion 等；
- `frontend/device/sysfs_light.lua`：sysfs 背光；
- `frontend/device/wakeupmgr.lua`：RTC/唤醒管理；
- `frontend/ui/network/manager.lua`：Wi-Fi 切换/恢复；
- `frontend/ui/screensaver.lua`、`ui/widget/screensaverwidget.lua`：屏保；
- Kobo 的 `powerd.lua`：suspend/resume、`checkUnexpectedWakeup`、
  `state-extended`、wakeup_count 的成熟参考。

### 4.3 Android/AOSP

- `system/core/libsuspend`：
  - `autosuspend.c`（earlysuspend → autosleep → wakeup_count 的选择）；
  - `autosuspend_earlysuspend.c`（`mem`/`on` + fb ack 线程）；
  - `autosuspend_autosleep.c`（`/sys/power/autosleep`）；
  - `autosuspend_wakeup_count.c`（wakeup_count + 信号量）；
- `PowerManagerService`、`WifiController`/`WifiStateMachine`/`WifiNative`、
  `AlarmManagerService`、`DisplayPowerController`、`WindowManagerService`；
- 内核 `kernel/power/wakelock.c`、`earlysuspend.c`、
  `fbearlysuspend.c`、`drivers/rtc/alarm.c`；
- Android launcher/KOReader Android 构建：
  `org.koreader.launcher` 的模块和 libs；`libkoreader-monolibtic.so` 的
  输入限制。

### 4.4 厂商/内核

- i.MX6 EPDC：`mxc_epdc_fb.c`、`mxcfb.h`、NXP i.MX6 Android PM 调试资料；
- Rockchip EBC、Kobo NTX、Kindle、PocketBook 等显示/电源驱动；
- 目标设备的 display/power/Wi-Fi 驱动源码和 dts/board 文件。

### 4.5 工具

`adb`、`busybox`、`getevent`、`evtest`、`fbset`、`fbgrab`、`strace`、
`dmesg`、串口 console、`/proc/last_kmsg`/pstore（如果存在）。

## 5. 测试与恢复

1. `session.sh --profile <id> --dry-run`；
2. `--no-stop` 先不停止 framework，验证 profile/命令；
3. 停止 framework 后验证 fb/input；
4. 启动 native KOReader，验证屏保、前光、Wi-Fi、电源键；
5. 退出后验证 Android 服务、governor、Wi-Fi 恢复；
6. 如果做 suspend：先用 `/sys/power/pm_test` 分段（`devices` → `platform`
   → `processors` → `core` → 真实 `mem`），每次都能自动恢复；生产 profile
   不保留 `pm_test`，并保留串口/长按电源键等恢复手段。

## 6. 常见坑

- **`session.sh` Permission denied**：APK 解压不保证可执行位；用
  `sh session.sh`，并在 `MainActivity` 里补 chmod。
- **缺少 `libkoreader-input.so`**：Android monolibtic 不含 evdev 输入模块；
  必须在构建 APK 前编译并打包。
- **清理 `/data/local/tmp` 破坏构建**：不要依赖临时目录里的构建产物；
  把 `libkoreader-input.so` 和源码放进仓库/固定路径。
- **不要盲目 rmmod Wi-Fi / unbind SDIO**：会重新 probe，重新
  `enable_irq_wake`，反而制造 OOB 唤醒。
- **USB 连接会阻止 suspend**：`gadget`/`cw201x` 等 wake lock；测试要拔线。
- **没有 `/proc/last_kmsg`/pstore**：挂死前的日志要主动写盘；否则只能靠
  串口。
- **触摸不是 suspend 的唤醒源**：不要用输入 inhibit 掩盖 suspend 失败；
  真正 suspend 后只有电源键/RTC/特定 GPIO 能唤醒。
- **PMS 不能单独使用**：它属于 `system_server`；native session 停止
  framework 后没有 PMS。需要 suspend 时复刻 `libsuspend` + wake lock 策略，
  而不是调用 PMS。
- **`ASSET_VERSION` 不递增**：已安装的 APK 不会重新解压新资源。
- **`start_on_boot`/`wifi_was_on`**：两个独立的自动 Wi-Fi 来源；要手动控制
  就同时检查 profile 和 KOReader 设置。

## 7. 移植检查清单

- [ ] root/native 执行、fb/evdev 可访问、recovery 可用
- [ ] 设备侦察信息记录完成
- [ ] 新 profile + `profilegen.py` 通过
- [ ] 显示后端正确（分辨率/stride/格式/旋转/pan/blank）
- [ ] RK EBC：`rk-ebc-probe info`/`pattern`/`corner` 标定 bpp、stride、
      方向；确认是 `/dev/ebc` 直显而不是 fb0
- [ ] RK EBC：EBC 线程不卡死（`GET_BUFFER` 不阻塞）；异常时 reboot 后重试
- [ ] 输入 key map、触摸协议、quirk 正确；触摸方向与 `touch_rotation` 一致
- [ ] host 服务停止/恢复正确
- [ ] Wi-Fi up/down/dhcp/release 正确，`sh` 调用
- [ ] 电池/前光 sysfs 正确
- [ ] 屏保/电源键/前光/Wi-Fi/关机行为符合预期
- [ ] `libkoreader-input.so` 已编译并打包
- [ ] APK 资源版本递增，安装/重解压流程验证
- [ ] 退出后 Android 完整恢复
- [ ] （可选）suspend 接口、wake lock、Wi-Fi OOB、RTC、日志/恢复验证
