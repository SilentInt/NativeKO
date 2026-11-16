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
]]

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
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_full,
                    self.ebc_update_mode_full, true)
end

function framebuffer:refreshPartialImp(x, y, w, h)
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_partial, false)
end

function framebuffer:refreshNoMergePartialImp(x, y, w, h)
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_partial, false)
end

function framebuffer:refreshFlashPartialImp(x, y, w, h)
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_full, false)
end

function framebuffer:refreshUIImp(x, y, w, h)
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_partial, false)
end

function framebuffer:refreshNoMergeUIImp(x, y, w, h)
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_partial, false)
end

function framebuffer:refreshFlashUIImp(x, y, w, h)
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_partial,
                    self.ebc_update_mode_full, false)
end

function framebuffer:refreshFastImp(x, y, w, h)
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_fast,
                    self.ebc_update_mode_fast, false)
end

function framebuffer:refreshA2Imp(x, y, w, h)
    self:ebcRefresh(x, y, w, h, self.ebc_waveform_fast,
                    self.ebc_update_mode_fast, false)
end

function framebuffer:refreshWaitForLastImp()
end

function framebuffer:close()
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
