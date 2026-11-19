-- Generic Rockchip EBC direct-framebuffer backend.
--
-- Some Rockchip e-ink devices expose the scanned-out image not through
-- /dev/graphics/fb0, but through the EBC (E-Book Controller) character device
-- /dev/ebc.  This backend owns that buffer directly, so KOReader can drive the
-- panel with no SurfaceFlinger / hwcomposer involvement.
--
-- Tested reference device:
--   Onyx NoteS / 超星 NoteSL, RK3288, Android 6.0.1, kernel 3.10,
--   1200x825 panel, driver K29_EBC_DRIVER_VERSION_1.00.
--   /dev/ebc mmap: 1200x825, 32bpp, stride 4800.
--   Panel is the buffer rotated 90 degrees clockwise:
--     buffer (0,0)   -> portrait top-right
--     buffer (0,H-1) -> portrait top-left
--   KOReader's is_always_portrait + bb:rotate(-90) yields the same transform.
--
-- Protocol (Rockchip EBC, values from the public rk29_ebc driver and the
-- device's own hwcomposer):
--   EBC_GET_BUFFER      0x7000  acquire a free buffer (offset + geometry)
--   EBC_SEND_BUFFER     0x7001  post/repost the current buffer/window
--   EBC_GET_DRIVER_SN    0x7002  driver version string
--   EBC_GET_BUFFER_INFO 0x7003  geometry (offset/epd_mode are uninitialized)
--   EBC_SEND_UPDATE     0x700c  drive the panel for a rect/waveform
--
-- The old Rockchip "software EBC" auto-image path uses 4bpp (two pixels per
-- byte).  That is NOT necessarily the direct display buffer: on the NoteSL,
-- 4bpp only covers a narrow strip; 32bpp (stride = width * 4) is correct.
-- Use tools/rk-ebc-probe to determine the format on a new model.

local ffi = require("ffi")
local bit = require("bit")
local BB = require("ffi/blitbuffer")
local C = ffi.C

require("ffi/posix_h")

ffi.cdef[[
typedef struct {
    int32_t offset;
    int32_t epd_mode;
    int32_t height;
    int32_t width;
    int32_t vir_height;
    int32_t vir_width;
    int32_t fb_width;
    int32_t fb_height;
    int32_t color_panel;
    int32_t win_x1;
    int32_t win_y1;
    int32_t win_x2;
    int32_t win_y2;
    int32_t rotate;
} rk_ebc_buf_info;

typedef struct {
    int32_t rect[4];          /* order is configurable: y,x,w,h or x,y,w,h */
    int32_t waveform_mode;
    int32_t update_mode;
    int32_t update_marker;
    int32_t unknown_1c;
    int32_t flags;
    int32_t unknown_24;
} rk_ebc_send_update;

/* Bounded-time wrappers from libnativeko-ebc.so (optional). */
int nativeko_ebc_acquire(int fd, rk_ebc_buf_info *info, int timeout_ms);
int nativeko_ebc_send(int fd, rk_ebc_buf_info *info);
int nativeko_ebc_status(int fd, int *status, int timeout_ms);
int nativeko_ebc_draw_enable(int fd);
int nativeko_ebc_draw_stop(int fd);
]]

local ETIMEDOUT = 110

local function load_ebc_helper()
    local dir = os.getenv("KO_NATIVE_DIR")
    if not dir or dir == "" then return nil end
    local ok, lib = pcall(ffi.load, dir .. "/libnativeko-ebc.so")
    if ok then return lib end
    return nil
end

local framebuffer = {
    device_node = "/dev/ebc",
    fd = -1,
    data = nil,
    map_len = 0,
    marker = 1,

    -- Buffer geometry/format.  Profiles override these.
    ebc_width = 1200,
    ebc_height = 825,
    ebc_bpp = 32,
    ebc_stride = 4800,
    ebc_offset = 0,
    ebc_rotate = 0,          -- optional extra bb rotation, degrees CCW

    -- ioctl numbers (some vendor kernels shift them)
    ebc_cmd_send_buffer = 0x7001,
    ebc_cmd_send_update = 0x700c,
    ebc_cmd_buffer_info = 0x7003,
    ebc_cmd_driver_sn = 0x7002,

    -- Refresh parameters.
    ebc_enabled = true,
    ebc_send_buffer_each = true,
    ebc_send_initial = true,
    ebc_epd_mode = 1,          -- EPD_FULL for SET_EBC_SEND_BUFFER
    ebc_rect_order = "yxwh",   -- "yxwh" (rk29) or "xywh"
    ebc_waveform_full = 2,     -- GC16
    ebc_update_mode_full = 1,  -- flashing/full
    ebc_waveform_partial = 2,
    ebc_update_mode_partial = 0,
    ebc_waveform_fast = 1,     -- DU
    ebc_update_mode_fast = 0,
    ebc_unknown_1c = 0x1000,
    ebc_flags = 0x21000,

    -- Vendor HWC path (Likebook Alita): instead of a fixed mmap offset and
    -- 0x700c, acquire a buffer with GET_BUFFER, write an 8bpp frame, and post
    -- it with SEND_BUFFER.  The panel code is 5-bit (0..30), not 0..255.
    ebc_vendor_post = false,
    ebc_cmd_get_buffer = 0x7000,
    ebc_cmd_draw_enable = 0x7008,
    ebc_cmd_draw_stop = 0x7006,
    ebc_epd_mode_full = 1,       -- EPD_FULL
    ebc_epd_mode_partial = 15,   -- EPD_REGLA (text/quality partial)
    ebc_epd_mode_ui = 15,        -- EPD_REGLA
    ebc_epd_mode_flash = 11,     -- EPD_FORCE_FULL
    ebc_epd_mode_fast = 18,      -- EPD_FAST
    ebc_epd_mode_a2 = 2,         -- EPD_A2
    ebc_epd_mode_dither = 100,   -- EPD_DITHER
    ebc_epd_mode_screensaver = 102, -- EPD_FULL_DITHER
    ebc_map_len = 12 * 1024 * 1024,
    ebc_gray_shift = 3,
    ebc_gray_max = 30,
    ebc_gamma_level = nil,  -- sys.by.gammalevel; use the vendor 16-gray LUT
    ebc_screensaver_mode = false, -- vendor EPD_FULL_DITHER screensaver path

    -- Bounded EBC waits.  GET_BUFFER blocks in ebc_empty_buf_get when the
    -- kernel EBC thread has no free buffer (usually after a frame timeout).
    -- With the helper loaded we time out instead of deadlocking the UI thread.
    ebc_acquire_timeout_ms = 1000,
    ebc_status_timeout_ms = 300,
    ebc_helper = nil,
    _ebc_wedged = false,
    _ebc_wedge_logged = false,
}

function framebuffer:init()
    local w = self.ebc_width or 1200
    local h = self.ebc_height or 825
    local bpp = self.ebc_bpp or 32
    local stride = self.ebc_stride or (w * bpp / 8)
    local offset = self.ebc_offset or 0
    local size = offset + (stride * h)
    local map_len = bit.band(size + 4095, bit.bnot(4095))

    self.fd = C.open(self.device_node, bit.bor(C.O_RDWR, C.O_CLOEXEC))
    if self.fd == -1 then
        error("framebuffer_rk_ebc: cannot open " .. self.device_node)
    end

    if self.ebc_vendor_post then
        self:_vendorInit(w, h, stride)
        framebuffer.parent.init(self)
        if self.ebc_enabled and self.ebc_send_initial then
            self:_vendorPost(self.ebc_epd_mode_full)
        end
        return
    end

    self.data = C.mmap(nil, map_len, bit.bor(C.PROT_READ, C.PROT_WRITE),
                       C.MAP_SHARED, self.fd, 0)
    if self.data == C.MAP_FAILED then
        C.close(self.fd)
        error("framebuffer_rk_ebc: cannot mmap " .. self.device_node)
    end
    self.map_len = map_len
    self.stride = stride
    self.width = w
    self.height = h
    self.bpp = bpp

    local bbtype = bpp == 32 and BB.TYPE_BBRGB32
        or bpp == 16 and BB.TYPE_BBRGB16
        or BB["TYPE_BB" .. bpp]
    self.bb = BB.new(w, h, bbtype,
                     ffi.cast("uint8_t *", self.data) + offset,
                     stride, w)
    self.screen_size = { w = w, h = h }
    self.debug("framebuffer_rk_ebc: EBC buffer", w, h, bpp,
               "stride", stride, "offset", offset)

    if self.ebc_rotate and self.ebc_rotate ~= 0 then
        -- Positive = counter-clockwise, matching bb:rotate().
        self.bb:rotate(self.ebc_rotate)
        self.screen_size = { w = self.bb:getWidth(), h = self.bb:getHeight() }
    end

    self.bb:fill(BB.COLOR_WHITE)
    framebuffer.parent.init(self)

    if self.ebc_enabled and self.ebc_send_initial then
        self:_sendBuffer()
        self:_sendUpdate(0, 0, w, h,
                         self.ebc_waveform_full, self.ebc_update_mode_full)
    end
end



-- The vendor HWC builds this table in init_gamma_table(gamma_level) and uses
-- it for both rgb_to_16gray and Luma8bit_to_16gray.  Values are 0..30 (even
-- levels), with the exact piecewise curve below.  This is what the stock UI
-- feeds to the EBC driver; a linear 0..30 map does not match it.
local function build_gamma_lut(level)
    level = tonumber(level) or 14
    if level < 0 then level = 0 end
    if level > 80 then level = 80 end
    local function trunc_div(a, b)
        local q = a / b
        if q >= 0 then return math.floor(q) end
        return math.ceil(q)
    end
    local p = level
    local u = 224 - (bit.rshift(p, 1) + p * 2)
    local q = trunc_div(u, 14)
    local r = u - q * 14
    local d = q - 16 - r
    local low_end = p * 2 + 16
    local high_start = 240 - bit.rshift(p, 1)
    local lut = ffi.new("uint8_t[256]")
    for i = 0, 255 do
        local v
        if i < low_end then
            v = 0
        elseif i > high_start then
            v = 30
        elseif r < 1 then
            v = trunc_div(d - p * 2 + i, q) * 2
        else
            local tmp = q - 15 - p * 2 + i
            local vv = trunc_div(tmp, q + 1)
            v = vv * 2
            if tmp == vv * (q + 1) then
                r = r - 1
            end
        end
        if v < 0 then v = 0 elseif v > 30 then v = 30 end
        lut[i] = v
    end
    return lut
end

-- Vendor HWC path: the driver hands out a rotating buffer offset through
-- GET_BUFFER; the frame must be written there, then posted with SEND_BUFFER.
-- Keeping the vendor ebc_buf_info intact is important (rotate/geometry).
function framebuffer:_vendorInit(w, h, stride)
    local map_len = self.ebc_map_len or (12 * 1024 * 1024)
    self.ebc_helper = load_ebc_helper()
    local rc
    if self.ebc_helper then
        rc = self.ebc_helper.nativeko_ebc_draw_enable(self.fd)
    else
        rc = C.ioctl(self.fd, self.ebc_cmd_draw_enable, nil)
        self.debug("framebuffer_rk_ebc: libnativeko-ebc.so missing, "
            .. "EBC ioctls are unbounded")
    end
    if rc < 0 then
        self.debug("framebuffer_rk_ebc: DRAW_ENABLE failed")
    end
    self.data = C.mmap(nil, map_len, bit.bor(C.PROT_READ, C.PROT_WRITE),
                       C.MAP_SHARED, self.fd, 0)
    if self.data == C.MAP_FAILED then
        C.close(self.fd)
        error("framebuffer_rk_ebc: cannot mmap " .. self.device_node)
    end
    self.map_len = map_len
    self.stride = stride
    self.width = w
    self.height = h
    self.bpp = 8
    self.screen_size = { w = w, h = h }

    -- The panel buffer is 8bpp but carries a 5-bit / 16-level code:
    -- 0x00 black .. 0x1e white.  Prefer the vendor gamma curve; keep the
    -- linear shift as a fallback for profiles without a gamma level.
    if self.ebc_gamma_level ~= nil then
        self._gray_lut = build_gamma_lut(self.ebc_gamma_level)
    else
        local lut = ffi.new("uint8_t[256]")
        local shift = self.ebc_gray_shift or 3
        local maxv = self.ebc_gray_max or 30
        for i = 0, 255 do
            local v = bit.rshift(i, shift)
            if v > maxv then v = maxv end
            lut[i] = v
        end
        self._gray_lut = lut
    end

    self.bb = BB.new(w, h, BB.TYPE_BB8)
    self.bb:fill(BB.COLOR_WHITE)
    if self.ebc_rotate and self.ebc_rotate ~= 0 then
        self.bb:rotate(self.ebc_rotate)
        self.screen_size = { w = self.bb:getWidth(), h = self.bb:getHeight() }
    end
    self.debug("framebuffer_rk_ebc: vendor POST buffer", w, h,
               "stride", stride, "map", map_len,
               "helper", self.ebc_helper and "yes" or "no")
end

function framebuffer:_vendorConvert(dst)
    local src = ffi.cast("uint8_t*", self.bb.data)
    local lut = self._gray_lut
    local n = self.ebc_stride * self.ebc_height
    for i = 0, n - 1 do
        dst[i] = lut[src[i]]
    end
end

function framebuffer:_vendorStatus(timeout_ms)
    local lib = self.ebc_helper
    if not lib then return nil, nil end
    local st = ffi.new("int[2]")
    local rc = lib.nativeko_ebc_status(self.fd, st,
        timeout_ms or self.ebc_status_timeout_ms)
    if rc < 0 then
        return nil, ffi.errno()
    end
    return { st[0], st[1] }, nil
end

function framebuffer:_vendorWedge(reason)
    self._ebc_wedged = true
    if not self._ebc_wedge_logged then
        self._ebc_wedge_logged = true
        self.debug("framebuffer_rk_ebc: EBC wedged: " .. tostring(reason))
    end
end

function framebuffer:_vendorPost(mode)
    if not self.ebc_enabled then return false end
    if self._ebc_wedged then return false end
    if os.getenv("KO_NATIVE_EBC_LOG") then
        local info = debug.getinfo(2, "nSl")
        print(os.date("%H:%M:%S"), "EBC post mode=", mode,
              info and (info.name or info.short_src) or "?",
              info and info.currentline or "")
    end
    local info = ffi.new("rk_ebc_buf_info")
    local lib = self.ebc_helper
    local rc
    if lib then
        rc = lib.nativeko_ebc_acquire(self.fd, info,
            self.ebc_acquire_timeout_ms)
    else
        rc = C.ioctl(self.fd, self.ebc_cmd_get_buffer, info)
    end
    if rc < 0 or info.offset == -1 then
        local err = ffi.errno()
        if lib and err == ETIMEDOUT then
            self:_vendorWedge("GET_BUFFER timeout")
        else
            self.debug("framebuffer_rk_ebc: GET_BUFFER failed errno=" .. err)
        end
        return false
    end
    local off = tonumber(info.offset)
    local need = self.ebc_stride * self.ebc_height
    if off < 0 or off + need > self.map_len then
        self.debug("framebuffer_rk_ebc: bad buffer offset", off)
        return false
    end
    local dst = ffi.cast("uint8_t*", self.data) + off
    self:_vendorConvert(dst)
    info.epd_mode = mode
    info.win_x1 = 0
    info.win_y1 = 0
    info.win_x2 = info.width > 0 and info.width or self.ebc_width
    info.win_y2 = info.height > 0 and info.height or self.ebc_height
    if lib then
        rc = lib.nativeko_ebc_send(self.fd, info)
    else
        rc = C.ioctl(self.fd, self.ebc_cmd_send_buffer, info)
    end
    if rc < 0 then
        self.debug("framebuffer_rk_ebc: SEND_BUFFER failed")
        self:_vendorWedge("SEND_BUFFER failed")
        return false
    end

    -- The HWC polls EBC status before reusing the buffer.  Do the same with
    -- a bound; a timeout here means the frame did not complete and the next
    -- GET_BUFFER would block.
    if lib then
        local st, err = self:_vendorStatus(self.ebc_status_timeout_ms)
        if not st and err == ETIMEDOUT then
            self:_vendorWedge("GET_STATUS timeout")
            return false
        end
    end
    return true
end

-- Re-arm the vendor EBC after mem resume.  The controller can come back with
-- draw mode off or a stale buffer queue; without this the first frame often
-- times out.  Reset the wedge flag so a recovered controller can be used
-- again.
function framebuffer:_vendorResume()
    self._ebc_wedged = false
    self._ebc_wedge_logged = false
    local lib = self.ebc_helper
    local rc
    if lib then
        rc = lib.nativeko_ebc_draw_enable(self.fd)
    else
        rc = C.ioctl(self.fd, self.ebc_cmd_draw_enable, nil)
    end
    if rc < 0 then
        self:_vendorWedge("resume DRAW_ENABLE failed")
        return false
    end
    if lib then
        local st, err = self:_vendorStatus(500)
        if not st and err == ETIMEDOUT then
            self:_vendorWedge("resume GET_STATUS timeout")
            return false
        end
    end
    self.debug("framebuffer_rk_ebc: EBC resumed")
    return true
end

function framebuffer:onResume()
    if self.ebc_vendor_post and self.fd and self.fd >= 0 then
        return self:_vendorResume()
    end
end


-- Screensaver/lock screen: the factory exposes EPD_FULL_DITHER (102) for
-- dithered full-screen images.  Keep this separate from refreshFullImp so
-- ordinary full refreshes still use EPD_FULL (1).
function framebuffer:refreshScreensaver()
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_screensaver or 102)
    else
        self:refreshFullImp(0, 0, self:getWidth(), self:getHeight())
    end
end

function framebuffer:_sendBuffer(epd_mode)
    if not self.ebc_enabled then return end
    local info = self._buf_info
    if not info then
        info = ffi.new("rk_ebc_buf_info")
        self._buf_info = info
    end
    info.offset = self.ebc_offset or 0
    info.epd_mode = epd_mode or self.ebc_epd_mode or 1
    info.height = self.height
    info.width = self.width
    info.vir_height = self.height
    info.vir_width = self.width
    info.fb_height = self.height
    info.fb_width = self.width
    info.color_panel = 0
    info.win_x1 = 0
    info.win_y1 = 0
    info.win_x2 = self.width - 1
    info.win_y2 = self.height - 1
    info.rotate = 270
    local rc = C.ioctl(self.fd, self.ebc_cmd_send_buffer, info)
    if rc < 0 then
        self.debug("framebuffer_rk_ebc: SEND_BUFFER failed")
    end
end

function framebuffer:_sendUpdate(px, py, pw, ph, waveform, update_mode)
    if not self.ebc_enabled then return end
    local sw, sh = self.bb.w, self.bb.h
    if px < 0 then pw = pw + px; px = 0 end
    if py < 0 then ph = ph + py; py = 0 end
    if px + pw > sw then pw = sw - px end
    if py + ph > sh then ph = sh - py end
    if pw <= 0 or ph <= 0 then return end

    local upd = self._upd
    if not upd then
        upd = ffi.new("rk_ebc_send_update")
        self._upd = upd
    end
    if self.ebc_rect_order == "xywh" then
        upd.rect[0] = px
        upd.rect[1] = py
    else
        upd.rect[0] = py
        upd.rect[1] = px
    end
    upd.rect[2] = pw
    upd.rect[3] = ph
    upd.waveform_mode = waveform
    upd.update_mode = update_mode
    upd.update_marker = self.marker
    upd.unknown_1c = self.ebc_unknown_1c
    upd.flags = self.ebc_flags
    upd.unknown_24 = 0

    local rc = C.ioctl(self.fd, self.ebc_cmd_send_update, upd)
    if rc < 0 then
        self.debug("framebuffer_rk_ebc: SEND_UPDATE failed")
    end
    self.marker = self.marker + 1
    if self.marker >= 0x7fffffff then self.marker = 1 end
end

-- Convert a logical KOReader rectangle to the physical EBC buffer rectangle
-- and refresh it.  Full repaints can re-post the buffer; partial updates reuse
-- the current one (configurable via ebc_send_buffer_each).
function framebuffer:ebcRefresh(x, y, w, h, waveform, update_mode, full)
    x, y, w, h = self.bb:getPhysicalRect(x, y, w, h)
    if full or self.ebc_send_buffer_each then
        self:_sendBuffer()
    end
    self:_sendUpdate(x, y, w, h, waveform, update_mode)
end

function framebuffer:refreshFullImp(x, y, w, h)
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_full)
        return
    end
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_full,
                    self.ebc_update_mode_full, true)
end

function framebuffer:refreshPartialImp(x, y, w, h)
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_partial)
        return
    end
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_partial, false)
end

function framebuffer:refreshNoMergePartialImp(x, y, w, h)
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_partial)
        return
    end
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_partial, false)
end

function framebuffer:refreshFlashPartialImp(x, y, w, h)
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_flash)
        return
    end
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_full, false)
end

function framebuffer:refreshUIImp(x, y, w, h)
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_ui)
        return
    end
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_partial, false)
end

function framebuffer:refreshNoMergeUIImp(x, y, w, h)
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_ui)
        return
    end
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_partial, false)
end

function framebuffer:refreshFlashUIImp(x, y, w, h)
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_flash)
        return
    end
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_full, false)
end

function framebuffer:refreshFastImp(x, y, w, h)
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_fast)
        return
    end
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_fast,
                    self.ebc_update_mode_fast, false)
end

function framebuffer:refreshA2Imp(x, y, w, h)
    if self.ebc_vendor_post then
        self:_vendorPost(self.ebc_epd_mode_a2)
        return
    end
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_fast,
                    self.ebc_update_mode_fast, false)
end

function framebuffer:refreshWaitForLastImp()
end

function framebuffer:close()
    if self.ebc_vendor_post and self.fd and self.fd >= 0 then
        if self.ebc_helper then
            self.ebc_helper.nativeko_ebc_draw_stop(self.fd)
        else
            C.ioctl(self.fd, self.ebc_cmd_draw_stop, nil)
        end
    end
    if self.bb then
        self.bb:free()
        self.bb = nil
    end
    if self.data and self.map_len > 0 then
        C.munmap(self.data, self.map_len)
        self.data = nil
    end
    if self.fd ~= nil and self.fd >= 0 then
        C.close(self.fd)
        self.fd = -1
    end
end

return require("ffi/framebuffer"):extend(framebuffer)
