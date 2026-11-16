-- Profile-driven power/frontlight backend for native e-ink devices.
--
-- The profile is passed in by device/native/device.lua:
--   power.battery_capacity, power.battery_status, power.frontlight,
--   power.fl_min, power.fl_max.

local BasePowerD = require("device/generic/powerd")
local ffiUtil = require("ffi/util")

local PowerD = BasePowerD:new{
    fl_min = 0,
    fl_max = 100,
}

function PowerD:init()
    local pw = self.profile.power or {}
    self.capacity_file = pw.battery_capacity
        or "/sys/class/power_supply/battery/capacity"
    self.status_file = pw.battery_status
        or "/sys/class/power_supply/battery/status"
    self.frontlight_file = pw.frontlight
    self.fl_min = pw.fl_min or 0
    self.fl_max = pw.fl_max or 100
end

--- @note: Called once from BasePowerD:new to seed fl_intensity. When the
--- light is off, return the remembered level so the next toggle restores it.
function PowerD:frontlightIntensityHW()
    if not self.frontlight_file then return 0 end
    local val = self:read_int_file(self.frontlight_file)
    if val == 0 then
        val = G_reader_settings:readSetting("frontlight_intensity") or 20
    end
    return val
end

--- @note: Must query the hardware, because frontlightIntensityHW has a
--- remembered-value fallback while the light is off.
function PowerD:isFrontlightOnHW()
    if not self.frontlight_file then return false end
    return self:read_int_file(self.frontlight_file) > 0
end

function PowerD:setIntensityHW(intensity)
    if not self.frontlight_file then return end
    ffiUtil.writeToSysfs(intensity, self.frontlight_file)
    self:_decideFrontlightState()
end

--- @note: Persist the BasePowerD value: when toggled off, the previous
--- untoggled intensity is what should survive.
function PowerD:saveSettings()
    if self.device:hasFrontlight() then
        G_reader_settings:saveSetting("frontlight_intensity", self.fl_intensity)
    end
end

--- @note: The frontlight LEDs are a measurable drain while the screensaver
--- is shown; blank them but keep fl_intensity so afterResume restores the
--- level. This is independent of whether the device actually suspends.
function PowerD:beforeSuspend()
    self.fl_was_on = self:isFrontlightOn()
    if self.fl_was_on then
        self:setIntensityHW(self.fl_min)
    end
    BasePowerD.beforeSuspend(self)
end

function PowerD:afterResume()
    if self.fl_was_on then
        self:setIntensityHW(self.fl_intensity)
        self.is_fl_on = true
    end
    BasePowerD.afterResume(self)
end

function PowerD:getCapacityHW()
    if not self.capacity_file then return 0 end
    return self:read_int_file(self.capacity_file)
end

function PowerD:isChargingHW()
    if not self.status_file then return false end
    -- "Full" still means plugged in.
    return self:read_str_file(self.status_file) ~= "Discharging"
end

function PowerD:isChargedHW()
    if not self.status_file then return false end
    return self:read_str_file(self.status_file) == "Full"
end

return PowerD
