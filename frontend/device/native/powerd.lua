-- Profile-driven power/frontlight backend for native e-ink devices.
--
--   power.battery_capacity, power.battery_status, power.frontlight,
--   power.frontlight_warm, power.fl_min/fl_max, power.fl_warmth_min/max.
--
-- Devices with two backlight channels (e.g. Likebook Alita: rk28_bl and
-- rk28_bl_warm) expose KOReader's Natural Light warmth API without touching
-- the generic powerd/device code.

local BasePowerD = require("device/generic/powerd")
local ffiUtil = require("ffi/util")
local logger = require("logger")

local PowerD = BasePowerD:new{
    fl_min = 0,
    fl_max = 100,
    fl_warmth_min = 0,
    fl_warmth_max = 100,
}

function PowerD:init()
    local pw = self.profile.power or {}
    self.capacity_file = pw.battery_capacity
        or "/sys/class/power_supply/battery/capacity"
    self.status_file = pw.battery_status
        or "/sys/class/power_supply/battery/status"
    self.frontlight_file = pw.frontlight
    self.frontlight_warm_file = pw.frontlight_warm
    self.fl_min = pw.fl_min or 0
    self.fl_max = pw.fl_max or 100
    self.fl_warmth_min = pw.fl_warmth_min or 0
    self.fl_warmth_max = pw.fl_warmth_max or 100
    -- BasePowerD's fl_warmth is in the KOReader 0..100 scale; keep the native
    -- value separately for the two channel write.
    self.fl_warmth = G_reader_settings:readSetting("frontlight_warmth") or 0
    self._native_warmth = nil
end

function PowerD:_clampWarmth(warmth)
    local min, max = self.fl_warmth_min, self.fl_warmth_max
    if warmth < min then return min end
    if warmth > max then return max end
    return warmth
end

function PowerD:_nativeWarmth()
    if self._native_warmth ~= nil then return self._native_warmth end
    -- With fl_warmth_max = 100 the KOReader and native scales coincide.
    if self.fl_warmth_max == 100 then return self.fl_warmth or 0 end
    return (self.fl_warmth or 0) * self.fl_warmth_max / 100
end

function PowerD:_applyFrontlight(intensity, native_warmth)
    if not self.frontlight_file then return end
    intensity = tonumber(intensity) or 0
    if intensity < self.fl_min then intensity = self.fl_min end
    if intensity > self.fl_max then intensity = self.fl_max end

    if not self.frontlight_warm_file then
        ffiUtil.writeToSysfs(intensity, self.frontlight_file)
        return
    end

    local warmth = self:_clampWarmth(native_warmth or self:_nativeWarmth())
    local span = self.fl_warmth_max - self.fl_warmth_min
    local pct = span > 0 and ((warmth - self.fl_warmth_min) * 100 / span) or 0
    local white = math.floor(intensity * (100 - pct) / 100 + 0.5)
    local warm = math.floor(intensity * pct / 100 + 0.5)
    ffiUtil.writeToSysfs(white, self.frontlight_file)
    ffiUtil.writeToSysfs(warm, self.frontlight_warm_file)
end

--- @note: Called once from BasePowerD:new to seed fl_intensity. When the
--- light is off, return the remembered level so the next toggle restores it.
function PowerD:frontlightIntensityHW()
    if not self.frontlight_file then return 0 end
    local white = self:read_int_file(self.frontlight_file)
    if self.frontlight_warm_file then
        local warm = self:read_int_file(self.frontlight_warm_file)
        local total = white + warm
        if total > 0 then
            return math.min(total, self.fl_max)
        end
    elseif white > 0 then
        return white
    end
    return G_reader_settings:readSetting("frontlight_intensity") or 20
end

--- @note: Must query the hardware, because frontlightIntensityHW has a
--- remembered-value fallback while the light is off.
function PowerD:isFrontlightOnHW()
    if not self.frontlight_file then return false end
    if self:read_int_file(self.frontlight_file) > 0 then return true end
    if self.frontlight_warm_file
        and self:read_int_file(self.frontlight_warm_file) > 0 then
        return true
    end
    return false
end

function PowerD:setIntensityHW(intensity)
    self:_applyFrontlight(intensity, self:_nativeWarmth())
    self:_decideFrontlightState()
end

function PowerD:setWarmthHW(warmth)
    self._native_warmth = warmth
    local intensity = self.fl_intensity
    if intensity == nil then
        intensity = self:frontlightIntensityHW()
    end
    self:_applyFrontlight(intensity, warmth)
    self:_decideFrontlightState()
end

function PowerD:frontlightWarmthHW()
    return self:_nativeWarmth()
end

--- @note: Persist the BasePowerD values: when toggled off, the previous
--- untoggled intensity/warmth is what should survive.
function PowerD:saveSettings()
    if self.device:hasFrontlight() then
        G_reader_settings:saveSetting("frontlight_intensity", self.fl_intensity)
        if self.device:hasNaturalLight() then
            G_reader_settings:saveSetting("frontlight_warmth", self.fl_warmth)
        end
    end
end

--- @note: The frontlight LEDs are a measurable drain while the screensaver
--- is shown; blank them but keep fl_intensity/fl_warmth so afterResume
--- restores the level.
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
