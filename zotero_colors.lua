--[[--
Highlight colours in the reader.

KOReader has a fixed list of colour names (red, orange, yellow, green, olive,
cyan, blue, purple, gray) and one fixed RGB value per name. It draws a
highlight by tinting the page with that value. Two things follow:

  * Zotero's palette does not fit the list: Zotero has magenta, KOReader has
    olive and cyan instead;
  * on a grey e-ink screen only the brightness of a colour is left. KOReader's
    yellow is almost white there (the highlight cannot be seen) and its blue,
    purple, red and green are so dark that the text under them is hard to read.

Both the list and the values are plain Lua tables that the reader looks up
whenever it shows the colour picker or draws a highlight. This module replaces
their contents while KOReader runs; nothing of KOReader is changed on disk,
and an annotation keeps its colour *name*, so sync is not affected.

  palette  the picker offers Zotero's eight colours, in Zotero's order
  tints    every colour is drawn as a grey of a chosen darkness (per colour)

Olive and cyan stay drawable (existing highlights keep working); they are
simply no longer offered for new highlights while the palette is on.
]]

local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")

local Colors = { fork = "0.6" }

-- Zotero's palette in the order of Zotero's own picker: label, name, colour
local ZOTERO = {
    { _("Yellow"), "yellow", "#FFD400" },
    { _("Red"), "red", "#FF6666" },
    { _("Green"), "green", "#5FB236" },
    { _("Blue"), "blue", "#2EA8E5" },
    { _("Purple"), "purple", "#A28AE5" },
    { _("Magenta"), "magenta", "#E56EEE" },
    { _("Orange"), "orange", "#F19837" },
    { _("Gray"), "gray", nil }, -- drawn by KOReader's own "gray highlight opacity"
}

-- Darkness of the tint in percent (0 = white, 100 = black). Readability comes
-- first: nothing is dark enough to make the text under it hard to read. Three
-- steps can be told apart: yellow (the usual highlight), green, the others.
local DEFAULT_LEVEL = {
    yellow = 14,
    green = 28,
    orange = 36,
    red = 50,
    blue = 50,
    purple = 50,
    magenta = 50,
}
-- KOReader colours Zotero does not have are drawn like their nearest relative
local DRAWN_LIKE = { olive = "green", cyan = "blue" }

Colors.TINTED = { "yellow", "red", "green", "blue", "purple", "magenta", "orange" }

local settings          -- a LuaSettings object (the plugin's)
local original_values   -- KOReader's own palette
local original_list     -- KOReader's own picker list
local ReaderHighlight

--- Can this device show colour at all? (The hardware, not the reader's
-- "color rendering" switch: grey tints make sense on any grey screen.)
local function color_screen()
    local ok, res = pcall(function()
        return require("device"):hasColorScreen()
    end)
    return ok and res and true or false
end

--- @param plugin_settings LuaSettings with readSetting/saveSetting
function Colors.init(plugin_settings)
    settings = plugin_settings
    if not original_values then
        original_values = {}
        for k, v in pairs(Blitbuffer.HIGHLIGHT_COLORS) do original_values[k] = v end
    end
    if not original_list then
        local ok, mod = pcall(require, "apps/reader/modules/readerhighlight")
        if ok and type(mod) == "table" and type(mod.highlight_colors) == "table" then
            ReaderHighlight = mod
            original_list = {}
            for i, v in ipairs(mod.highlight_colors) do original_list[i] = v end
        end
    end
end

function Colors.paletteEnabled()
    if not settings then return false end
    return settings:readSetting("highlight_palette") ~= false -- on unless turned off
end

function Colors.tintsEnabled()
    if not settings then return false end
    local v = settings:readSetting("highlight_tints")
    if v == nil then return not color_screen() end -- automatic: on for grey screens
    return v == true
end

function Colors.setPaletteEnabled(on)
    settings:saveSetting("highlight_palette", on and true or false)
end

function Colors.setTintsEnabled(on)
    settings:saveSetting("highlight_tints", on and true or false)
end

--- Darkness (percent) of a colour's tint.
function Colors.level(name)
    local saved = settings and settings:readSetting("highlight_tint_levels")
    local v = type(saved) == "table" and tonumber(saved[name]) or nil
    v = v or DEFAULT_LEVEL[name] or 30
    return math.max(0, math.min(90, math.floor(v + 0.5)))
end

function Colors.setLevel(name, percent)
    local saved = settings:readSetting("highlight_tint_levels")
    if type(saved) ~= "table" then saved = {} end
    saved[name] = math.max(0, math.min(90, math.floor((tonumber(percent) or 0) + 0.5)))
    settings:saveSetting("highlight_tint_levels", saved)
end

function Colors.resetLevels()
    settings:delSetting("highlight_tint_levels")
end

local function grey(percent)
    local v = math.floor(255 * (1 - percent / 100) + 0.5)
    return string.format("#%02X%02X%02X", v, v, v)
end

--- Put the chosen palette and tints in place (or KOReader's own back).
function Colors.apply()
    if not original_values then return false end
    local values = {}
    for k, v in pairs(original_values) do values[k] = v end
    -- Zotero's magenta is always a colour the reader can draw
    values.magenta = "#E56EEE"
    local palette, tints = Colors.paletteEnabled(), Colors.tintsEnabled()
    if palette then
        for __, c in ipairs(ZOTERO) do
            if c[3] then values[c[2]] = c[3] end
        end
    end
    if tints then
        for __, name in ipairs(Colors.TINTED) do
            values[name] = grey(Colors.level(name))
        end
        for name, like in pairs(DRAWN_LIKE) do
            values[name] = grey(Colors.level(like))
        end
    end
    -- in place: the reader holds on to these tables
    local target = Blitbuffer.HIGHLIGHT_COLORS
    for k in pairs(target) do target[k] = nil end
    for k, v in pairs(values) do target[k] = v end

    if ReaderHighlight and original_list then
        local list = ReaderHighlight.highlight_colors
        for i = #list, 1, -1 do list[i] = nil end
        if palette then
            for i, c in ipairs(ZOTERO) do list[i] = { c[1], c[2] } end
        else
            for i, v in ipairs(original_list) do list[i] = v end
        end
    end
    return true
end

--- Label of a colour for menus.
function Colors.label(name)
    for __, c in ipairs(ZOTERO) do
        if c[2] == name then return c[1] end
    end
    return name
end

return Colors
