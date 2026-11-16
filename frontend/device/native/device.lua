-- Profile-driven native (framebuffer/evdev) device backend.
--
-- Device data lives in a generated profile.lua (platform/native/profiles/<id>),
-- selected through KO_NATIVE_PROFILE by platform/native/core/session.sh. This
-- module only wires that data into KOReader, so adding a device is a profile
-- plus, if needed, a display/host/wifi driver.

local Generic = require("device/generic/device")
local logger = require("logger")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local C = ffi.C
require("ffi/linux_input_h")

local profile_path = os.getenv("KO_NATIVE_PROFILE")
if not profile_path or profile_path == "" then
    error("device/native: KO_NATIVE_PROFILE is not set")
end
local P = dofile(profile_path)
local native_dir = os.getenv("KO_NATIVE_DIR") or "/data/local/tmp/nativeko"
local profile_id = P.id or "native"

local function yes() return true end
local function no() return false end

-- bionic API 19 has no getifaddrs(); use the device's ip/ping tools for the
-- network checks and the network info dialog.
local function run_cmd(cmd)
    local p = io.popen(cmd, "r")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    return out
end

local pw = P.power or {}
local disp = P.display or {}
local net = P.network or {}
local host = P.host or {}
local inp = P.input or {}
local paths = P.paths or {}
local tools = P.tools or {}
local ip_cmd = tools.ip or "/system/bin/ip"
local ping_cmd = tools.ping or "/system/bin/ping"
local setsid_cmd = tools.setsid or "setsid"
local getprop_cmd = tools.getprop or "getprop"

local has_frontlight = pw.frontlight ~= nil and pw.frontlight ~= ""
local has_network = net.manage == true

local Device = Generic:extend{
    model = P.model or ("Native e-ink (" .. profile_id .. ")"),
    isTouchDevice = yes,
    hasMultitouch = yes,
    hasKeys = yes,
    hasDPad = no,
    hasEinkScreen = yes,
    hasColorScreen = no,
    canHWInvert = (disp.can_hw_invert ~= false) and yes or no,
    canHWDither = (disp.can_hw_dither ~= false) and yes or no,

    hasFrontlight = has_frontlight and yes or no,
    hasNaturalLight = no,
    hasNaturalLightMixer = no,
    frontlight_settings = has_frontlight and { frontlight_white = pw.frontlight } or nil,

    hasWifiManager = has_network and yes or no,
    hasWifiToggle = has_network and yes or no,
    hasWifiRestore = has_network and yes or no,
    hasFastWifiStatusQuery = no,
    hasSeamlessWifiToggle = no,

    hasOTAUpdates = no,
    hasExitOptions = yes,
    canSuspend = (pw.model and pw.model ~= "none") and yes or no,
    canPowerOff = yes,
    canReboot = no,
    needsScreenRefreshAfterResume =
        (disp.needs_refresh_after_resume == true) and yes or no,
    suspend_wait_timeout = pw.suspend_wait_timeout or 1,

    display_dpi = disp.dpi or 300,
    home_dir = paths.home_dir or "/sdcard/Books",
}

-- ffi/framebuffer_mxcfb.lua selects the i.MX6 EPDC ABI from this flag; the
-- profile decides which variant (if any) applies.
function Device:isT65A()
    return (disp.mxcfb_variant or "") == "t65a"
end

-- The display backend is selected by the profile, so porting to a device with
-- a different e-ink controller does not require editing this file.
local function getFramebufferModule()
    local backend = disp.backend or "mxcfb"
    if backend == "rk_ebc" or backend == "onyx_ebc" then
        return "ffi/framebuffer_rk_ebc"
    elseif backend == "linux" or backend == "fbdev" then
        return "ffi/framebuffer_linux"
    end
    return "ffi/framebuffer_mxcfb"
end

function Device:init()
    local backend = disp.backend or "mxcfb"
    -- Rockchip EBC drives the panel from /dev/ebc's own buffer, not fb0.
    local device_node = disp.fb or "/dev/graphics/fb0"
    if backend == "rk_ebc" or backend == "onyx_ebc" then
        device_node = disp.ebc_device or "/dev/ebc"
    end
    self.screen = require(getFramebufferModule()):new{
        device = self,
        debug = logger.dbg,
        device_node = device_node,
        is_always_portrait = disp.portrait == true,
        -- Rockchip EBC direct-buffer geometry and refresh tuning.
        ebc_width = disp.ebc_width,
        ebc_height = disp.ebc_height,
        ebc_bpp = disp.ebc_bpp,
        ebc_stride = disp.ebc_stride,
        ebc_offset = disp.ebc_offset,
        ebc_rotate = disp.ebc_rotate,
        ebc_enabled = disp.ebc_enabled,
        ebc_send_buffer_each = disp.ebc_send_buffer_each,
        ebc_send_initial = disp.ebc_send_initial,
        ebc_cmd_send_buffer = disp.ebc_cmd_send_buffer,
        ebc_cmd_send_update = disp.ebc_cmd_send_update,
        ebc_epd_mode = disp.ebc_epd_mode,
        ebc_rect_order = disp.ebc_rect_order,
        ebc_waveform_full = disp.ebc_waveform_full,
        ebc_update_mode_full = disp.ebc_update_mode_full,
        ebc_waveform_partial = disp.ebc_waveform_partial,
        ebc_update_mode_partial = disp.ebc_update_mode_partial,
        ebc_waveform_fast = disp.ebc_waveform_fast,
        ebc_update_mode_fast = disp.ebc_update_mode_fast,
        ebc_flags = disp.ebc_flags,
        ebc_unknown_1c = disp.ebc_unknown_1c,
    }

    -- KOReader convention (c.f. PocketBook): the total touch rotation is the
    -- current UI rotation plus the panel's raw-touch offset.  A raw-axis
    -- swap/invert is handled separately by the input quirks below.
    G_reader_settings:saveSetting("closed_rotation_mode", 0)
    self.screen.getTouchRotation = function()
        return (4 + self.screen:getRotationMode()
                    + (disp.touch_rotation or 0)) % 4
    end

    self.powerd = require("device/native/powerd"):new{
        device = self,
        profile = P,
    }

    -- Hardware suspend driver (profile power.model).  "none" keeps the
    -- screensaver-only behaviour.
    if pw.model and pw.model ~= "none" then
        local ok, suspend_driver = pcall(require,
            "device/native/suspend/" .. pw.model)
        if ok and suspend_driver then
            self.suspend_driver = suspend_driver
        else
            logger.warn("device/native: cannot load suspend driver",
                        pw.model, suspend_driver)
        end
    end

    local event_map = {}
    for code, name in pairs(inp.keys or {}) do
        event_map[tonumber(code)] = name
    end
    self.input = require("device/input"):new{
        device = self,
        event_map = event_map,
    }
    for _, dev in ipairs(inp.devices or {}) do
        self.input:open(dev)
    end

    local quirks = {}
    for _, q in ipairs(inp.quirks or {}) do
        quirks[q] = true
    end

    if quirks.power_down_only then
        -- gpio-keys reports KEY_POWER down and up; Device:onPowerEvent()
        -- treats every event as a toggle, so only forward the key-down.
        self.input.event_map_adapter["Power"] = function(ev)
            if ev.value == 1 then
                return "Power"
            end
        end
    end

    if quirks.mt_a_touch_up then
        -- goodix-ts (MT protocol A) sends BTN_TOUCH UP without
        -- ABS_MT_TRACKING_ID = -1; end the current slot ourselves.
        self.input.event_map[C.BTN_TOUCH] = "TouchUp"
        self.input.event_map_adapter["TouchUp"] = function(ev)
            if ev.value == 0 then
                self.input:setCurrentMtSlotChecked("id", -1)
            end
        end
    end

    -- Some panels report raw axes that are transposed or mirrored relative to
    -- the framebuffer.  The standard rotation modes cannot express a pure
    -- swap (they always invert one axis), so allow a profile-driven transform
    -- on ABS_X/ABS_MT_POSITION_* before KOReader sees the events.
    if quirks.touch_swap_xy or quirks.touch_invert_x or quirks.touch_invert_y then
        local max_x = inp.touch_max_x or disp.ebc_width or 1200
        local max_y = inp.touch_max_y or disp.ebc_height or 825
        local swap = quirks.touch_swap_xy and true or false
        local inv_x = quirks.touch_invert_x and true or false
        local inv_y = quirks.touch_invert_y and true or false
        local orig_handle_touch = self.input.handleTouchEv
        self.input.handleTouchEv = function(input, ev)
            if ev.type == C.EV_ABS then
                if ev.code == C.ABS_MT_POSITION_X or ev.code == C.ABS_X then
                    if swap then
                        ev.code = (ev.code == C.ABS_MT_POSITION_X)
                            and C.ABS_MT_POSITION_Y or C.ABS_Y
                        -- the value becomes the new y axis, range max_x
                        if inv_y then ev.value = max_x - ev.value end
                    elseif inv_x then
                        ev.value = max_x - ev.value
                    end
                elseif ev.code == C.ABS_MT_POSITION_Y or ev.code == C.ABS_Y then
                    if swap then
                        ev.code = (ev.code == C.ABS_MT_POSITION_Y)
                            and C.ABS_MT_POSITION_X or C.ABS_X
                        -- the value becomes the new x axis, range max_y
                        if inv_x then ev.value = max_y - ev.value end
                    elseif inv_y then
                        ev.value = max_y - ev.value
                    end
                end
            end
            return orig_handle_touch(input, ev)
        end
        logger.info("device/native: touch transform",
                    swap and "swap" or "keep",
                    inv_x and "inv-x" or "", inv_y and "inv-y" or "")
    end

    -- After suspend/resume the touch controller can deliver a frame that has
    -- a tracking/slot id but no coordinates yet.  Feed the gesture detector
    -- only complete frames: an active slot without x/y would otherwise crash
    -- Contact:getPath (e.g. "attempt to perform arithmetic on field 'x'").
    do
        local inner_handle_touch = self.input.handleTouchEv
        self.input.handleTouchEv = function(input, ev)
            if ev.type == C.EV_SYN and ev.code == C.SYN_REPORT then
                local incomplete = false
                for _, slot in pairs(input.MTSlots or {}) do
                    if slot.id ~= nil and slot.id ~= -1
                        and (slot.x == nil or slot.y == nil) then
                        incomplete = true
                        break
                    end
                end
                if incomplete then
                    input:newFrame()
                    return
                end
            end
            return inner_handle_touch(input, ev)
        end
    end

    logger.info("device/native: profile", profile_id)
    Generic.init(self)
end

function Device:initNetworkManager(NetworkMgr)
    if not has_network then
        return
    end

    local iface = net.iface or "wlan0"
    local ctrl_dir = net.ctrl_dir or "/data/misc/wifi/sockets"
    -- Android init often exposes only a global supplicant socket
    -- (-g@android:wpa_wlan0).  In that case commands need an IFNAME prefix,
    -- and the socket path is not ctrl_dir/iface.
    local ctrl_interface = net.ctrl_interface or (ctrl_dir .. "/" .. iface)
    if net.wpa_global then
        local ok, WpaClient = pcall(require, "lj-wpaclient/wpaclient")
        if ok and WpaClient then
            WpaClient.ifname = net.wpa_ifname or iface
        end
    end
    local session = native_dir .. "/session.sh"

    local function session_bg(sub)
        return string.format(
            "%s sh %s --profile %s %s >/dev/null 2>&1 &",
            setsid_cmd, session, profile_id, sub)
    end

    local function session_fg(sub)
        return string.format("sh %s --profile %s %s", session, profile_id, sub)
    end

    function NetworkMgr:getNetworkInterfaceName()
        return iface
    end

    NetworkMgr:setWirelessBackend("wpa_supplicant", {
        ctrl_interface = ctrl_interface,
    })

    function NetworkMgr:isWifiOn()
        local prop = net.service_prop
        if prop and prop ~= "" then
            local out = run_cmd(getprop_cmd .. " " .. prop)
            return out ~= nil and out:gsub("%s+$", "") == "running"
        end
        return os.execute(ip_cmd .. " link show " .. iface .. " >/dev/null 2>&1") == 0
    end

    -- connectivityCheck() polls this every 250ms; cache the fork+exec.
    local last_connected_check = 0
    local last_connected = false
    function NetworkMgr:isConnected()
        local now = os.time()
        if now - last_connected_check < 2 then
            return last_connected
        end
        last_connected_check = now
        local out = run_cmd(ip_cmd .. " -4 addr show " .. iface .. " 2>/dev/null")
        last_connected = out ~= nil and out:find("inet ", 1, true) ~= nil
        return last_connected
    end

    function NetworkMgr:turnOnWifi(complete_callback, interactive)
        os.execute(session_bg("wifi-up"))
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local wait_msg = InfoMessage:new{ text = _("Turning on Wi-Fi…") }
        UIManager:show(wait_msg)

        local function supplicant_ready()
            if not self:isWifiOn() then
                return false
            end
            local ok, WpaClient = pcall(require, "lj-wpaclient/wpaclient")
            if not ok or not WpaClient then
                return false
            end
            local client = WpaClient.new(ctrl_interface)
            if not client then
                return false
            end
            client:close()
            return true
        end

        local function wait_and_scan(iter)
            if not supplicant_ready() and iter < 30 then
                UIManager:scheduleIn(1, function()
                    wait_and_scan(iter + 1)
                end)
                return
            end
            UIManager:close(wait_msg)
            self:reconnectOrShowNetworkMenu(complete_callback, interactive)
        end
        UIManager:scheduleIn(1, function() wait_and_scan(1) end)
    end

    function NetworkMgr:turnOffWifi(complete_callback)
        os.execute(session_fg("wifi-down"))
        if complete_callback then complete_callback() end
    end

    function NetworkMgr:restoreWifiAsync()
        os.execute(session_bg("wifi-up"))
    end

    function NetworkMgr:obtainIP()
        os.execute(session_bg("wifi-dhcp"))
    end

    function NetworkMgr:releaseIP()
        -- Only drop the DHCP lease; the association stays up so obtainIP()
        -- can renew it (NetworkMgr does this on a stale-lease switch).
        os.execute(session_fg("wifi-release"))
    end
end

function Device:retrieveNetworkInfo()
    local iface = net.iface or "wlan0"
    local out = run_cmd(ip_cmd .. " addr show " .. iface .. " 2>/dev/null")
    if not out or out == "" then
        return _("Interface ") .. iface .. _(" is down")
    end

    local lines = {}
    table.insert(lines, _("Interface: ") .. iface)
    local mac = out:match("link/ether%s+(%S+)")
    if mac then
        table.insert(lines, _("MAC: ") .. mac)
    end

    local ssid
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        local current = NetworkMgr:getCurrentNetwork()
        ssid = current and current.ssid
    end
    if ssid then
        table.insert(lines, _("SSID: \"") .. ssid .. "\"")
    else
        table.insert(lines, _("SSID: off/any"))
    end

    local ipv4 = out:match("inet%s+([%d%.]+/%d+)")
    if ipv4 then
        table.insert(lines, _("IPv4: ") .. ipv4)
    end
    local ipv6 = out:match("inet6%s+([%x:]+/%d+)")
    if ipv6 then
        table.insert(lines, _("IPv6: ") .. ipv6)
    end

    local route = run_cmd(ip_cmd .. " route show default 2>/dev/null")
    local gateway = route and route:match("via%s+([%d%.]+)")
    if gateway then
        table.insert(lines, _("Default gateway: ") .. gateway)
        local ok_ping = os.execute(string.format(
            "%s -q -c1 -W 2 %s >/dev/null 2>&1", ping_cmd, gateway)) == 0
        table.insert(lines, ok_ping and _("Gateway ping successful")
                                  or _("Gateway ping FAILED"))
    end

    return table.concat(lines, "\n")
end

function Device:saveSettings()
    self.powerd:saveSettings()
end

-- Enter/leave hardware suspend through the profile-selected driver.  The
-- state write blocks until the kernel resumes, so Device:suspend() only
-- returns after wakeup.
function Device:suspend()
    if self.suspend_driver then
        self._suspend_in_progress = true
        self._resume_pending_wake = false
        local ok = self.suspend_driver.suspend(self, pw, disp, net)
        -- The state write returned: the kernel either resumed or aborted the
        -- request.  Either way the resume UI is now responsible for closing
        -- the screensaver; stay busy and ignore further power keys until it
        -- has finished (including the full repaint).
        self._suspend_in_progress = false
        self._resume_in_progress = true
        self._resume_pending_wake = true
        return ok
    end
    logger.info("device/native: suspend disabled (screensaver only)")
    return false
end

function Device:resume()
    if self.suspend_driver then
        return self.suspend_driver.resume(self, pw, disp, net)
    end
    logger.info("device/native: screensaver closed (no suspend)")
end

function Device:rescheduleSuspend(delay)
    if not self:canSuspend() then
        return
    end
    local UIManager = require("ui/uimanager")
    self.suspend_wait_timeout = delay or self.suspend_wait_timeout or 1
    UIManager:unschedule(self.suspend)
    UIManager:scheduleIn(self.suspend_wait_timeout, self.suspend, self)
end

function Device:powerOff()
    logger.info("device/native: powering off")
    os.execute("sync")
    -- The session and the NativeKO launcher both run as root.
    local rc = os.execute("/system/bin/reboot -p")
    if rc ~= 0 then
        logger.warn("device/native: reboot -p failed, trying sys.powerctl")
        os.execute("setprop sys.powerctl shutdown")
    end
end

-- Power-key handling: show the screensaver, then suspend after a short delay
-- (so the panel has painted it).  The resume power key closes the screensaver
-- and restores Wi-Fi/frontlight.
function Device:onPowerEvent(ev)
    local UIManager = require("ui/uimanager")
    local Screensaver = require("ui/screensaver")

    if self.screen_saver_mode then
        if ev == "Power" or ev == "Resume" then
            -- The suspend driver is still blocked in the kernel; nothing
            -- should be dispatching input here, but be defensive.
            if self._suspend_in_progress then
                return
            end
            self._resume_pending_wake = false
            self._resume_in_progress = true
            UIManager:unschedule(self.suspend)
            self:resume()
            local function finish_resume()
                self._resume_in_progress = false
            end
            local widget_was_closed = Screensaver:close()
            if widget_was_closed and self:needsScreenRefreshAfterResume() then
                UIManager:scheduleIn(1, function()
                    self.screen:refreshFull(0, 0,
                        self.screen:getWidth(), self.screen:getHeight())
                    finish_resume()
                end)
            else
                finish_resume()
            end
            self.powerd:afterResume()
            if self._wifi_was_on_before_screensaver then
                local NetworkMgr = require("ui/network/manager")
                NetworkMgr:restoreWifiAsync()
                self._wifi_was_on_before_screensaver = false
            end
        end
        return
    end

    -- Do not start a new suspend/wake until the previous suspend/resume
    -- transition (and its repaint) has fully completed.
    if self._suspend_in_progress or self._resume_in_progress then
        logger.dbg("device/native: power event ignored (suspend/resume in progress)")
        return
    end

    if ev == "Power" or ev == "Suspend" then
        -- Touch must not dismiss the screensaver on this device; only the
        -- power key (this handler) closes it.
        local ok, ScreenSaverWidget = pcall(require, "ui/widget/screensaverwidget")
        if ok and ScreenSaverWidget then
            ScreenSaverWidget.onTap = function() end
        end
        Screensaver:setup()
        Screensaver:show()
        if self:needsScreenRefreshAfterResume() then
            self.screen:refreshFull(0, 0,
                self.screen:getWidth(), self.screen:getHeight())
        end
        UIManager:forceRePaint()
        -- The screensaver is our "sleep" state: turn Wi-Fi off, and restore it
        -- when the power key closes the screensaver.
        if self:hasWifiToggle() then
            local NetworkMgr = require("ui/network/manager")
            self._wifi_was_on_before_screensaver = NetworkMgr:isWifiOn()
            if self._wifi_was_on_before_screensaver then
                NetworkMgr:disableWifi()
            end
        end
        self.powerd:beforeSuspend()
        self:rescheduleSuspend(self.suspend_wait_timeout)
    end
end

return Device
