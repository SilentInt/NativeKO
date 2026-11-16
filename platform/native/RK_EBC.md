# Rockchip EBC 电子墨水屏移植与探测

本文记录 **Rockchip EBC（E-Book Controller）直显缓冲** 这一类 RK 电子墨水设备的
通用驱动方式。它不是某一个机型的私有做法：任何把扫描缓冲暴露在 `/dev/ebc` 的
RK29/RK30/RK3288 设备都可以按同样步骤探测、标定并接入 NativeKO。

已验证参考机型：**Onyx NoteS / 超星 NoteSL（RK3288，Android 6.0.1，kernel 3.10）**。

---

## 1. 已验证机型的关键信息

| 项目 | 值 |
|---|---|
| 设备 | Onyx NoteS / 超星 SP_NoteSL（系统为 NoteS 6199） |
| SoC | Rockchip RK3288 |
| CPU | 4× ARM Cortex-A17（ARMv7，`CPU part 0xc0d`，NEON/VFPv4） |
| 内核 | `Linux 3.10.0 #1 SMP PREEMPT Mon Nov 2 16:45:12 CST 2020` |
| Android | 6.0.1 / API 23 / armeabi-v7a |
| 面板 | 1200×825（9.7"，约 150–160 dpi），16 级灰度 |
| 显示节点 | `/dev/graphics/fb0`（32bpp，stride 4800，virtual 1200×4125）+ `/dev/ebc` |
| EBC 驱动 | `K29_EBC_DRIVER_VERSION_1.00`（Onyx `onyx_epdc` 系列） |
| 面板旋转 | `GET_EBC_BUFFER_INFO.rotate = 270` |
| 直显缓冲 | `/dev/ebc` mmap，1200×825，**32bpp**，stride **4800**，offset 0 |
| buffer → 竖屏映射 | buffer 左上角 → 竖屏**右上角**（90° CW）；buffer 左下角 → 竖屏左上角 |
| 触摸 | `fts_ts`，MT-B，slot、tracking id、BTN_TOUCH 完整，范围 1200×825 |
| 电源键 / 返回键 | `rk29-keypad`，KEY_POWER=116，KEY_WAKEUP=143，KEY_BACK=158 |
| 电池 | `/sys/class/power_supply/battery/{capacity,status}` |
| Wi-Fi | `bcmdhd`（内建），`wlan0`，`wpa_supplicant` + `dhcpcd` |
| 无 BusyBox | 只有 toybox；NativeKO 用 `/system/bin/toybox` 作为 `$BB` |

> 注意：这台机器是“SP_NoteSL 的 boot/kernel + NoteS 的 system”的混刷状态，
> 内核与 system 不完全配套；`/sys/class/backlight` 为空、`lm3630a` 未绑定驱动，
> 所以前光在 NativeKO 中暂时不可控。EBC 显示不受影响。

---

## 2. 两种 RK EBC 驱动模型

RK 电子墨水设备常见两种显示路径，移植前必须先判断是哪一种：

### 2.1 fbdev + EBC 更新（i.MX 风格 / 部分 RK）

- 应用写 `/dev/graphics/fb0`（或 `/dev/fb0`），再通过 `/dev/ebc` 的
  `SET_EBC_SEND_UPDATE` 触发区域刷新。
- 早期 T65A（i.MX6 EPDC）属于这一类。
- 在 NoteSL 上，仅写 fb0 + `SEND_UPDATE` **不会**让面板更新；fb0 不是 EBC
  直显缓冲。

### 2.2 EBC 直显缓冲（本文重点）

- 面板扫描的是 `/dev/ebc` mmap 出来的缓冲，fb0 只是 Android compositor 的
  中间层。
- 应用直接 `mmap /dev/ebc`、往缓冲里画、用 `SET_EBC_SEND_BUFFER` 提交当前
  缓冲，再用 `SET_EBC_SEND_UPDATE` 驱动面板。
- 不需要 SurfaceFlinger / hwcomposer；NativeKO 用这种模型可以完全接管刷新。
- NoteSL 的直显缓冲是 **32bpp、stride = width×4**，不是老 Rockchip
  `software_ebc` 自动图像路径的 4bpp。用 4bpp 只会覆盖靠边的一条。

判断方法：跑 `rk-ebc-probe info`，再按第 4 节做 bpp/stride 标定。

---

## 3. EBC ioctl 与结构体

命令号是 **裸整数**（不是 `_IOW` 编码），部分厂商会整体偏移；NativeKO 的
profile 用 `ebc_cmd_*` 字段覆盖。

| 命令 | 值 | 说明 |
|---|---|---|
| `GET_EBC_BUFFER` | `0x7000` | 取一个空闲 buffer；填 `offset` + 几何。可能阻塞。 |
| `SET_EBC_SEND_BUFFER` | `0x7001` | 提交/重提当前 buffer 和窗口。 |
| `GET_EBC_DRIVER_SN` | `0x7002` | 返回驱动版本字符串（如 `K29_EBC_DRIVER_VERSION_1.00`）。 |
| `GET_EBC_BUFFER_INFO` | `0x7003` | 返回几何；`offset`/`epd_mode` 可能未初始化。 |
| `SET_EBC_SEND_UPDATE` | `0x700c` | 按矩形/波形驱动面板。 |

### 3.1 `struct ebc_buf_info`（14×int32，`__packed`）

```
offset, epd_mode, height, width, vir_height, vir_width,
fb_width, fb_height, color_panel, win_x1, win_y1, win_x2, win_y2, rotate
```

- `offset`：相对 `/dev/ebc` mmap 基址的 **字节偏移**。
- `epd_mode`：`SET_EBC_SEND_BUFFER` 的刷新模式（见 3.2）。
- `win_x1/y1/x2/y2`：窗口（像素坐标，x2/y2 为包含端点）。
- `rotate`：面板相对缓冲的旋转（NoteSL 为 270）。

### 3.2 `epd_refresh_mode`（`epd_mode`）

```
0  EPD_AUTO        1  EPD_FULL       2  EPD_A2
3  EPD_PART        4  EPD_FULL_DITHER
5  EPD_RESET       6  EPD_BLACK_WHITE
7  EPD_BG          8  EPD_BLOCK      9  EPD_FULL_WIN
10 EPD_OED_PART    11 EPD_DIRECT_PART 12 EPD_DIRECT_A2
16 EPD_AUTO_BG
```

NoteSL 上使用 `EPD_FULL = 1`。

### 3.3 `struct ebc_send_update`（10×int32，`0x28` 字节）

```
rect[4]; waveform_mode; update_mode; update_marker;
unknown_1c; flags; unknown_24;
```

- **rect 顺序**：rk29 驱动是 `{ y, x, w, h }`（注意不是 x,y）。profile 的
  `ebc_rect_order` 可设为 `"yxwh"` 或 `"xywh"`。
- `waveform_mode`：2=GC16，1=DU，6=REAGL（不同驱动可能不同）。
- `update_mode`：0=局部，1=闪烁/全刷。
- `update_marker`：每次提交递增，不能复用。
- `unknown_1c`：NoteSL 用 `0x1000`；某些驱动是温度/延迟，需实测。
- `flags`：NoteSL 用 `0x21000`；不同驱动/波形可能不同。

---

## 4. 探测与标定流程

### 4.1 采集设备信息

```sh
cat /proc/cpuinfo
cat /proc/version
getprop ro.product.model
getprop ro.product.device
getprop ro.build.version.release
getprop ro.build.version.sdk
cat /proc/bus/input/devices
getevent -pl            # 如有
ls -l /dev/ebc /dev/graphics/fb0
cat /proc/misc
for f in /sys/class/graphics/fb0/*; do
    [ -f "$f" ] && echo -n "$f=" && cat "$f" 2>/dev/null | head -c 200 && echo
done
ls /sys/class/backlight /sys/class/power_supply
getprop | grep -E 'init.svc|wifi|wpa'
```

### 4.2 只读探针

零编译的只读信息采集：

```sh
adb push platform/native/tools/rk-ebc-env.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/rk-ebc-env.sh'
```

它会打印 CPU/内核/显示节点/fb0 属性/输入/电源/Wi-Fi/init 服务/工具路径。

EBC buffer/刷新检查（需要交叉编译）：

```sh
# 在主机上编译
ADB=/path/to/adb bash platform/native/tools/build-rk-ebc-probe.sh
adb push platform/native/tools/rk-ebc-probe /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/rk-ebc-probe'

adb shell su -c '/data/local/tmp/rk-ebc-probe info'
adb shell su -c '/data/local/tmp/rk-ebc-probe hist'
```

`info` 会打印：CPU/内核摘要、fb0 的 virtual_size/stride/bpp/rotate、
`/proc/misc`、EBC 驱动版本、buffer 几何、GET_BUFFER 结果、输入设备。
`hist` 会对 `/dev/ebc` mmap 的每 1MB 区域做字节直方图，帮助判断
“全是 0 / 全白 / 有真实内容”。

> `GET_BUFFER` 如果输出 `BLOCKED`，说明 EBC 内核线程卡住（`epdc_eink_refre`
> 处于 D 状态时要 `down` 信号量）。**重启设备后再试**；不要继续发 EBC ioctl。

### 4.3 停止 framework

```sh
adb shell su -c 'for s in zygote surfaceflinger media drm installd keystore ril-daemon; do
    setprop ctl.stop $s
done'
```

确认 `ps | grep -E 'zygote|surfaceflinger|system_server|com.onyx'` 为空。

### 4.4 标定 bpp / stride

`pattern` 会先 `memset` 整个 8MB mmap 为白，再按给定 bpp/stride 画图案，
`SEND_BUFFER + SEND_UPDATE` 提交。观察面板：

```sh
# 32bpp RGBA，stride = width*4
rk-ebc-probe pattern 32 4800 stripes
rk-ebc-probe pattern 32 4800 black
rk-ebc-probe pattern 32 4800 white

# 若只出现靠边一条/局部，依次试：
rk-ebc-probe pattern 16 2400 stripes
rk-ebc-probe pattern 8  1200 stripes
rk-ebc-probe pattern 4  600  stripes
```

判断：

- **整屏图案** → bpp/stride 正确。
- **靠边一条 / 只有一侧** → stride 太小（驱动按更大 bpp 读）。继续加大 bpp。
- **花屏/重复** → stride 太大或像素顺序不同。
- **整屏全白但图案不对** → bpp/stride 基本对，检查旋转/镜像/像素格式。

### 4.5 标定方向/镜像

```sh
rk-ebc-probe pattern 32 4800 corner 0   # buffer (0,0)
# 依次 1=右上、2=左下、3=右下
```

记录 buffer 的四个角在竖屏上分别出现在哪个角。NoteSL 的结果：

- buffer (0,0) → 竖屏**右上**
- buffer (0,H-1) → 竖屏**左上**

这等价于面板把 buffer **顺时针旋转 90°**。KOReader 侧用：

```json
"portrait": true,
"touch_rotation": 0,
"input": {
  "quirks": ["touch_swap_xy", "touch_invert_x"],
  "touch_max_x": 1200,
  "touch_max_y": 825
}
```

`is_always_portrait` 会对横向 buffer 做 `bb:rotate(-90)`，正好得到同样的
逻辑→buffer 映射。

**触摸方向要单独标定**：NoteSL 的触摸 raw 轴与逻辑坐标是「交换 + 反转 x」
（不是标准的 rotation 1/3，后者还会在另一个轴上加反转）。原生后端的
`getTouchRotation()` 按 KOReader 惯例返回
`(当前UI旋转 + touch_rotation) % 4`；纯交换/镜像由 `input.quirks` 处理：

- `touch_swap_xy`：交换 raw X/Y；
- `touch_invert_x` / `touch_invert_y`：在交换后的坐标上反转对应轴；
- `touch_max_x` / `touch_max_y`：raw 轴的最大值（用于反转）。

标准 rotation 能覆盖的机型直接用 `touch_rotation: 1/2/3`，不要同时用
swap quirk。方向必须用 `corner` 图案 + 实际点击验证；只测显示不算数。

### 4.6 生成 profile

```json
"display": {
  "backend": "rk_ebc",
  "portrait": true,
  "touch_rotation": 0,
  "dpi": 160,
  "can_hw_invert": false,
  "can_hw_dither": false,
  "ebc_device": "/dev/ebc",
  "ebc_width": 1200,
  "ebc_height": 825,
  "ebc_bpp": 32,
  "ebc_stride": 4800,
  "ebc_offset": 0,
  "ebc_rotate": 0,
  "ebc_enabled": true,
  "ebc_send_initial": true,
  "ebc_send_buffer_each": true,
  "ebc_epd_mode": 1,
  "ebc_cmd_send_buffer": 28673,
  "ebc_cmd_send_update": 28684,
  "ebc_rect_order": "yxwh",
  "ebc_waveform_full": 2,
  "ebc_update_mode_full": 1,
  "ebc_waveform_partial": 2,
  "ebc_update_mode_partial": 0,
  "ebc_waveform_fast": 1,
  "ebc_update_mode_fast": 0,
  "ebc_flags": 135168,
  "ebc_unknown_1c": 4096
},
"input": {
  "quirks": ["power_down_only", "touch_swap_xy", "touch_invert_x"],
  "touch_max_x": 1200,
  "touch_max_y": 825
}
```

> JSON 里命令号要写十进制：`0x7001=28673`，`0x700c=28684`。

完整 profile 见 `profiles/notesl/profile.json`。

---

## 5. NativeKO 中的显示后端

- 模块：`base/ffi/framebuffer_rk_ebc.lua`
- profile `display.backend`：`rk_ebc`（旧的 `onyx_ebc` 也兼容，会映射到同一模块）
- 设备侧选择：`frontend/device/native/device.lua` 的 `getFramebufferModule()`

后端行为：

1. `open(ebc_device)` + `mmap`（`ebc_width × ebc_height × bpp/8`）。
2. 用 `BB.new(..., stride, width)` 把 EBC 直显缓冲映射成 KOReader 的屏幕
   blitbuffer；`is_always_portrait` 负责横屏 buffer → 竖屏逻辑。
3. `SET_EBC_SEND_BUFFER` 提交当前缓冲（`ebc_epd_mode`）。
4. `SET_EBC_SEND_UPDATE` 按逻辑矩形转换后的物理矩形驱动面板
   （`ebc_rect_order`、波形、update_mode、marker、flags）。
5. 首次启动先填白并做一次全刷，避免残留画面。

可调字段：

- `ebc_send_buffer_each`：每次刷新都重提 buffer。NoteSL 上为 `true`；
  如果某机型局部刷新不需要重提，可设 `false` 降低开销。
- `ebc_send_initial`：初始化时是否清屏+全刷。
- `ebc_waveform_*` / `ebc_update_mode_*`：全刷/局部/快速刷新的波形和模式。
- `ebc_flags` / `ebc_unknown_1c`：驱动相关；先用参考值，再逐项调。
- `ebc_enabled`：`false` 时只画缓冲、不发 ioctl（用于对照/调试）。

---

## 6. 电源键、前光、Wi-Fi

EBC 直显只负责屏幕，不改变 NativeKO 的其它行为：

- 电源键仍由 `frontend/device/native/device.lua` 的 `onPowerEvent()` 处理：
  屏保显示/关闭、前光、Wi-Fi、`canSuspend=no`。
- 前光：本机 `lm3630a` 未绑定驱动、`/sys/class/backlight` 为空，profile 里
  `power.frontlight` 留空；有 sysfs 的机型填实际路径即可。
- Wi-Fi：`wpa_supplicant_android` 驱动；本机 `bcmdhd` 内建，无需 insmod。
  无 BusyBox 的机型把 `tools.busybox` 指向 `/system/bin/toybox`。

---

## 7. 常见问题

- **只有靠边一条/局部显示**：bpp/stride 不对。NoteSL 必须用 32bpp/4800，
  不是 4bpp/600。
- **整屏黑**：先 `pattern 32 4800 white`；若全白则格式对，问题在刷新参数/
  波形。若仍黑，检查 EBC 线程是否卡死（重启）。
- **图案旋转/镜像**：用 `corner` 标定，调整 `portrait`/`touch_rotation`/
  `ebc_rotate`。
- **显示方向对但触摸错**：先试 `touch_rotation` 1/3；若是「纯交换」，
  用 `input.quirks` 的 `touch_swap_xy` + `touch_invert_x`/`touch_invert_y`。
  NoteSL 最终是 `swap_xy + invert_x`。
- **`GET_BUFFER` 阻塞**：`epdc_eink_refre` 线程卡在 D 状态；重启后先停
  SurfaceFlinger，再按顺序测试，不要先跑多个会卡线程的 ioctl。
- **SurfaceFlinger 竞争**：直显模式下必须停 framework；否则 SF 会覆盖缓冲。
- **fb0 + SEND_UPDATE 无效**：很多 RK EBC 直显机型走 `/dev/ebc`，不是 fb0。
  `RK_FBIOSET_CONFIG_DONE (0x4628)` 只把 fb0 拷进 software EPDC，
  不保证刷新；NativeKO 直接走 EBC 缓冲。
- **command 号偏移**：不同 BSP 可能是 0x7000 基址的其他编号；用
  `rk-ebc-probe` 和 `ebc_cmd_*` 覆盖。
- **`offset`/`epd_mode` 是垃圾值**：`GET_EBC_BUFFER_INFO` 不初始化它们；
  用 `GET_BUFFER` 的 `offset` 或 profile 的 `ebc_offset`。
- **重启恢复**：测试期间随时 `adb reboot`；Android 会正常启动。

---

## 8. 移植检查清单

- [ ] 记录 CPU/SoC、内核、Android 版本、面板分辨率/旋转
- [ ] `ls /dev/ebc /dev/graphics/fb0`，确认直显节点
- [ ] `rk-ebc-probe info` 读到驱动版本、几何、`rotate`
- [ ] 停 framework，`rk-ebc-probe pattern` 标定 bpp/stride（32/16/8/4）
- [ ] `corner` 标定方向，确定 `portrait`/`touch_rotation`/`ebc_rotate`
- [ ] 实际点击验证触摸；必要时用 `touch_swap_xy`/`touch_invert_x/y`
- [ ] 写入 profile，`profilegen.py` 生成 `profile.env/lua`
- [ ] KOReader 首屏、翻页、局部刷新、屏保/电源键、触摸方向
- [ ] 退出后 Android 正常恢复（`session.sh` trap 或 reboot）
- [ ] 记录该机型的 EBC 命令号/结构差异（如果有）

---

## 9. 参考

- `platform/native/PORTING.md` — NativeKO 通用移植流程
- `platform/native/profiles/notesl/profile.json` — 本文参考 profile
- `base/ffi/framebuffer_rk_ebc.lua` — 直显后端实现
- `platform/native/tools/rk-ebc-probe.c` — 探测/标定工具
- `platform/native/tools/rk-ebc-env.sh` — 零编译只读环境采集
- Rockchip 公开 EBC 驱动（rk29_ebc / software_ebc）与 Supernote 公开的
  `drivers/gpu/drm/rockchip/eink/` 头文件：`struct ebc_buf_info`、
  `EPD_*` 模式、`ebc_buf_s` 缓冲管理
- `spavikevik/palma2pro-eos`（更新一代 Onyx EBC 的文档与工具）
