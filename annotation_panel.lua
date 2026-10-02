local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local logger = require("logger")

local AnnotationPanel = {}

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
        onMenuChoice = function(_, item)
            local ann = item.ann
            if ann == nil then
                return
            end
            local page = ann.pageno or ann.page
            if page and ui.paging and ui.paging.onGotoPage then
                ui.paging:onGotoPage(tonumber(page))
            elseif page and ui.link and ui.link.onGotoPage then
                ui.link:onGotoPage(tonumber(page))
            elseif page and ui.document and ui.document.gotoPage then
                pcall(function()
                    ui.document:gotoPage(tonumber(page))
                    UIManager:setDirty(ui.view and ui.view.dialog or "all", "partial")
                end)
            elseif ann.pos0 and ann.pos0.xpointer and ui.link and ui.link.onGotoXPointer then
                ui.link:onGotoXPointer(ann.pos0.xpointer)
            end
            UIManager:close(menu)
        end,
        onMenuHold = function(_, item)
            local ann = item.ann
            if ann == nil then
                return true
            end
            UIManager:show(ConfirmBox:new({
                text = _("Delete this annotation?"),
                ok_text = _("Delete"),
                ok_callback = function()
                    local idx = item.index
                    if ui.annotation and ui.annotation.annotations and idx then
                        table.remove(ui.annotation.annotations, idx)
                        if ui.annotation.onAnnotationsModified then
                            pcall(function()
                                ui.annotation:onAnnotationsModified()
                            end)
                        elseif ui.doc_settings then
                            ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
                            ui.doc_settings:flush()
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
