--[[--
A way out of the popup that follows a text selection.

With KOReader's "Highlight action: Highlight" and a "Highlight prompt"
(colour, style or both), lifting the finger from a selection brings up a
small list of colours. Whatever happens next makes a highlight: a tap on a
colour, and a tap beside the list as well (it takes the current colour). A
selection that went wrong - one word too many, the wrong line - can only be
highlighted and then deleted again through the highlight's own dialog.

This adds one button to that list, "Discard": the selection is dropped and
nothing is highlighted. Everything else stays KOReader's: the list is its
own widget with its own behaviour, with a row added.

It is the reader's popup, so it applies to every document, not only to
Zotero's.

@module zotero_highlight
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Highlight = { fork = "0.6" }

local settings          -- the plugin's LuaSettings
local ReaderHighlight   -- KOReader's class
local original_prompt   -- its showHighlightPrompt

function Highlight.enabled()
    if not settings then return false end
    return settings:readSetting("highlight_prompt_discard") ~= false -- on unless turned off
end

function Highlight.setEnabled(on)
    settings:saveSetting("highlight_prompt_discard", on and true or false)
end

--- Is the reader one this can work with? (Its popup is built from these parts.)
function Highlight.available()
    return original_prompt ~= nil
end

--- One more row in a list KOReader has built: "Discard".
local function add_discard(selector, discard)
    local ButtonDialog = require("ui/widget/buttondialog")
    table.insert(selector.buttons, { {
        text = _("Discard"),
        callback = function()
            UIManager:close(selector)
            discard()
        end,
    } })
    -- (built again with the row in it, as the widget does itself when it is kept open)
    ButtonDialog.init(selector)
end

--- KOReader's ReaderHighlight:showHighlightPrompt, with the button.
local function prompt_with_discard(self, caller_callback, prompt)
    local ButtonSelector = require("ui/widget/buttonselector")
    if self.highlight_dialog then
        UIManager:close(self.highlight_dialog)
        self.highlight_dialog = nil
    end
    if self.hold_pos and not self.selected_text then
        self:highlightFromHoldPos()
    end
    if not (self.selected_text and self.selected_text.pos0 and self.selected_text.pos1) then return end

    local function highlight(then_color)
        if then_color then
            self:showHighlightPrompt(caller_callback, "color")
        else
            local index = self:saveHighlight(true)
            self:clear()
            if caller_callback then
                caller_callback(index)
            end
        end
    end
    local function discard()
        logger.dbg("Zotero: selection discarded in the highlight prompt")
        self:clear()
    end

    local selector
    if prompt == "color" then
        selector = ButtonSelector:new{
            current_value = self.view.highlight.saved_color,
            values = self.highlight_colors,
            bg_colors = self:getHighlightColorList(),
            apply_current_value = true,
            callback = function(value)
                self.selected_text.color = value
                highlight()
            end,
            tap_close_callback = function()
                highlight()
            end,
            anchor = function()
                return self:_getDialogAnchor(selector)
            end,
        }
    else -- "style", "all"
        local function with_color()
            return prompt == "all" and self.selected_text.drawer ~= "invert"
        end
        selector = ButtonSelector:new{
            current_value = self.view.highlight.saved_drawer,
            values = ReaderHighlight.getHighlightStyles(),
            apply_current_value = true,
            callback = function(value)
                self.selected_text.drawer = value
                highlight(with_color())
            end,
            tap_close_callback = function()
                highlight(with_color())
            end,
            anchor = function()
                return self:_getDialogAnchor(selector)
            end,
        }
    end
    add_discard(selector, discard)
    UIManager:show(selector)
    return selector
end

local KNOWN_PROMPTS = { color = true, style = true, all = true }

--- Put the button into the reader's popup. Safe to call more than once.
-- @param plugin_settings LuaSettings with readSetting/saveSetting
function Highlight.install(plugin_settings)
    settings = plugin_settings
    if original_prompt then return true end
    local ok, mod = pcall(require, "apps/reader/modules/readerhighlight")
    if not ok or type(mod) ~= "table" then return false end
    -- only a reader whose popup is made the way this expects
    for __, name in ipairs({ "showHighlightPrompt", "saveHighlight", "clear", "highlightFromHoldPos",
        "getHighlightColorList", "getHighlightStyles", "_getDialogAnchor" }) do
        if type(mod[name]) ~= "function" then
            logger.info("Zotero: the highlight prompt is left as it is (this reader has no", name .. ")")
            return false
        end
    end
    if type(mod.highlight_colors) ~= "table" or not pcall(require, "ui/widget/buttonselector") then return false end
    ReaderHighlight = mod
    original_prompt = mod.showHighlightPrompt
    mod.showHighlightPrompt = function(self, caller_callback, prompt)
        local which = prompt or G_reader_settings:readSetting("highlight_prompt")
        if not Highlight.enabled() or not KNOWN_PROMPTS[which] then
            return original_prompt(self, caller_callback, prompt)
        end
        local done, result = pcall(prompt_with_discard, self, caller_callback, which)
        if not done then
            -- never in the way of highlighting: the reader's own popup instead
            logger.warn("Zotero: highlight prompt with a Discard button failed, using the reader's:", tostring(result))
            return original_prompt(self, caller_callback, prompt)
        end
        return result
    end
    return true
end

return Highlight
