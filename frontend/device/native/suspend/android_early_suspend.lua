-- Android legacy wakelock / early-suspend driver for the T65A (i.MX6 EPDC).
--
-- This follows the "userspace owns suspend" model: with zygote/SurfaceFlinger
-- stopped, KOReader holds the only session wake lock, releases the framework
-- locks that were left behind, requests "mem", and then drops its own lock.
-- The kernel's early-suspend path handles the EPDC handshake through
-- wait_for_fb_sleep/wait_for_fb_wake (drivers/pm/android_early_suspend.sh
-- starts the acker before the framework is stopped).
--
-- Order matters: request "mem" while still holding the session lock, then
-- drop the lock.  Dropping it is what lets pm_suspend run.  We then sleep
-- briefly so suspend_work can freeze us; on resume execution continues there.
-- The acker re-acquires the session lock as soon as late_resume completes,
-- and this driver re-acquires it again before resetting input/UI state.
--
-- Notes for this model:
--   * never write the RTC; it is shared with Android.  We only log it.
--   * there is no USB/charging gate; suspend is allowed while plugged in.
--   * the wake key can be consumed by the kernel suspend path, so the UI
--     resume is driven by Device:suspend() after this driver returns.
--
-- Profile fields (power.*):
--   suspend_state       "mem" (default)
--   suspend_wait_timeout screensaver delay before the request (in device.lua)
--   wake_lock_name      base name for the per-session lock
--   wake_unlock         extra framework lock names to release

local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local logger = require("logger")

-- struct timespec is two longs on arm; this avoids depending on a cdef.
pcall(ffi.cdef, "int clock_gettime(int clk_id, long *ts);")
local CLOCK_MONOTONIC = 1
local CLOCK_BOOTTIME = 7

local M = {}

local native_dir = os.getenv("KO_NATIVE_DIR") or "/data/local/tmp/nativeko"
local log_path = native_dir .. "/suspend.log"

local function log(msg)
    local f = io.open(log_path, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S"), " ", msg, "\n")
        f:close()
    end
    logger.info("device/native suspend: " .. msg)
end

local function read_sys(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

local function write_sys(path, value)
    if not path or path == "" then return false end
    return ffiUtil.writeToSysfs(tostring(value), path)
end

local function run(cmd)
    local p = io.popen(cmd, "r")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    return out
end

local function tail_lines(text, count)
    if not text then return nil end
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    local first = #lines - count + 1
    if first < 1 then first = 1 end
    local out = {}
    for i = first, #lines do
        out[#out + 1] = lines[i]
    end
    return table.concat(out, "\n")
end

local function session_lock(pw)
    local name = os.getenv("KO_NATIVE_WAKE_LOCK")
    if not name or name == "" then
        name = pw.wake_lock_name or "nativeko"
    end
    return name
end

local function clock(id)
    local ts = ffi.new("long[2]")
    if ffi.C.clock_gettime(id, ts) ~= 0 then return nil end
    return tonumber(ts[0]) + tonumber(ts[1]) / 1000000000
end

local function active_locks()
    local locks = {}
    for name in (read_sys("/sys/power/wake_lock") or ""):gmatch("%S+") do
        locks[name] = true
    end
    return locks
end

local function log_locks(label)
    log(label .. " wake_lock: " .. (read_sys("/sys/power/wake_lock") or ""))
end

-- Framework locks are left active when zygote/system_server are stopped and
-- nobody releases them.  Also drop session locks leaked by an older core;
-- never drop the current session lock here.
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
                names[name] = true
            end
        end
    end
    for name in pairs(names) do
        if name ~= keep then
            if write_sys("/sys/power/wake_unlock", name) then
                log("released lock " .. name)
            else
                log("release failed " .. name)
            end
        end
    end
end

local function log_dmesg()
    local out = tail_lines(run("dmesg 2>/dev/null"), 160)
    if not out or out == "" then return end
    local f = io.open(log_path, "a")
    if f then
        f:write("---- dmesg after resume ----\n", out, "\n")
        f:close()
    end
end

function M.suspend(device, pw, disp, net)
    local lock = session_lock(pw)
    log("suspend begin lock=" .. tostring(lock))

    log_locks("before cleanup")
    release_other_locks(pw, lock)
    os.execute("sync")
    log_locks("after cleanup")

    -- Read-only: the RTC alarm belongs to Android and may hold wake events we
    -- do not own.
    log("rtc wakealarm (untouched): "
        .. tostring(read_sys("/sys/class/rtc/rtc0/wakealarm")))

    local mono1 = clock(CLOCK_MONOTONIC)
    local boot1 = clock(CLOCK_BOOTTIME)

    local state = pw.suspend_state or "mem"
    log("request " .. state)
    if not write_sys("/sys/power/state", state) then
        log("state write failed")
        return false, "state"
    end

    -- This is the actual transition point: pm_suspend runs once the last
    -- suspend wakelock is gone.  The sleep yields the CPU so suspend_work
    -- can run and freeze us; if the request is aborted we simply wake after
    -- the timeout.
    log("release session lock")
    write_sys("/sys/power/wake_unlock", lock)
    ffiUtil.sleep(0.5)

    -- Reached after resume (or after an aborted request).
    if lock and lock ~= "" then
        write_sys("/sys/power/wake_lock", lock)
    end
    -- PowerManagerService.nativeWake() equivalent: finish late_resume and
    -- unblank the EPDC.
    write_sys("/sys/power/state", "on")

    local mono2 = clock(CLOCK_MONOTONIC)
    local boot2 = clock(CLOCK_BOOTTIME)
    local slept = 0
    if mono1 and boot1 and mono2 and boot2 then
        slept = (boot2 - boot1) - (mono2 - mono1)
        if slept < 0 then slept = 0 end
    end
    log(string.format(
        "NATIVE_SUSPEND_CLOCKS monotonic %.3f boottime %.3f suspended %.3f",
        mono2 or 0, boot2 or 0, slept))

    -- Account the sleep so UIManager/Device timers do not think the whole
    -- interval was spent awake.
    device.last_suspend_time = slept
    device.total_suspend_time = (device.total_suspend_time or 0) + slept

    -- The kernel may have consumed the wake key, and goodix MT-A state can
    -- be stale across a suspend.  Reset both the input parser and the UI
    -- time base, then let AutoSuspend see an InputEvent so its idle timer
    -- restarts instead of immediately re-suspending.
    pcall(function()
        device.input:resetState()
    end)
    local ui_ok, UIManager = pcall(require, "ui/uimanager")
    if ui_ok and UIManager then
        local time_ok, time = pcall(require, "ui/time")
        if time_ok and time then
            UIManager._now = time.now()
        end
        pcall(function()
            UIManager.event_hook:execute("InputEvent")
        end)
    end

    log_locks("after resume")
    log_dmesg()
    log("resumed")

    -- A sub-second "sleep" is an aborted transition (another lock or a wake
    -- event); report it so the caller can avoid treating it as a real sleep.
    if slept < 0.5 then
        return false, "aborted"
    end
    return true
end

function M.resume(device, pw, disp, net)
    local lock = session_lock(pw)
    if lock and lock ~= "" then
        write_sys("/sys/power/wake_lock", lock)
    end
    write_sys("/sys/power/state", "on")
    log("resume hook")
end

function M.wake(device, pw, disp, net)
    M.resume(device, pw, disp, net)
end

return M
