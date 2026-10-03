local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Event = require("ui/event")
local _ = require("gettext")
local logger = require("logger")

local AnnotationPanel = { fork = "0.6" }

local function sourceBadge(ann)
    if ann.zoteroKey then
        return "[Z] "
    end
    return "[L] "
end
local function truncate(s, max_len)
    s = s or ""
    max_len = max_len or 80
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len - 1) .. "…"
end

local function annotationLabel(ann)
    local page = ann.pageno or ann.page or "?"
    local text = ann.note or ann.text or _("(no text)")
    return sourceBadge(ann) .. "p." .. tostring(page) .. " — " .. truncate(text, 70)
end
local function matchesFilter(ann, filter)
    if filter == nil or filter == "" then
        return true
    end
    filter = string.lower(filter)
    local hay = string.lower(
        tostring(ann.text or "")
            .. " "
            .. tostring(ann.note or "")
            .. " "
            .. tostring(ann.pageno or ann.page or "")
            .. " "
            .. tostring(ann.zoteroKey or "")
    )
    return hay:find(filter, 1, true) ~= nil
end
local function getAnnotationsFromReader(ui)
    if ui and ui.annotation and ui.annotation.annotations then
        return ui.annotation.annotations
    end
    return {}
end

function AnnotationPanel.show(ui, opts)
    opts = opts or {}
    if ui == nil then
        UIManager:show(InfoMessage:new({
            text = _("No document open."),
            timeout = 2,
        }))
        return
    end
    local filter = opts.filter or ""
    local annotations = getAnnotationsFromReader(ui)
    local items = {}
    local index_map = {}

    for i, ann in ipairs(annotations) do
        if matchesFilter(ann, filter) then
            table.insert(items, {
                text = annotationLabel(ann),
                ann = ann,
                index = i,
            })
            index_map[#items] = i
        end
    end
    if #items == 0 then
        UIManager:show(InfoMessage:new({
            text = filter ~= "" and _("No matching annotations.") or _("No annotations in this document."),
            timeout = 2,
        }))
        return
    end
    local menu
    menu = Menu:new({
        title = _("Document annotations") .. (filter ~= "" and (" — " .. filter) or ""),
        item_table = items,
        is_borderless = true,
        is_popout = true,
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function()
            local dialog
            dialog = InputDialog:new({
                title = _("Filter annotations"),
                input = filter,
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = _("Filter"),
                            is_enter_default = true,
                            callback = function()
                                local q = dialog:getInputText()
                                UIManager:close(dialog)
                                UIManager:close(menu)
                                AnnotationPanel.show(ui, { filter = q })
                            end,
                        },
                    },
                },
            })
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
        onMenuChoice = function(__, item)
            local ann = item.ann
            if ann == nil then
                return
            end
            UIManager:close(menu)
            -- Go there the way KOReader's own bookmark list does: works for
            -- page numbers (PDF) and for positions inside a book (EPUB).
            local ok = pcall(function()
                if ui.link and ui.link.addCurrentLocationToStack then
                    ui.link:addCurrentLocationToStack()
                end
                if ui.bookmark and ui.bookmark.gotoBookmark then
                    ui.bookmark:gotoBookmark(ann.page, ann.pos0)
                elseif ui.rolling then
                    ui:handleEvent(Event:new("GotoXPointer", ann.page, ann.pos0 or ann.page))
                else
                    ui:handleEvent(Event:new("GotoPage", tonumber(ann.page)))
                end
            end)
            if not ok then
                logger.warn("Zotero: could not go to the annotation")
            end
        end,
        onMenuHold = function(__, item)
            local ann = item.ann
            if ann == nil then
                return true
            end
            UIManager:show(ConfirmBox:new({
                text = ann.zoteroKey
                    and _("Delete this annotation?\n\nIt will also be deleted in Zotero at the next sync.")
                    or _("Delete this annotation?"),
                ok_text = _("Delete"),
                ok_callback = function()
                    -- Find it again (the list may have changed) and delete it
                    -- through the reader, so that everything that depends on
                    -- it - the page display, statistics, the sync's delete
                    -- log - is told.
                    local list = ui.annotation and ui.annotation.annotations or {}
                    local idx
                    for i, a in ipairs(list) do
                        if a == ann then
                            idx = i
                            break
                        end
                    end
                    if idx then
                        if ann.drawer and ui.highlight and ui.highlight.deleteHighlight then
                            ui.highlight:deleteHighlight(idx)
                        elseif ui.bookmark and ui.bookmark.removeItemByIndex then
                            ui.bookmark:removeItemByIndex(idx)
                        end
                        UIManager:close(menu)
                        AnnotationPanel.show(ui, { filter = filter })
                    end
                end,
            }))
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
        end,
    })
    UIManager:show(menu)
end
return AnnotationPanel
