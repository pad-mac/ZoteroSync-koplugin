--[[--
The small pictures at the left of the rows of the Zotero browser.

A file: a page with its kind written across it (PDF, EPUB, WEB). Black, with
the kind in a filled band, when the file is on this device; grey, with the
band left empty, when it would have to be downloaded first.

A collection: a folder. Filled, with an arrow pointing down, when the
collection is one of those whose files a sync downloads.

A group library: two people.

The buttons of the browser's title bar (sync, sort) are pictures in the
style of the reader's own icons, written once as files (Icons.svg).

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

--- A filled disc (radius r, centre cx, cy), drawn row by row.
local function disc(bb, cx, cy, r, color)
    for dy = -r, r do
        local half = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
        if half > 0 then bb:paintRect(cx - half, cy + dy, 2 * half, 1, color) end
    end
end
--- Head and shoulders, `size` high, its top at y.
local function person(bb, cx, y, size, color, grow)
    grow = grow or 0
    local r = math.floor(size * 0.22) + grow
    disc(bb, cx, y + r, r, color)
    local top = y + math.floor(size * 0.50) - grow
    local half_w = math.floor(size * 0.38) + grow
    local h = y + size - top + grow
    for row = 0, h - 1 do
        -- the upper half of an ellipse: shoulders
        local t = 1 - row / h
        local half = math.floor(half_w * math.sqrt(math.max(0, 1 - t * t)) + 0.5)
        if half > 0 then bb:paintRect(cx - half, top + row, 2 * half, 1, color) end
    end
end

local function paint_group(self, bb, x, y)
    local m = self.metrics
    local size = math.floor(m.h * 0.80)
    local top = y + math.floor((m.h - size) / 2)
    local cx = x + math.floor(m.w / 2)
    local back_size = math.floor(size * 0.82)
    -- the one behind, then the one in front with a white rim between them
    person(bb, cx + math.floor(size * 0.26), top, back_size, BLACK)
    person(bb, cx - math.floor(size * 0.12), top + size - back_size - math.floor(size * 0.0), size, WHITE, 2 * m.line)
    person(bb, cx - math.floor(size * 0.12), top + size - back_size - math.floor(size * 0.0), size, BLACK)
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
    elseif self.what == "group" then
        paint_group(self, bb, x, y)
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

--- A group library.
function Icons.group(metrics)
    return Picture:new{ metrics = metrics, what = "group" }
end

-- ---------------------------------------------------------------------------
-- Pictures for buttons, as SVG files
-- ---------------------------------------------------------------------------

local SVG = {
    ["zotero.sync"] = [[<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><path style="fill:none;stroke:#000000;stroke-width:2;stroke-linecap:round;stroke-linejoin:round" d="M 36.80 21.74 A 13 13 0 0 0 11.44 20.64 M 11.20 26.26 A 13 13 0 0 0 36.56 27.36 M 15.84 17.33 L 11.44 20.64 L 9.29 15.57 M 32.16 30.67 L 36.56 27.36 L 38.71 32.43"/></svg>]],
    ["zotero.sync.busy"] = [[<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><path style="fill:none;stroke:#000000;stroke-width:2;stroke-linecap:round;stroke-linejoin:round" d="M 36.80 21.74 A 13 13 0 0 0 11.44 20.64 M 11.20 26.26 A 13 13 0 0 0 36.56 27.36 M 15.84 17.33 L 11.44 20.64 L 9.29 15.57 M 32.16 30.67 L 36.56 27.36 L 38.71 32.43"/><rect x="20" y="20" width="8" height="8" style="fill:#000000;stroke:none"/></svg>]],
    ["zotero.sort"] = [[<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><path style="fill:none;stroke:#000000;stroke-width:2;stroke-linecap:round;stroke-linejoin:round" d="M 7 13 L 29 13 M 7 24 L 24 24 M 7 35 L 19 35 M 37 9 L 37 38 M 40.86 33.40 L 37.00 38.00 L 33.14 33.40"/></svg>]],
}

--- The file of a button picture ("zotero.sync", "zotero.sync.busy",
-- "zotero.sort"), written into `dir` if it is not there as it should be.
-- @return its path, or nil
function Icons.svg(name, dir)
    local content = SVG[name]
    if not content or not dir then return nil end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local path = dir .. "/" .. name .. ".svg"
    local f = io.open(path, "rb")
    local have = f and f:read("*a")
    if f then f:close() end
    if have ~= content then
        f = io.open(path, "wb")
        if not f then return nil end
        f:write(content)
        f:close()
    end
    return path
end

return Icons
