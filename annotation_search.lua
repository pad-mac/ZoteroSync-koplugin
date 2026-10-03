local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")
local logger = require("logger")
local ZoteroAPI = require("zoteroapi")
local Event = require("ui/event")

local AnnotationSearch = { fork = "0.6" }
local function truncate(s, max_len)
    s = s or ""
    max_len = max_len or 90
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len - 1) .. "…"
end
local function resultLabel(row)
    local page = row.page ~= "" and ("p." .. row.page .. " — ") or ""
    local body = row.comment ~= "" and row.comment or row.text
    if body == nil or body == "" then
        body = _("(empty)")
    end
    local title = row.parentTitle ~= "" and row.parentTitle or (row.attachmentKey or "?")
    return truncate(title, 40) .. "\n" .. page .. truncate(body, 80)
end
function AnnotationSearch.show(plugin, initial_query)
    local dialog
    dialog = InputDialog:new({
        title = _("Search annotations"),
        input = initial_query or "",
        input_hint = _("text, comment, title…"),
        description = _("Search highlights and notes across the synchronized Zotero library."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local q = dialog:getInputText()
                        UIManager:close(dialog)
                        AnnotationSearch.showResults(plugin, q)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end
function AnnotationSearch.showResults(plugin, query)
    local ok, results = pcall(ZoteroAPI.searchAnnotations, query)
    if not ok then
        logger.err("Zotero: searchAnnotations failed: ", results)
        UIManager:show(InfoMessage:new({
            text = _("Annotation search failed."),
            timeout = 3,
            icon = "notice-warning",
        }))
        return
    end
    if results == nil or #results == 0 then
        UIManager:show(InfoMessage:new({
            text = _("No annotations found."),
            timeout = 2,
        }))
        return
    end
    local items = {}
    for __, row in ipairs(results) do
        table.insert(items, {
            text = resultLabel(row),
            row = row,
        })
    end
    local menu
    menu = Menu:new({
        title = _("Annotation results") .. " (" .. #items .. ")",
        item_table = items,
        is_borderless = true,
        is_popout = true,
        multilines_show_more_text = true,
        onMenuChoice = function(__, item)
            local row = item.row
            if row == nil or row.attachmentKey == nil then
                return
            end
            UIManager:close(menu)
            AnnotationSearch.openAnnotation(plugin, row)
        end,
        close_callback = function()
            UIManager:close(menu)
        end,
    })
    UIManager:show(menu)
end
function AnnotationSearch.openAnnotation(plugin, row)
    local item = ZoteroAPI.getItem(row.attachmentKey)
    if item == nil then
        UIManager:show(InfoMessage:new({
            text = _("Attachment not found in local library."),
            timeout = 3,
            icon = "notice-warning",
        }))
        return
    end
    local function open_path(path)
        if path == nil then
            return
        end
        -- Where to go is remembered and used once the document is open and
        -- its Zotero annotations are in place (see jumpIfPending).
        AnnotationSearch.pending_jump = { key = row.key, path = path, page = tonumber(row.page), at = os.time() }
        local ReaderUI = require("apps/reader/readerui")
        local current = ReaderUI.instance
        if current and current.document and ZoteroAPI.pathsEqual(current.document.file, path) then
            AnnotationSearch.jumpIfPending(current) -- this very document is open
        elseif plugin and plugin.ui and plugin.ui.switchDocument then
            plugin.ui:switchDocument(path)
        elseif plugin and plugin.ui and plugin.ui.openFile then
            plugin.ui:openFile(path)
        else
            ReaderUI:showReader(path)
        end
    end
    local local_path = ZoteroAPI.resolveAttachmentPath(item)
    if local_path then
        open_path(local_path)
        return
    end
    NetworkMgr:runWhenOnline(function()
        local path, err = ZoteroAPI.downloadAndGetPath(item.key)
        if path then
            open_path(path)
        else
            UIManager:show(InfoMessage:new({
                text = _("Could not open attachment: ") .. tostring(err or _("unknown error")),
                timeout = 4,
                icon = "notice-warning",
            }))
        end
    end)
end

--- Is the document that has just been opened the one an annotation was
-- chosen in (so that the reader is about to go to that annotation)?
function AnnotationSearch.isPending(ui)
    local jump = AnnotationSearch.pending_jump
    return jump ~= nil and os.time() - (jump.at or 0) <= 120
        and ui ~= nil and ui.document ~= nil and ZoteroAPI.pathsEqual(ui.document.file, jump.path) or false
end

--- Go to the annotation chosen in the search results, if the document that
-- has just been opened is the one it belongs to.
-- @param ui the ReaderUI of the open document
function AnnotationSearch.jumpIfPending(ui)
    local jump = AnnotationSearch.pending_jump
    if not jump then
        return false
    end
    AnnotationSearch.pending_jump = nil
    if os.time() - (jump.at or 0) > 120 then
        return false
    end
    if not ui or not ui.document or not ZoteroAPI.pathsEqual(ui.document.file, jump.path) then
        return false
    end
    local ok, err = pcall(function()
        for __, ann in ipairs(ui.annotation and ui.annotation.annotations or {}) do
            if ann.zoteroKey == jump.key then
                if ui.link and ui.link.addCurrentLocationToStack then
                    ui.link:addCurrentLocationToStack()
                end
                ui.bookmark:gotoBookmark(ann.page, ann.pos0)
                return
            end
        end
        -- Not in the document (a kind of annotation the reader does not
        -- show, or one that could not be placed): at least its page, in a PDF.
        if ui.paging and jump.page then
            ui:handleEvent(Event:new("GotoPage", jump.page))
        end
    end)
    if not ok then
        logger.warn("Zotero: could not go to the annotation:", tostring(err))
    end
    return ok
end

return AnnotationSearch
