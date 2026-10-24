--[[--
What the user sees of background work.

The indicator: a small box in a corner of the screen while a sync (or a
download) runs, with what it is doing ("items 40%", "annotations 12/80").
It is a "toast": it never takes a tap, which goes to whatever is beneath it.
It is repainted only when its text changes, at most every few seconds, and
only its own small area of the screen is refreshed.

The download dialog: the progress of a file being downloaded to be opened,
with a button to cancel it. The reader stays usable meanwhile.

@module zotero_indicator
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Screen = Device.screen

local M = { fork = "0.6" }

M.CORNERS = { "top_right", "top_left", "bottom_right", "bottom_left" }
local MIN_GAP = 2.5 -- seconds between two repaints of the indicator

-- ---------------------------------------------------------------------------
-- The indicator
-- ---------------------------------------------------------------------------

local Box = WidgetContainer:extend{
    name = "zotero_sync_indicator",
    toast = true,      -- above everything, never takes a tap
    corner = "top_right",
    icon_file = nil,
    text = "",
}

function Box:init()
    local face = Font:getFace("cfont", 15)
    local icon_size = Screen:scaleBySize(19)
    local pad = Screen:scaleBySize(4)
    -- wide enough for the longest text it shows
    local probe = TextWidget:new{ text = "annotations 888/888", face = face }
    local text_w = probe:getSize().w
    local text_h = probe:getSize().h
    probe:free()
    self.text_widget = TextWidget:new{ text = self.text, face = face, max_width = text_w }
    local row = HorizontalGroup:new{ align = "center" }
    if self.icon_file then
        row[#row + 1] = IconWidget:new{ file = self.icon_file, width = icon_size, height = icon_size, alpha = true }
        row[#row + 1] = HorizontalSpan:new{ width = pad }
    end
    row[#row + 1] = LeftContainer:new{ dimen = Geom:new{ w = text_w, h = math.max(text_h, icon_size) }, self.text_widget }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        padding = pad,
        padding_left = pad + Size.padding.small,
        padding_right = pad + Size.padding.small,
        row,
    }
    self[1] = self.frame
    local size = self.frame:getSize()
    local margin = Screen:scaleBySize(6)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local left = self.corner == "top_left" or self.corner == "bottom_left"
    local top = self.corner == "top_left" or self.corner == "top_right"
    self.dimen = Geom:new{
        x = left and margin or (sw - size.w - margin),
        y = top and margin or (sh - size.h - margin),
        w = size.w, h = size.h,
    }
end

function Box:paintTo(bb)
    self.frame:paintTo(bb, self.dimen.x, self.dimen.y)
end

function Box:setText(text)
    if text == self.text then return false end
    self.text = text
    self.text_widget:setText(text)
    return true
end

local box, last_paint, pending = nil, 0, nil

local function now()
    return require("ui/time").to_s(require("ui/time").now())
end

--- Show the indicator with this text (or update it).
-- @param opts.corner, opts.icon_file
function M.show(text, opts)
    opts = opts or {}
    text = tostring(text or "")
    if box and box.corner ~= (opts.corner or box.corner) then M.hide() end
    if not box then
        box = Box:new{ text = text, corner = opts.corner or "top_right", icon_file = opts.icon_file }
        UIManager:show(box, "ui", box.dimen)
        last_paint = now()
        return
    end
    box.wanted = text
    if pending then return end
    local function paint()
        pending = nil
        if not box then return end
        if box:setText(box.wanted) then
            last_paint = now()
            UIManager:setDirty(box, "fast", box.dimen)
        end
    end
    local wait = MIN_GAP - (now() - last_paint)
    if wait <= 0 then
        paint()
    else
        pending = paint
        UIManager:scheduleIn(wait, paint)
    end
end

function M.hide()
    if pending then UIManager:unschedule(pending); pending = nil end
    if box then
        local b = box
        box = nil
        UIManager:close(b, "ui", b.dimen)
    end
end

function M.shown() return box ~= nil end

-- ---------------------------------------------------------------------------
-- The download dialog
-- ---------------------------------------------------------------------------

local Dialog = InputContainer:extend{
    title = nil,
    name_text = nil,
    on_cancel = nil,
    modal = true,
}

function Dialog:init()
    local w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.8)
    self.status_widget = TextWidget:new{ text = _("Starting…"), face = Font:getFace("smallinfofont"), max_width = w }
    self.bar = ProgressWidget:new{
        width = w, height = Screen:scaleBySize(12), percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK, padding = Size.padding.small, margin = Size.margin.tiny,
    }
    local cancel = Button:new{
        text = _("Cancel"), width = math.floor(w / 2), bordersize = Size.border.button,
        callback = function()
            if self.on_cancel then self.on_cancel() end
            self:close()
        end,
        show_parent = self,
    }
    local group = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = self.title or _("Downloading"), face = Font:getFace("tfont"), bold = true, max_width = w },
        VerticalSpan:new{ width = Size.span.vertical_default },
        TextWidget:new{ text = self.name_text or "", face = Font:getFace("cfont"), max_width = w },
        VerticalSpan:new{ width = Size.span.vertical_default },
        self.status_widget,
        self.bar,
        VerticalSpan:new{ width = Size.span.vertical_large },
        cancel,
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        group,
    }
    self[1] = CenterContainer:new{ dimen = Screen:getSize(), self.frame }
    self.last = 0
end

--- @param bytes downloaded so far; total (nil: not known)
function Dialog:report(bytes, total)
    local t = now()
    if t - self.last < 1.5 and not (total and bytes >= total) then return end
    self.last = t
    local text
    if total and total > 0 then
        text = string.format("%.1f / %.1f MB", bytes / 1e6, total / 1e6)
        self.bar:setPercentage(math.min(1, bytes / total))
    else
        text = string.format("%.1f MB", bytes / 1e6)
    end
    self.status_widget:setText(text)
    if self.frame.dimen then UIManager:setDirty(self, "fast", self.frame.dimen) end
end

function Dialog:show() UIManager:show(self, "ui") end
function Dialog:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self, "ui")
end

function M.downloadDialog(opts)
    return Dialog:new(opts)
end

return M
