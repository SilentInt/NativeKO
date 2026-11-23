# Onyx NoteS / 文石 NoteSL 适配记录

设备：Onyx NoteS / NoteSL（文石）。系统上报为 NoteS，1200×825 EBC 面板。
本文记录 NativeKO 在这台机器上的休眠、Wi-Fi 和恢复路径结论。

> **不要和 K103 混淆。** K103 是博阅 Likebook Alita（RK3368、1872×1404、
> Android 8.1），见 [`K103_ALITA.md`](K103_ALITA.md)。NoteSL 是 RK3288、
> 1200×825、Android 6.0.1、kernel 3.10 的另一台设备。

## 1. 硬件与 profile

| 项目 | 值 |
|---|---|
| SoC | Rockchip RK3288 |
| 系统 | Android 6.0.1（kernel 3.10） |
| 面板 | 1200×825 |
| 显示 | `/dev/ebc` 直显，32bpp，stride 4800 |
| 触摸 | 原始轴交换 + X 镜像（`touch_swap_xy` + `touch_invert_x`） |
| Wi-Fi | bcmdhd，SDIO，内置驱动（无独立 `.ko`） |
| PM | `/sys/power/state = freeze standby mem`，`android_wakeup_count` |
| profile | `platform/native/profiles/notesl/profile.json` |

显示后端和 EBC 协议见 [`RK_EBC.md`](RK_EBC.md)。NoteSL 使用
`SEND_BUFFER` + `SEND_UPDATE`，不是 K103 的 vendor `GET_BUFFER` 路径。

## 2. 休眠模型

NoteSL 使用：

```json
"power": {
  "model": "android_wakeup_count",
  "suspend_state": "mem",
  "suspend_fallback": "standby",
  "suspend_wait_timeout": 2,
  "wifi_keep_on_suspend": true
}
```

流程：

```
awake --Power--> screensaver --2s--> suspending --driver 返回--> resuming --> awake
```

- session 持有 `nativeko-<pid>` wake lock；
- 驱动释放 framework 锁和 session lock 后写 `mem`；
- 唤醒后重新获取 session lock，Device 主动执行 resume UI；
- resume 后 1.5 秒内忽略 Power 事件，避免唤醒键回声再次进屏保；
- 没有任何 RTC 唤醒闹钟或测试 watchdog。

### 2.1 不要解绑 SDIO / 不要卸载 bcmdhd

NoteSL 的 bcmdhd 是内置驱动。实测两条“清理”路径都会让内核 panic：

1. **卸载/解绑 SDIO**：

   ```
   sdioh_remove -> sdioh_detach -> sdio_disable_func
   Kernel panic - not syncing: Fatal exception in interrupt
   ```

2. **mem 后重新 `ip link set wlan0 up`**：

   ```
   dhd_open -> wl_android_wifi_on -> sdio_reset_comm -> mmc_go_idle
   Unable to handle kernel paging request
   Kernel panic - not syncing: Fatal exception
   ```

因此当前 profile：

- **没有** `suspend_unbind`；
- **没有** `suspend_unload`；
- 不在 suspend 时 `wifi_unload`；
- `wifi_keep_on_suspend = true`，避免 resume 后 `dhd_open`。

这是用户态 workaround。要彻底解决，需要修 bcmdhd/SDIO 的 suspend/resume
路径，而不是继续在 shell 里 unbind/rmmod。

## 3. Wi-Fi

NoteSL 的 supplicant 只暴露全局 socket：

```
/dev/socket/wpa_wlan0
```

profile：

```json
"network": {
  "start_on_boot": true,
  "service": "wpa_supplicant",
  "service_prop": "init.svc.wpa_supplicant",
  "ctrl_interface": "/dev/socket/wpa_wlan0",
  "wpa_global": true,
  "wpa_ifname": "wlan0",
  "dhcp_cmd": "/system/bin/dhcpcd"
}
```

- 启动时后台执行 `wifi_up`，不阻塞 KOReader；
- 成功的 `authenticateNetwork` 会在 native 侧补 `SAVE_CONFIG`，写入
  `/data/misc/wifi/wpa_supplicant.conf`；
- 启动/resume 后自动做一次非交互式
  `reconnectOrShowNetworkMenu(nil, false)`，使用 KOReader 保存的网络；
- `wifi_up` 幂等：supplicant 已运行时不重复 stop/start；只有会话启动时
  强制重启一次；
- resume 后 `restoreWifiAsync()` + `scheduleConnectivityCheck()`，同步
  `NetworkConnected`、`wifi_was_on` 和 `lease_ssid`。

### 3.1 扫描限制

NoteSL 只有全局 supplicant socket，没有 per-interface
`/data/misc/wifi/sockets/wlan0`。KOReader 的扫描依赖 `ATTACH` + scan event，
在这条全局 socket 上可能很慢或拿不到完整列表。自动连接保存网络不依赖扫描，
所以启动/resume 仍能连上。

## 4. 唤醒路径与诊断

`Device:_resumeUI` 的步骤日志：

```
resumeUI begin
resumeUI driver resume begin/returned
resumeUI screensaver close begin/returned
resumeUI full refresh scheduled/begin/returned
resumeUI afterResume begin/returned
resumeUI end
resume UI finished
```

Resume 广播（`UIManager:broadcastEvent`）会记录每个 handler 的
`begin/returned`，用于区分 `book_desktop`、screensaver widget 等。

已知结论：

- NoteSL 的 `mem`/resume 本身可以完成；
- 不要用 SDIO unload 或重新 `ip link up` 来“修复”Wi-Fi，否则会 panic；
- Wi-Fi OOB 不计入有效的 `wakeup_count`；RTC `wakealarm` 为空；
- `alarmtimer` 为 0，没有残留定时器唤醒证据。

## 5. 验证清单

- [x] `/dev/ebc` 32bpp，stride 4800，1200×825
- [x] 触摸交换 + X 镜像
- [x] `android_wakeup_count` + `mem` suspend/resume
- [x] 不在 suspend 解绑 SDIO / 不卸载 bcmdhd
- [x] `wifi_keep_on_suspend = true`
- [x] 启动自动 Wi-Fi，保存网络后自动重连
- [x] resume 后 `restoreWifiAsync` + connectivity check
- [x] 无 RTC/alarmtimer 唤醒
- [x] asset 37 实机测试：无重启，Wi-Fi 恢复
- [ ] 连续多轮 suspend/resume 稳定性复测
- [ ] 如需真正修 bcmdhd/SDIO resume，需要内核/driver 侧工作

## 6. 相关文档

- [`README.md`](README.md) — 框架、profile 字段
- [`PORTING.md`](PORTING.md) — 移植步骤
- [`RK_EBC.md`](RK_EBC.md) — Rockchip EBC 显示协议
- [`K103_ALITA.md`](K103_ALITA.md) — 博阅 Alita K103，另一台设备
