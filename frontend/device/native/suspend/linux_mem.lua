-- Generic Linux suspend driver: blank the framebuffer, write the configured
-- power state, restore the framebuffer on wake.
--
-- Profile fields: power.suspend_state, power.suspend_fallback, display.blank.

local ffiUtil = require("ffi/util")
local logger = require("logger")

local M = {}

local function set_blank(disp, value)
    if disp.blank and disp.blank ~= "" then
        ffiUtil.writeToSysfs(value, disp.blank)
    end
end

M.blank = set_blank

local function set_wakeups(pw, value)
    for _, path in ipairs(pw.wakeup_disable or {}) do
        ffiUtil.writeToSysfs(value, path)
    end
end

M.set_wakeups = set_wakeups

function M.suspend(device, pw, disp)
    set_wakeups(pw, "disabled")
    set_blank(disp, "1")

    local state = pw.suspend_state or "mem"
    logger.info("device/native: entering suspend (" .. state .. ")")
    local ok = ffiUtil.writeToSysfs(state, "/sys/power/state")
    if not ok and pw.suspend_fallback and pw.suspend_fallback ~= "" then
        logger.warn("device/native: " .. state .. " suspend failed, trying "
            .. pw.suspend_fallback)
        ok = ffiUtil.writeToSysfs(pw.suspend_fallback, "/sys/power/state")
    end
    if ok then
        logger.info("device/native: woke from suspend")
    else
        logger.warn("device/native: kernel refused to suspend")
    end

    set_blank(disp, "0")
    set_wakeups(pw, "enabled")
    return ok
end

function M.resume(device, pw, disp)
    set_blank(disp, "0")
    set_wakeups(pw, "enabled")
end

return M
