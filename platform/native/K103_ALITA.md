# K103 / Likebook Alita 适配记录

设备：博阅 Likebook Alita（`ro.product.model=Likebook-K103`，`ro.product.device=K103`，
`ro.product.brand=Boyue`）。K103 是博阅 Alita，**不是** Onyx/超星 NoteSL；
NoteSL 是另一台 RK3288、1200×825 的设备（`profiles/notesl`）。

本文记录 NativeKO 在这台机器上的完整适配过程、已验证结论和踩坑经验，供其他
Rockchip EBC + Android 8 设备复用。

## 1. 硬件/系统

| 项目 | 值 |
|---|---|
| SoC | Rockchip RK3368，8×Cortex-A53 |
| 系统 | Android 8.1.0（SDK 27），root / Magisk 31.1 |
| 内核 | Linux 4.4.103 |
| 面板 | 1872×1404，i.MX/EPD 类 EBC |
| 显示节点 | `/dev/ebc` 与 `/dev/graphics/fb0` |
| fb0 | 1872×1404，32bpp，stride 7488 |
| 触摸 | `cyttsp5_mt`（MT-B，event0，X 0..1403 / Y 0..1871） |
| 按键 | `cyttsp5_btn`（KEY_BACK=158，event1）、`rk29-keypad`（KEY_POWER=116，event4） |
| 前光 | `rk28_bl`（冷）与 `rk28_bl_warm`（暖），0..255 |
| Wi-Fi | `wlan0`，`/vendor/bin/hw/wpa_supplicant` init 服务 |
| PM | `/sys/power/state = freeze mem idle`，`autosleep=off` |

## 2. 显示：直接驱动 `/dev/ebc`

SurfaceFlinger/hwcomposer 停掉后，直接 mmap `/dev/ebc`，不走 fb0：

- buffer 是 **8bpp**，但每个字节是 **5-bit 灰度码（0..31）**；
  - `0x00` = 黑，`0x1E` = 白；
  - `0xFF` 不是有效白，会被波形刷掉（表现为“黑块闪一下就消失”）。
- 面板把 buffer **顺时针旋转 90°** 扫描：
  - buffer (0,0) → 视觉右上；
  - buffer (0,H-1) → 视觉左上。
- `GET_BUFFER (0x7000)` 返回的 offset **不是固定 0**（实测有 0、2628288、
  7884864 等），必须写回返回的 offset。
- 提交用 `SEND_BUFFER (0x7001)`，`epd_mode` 放在 `ebc_buf_info` 偏移 4；
  `win_x1=0, win_y1=0, win_x2=width, win_y2=height`。
- `0x7007` 是 `GET_EBC_STATUS`，**不是** SEND_UPDATE；`0x700c` 不在 HWC 的
  刷新链路里，不要拿它当更新命令。
- `DRAW_ENABLE (0x7008)` 在 init 时调用一次；驱动侧 `drawtest` 验证过同一个
  fd 内连续 GET_BUFFER/SEND_BUFFER。

### 2.1 原厂刷新模式表

来自 `ByDeviceTest/com/boyue/api/impl/RK3368Impl` 和
`android.view.View.setByEinkUpdateMode`：

| 名称 | 值 | 用途 |
|---|---:|---|
| EPD_FULL | 1 | 全刷（黑白闪） |
| EPD_A2 | 2 | A2 |
| EPD_PART | 3 | 默认局刷（`ro.default.epdmode=3`） |
| EPD_BLACK_WHITE | 6 | 黑白 |
| EPD_FORCE_FULL | 11 | 强制全刷 |
| EPD_REGLA | 15 | REGAL，文本优化，低残影/低闪 |
| EPD_ADAPTIVE | 17 | 自适应 |
| EPD_FAST | 18 | 快速 |
| EPD_DITHER | 100 | 抖动 |
| EPD_FULL_DITHER | 102 | 全刷抖动 |

NativeKO 当前映射（`platform/native/profiles/alita/profile.json`）：

| KOReader 类型 | epd_mode |
|---|---:|
| full | 1 |
| partial | 15 |
| ui | 3（EPD_PART，菜单/对话框实验） |
| flashpartial / flashui | 11 |
| fast | 18 |
| a2 | 2 |
| screensaver | 不单独 post（不启用 102） |

### 2.2 原厂 gamma LUT

HWC 的 `init_gamma_table(sys.by.gammalevel)` 生成 256 项表，当前
`sys.by.gammalevel=14`：

- 低端 0..43 → 0；
- 高端 234..255 → 30；
- 中间按曲线输出偶数级 0,2,…,30。

驱动在 `_vendorInit` 里按同一公式建表；线性 `v>>3` 和原厂曲线不一致，会
影响文字/菜单的对比度和残影观感。

### 2.3 EBC buffer 生命周期与 frame timeout

`_vendorPost` 的流程是：

```
GET_BUFFER(0x7000) -> 写 8bpp 帧 -> SEND_BUFFER(0x7001)
```

`SEND_BUFFER` 只是把 buffer 放进内核队列并立即返回；内核 EBC 线程完成这一帧
后才把 buffer 放回空闲池。`DRAW_ENABLE/STOP` 是会话级的，**不是每帧开关**；
`DRAW_STOP` 只在 framebuffer close 时调用。

内核日志出现 `frame timeout.` 时，buffer 可能没有回到空闲池；下一次
`GET_BUFFER` 会永久阻塞在 `ebc_empty_buf_get`。KOReader 是单线程，主线程
一卡，输入/电源键就全部无响应，表现和“睡死”一样。

修复：

- `libnativeko-ebc.so` 用 `SIGALRM` 给 `GET_BUFFER`/`GET_STATUS` 加超时；
  超时后标记 EBC wedged，跳过后续刷新，主线程继续处理输入；
- resume 时重新 `DRAW_ENABLE` 并轮询 `GET_STATUS`，避免第一次刷新就
  timeout；
- helper 缺失时退回直接 ioctl，但会记录警告（APK 会内置 helper）。

如果 ioctl 本身不可中断，超时也无法返回；这种情况只能重启恢复。

## 3. 触摸

- `cyttsp5_mt` 是 MT-B（有 slot/tracking id）；不需要 `mt_a_touch_up`。
- raw 坐标已经是竖屏 1404×1872 方向：`touch_rotation: 0`，无需 swap/invert。
- `power_down_only`：gpio-keys 会发 down/up，只转发 down，避免一次按键 toggle
  两次。
- 唤醒时内核可能吃掉电源键事件；电源键状态机不能依赖按键来恢复 UI。

## 4. 电源与休眠

### 4.1 前置条件

- `/sys/power/state = freeze mem idle`；`mem` 是最省电的可用状态。
- `autosleep=off`；由 driver 显式写 `mem`。
- 停 framework 后仍会有冗余服务，必须停：

```
zygote, zygote_secondary, surfaceflinger,
boyuedrawserver, hwcomposer-2-1
```

`boyuedrawserver` 是博阅 EPD 服务，`hwcomposer-2-1` 在没有 SF 时也是冗余，
两者都可能和 `/dev/ebc` 竞争。

- `PowerManagerService.Display` 是 framework 停止后遗留的锁，必须在
  `pm_start`/driver 里释放。

### 4.2 已验证的 suspend

```
suspend begin lock=nativeko-<pid>
wake_lock before mem:            (空)
request mem
resumed state=mem
```

内核：

```
PM: suspend entry
Freezing user space processes ... done
PM: suspend exit
```

实测多次真实休眠（3s/8s/11s 等），唤醒后 session lock 重新拿回，Wi-Fi/USB
可用。

### 4.3 状态机（重要经验）

最初的实现有多个 busy 布尔量（`_suspend_in_progress`、`_resume_in_progress`、
`_resume_pending_wake`、合成 Resume、settle 定时器等），在“唤醒键被吃掉”或
“写 state 返回错误”时会卡死：后续电源键全被忽略。

最终收敛成一个显式状态：

```
awake --Power--> screensaver --2s--> suspending --driver返回--> resuming --> awake
  ^                    |
  |                    +--Power--> awake（取消还没开始的 suspend）
  +--Power（suspending/resuming 期间忽略）
```

- driver 返回后 **Device 主动执行 resume UI**，不依赖唤醒键；
- 唤醒键可能在内核 resume 后再次投递到用户态；resume 后只丢弃**一个**
  Power 事件（一次性，2s 安全解除），避免它把刚关闭的屏保重新打开；
- suspend 失败/中止（包括 `write("/sys/power/state")` 返回错误，但内核其实
  短暂进过 mem）→ 回到 `screensaver`，下一次按键只关屏保；
- 不做 USB/充电门禁：插线时也允许 suspend（未做专项充电测试）；
- 没有定时锁键窗口；busy 只覆盖真正的驱动调用和 resume 重绘。

### 4.4 写 state 的“失败”

`write("/sys/power/state", "mem")` 在 suspend 被立即唤醒/中止时可能返回
错误（EINTR/EBUSY），但 dmesg 仍能看到 entry/exit。驱动日志会显示
`state=nil`，这不是“完全没睡”，而是“这次写调用被中断”。按失败处理，
回屏保/不进入 resume-busy 即可。

## 5. 双色温前光

Alita 有两个独立背光节点：

- 冷：`/sys/class/backlight/rk28_bl/brightness`
- 暖：`/sys/class/backlight/rk28_bl_warm/brightness`

没有改 KOReader 通用 `device/generic/*`，只在 native 设备侧实现：

- profile：`power.frontlight` + `power.frontlight_warm`，
  `fl_warmth_min=0`、`fl_warmth_max=100`；
- `device.lua`：只有存在 warm 节点时才设
  `hasNaturalLight/hasNaturalLightMixer`；
- `device/native/powerd.lua`：按强度与 warmth 分配两个通道：
  `white = intensity*(100-pct)/100`、`warm = intensity*pct/100`；
- 保存/恢复 `frontlight_intensity` 与 `frontlight_warmth`；
- suspend 时两路都关，resume 恢复。

## 6. Wi-Fi

### 6.1 服务与控制通道

- init 服务：`wpa_supplicant`，实际启动
  `/vendor/bin/hw/wpa_supplicant /vendor/etc/wifi/wpa_config.txt`；
- 同时提供：
  - 全局 socket：`/dev/socket/wpa_wlan0`（命令需 `IFNAME=wlan0 ` 前缀）；
  - 每接口 socket：`/data/misc/wifi/sockets/wlan0`（本 profile 使用）。
- ROM **没有 dhcpcd/udhcpc/dhcpclient**；DHCP 用 Magisk busybox：
  `/data/adb/magisk/busybox udhcpc`，`udhcpc.sh` 安装 IP/路由/`net.dns1`。
- 实测：SSID、`wpa_state=COMPLETED`、IP `192.168.1.114/24`、默认路由、
  gateway/外网 ping 均正常。

### 6.2 SELinux 回包拦截

Android 8 的 wpa_supplicant 在 `hal_wifi_supplicant_default` 域，
KOReader 在 `magisk` 域。它会收下 `SCAN`，但回包被拒绝：

```
avc: denied { sendto }
  scontext=u:r:hal_wifi_supplicant_default:s0
  tcontext=u:r:magisk:s0
  tclass=unix_dgram_socket
```

`chcon` 客户端 socket 无效（peer 标签取进程域）；`runcon` 到 supplicant
域也被 exec 权限拒绝。最终用 profile 驱动的定向 allow：

```json
"selinux_allow": [
  "allow hal_wifi_supplicant_default magisk unix_dgram_socket sendto"
]
```

`wifi_up` 每次通过 `magiskpolicy --live` 应用（重启后自动补）。不要关闭
全局 SELinux。

### 6.3 DNS

framework 停止后没有 netd 的 dnsproxyd resolver 配置，`net.dns1` 属性不足
以让 bionic `getaddrinfo` 工作；`res_query` 也走代理。解决方式是一个
**LD_PRELOAD 的 `getaddrinfo` shim**（`platform/native/common/dns-resolver.c`）：

- 直接向 `KO_NATIVE_DNS`（profile `network.dns`，如 `223.5.5.5 1.1.1.1`）
  发 UDP/EDNS 查询；
- 支持 A/AAAA、数值地址、NULL node、service 端口；
- 只覆盖动态链接的 KOReader 进程，不依赖 netd/ndc；
- 32-bit shim 在构造函数里 `unsetenv("LD_PRELOAD")`，避免 64-bit 子进程
  `/system/bin/sh` 加载失败；
- profile 没有 `dns` 时不预加载，旧机型不受影响。

已验证：`getaddrinfo("www.baidu.com")` 返回成功；IP 连通、gateway/外网 ping
正常。域名解析通过 shim 工作。

## 7. 后台冗余进程

停 framework 后仍常驻、但对 native KOReader 基本冗余：

- 已加入 host stop：`zygote`、`zygote_secondary`、`surfaceflinger`、
  `boyuedrawserver`、`hwcomposer-2-1`
- 可进一步省电的候选：audio HAL/audioserver、bluetooth、cas、configstore、
  drm/Widevine、gatekeeper、hidl_memory、keymaster、light HAL、media codec/
  extractor/metrics、power HAL、sensors、tee-supplicant、thermalservice、
  tombstoned、wifi HAL/wificond/netd（不用 Android Wi-Fi/DNS 时）
- 建议保留：`adbd`（调试）、`magiskd`（root）、`logd`、`vold`/`storaged`、
  `lmkd`、servicemanager/hwservicemanager/vndservicemanager、`healthd`、
  `wpa_supplicant`（Wi-Fi）

## 8. 构建与安装

```sh
ADB=/mnt/c/tools/android-sdk/platform-tools/adb.exe \
  PROFILE_ID=alita bash platform/android/nativeko/build.sh
```

- profile id：`alita`；
- APK 内置默认 profile `alita`（构建时写入 `native/profile.id`）；
- 启动器图标为线条风 **NKO**，资源在
  `platform/android/nativeko/res/mipmap-*`；
- 首次启动解压 assets；用户数据仍在 `/sdcard/koreader`。

## 9. 已知问题/后续

- 刷新模式（1/15/11/18/2）仍按观感调优；可继续对比 EPD_PART(3)、
  EPD_ADAPTIVE(17)；
- DNS shim 是通用 userspace 方案，但对使用 VPN/Private DNS 的场景不适用；
- SELinux allow 规则按 profile 应用，依赖 Magisk 的 `magiskpolicy`；
- `udhcpc` 依赖 Magisk busybox；若要 APK 完全自包含，可内置静态 busybox；
- T65A 的 suspend 驱动已按 JDRead1 方案重写，但仍需在 T65A 实机复测；
- 锁屏 dither (102) 已禁用，避免额外全刷/滚动条。

## 10. 验证清单

- [x] `/dev/ebc` 8bpp 5-bit，白=0x1E
- [x] 原厂 gamma LUT (gammalevel=14)
- [x] 触摸方向/MT-B/按键
- [x] 双色温前光
- [x] `mem` 真实 suspend（dmesg entry/exit）
- [x] 停机服务：zygote_secondary/boyuedrawserver/hwcomposer
- [x] Wi-Fi 扫描/连接/DHCP
- [x] SELinux 回包 allow
- [x] DNS shim（getaddrinfo）
- [x] EBC GET_BUFFER 超时保护 + resume 重新初始化
- [x] APK 构建（profile.id=alita，线条 NKO 图标）并安装

## 11. 与 NoteSL/T65A 的兼容性

- `base/ffi/framebuffer_rk_ebc.lua` 的改动是 **纯新增、无删除**：
  - `ebc_vendor_post=false`（notesl 未设置）时仍走原来的 32bpp +
    `SEND_BUFFER(0x7001)` + `SEND_UPDATE(0x700c)` 路径；
  - vendor gamma/GET_BUFFER/模式映射只在 alita profile 打开；
  - `refreshScreensaver` 只在 `ebc_screensaver_mode=true` 时由 Device 调用，
    notesl 不设置。
- `notesl` profile 未改；`t65a` profile 保持 `power.model="none"`，
  screensaver-only。T65A 的 early-suspend 驱动仍保留在仓库里，但未启用，
  等实机复测后再打开。
- 电源状态机（`Device:suspend/onPowerEvent`）是**所有 native 设备共用**的
  重写：driver 返回后由 Device 主动恢复 UI。NoteSL 的 suspend 行为需要
  在 NoteSL 实机上做一次回归测试（显示后端不受影响）。
- DNS shim 只在 profile 配置了 `network.dns` 时预加载；`udhcpc` 只在
  `dhcp_kind="udhcpc"` 时启用；双色温只在 `frontlight_warm` 存在时启用。
