--[[--
The small pictures at the left of the rows of the Zotero browser.

A file: a page with its kind written across it (PDF, EPUB, WEB). Black, with
the kind in a filled band, when the file is on this device; grey, with the
band left empty, when it would have to be downloaded first.

A collection: a folder. Filled, with an arrow pointing down, when the
collection is one of those whose files a sync downloads.

They are drawn with rectangles, not taken from a font or from picture files:
the same on every device and at every size, and sharp on an e-ink screen.

@module zotero_icons
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")

local Screen = Device.screen

local Icons = { fork = "0.6" }

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GREY = Blitbuffer.COLOR_DARK_GRAY

Icons.LABELS = { pdf = "PDF", epub = "EPUB", html = "WEB" }

--- Sizes for a list whose rows are row_height high and whose text has font_size.
-- @return metrics: every picture has the size metrics.w x metrics.h
function Icons.metrics(row_height, font_size)
    -- as high as suits the text beside it (the rows of a list with few rows
    -- are much higher than their text), and never higher than the row allows
    font_size = font_size or 20
    local h = math.min(math.floor(row_height * 0.8), math.floor(Screen:scaleBySize(font_size) * 1.6))
    if h % 2 == 1 then h = h - 1 end
    local m = {
        h = h,
        line = math.max(1, math.floor(h / 22 + 0.5)),
        label_face = Font:getFace("cfont", math.max(6, math.floor(font_size * 0.52))),
        label_w = {},
    }
    -- the band is as wide as the longest kind needs, for every kind
    local widest = 0
    for kind, label in pairs(Icons.LABELS) do
        local tw = TextWidget:new{ text = label, face = m.label_face, bold = true }
        m.label_w[kind] = tw:getSize().w
        m.label_h = tw:getSize().h
        if m.label_w[kind] > widest then widest = m.label_w[kind] end
        tw:free()
    end
    m.band_h = math.min(math.floor(h * 0.46), m.label_h + 2 * m.line)
    m.w = math.max(widest + 4 * m.line + 2, math.floor(h * 0.9))
    m.page_w = math.floor(h * 0.74)
    return m
end

local Picture = Widget:extend{
    metrics = nil,
    what = nil,   -- "file" | "folder"
    kind = nil,   -- of a file
    filled = false,
}

function Picture:getSize()
    return Geom:new{ w = self.metrics.w, h = self.metrics.h }
end

local function paint_file(self, bb, x, y)
    local m = self.metrics
    local t = m.line
    local ink = self.filled and BLACK or GREY
    -- the page, its top right corner folded
    local pw, ph = m.page_w, m.h
    local px = x + math.floor((m.w - pw) / 2)
    local ear = math.floor(pw * 0.34)
    bb:paintBorder(px, y, pw, ph, t, ink)
    bb:paintRect(px + pw - ear, y, ear, ear, WHITE)
    bb:paintRect(px + pw - ear - t, y, t, ear + t, ink)       -- the fold, down
    bb:paintRect(px + pw - ear - t, y + ear, ear + t, t, ink) -- the fold, across
    for i = 0, ear - 1 do                                     -- the cut edge
        bb:paintRect(px + pw - ear + i, y + i, t, t, ink)
    end
    -- the band with the kind
    local bh = m.band_h
    local by = y + ph - bh - math.floor(ph * 0.14)
    if self.filled then
        bb:paintRect(x, by, m.w, bh, BLACK)
    else
        bb:paintRect(x, by, m.w, bh, WHITE)
        bb:paintBorder(x, by, m.w, bh, t, GREY)
    end
    local label = TextWidget:new{
        text = Icons.LABELS[self.kind] or "?",
        face = m.label_face,
        bold = true,
        fgcolor = self.filled and WHITE or GREY,
    }
    local size = label:getSize()
    label:paintTo(bb, x + math.floor((m.w - size.w) / 2), by + math.floor((bh - size.h) / 2))
    label:free()
end

local function paint_folder(self, bb, x, y)
    local m = self.metrics
    local t = m.line
    local fw = math.min(m.w, math.floor(m.h * 1.08))
    local fh = math.floor(m.h * 0.74)
    local fx = x + math.floor((m.w - fw) / 2)
    local fy = y + math.floor((m.h - fh) / 2)
    local tab_w, tab_h = math.floor(fw * 0.44), math.max(2 * t, math.floor(fh * 0.18))
    if self.filled then
        bb:paintRect(fx, fy, tab_w, tab_h, BLACK)
        bb:paintRect(fx, fy + tab_h, fw, fh - tab_h, BLACK)
        -- an arrow pointing down
        local body_h = fh - tab_h
        local head_w = math.floor(fw * 0.40)
        if head_w % 2 == 1 then head_w = head_w + 1 end
        local head_h = head_w / 2
        local stem_w = math.max(2 * t, math.floor(head_w * 0.34))
        if stem_w % 2 == 1 then stem_w = stem_w + 1 end
        local stem_h = math.max(t, math.floor(body_h * 0.62) - head_h)
        local cx = fx + math.floor(fw / 2)
        local top = fy + tab_h + math.floor((body_h - stem_h - head_h) / 2)
        bb:paintRect(cx - stem_w / 2, top, stem_w, stem_h, WHITE)
        for i = 0, head_h - 1 do
            bb:paintRect(cx - head_w / 2 + i, top + stem_h + i, head_w - 2 * i, 1, WHITE)
        end
    else
        bb:paintBorder(fx, fy, tab_w, tab_h + t, t, BLACK)
        bb:paintBorder(fx, fy + tab_h, fw, fh - tab_h, t, BLACK)
        bb:paintRect(fx + t, fy + tab_h, tab_w - 2 * t, t, WHITE) -- the tab opens into the folder
    end
end

function Picture:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.metrics.w, h = self.metrics.h }
    if self.what == "folder" then
        paint_folder(self, bb, x, y)
    else
        paint_file(self, bb, x, y)
    end
end

--- @param kind "pdf" | "epub" | "html"
-- @param on_device is the file on this device?
function Icons.file(metrics, kind, on_device)
    return Picture:new{ metrics = metrics, what = "file", kind = kind, filled = on_device and true or false }
end

--- @param downloads is this a collection whose files a sync downloads?
function Icons.folder(metrics, downloads)
    return Picture:new{ metrics = metrics, what = "folder", filled = downloads and true or false }
end

return Icons
