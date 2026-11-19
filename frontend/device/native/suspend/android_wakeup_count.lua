-- Android 6 wakelock / wakeup_count suspend driver.
--
-- Unlike the legacy early-suspend model, this kernel has no
-- /sys/power/wait_for_fb_* and no earlysuspend module.  Suspend is requested
-- by writing "mem" to /sys/power/state; the write blocks until the system
-- resumes.  The wakelock interface rejects suspend while a lock is held, so
-- the session lock is released last and re-acquired immediately on wake.
--
-- Profile fields (power.*):
--   suspend_state        "mem" (default), fallback "standby"/"freeze"
--   suspend_fallback     state to try if the primary write fails
--   suspend_wait_timeout delay before suspending after the screensaver
--   rtc_alarm            RTC alarm node; stale alarms are cleared before
--                        sleeping (the driver does not arm a wake alarm)
--   suspend_unbind       "driver:device" platform devices to unbind before
--                        suspend and bind again after resume
--   wake_lock_name       base session-lock name
--   wake_unlock          extra lock names to release before suspend

local ffiUtil = require("ffi/util")
local logger = require("logger")

local M = {}

local native_dir = os.getenv("KO_NATIVE_DIR") or "/data/local/tmp/nativeko"
local profile_id = os.getenv("KO_NATIVE_PROFILE_ID") or "notesl"
local log_path = native_dir .. "/suspend.log"

local function log(msg)
    local f = io.open(log_path, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S"), " ", msg, "\n")
        f:close()
    end
    logger.info("device/native suspend: " .. msg)
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

local function write_sysfs(path, value)
    if not path or path == "" then return false end
    return ffiUtil.writeToSysfs(tostring(value), path)
end

local function session_lock(pw)
    local name = os.getenv("KO_NATIVE_WAKE_LOCK")
    if not name or name == "" then
        name = pw.wake_lock_name or "nativeko"
    end
    return name
end

local function active_locks()
    local locks = {}
    local line = read_file("/sys/power/wake_lock") or ""
    for name in line:gmatch("%S+") do
        locks[name] = true
    end
    return locks
end

-- Release framework/session locks except the current session lock.  Stale
-- PowerManagerService.* locks survive a stopped system_server and would make
-- the wakelock driver refuse late suspend.
local function release_other_locks(pw, keep)
    local names = {}
    for _, name in ipairs(pw.wake_unlock or {}) do
        names[name] = true
    end
    local base = pw.wake_lock_name
    for name in pairs(active_locks()) do
        if name ~= keep then
            if name:match("^PowerManagerService%.") or name == "KeyEvents" then
                names[name] = true
            elseif base and base ~= ""
                and (name == base or name:sub(1, #base + 1) == base .. "-")
            then
                -- A session lock leaked by an older core; not ours.
                names[name] = true
            end
        end
    end
    for name in pairs(names) do
        if name ~= keep then
            if write_sysfs("/sys/power/wake_unlock", name) then
                log("released lock " .. name)
            end
        end
    end
end

local function clear_alarm(pw)
    if pw.rtc_alarm and pw.rtc_alarm ~= "" then
        write_sysfs(pw.rtc_alarm, "0")
    end
end



-- Some boards have a probe/resume path that times out for hardware that is
-- not fitted (e.g. the NoteSL has no SD slot, but mmc1 still spends ~10s in
-- resume timeouts).  Unbind those platform devices before sleeping and bind
-- them again after resume.  Profile format: "driver:device".
local function for_each_unbind(pw, action)
    for _, spec in ipairs(pw.suspend_unbind or {}) do
        local driver, dev = spec:match("^([^:]+):(.+)$")
        if driver and dev then
            local path = "/sys/bus/platform/drivers/" .. driver .. "/" .. action
            if write_sysfs(path, dev) then
                log(action .. " " .. driver .. " " .. dev)
            else
                log(action .. " failed for " .. driver .. " " .. dev)
            end
        end
    end
end


local function suspend_state(pw)
    local state = pw.suspend_state or "mem"
    if write_sysfs("/sys/power/state", state) then
        return state
    end
    local fallback = pw.suspend_fallback
    if fallback and fallback ~= "" and fallback ~= state then
        log(state .. " failed, trying " .. fallback)
        if write_sysfs("/sys/power/state", fallback) then
            return fallback
        end
    end
    return nil
end

function M.suspend(device, pw, disp, net)
    local lock = session_lock(pw)
    log("suspend begin lock=" .. tostring(lock))

    -- Wi-Fi is normally brought down before sleeping (bcmdhd's OOB IRQ can
    -- otherwise abort the transition).  Profiles that know the radio cannot
    -- wake the SoC can opt out with wifi_keep_on_suspend.
    if pw.wifi_keep_on_suspend ~= true then
        os.execute(string.format(
            "sh %s/session.sh --profile %s wifi-suspend >/dev/null 2>&1",
            native_dir, profile_id))
    end

    clear_alarm(pw)
    release_other_locks(pw, lock)
    for_each_unbind(pw, "unbind")
    os.execute("sync")

    -- The session lock must be dropped last: the wakelock driver refuses
    -- late suspend while any lock is active.
    if lock and lock ~= "" then
        write_sysfs("/sys/power/wake_unlock", lock)
    end
    log("wake_lock before mem: "
        .. (read_file("/sys/power/wake_lock") or ""))
    log("request " .. (pw.suspend_state or "mem"))

    local state = suspend_state(pw)

    -- Reached only after resume (or after a failed/aborted request).
    for_each_unbind(pw, "bind")
    if lock and lock ~= "" then
        write_sysfs("/sys/power/wake_lock", lock)
    end
    clear_alarm(pw)
    if state then
        log("resumed state=" .. tostring(state))
    else
        log("suspend failed/aborted")
    end
    return state ~= nil
end

function M.resume(device, pw, disp, net)
    local lock = session_lock(pw)
    if lock and lock ~= "" then
        write_sysfs("/sys/power/wake_lock", lock)
    end
    clear_alarm(pw)
    -- The EBC controller loses its draw/buffer state across mem.  Re-enable
    -- it before the first post-resume frame; otherwise SEND_BUFFER can time
    -- out and the next GET_BUFFER blocks forever in ebc_empty_buf_get.
    if device and device.screen and device.screen.onResume then
        local ok, err = pcall(function()
            device.screen:onResume()
        end)
        if not ok then
            log("screen resume failed: " .. tostring(err))
        end
    end
    log("resume")
end

function M.wake(device, pw, disp, net)
    M.resume(device, pw, disp, net)
end

return M
