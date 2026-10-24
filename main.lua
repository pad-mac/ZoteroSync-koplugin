local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher") -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SpinWidget = require("ui/widget/spinwidget")
local DataStorage = require("datastorage")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local Geom = require("ui/geometry")
local _ = require("gettext")
-- KOReader keeps the plugin's folder on the module path only while this file
-- is being loaded, so every module of the plugin is required here, at the top.
local ZoteroAPI = require("zoteroapi")
local Annotations = require("annotations")
local Util = require("zotero_util")
local Sync = require("zotero_sync")
local Doc = require("zotero_doc")
local AnnotationSync = require("zotero_annsync")
local Colors = require("zotero_colors")
local Position = require("zotero_position")
local Icons = require("zotero_icons")
local Highlight = require("zotero_highlight")
local Update = require("zotero_update")
local itemInfoViewer = require("zoteroiteminfo")
local AnnotationPanel = require("annotation_panel")
local AnnotationSearch = require("annotation_search")
local Notification = require("ui/widget/notification")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local DocSettings = require("docsettings")
local Trapper = require("frontend/ui/trapper")
local DEFAULT_LINES_PER_PAGE = 14

local init_done = false

-- KOReader keeps one module per name for all plugins. Another Zotero plugin
-- (the original zotero.koplugin, or a second copy of this one under another
-- folder name) has modules called "zoteroapi" and "annotations" too, and
-- whichever plugin is loaded first wins. This plugin cannot run on theirs.
local FORK = "0.6"
local foreign_modules = {}
for name, mod in pairs({
    zoteroapi = ZoteroAPI, annotations = Annotations, zotero_util = Util, zotero_sync = Sync,
    zotero_doc = Doc, zotero_annsync = AnnotationSync, zotero_colors = Colors, zotero_position = Position, zoteroiteminfo = itemInfoViewer,
    annotation_panel = AnnotationPanel, annotation_search = AnnotationSearch, zotero_icons = Icons,
    zotero_highlight = Highlight, zotero_update = Update,
}) do
    if type(mod) ~= "table" or mod.fork ~= FORK then
        foreign_modules[#foreign_modules + 1] = name
    end
end
table.sort(foreign_modules)

local function init_error(e)
    logger.err("Zotero: could not initialize:", tostring(e), debug.traceback())
end

-- os.time() of the last sign of life of a sync that is running
local sync_alive_at

local function syncBusy()
    return sync_alive_at ~= nil and os.time() - sync_alive_at < 300
end

local function readableStatus(value)
    if value == nil then return nil end
    if type(value) ~= "table" then return tostring(value) end
    local ok, json = pcall(require, "json")
    if ok and json and json.encode then
        local encoded_ok, encoded = pcall(json.encode, value)
        if encoded_ok and encoded then return encoded end
    end
    local parts = {}
    for k, v in pairs(value) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        if #parts >= 12 then
            parts[#parts + 1] = "…"
            break
        end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

--- Progress reporting for a sync that runs inside Trapper:wrap.
-- Every message shown costs a tenth of a second and a screen refresh, so the
-- same kind of message is shown at most once per second. The function
-- returns false from the moment the user chooses to stop the sync.
local function makeProgress(not_stoppable)
    local last_kind, last_time
    local stopped = false
    local hint = not_stoppable and "" or ("\n\n" .. _("(Tap this message to stop.)"))
    local function progress(msg)
        sync_alive_at = os.time()
        if stopped then return false end
        local text = readableStatus(msg) or ""
        local kind = text:gsub("%d+", "#")
        local now = os.time()
        if kind == last_kind and now == last_time then return true end
        last_kind, last_time = kind, now
        if Trapper:info(text .. hint) == false then
            stopped = true
            return false
        end
        return true
    end
    return progress, function() return stopped end
end

local table_empty = function(table)
    -- see https://stackoverflow.com/a/1252776
    local next = next
    return (next(table) == nil)
end

local function truncatePath(p, max_len)
    max_len = max_len or 40
    if p == nil or p == "" then
        return _("(not set)")
    end
    if #p <= max_len then
        return p
    end
    return "…" .. p:sub(-max_len + 2)
end
-- Writing highlights into the PDF file itself.
--
-- For a PDF that belongs to Zotero this is off unless the user turns it on:
-- annotations travel as Zotero annotations, and a second copy embedded in the
-- file would change the attachment on this device only (it no longer matches
-- the file Zotero has) and show up twice wherever both are displayed.
local function pdfWritingDisabled()
    local settings = ZoteroAPI.getSettings()
    if settings:has("auto_disable_pdf_writing") then
        return settings:isTrue("auto_disable_pdf_writing") -- an explicit choice made in the menu
    end
    return true
end
local function configureZoteroDocumentSettings(file_path)
    if file_path and file_path:lower():match("%.pdf$") then
        local want = not pdfWritingDisabled()
        local doc_settings = DocSettings:open(file_path)
        if doc_settings:readSetting("highlight_write_into_pdf") ~= want then
            logger.info("Zotero: write highlights into PDF", want and "on" or "off", "for", file_path)
            doc_settings:saveSetting("highlight_write_into_pdf", want)
            doc_settings:flush()
        end
    end
end
local ZoteroBrowser = Menu:extend({
    no_title = false,
    is_borderless = true,
    is_popout = false,
    show_path = true,
    --    subtitle = "test path",
    title_bar_fm_style = true,
    parent = nil,
    title_bar_left_icon = "appbar.search",
    covers_full_screen = true,
    return_arrow_propagation = false,
    -- Slightly ugly using the option below, but better than truncated single line:
    multilines_show_more_text = true,
})
function ZoteroBrowser:init()
    Menu.init(self)
    self.paths = {}
    self.keys = {}
end
-- Show search input
function ZoteroBrowser:onLeftButtonTap()
    local search_query_dialog
    search_query_dialog = InputDialog:new({
        title = _("Search Zotero titles"),
        input = "",
        input_hint = "search query",
        description = _("This will search title and first author of all entries."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(search_query_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(search_query_dialog)
                        self:displaySearchResults(search_query_dialog:getInputText())
                    end,
                },
            },
        },
    })
    UIManager:show(search_query_dialog)
    search_query_dialog:onShowKeyboard()
end
function ZoteroBrowser:onReturn()
    table.remove(self.paths, #self.paths)
    table.remove(self.keys, #self.keys)
    local top = self.keys[#self.keys]
    if top == nil then
        self:displayCollection(nil)
    elseif top == "search" then
        -- back to an earlier search: shown again (it puts itself on the path)
        local query = table.remove(self.paths, #self.paths)
        table.remove(self.keys, #self.keys)
        self:displaySearchResults(query)
    else
        self:displayCollection(top)
    end
    return true
end
function ZoteroBrowser:openResolvedFile(full_path)
    if self.download_dialog then
        UIManager:close(self.download_dialog)
        self.download_dialog = nil
    end
    configureZoteroDocumentSettings(full_path)
    local close_cb = self.close_callback
    UIManager:scheduleIn(0.05, function()
        if close_cb then
            close_cb()
        end
        require("apps/reader/readerui"):showReader(full_path)
    end)
end
function ZoteroBrowser:showOpenError(e)
    local err_text = ""
    if e ~= nil then
        err_text = " " .. tostring(e)
    end
    UIManager:show(InfoMessage:new({
        text = _("Could not open file.") .. err_text,
        timeout = 5,
        icon = "notice-warning",
    }))
end
function ZoteroBrowser:openAttachment(key)
    local local_path, local_err = ZoteroAPI.tryResolveLocalAttachment(key)
    if local_err ~= nil then
        self:showOpenError(local_err)
        return
    end
    if local_path then
        self:openResolvedFile(local_path)
        return
    end
    self.download_dialog = InfoMessage:new({
        text = _("Downloading file"),
        timeout = 5,
        icon = "notice-info",
    })
    UIManager:show(self.download_dialog)
    NetworkMgr:runWhenOnline(function()
        local full_path, e = ZoteroAPI.downloadAndGetPath(key)
        if e ~= nil or full_path == nil then
            UIManager:close(self.download_dialog)
            self:showOpenError(e)
        else
            self:openResolvedFile(full_path)
        end
    end)
end
local KIND_LABEL = { pdf = "PDF", epub = "EPUB", html = _("Web snapshot") }

--- An entry was tapped: open its file. Links to web pages (a Google Books
-- link, say) are not files and are passed over; if the entry has several
-- files of the same kind, the user chooses.
function ZoteroBrowser:openItem(key, title)
    local attachments = ZoteroAPI.getItemAttachments(key)
    if attachments == nil or table_empty(attachments) then
        UIManager:show(InfoMessage:new({
            text = _("The selected entry does not have any attachments."),
            timeout = 5,
            icon = "notice-warning",
        }))
        return
    end
    local pick, usable = ZoteroAPI.pickAttachment(key)
    if pick then
        self:openAttachment(pick.key)
        return
    end
    if #usable == 0 then
        UIManager:show(InfoMessage:new({
            text = _("This entry has no file that can be opened here (PDF, EPUB or web snapshot); its attachments are links to web pages or files of other kinds."),
            timeout = 6,
            icon = "notice-warning",
        }))
        return
    end
    local dialog
    local buttons = {}
    for __, attachment in ipairs(usable) do
        buttons[#buttons + 1] = { {
            text = (KIND_LABEL[attachment.kind] or "?") .. " · " .. tostring(attachment.text),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:openAttachment(attachment.key)
            end,
        } }
    end
    dialog = ButtonDialog:new({
        title = title and (tostring(title) .. "\n" .. _("Which file?")) or _("Which file?"),
        buttons = buttons,
    })
    UIManager:show(dialog)
end
function ZoteroBrowser:onMenuSelect(item)
    if item.type == "collection" then
        table.insert(self.paths, item.text)
        table.insert(self.keys, item.key)
        self:displayCollection(item.key)
    elseif item.type == "wildcard_collection" then
        -- (one level, as a search for everything: one Return leads back)
        self:displaySearchResults("")
    elseif item.type == "item" then
        self:openItem(item.key, item.text)
    elseif item.type == "attachment" then
        self:openAttachment(item.key)
    elseif item.type == "label" then
        -- nop
    end
end
function ZoteroBrowser:onMenuHold(item)
    if item.type == "item" then
        --table.insert(self.paths, item.key)
        --table.insert(self.keys, item.key)
        --self:displayAttachments(item.key)
        local itemDetails = ZoteroAPI.getItemWithAttachments(item.key)
        local itemInfo = itemInfoViewer:new()
        itemInfo:show(itemDetails, function(key)
            self:openAttachment(key)
        end)
    elseif item.type == "collection" then
        local is_offline_enabled = ZoteroAPI.isOfflineCollection(item.key)
        local button_label = "▢  Download this collection during sync"
        if is_offline_enabled then
            button_label = "✓ Download this collection during sync"
        end
        local collection_dialog
        collection_dialog = ButtonDialog:new({
            title = item.text,
            buttons = {
                {
                    {
                        text = button_label,
                        callback = function()
                            if is_offline_enabled then
                                ZoteroAPI.removeOfflineCollection(item.key)
                            else
                                ZoteroAPI.addOfflineCollection(item.key)
                            end
                            UIManager:close(collection_dialog)
                            -- the folder in the list shows the choice
                            item.offline = not is_offline_enabled
                            item.decorated = nil
                            self:updateItems()
                        end,
                    },
                },
            },
        })
        UIManager:show(collection_dialog)
    end
end
function ZoteroBrowser:displaySearchResults(query)
    local items = ZoteroAPI.displaySearchResults(query)
    table.insert(self.paths, query)
    table.insert(self.keys, "search")
    items = self:addLabelIfEmpty(items, "No search results!")
    self:setItems(items)
end

function ZoteroBrowser:displayCollection(collection_id)
    local items = ZoteroAPI.displayCollection(collection_id)
    if collection_id == nil then
        if table_empty(items) then
            items = self:addLabelIfEmpty(items, "Library is empty! Synchronise first...")
        else
            table.insert(items, 1, {
                ["text"] = _("All Items"),
                ["type"] = "wildcard_collection",
            })
        end
    else
        items = self:addLabelIfEmpty(items)
    end
    self:setItems(items)
end
function ZoteroBrowser:addLabelIfEmpty(items, msg)
    if table_empty(items) then
        if msg == nil then
            msg = "No Items"
        end
        table.insert(items, 1, {
            ["text"] = _(msg),
            ["type"] = "label",
        })
    end

    return items
end

function ZoteroBrowser:displayAttachments(key)
    local attachments = ZoteroAPI.getItemAttachments(key) or {}
    attachments = self:addLabelIfEmpty(attachments)

    self:setItems(attachments)
end
function ZoteroBrowser:zPath()
    local path = "HOME"
    if #self.paths > 0 then
        if self.keys[#self.keys] == "search" then
            if self.paths[#self.paths] == "" then
                path = "/" .. _("All Items")
            else
                path = "Search results: '" .. self.paths[#self.paths] .. "'"
            end
        else
            path = "/" .. table.concat(self.paths, "/")
        end
    end
    return path
end

function ZoteroBrowser:setItems(items, subtitle)
    local subtitle = self:zPath()
    self:switchItemTable("Zotero Browser", items, nil, nil, subtitle)
end

--- What a row shows besides its text. Collections are set in bold, with a
-- folder; an entry gets the picture of the file a tap opens, black when that
-- file is on this device, grey when it has to be downloaded first.
-- Worked out for the rows of the page that is shown, when it is shown: a
-- collection may hold hundreds of entries, and each one costs a look at the
-- database and at the storage folder.
function ZoteroBrowser:decoratePage()
    local items = self.item_table
    if type(items) ~= "table" or not self.item_dimen or not self.perpage or not self.page then return end
    if not self.icon_metrics or self.icon_metrics_h ~= self.item_dimen.h or self.icon_metrics_font ~= self.font_size then
        self.icon_metrics = Icons.metrics(self.item_dimen.h, self.font_size)
        self.icon_metrics_h, self.icon_metrics_font = self.item_dimen.h, self.font_size
        self.state_w = self.icon_metrics.w + math.floor(self.icon_metrics.h * 0.3)
        for __, item in ipairs(items) do item.decorated = nil end
    end
    local m = self.icon_metrics
    local first = (self.page - 1) * self.perpage + 1
    for index = first, math.min(#items, first + self.perpage - 1) do
        local item = items[index]
        if not item.decorated then
            item.decorated = true
            item.state, item.bold = nil, nil
            if item.type == "collection" or item.type == "wildcard_collection" then
                item.bold = true
                item.state = Icons.folder(m, item.offline)
            elseif item.type == "item" or item.type == "attachment" then
                local ok, kind, on_device = pcall(ZoteroAPI.entryFileState, item.key, item.type == "attachment")
                if not ok then
                    logger.warn("Zotero: state of entry", tostring(item.key), "not determined:", tostring(kind))
                elseif kind then
                    item.file_kind, item.on_device = kind, on_device
                    item.state = Icons.file(m, kind, on_device)
                end
            end
        end
    end
end

function ZoteroBrowser:updateItems(select_number, no_recalculate_dimen)
    local ok, err = pcall(self.decoratePage, self)
    if not ok then logger.warn("Zotero: browser rows not decorated:", tostring(err)) end
    Menu.updateItems(self, select_number, no_recalculate_dimen)
end
local Plugin = WidgetContainer:new({
    name = "zoteroatelier",
    is_doc_only = false,
})
function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("zotero_browser_action", {
        category = "none",
        event = "ZoteroBrowserAction",
        title = _("Zotero Atelier Collection Browser"),
        general = true,
    })
    Dispatcher:registerAction("zotero_sync_action", {
        category = "none",
        event = "ZoteroSyncAction",
        title = _("Zotero Atelier Sync"),
        general = true,
    })
end
--- Run fn without treating the annotation changes it makes as the user's.
function Plugin:guarded(fn)
    local was = self._applying
    self._applying = true
    local ok, err = pcall(fn)
    self._applying = was
    if not ok then error(err, 0) end
end

--- Repaint and tell the user after annotations of the open document changed.
function Plugin:afterAnnotationChanges(stats, repaired, quiet)
    local ui = self.ui
    local changed = (repaired or 0) > 0 or (stats ~= nil and Sync.changedLocally(stats))
    if changed and ui then
        UIManager:setDirty(ui.dialog or "all", "ui")
    end
    if quiet or not changed then return end
    local parts = {}
    if stats then
        local done = Sync.summary(stats)
        for i = 1, #done do parts[#parts + 1] = done[i] end
        if stats.unplaced > 0 then
            parts[#parts + 1] = string.format(_("%d could not be placed"), stats.unplaced)
        end
    end
    if (repaired or 0) > 0 then
        parts[#parts + 1] = _("annotation list repaired")
    end
    if #parts > 0 then
        -- (with a source, or the reader may keep it to itself)
        Notification:notify(_("Zotero: ") .. table.concat(parts, ", "), Notification.SOURCE_ALWAYS_SHOW)
    end
end

--- Bring the open document up to date with the local copy of the library
-- (new and changed Zotero annotations, deletions). No network, no uploads.
function Plugin:importOpenDocument()
    local ui = self.ui
    if not init_done or not ui or not ui.document then return end
    local stats, repaired = AnnotationSync.openDocument(ui, function(fn) self:guarded(fn) end)
    if stats or (repaired or 0) > 0 then
        self:afterAnnotationChanges(stats, repaired)
    end
    -- opened from the annotation search: the reader goes to that annotation,
    -- not to where Zotero was last
    self:applyZoteroPosition(false, AnnotationSearch.isPending(ui))
end

--- Go to where Zotero last read the open document, if that is news.
-- @return the page gone to, or nil
function Plugin:applyZoteroPosition(quiet, stay)
    local ui = self.ui
    if not init_done or not ui or not ui.document then return nil end
    local ok, page = pcall(function()
        local key, file_path = AnnotationSync.identify(ui)
        if not key or not AnnotationSync.kindOf(file_path) then return nil end
        return Position.apply(ui, key, stay)
    end)
    if not ok then
        logger.warn("Zotero: applying the reading position failed:", tostring(page))
        return nil
    end
    if page and not quiet then
        Notification:notify(string.format(_("Zotero: continued on page %s (Back returns)"), tostring(page)),
            Notification.SOURCE_ALWAYS_SHOW)
    end
    return page
end

-- ---------------------------------------------------------------------------
-- A profile per kind of document
--
-- KOReader's profiles (Tools > Profiles) hold a set of settings - font,
-- margins, line spacing, zoom, ... - that is applied in one go. Here one of
-- them can be named for each kind of Zotero document; it is applied when a
-- document of that kind is opened. Only for documents that belong to Zotero:
-- other books keep to KOReader's own rules.
-- ---------------------------------------------------------------------------
local PROFILE_KINDS = { "pdf", "epub", "html" }

--- KOReader's profiles, by name.
local function koreaderProfiles(ui)
    local plugin = ui and ui.profiles
    if plugin and type(plugin.data) == "table" then return plugin.data end
    -- (the Profiles plugin is switched off: its profiles are still there)
    local ok, settings = pcall(function()
        return require("luasettings"):open(DataStorage:getSettingsDir() .. "/profiles.lua")
    end)
    return ok and settings and type(settings.data) == "table" and settings.data or {}
end

--- A short value that changes when anything in the profile does.
local function profileSignature(profile)
    local function write(v)
        if type(v) ~= "table" then return type(v):sub(1, 1) .. tostring(v) end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local out = {}
        for __, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. write(v[k]) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return require("ffi/sha2").md5(write(profile))
end

local function typeProfiles()
    local map = ZoteroAPI.getSettings():readSetting("type_profiles")
    return type(map) == "table" and map or {}
end

--- The profile chosen for the open document's kind, applied.
-- @return the profile's name when it was applied
function Plugin:applyTypeProfile()
    local ui = self.ui
    if not init_done or not ui or not ui.document or not ui.doc_settings then return nil end
    local map = typeProfiles()
    if next(map) == nil then return nil end
    local key, path = AnnotationSync.identify(ui)
    local kind = key and AnnotationSync.kindOf(path)
    local name = kind and map[kind]
    if not name then return nil end
    local profile = koreaderProfiles(ui)[name]
    if type(profile) ~= "table" then
        logger.warn("Zotero: the profile chosen for", kind, "documents no longer exists:", name)
        return nil
    end
    -- Once per document and state of the profile: what is changed in a single
    -- document afterwards stays, until the profile itself is changed (or
    -- another one is chosen), which every document then takes up when opened.
    local signature = name .. ":" .. profileSignature(profile)
    if ui.doc_settings:readSetting("zotero_type_profile") == signature then return nil end
    logger.info("Zotero: applying profile", name, "to", path)
    Dispatcher:init()
    -- A profile's settings are sent to the window on top. That is the reader,
    -- unless a message happens to lie over it at this moment: then they are
    -- handed to the reader directly, or they would go to the message and be lost.
    local on_top = false
    for widget in UIManager:topdown_widgets_iter() do
        if not widget.toast then
            on_top = widget == ui or widget == ui.dialog
            break
        end
    end
    local real_send = UIManager.sendEvent
    if not on_top then
        UIManager.sendEvent = function(__, event) return ui:handleEvent(event) end
    end
    -- (a profile that is set to show as a menu is carried out all the same)
    local ok, err = pcall(Dispatcher.execute, Dispatcher, profile, { qm_show = false })
    UIManager.sendEvent = real_send
    if not ok then
        -- (the dispatcher silences notifications while it works)
        UIManager:setSilentMode(false)
        error(err, 0)
    end
    ui.doc_settings:saveSetting("zotero_type_profile", signature)
    return name
end

function Plugin:getTypeProfileMenu()
    local labels = { pdf = "PDF", epub = "EPUB", html = _("Web snapshot") }
    local function set(kind, name)
        local map = typeProfiles()
        map[kind] = name
        ZoteroAPI.getSettings():saveSetting("type_profiles", map)
        ZoteroAPI.saveSettingsToFile()
    end
    local menu = {}
    for __, kind in ipairs(PROFILE_KINDS) do
        menu[#menu + 1] = {
            text_func = function()
                local name = typeProfiles()[kind]
                if name and type(koreaderProfiles(self.ui)[name]) ~= "table" then
                    name = name .. " " .. _("(no longer exists)")
                end
                return labels[kind] .. ": " .. (name or _("no profile"))
            end,
            sub_item_table_func = function()
                local names = {}
                for name, profile in pairs(koreaderProfiles(self.ui)) do
                    if type(name) == "string" and type(profile) == "table" then names[#names + 1] = name end
                end
                table.sort(names, function(a, b) return a:lower() < b:lower() end)
                local sub = { {
                    text = _("No profile"),
                    radio = true,
                    checked_func = function() return typeProfiles()[kind] == nil end,
                    callback = function() set(kind, nil) end,
                    separator = true,
                } }
                for __, name in ipairs(names) do
                    sub[#sub + 1] = {
                        text = name,
                        radio = true,
                        checked_func = function() return typeProfiles()[kind] == name end,
                        callback = function() set(kind, name) end,
                    }
                end
                if #names == 0 then
                    sub[#sub + 1] = {
                        text = _("There are no profiles yet"),
                        keep_menu_open = true,
                        callback = function()
                            UIManager:show(InfoMessage:new({
                                text = _("Profiles are made in KOReader's own menu: Tools > Profiles. Open a document of the kind, set font, margins and so on as you like them, then choose \"New with current book settings\" there. The profile can then be chosen here."),
                            }))
                        end,
                    }
                end
                return sub
            end,
        }
    end
    return menu
end

--- A web snapshot that was stored before snapshots were prepared for
-- KOReader's engine (ZoteroAPI.prepareSnapshot) and that carries no
-- highlights yet: prepared now, and opened again.
-- @return true when the document is being opened again
local snapshot_tried = {}
function Plugin:prepareOpenSnapshot(ui)
    if not ui.rolling or not ui.doc_settings or not ui.annotation then return false end
    local key, path = AnnotationSync.identify(ui)
    if not key or AnnotationSync.kindOf(path) ~= "html" or snapshot_tried[path] then return false end
    local storage = ZoteroAPI.storage_dir
    if not storage or path:sub(1, #storage + 1) ~= storage .. "/" then return false end
    local size = lfs.attributes(path, "size")
    if not size or ui.doc_settings:readSetting("zotero_snapshot_checked") == size then return false end
    snapshot_tried[path] = true
    if #ui.annotation.annotations > 0 then return false end
    local f = io.open(path, "rb")
    local src = f and f:read("*a")
    if f then f:close() end
    if type(src) ~= "string" then return false end
    if not require("zotero_html").engineCopy(src) then
        ui.doc_settings:saveSetting("zotero_snapshot_checked", size)
        return false
    end
    logger.info("Zotero: snapshot is opened again after being prepared for the reading engine:", path)
    ui:reloadDocument(function()
        local ok, err = pcall(ZoteroAPI.prepareSnapshot, path)
        if not ok then logger.warn("Zotero: snapshot not prepared:", tostring(err)) end
    end)
    return true
end

function Plugin:onReaderReady()
    if not init_done or not self.ui or not self.ui.document then return end
    local ui = self.ui
    -- the profile for this kind of document, as soon as the document stands
    -- (not when it was only opened again by the reader, to take up a setting)
    if not ui.reloading then
        UIManager:nextTick(function()
            if not ui.document then return end
            local ok, err = pcall(function() self:applyTypeProfile() end)
            if not ok then logger.warn("Zotero: applying the profile failed:", tostring(err)) end
        end)
    end
    -- a moment later, so that the document shows first
    UIManager:scheduleIn(0.3, function()
        if not ui.document then return end -- closed again already
        local okp, again = pcall(function() return self:prepareOpenSnapshot(ui) end)
        if not okp then logger.warn("Zotero: preparing the snapshot failed:", tostring(again)) end
        if okp and again then return end -- the import runs when it is open again
        local ok, err = pcall(function() self:importOpenDocument() end)
        if not ok then
            logger.err("Zotero: annotation import on open failed:", tostring(err))
        end
        -- opened from the annotation search: go to the annotation chosen there
        AnnotationSearch.jumpIfPending(ui)
    end)
end

--- The reader tells us when an annotation is added, changed or removed.
-- A removed annotation that exists in Zotero is noted in the document's
-- delete log: that note - and nothing else - is what later allows the
-- annotation to be deleted in Zotero.
function Plugin:onAnnotationsModified(items)
    if not init_done or self._applying or type(items) ~= "table" then return end
    local index = items.index_modified
    if type(index) ~= "number" or index >= 0 then return end
    local item = items[1]
    if type(item) ~= "table" or not Util.isValidKey(item.zoteroKey) then return end
    local ds = self.ui and self.ui.doc_settings
    if not ds then return end
    local log = ds:readSetting("zotero_deleted")
    if type(log) ~= "table" then log = {} end
    log[item.zoteroKey] = tonumber(item.zoteroVersion) or 0
    ds:saveSetting("zotero_deleted", log)
    logger.info("Zotero: annotation", item.zoteroKey, "deleted in the reader; will be deleted in Zotero at the next sync")
end

function Plugin:onCloseDocument()
    -- No upload here: sending to Zotero happens only when a sync is asked for.
    -- But while the book is still open, work out the Zotero positions of new
    -- EPUB highlights, so that a later sync can send them with the book closed.
    if not init_done or not self.ui or not self.ui.document then return end
    local ui = self.ui
    local ok, err = pcall(function()
        local key, file_path
        if ui.rolling then key, file_path = AnnotationSync.identify(ui) end
        local kind = key and AnnotationSync.kindOf(file_path)
        if kind then
            local n = Doc.cacheEpubPositions(ui, kind)
            -- and the Zotero form of the place the book is closed at
            if Position.cacheOnClose(ui, key) then n = n + 1 end
            if n > 0 and ui.dialog ~= ui then
                -- the reader saved the document's settings before telling us
                ui:saveSettings()
            end
        end
    end)
    if not ok then logger.warn("Zotero: preparing positions on closing failed:", tostring(err)) end
end

--- Keep the device from dozing while a sync runs. On Android the only means
-- the reader has is its "keep screen on" window flag; the user's own screen
-- timeout is put back afterwards. Elsewhere the reader's standby prevention
-- (which the progress messages already use) does the job.
local saved_screen_timeout
local function keepAwake(on)
    pcall(function()
        local ok, android = pcall(require, "android")
        if not ok or type(android) ~= "table" or type(android.timeout) ~= "table" then return end
        local C = require("ffi").C
        if on then
            if saved_screen_timeout ~= nil then return end
            if type(android.needsWakelocks) == "function" and android.needsWakelocks() then return end -- always on already
            local current = android.timeout.get()
            if current == C.AKEEP_SCREEN_ON_ENABLED then return end
            saved_screen_timeout = current
            android.timeout.set(C.AKEEP_SCREEN_ON_ENABLED)
        elseif saved_screen_timeout ~= nil then
            local previous = saved_screen_timeout
            saved_screen_timeout = nil
            android.timeout.set(previous)
        end
    end)
end

--- Run a sync: one at a time, online, with progress messages the user can
-- stop, and with a message instead of silence if it fails unexpectedly.
-- @param fn function(progress, stopped)
-- ---------------------------------------------------------------------------
-- Updates of the plugin (zotero_update.lua)
-- ---------------------------------------------------------------------------

local function runningVersion() return Update.versionOf(ZoteroAPI.version) end
local function updateDir() return ZoteroAPI.zotero_dir .. "/update" end

--- A version installed on disk that runs only after a restart, or nil.
local function installedNotRunning()
    local installed = ZoteroAPI.getSettings():readSetting("update_installed")
    if installed and Update.newer(installed, runningVersion()) then return installed end
    return nil
end

local function offerRestart(version)
    UIManager:askForRestart(string.format(_("Zotero Atelier %s is installed. It runs after KOReader has been restarted."), "v" .. version))
end

--- Install a release; the outcome is noted in the settings. @return true or nil, reason
function Plugin:installRelease(release)
    local ok, err = Update.install(release, self.path, updateDir())
    if ok then
        local settings = ZoteroAPI.getSettings()
        settings:saveSetting("update_installed", release.version)
        settings:delSetting("update_skip")
        ZoteroAPI.saveSettingsToFile()
    end
    return ok, err
end

--- After a sync (the network is up then): at most once a day, look for a new
-- version and install it. Quiet when nothing is found or GitHub cannot be
-- reached. @return a line for the sync's summary, or nil
function Plugin:autoUpdate(progress)
    local settings = ZoteroAPI.getSettings()
    if not Update.due(settings) or not self.path then return nil end
    settings:saveSetting("update_last_check", os.time())
    ZoteroAPI.saveSettingsToFile()
    progress(_("Looking for a new version of the plugin…"))
    local release, err = Update.latest()
    if not release then
        logger.info("Zotero: update check:", tostring(err))
        return nil
    end
    if not Update.newer(release.version, runningVersion())
        or release.version == installedNotRunning()
        or release.version == settings:readSetting("update_skip") then
        return nil
    end
    progress(string.format(_("Installing version %s of the plugin…"), release.version))
    local ok, ierr = self:installRelease(release)
    if not ok then
        logger.warn("Zotero: update to", release.version, "failed:", tostring(ierr))
        return string.format(_("A new version of the plugin (%s) could not be installed: %s"), release.version, tostring(ierr))
    end
    self.restart_for = release.version
    return string.format(_("The plugin was updated to version %s; it runs after KOReader has been restarted."), release.version)
end

--- "Check for updates now".
function Plugin:checkForUpdate()
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Trapper:info(_("Looking for a new version of the plugin…"))
            local settings = ZoteroAPI.getSettings()
            settings:saveSetting("update_last_check", os.time())
            ZoteroAPI.saveSettingsToFile()
            local release, err = Update.latest()
            if not release then
                Trapper:info(_("No update could be found:") .. " " .. tostring(err))
                return
            end
            local running = runningVersion()
            if not Update.newer(release.version, running) then
                Trapper:info(string.format(_("This is the latest version (%s)."), "v" .. tostring(running)))
                return
            end
            if release.version == installedNotRunning() then
                Trapper:clear()
                offerRestart(release.version)
                return
            end
            local notes = (release.notes or ""):gsub("\r", "")
            if #notes > 1200 then notes = notes:sub(1, 1200):gsub("[^\n]*$", "") .. "…" end
            local go = Trapper:confirm(string.format(_("Version %s is available (this is %s).\n\n%s\n\nInstall it now?"),
                "v" .. release.version, "v" .. tostring(running), notes), _("Later"), _("Install"))
            if not go then
                Trapper:clear()
                return
            end
            Trapper:info(string.format(_("Installing version %s of the plugin…"), release.version))
            local ok, ierr = self:installRelease(release)
            Trapper:clear()
            if not ok then
                UIManager:show(InfoMessage:new({ text = _("The update could not be installed:") .. "\n" .. tostring(ierr), icon = "notice-warning" }))
                return
            end
            offerRestart(release.version)
        end)
    end)
end

function Plugin:getUpdateMenu()
    return {
        {
            text_func = function()
                local waiting = installedNotRunning()
                if waiting then
                    return string.format(_("Restart KOReader to use %s"), "v" .. waiting)
                end
                return string.format(_("Check for updates (this is %s)"), "v" .. tostring(runningVersion()))
            end,
            callback = function()
                local waiting = installedNotRunning()
                if waiting then
                    offerRestart(waiting)
                else
                    self:checkForUpdate()
                end
            end,
        },
        {
            text = _("Install updates automatically"),
            help_text = _("After a sync, at most once a day, the plugin asks GitHub for a newer version and installs it; the new version runs after KOReader has been restarted. Only when the device is online for the sync anyway: Wi-Fi is never turned on for this.\n\nEach update is checked before anything is replaced (complete download, checksum, readable files, the right version), and the version it replaces is kept: \"Restore the previous version\" puts it back."),
            checked_func = function()
                return ZoteroAPI.getSettings():readSetting("update_auto") ~= false
            end,
            callback = function()
                local settings = ZoteroAPI.getSettings()
                settings:saveSetting("update_auto", settings:readSetting("update_auto") == false)
                ZoteroAPI.saveSettingsToFile()
            end,
        },
        {
            text_func = function()
                local previous = Update.previousVersion(updateDir())
                return previous and string.format(_("Restore the previous version (%s)"), "v" .. previous)
                    or _("Restore the previous version")
            end,
            enabled_func = function()
                return Update.previousVersion(updateDir()) ~= nil
            end,
            callback = function()
                local previous = Update.previousVersion(updateDir())
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new({
                    text = string.format(_("Put version %s back? Automatic updates leave out the version installed now until a newer one comes."), "v" .. tostring(previous)),
                    ok_text = _("Restore"),
                    ok_callback = function()
                        local ok, err = Update.restore(self.path, updateDir())
                        if not ok then
                            UIManager:show(InfoMessage:new({ text = _("The previous version could not be restored:") .. "\n" .. tostring(err), icon = "notice-warning" }))
                            return
                        end
                        local settings = ZoteroAPI.getSettings()
                        -- (the version that was replaced is not installed again automatically)
                        settings:saveSetting("update_skip", installedNotRunning() or runningVersion())
                        settings:saveSetting("update_installed", previous)
                        ZoteroAPI.saveSettingsToFile()
                        UIManager:askForRestart(string.format(_("Version %s is back in place. It runs after KOReader has been restarted."), "v" .. tostring(previous)))
                    end,
                }))
            end,
        },
    }
end

function Plugin:runSync(fn)
    if syncBusy() then
        UIManager:show(InfoMessage:new({
            text = _("A Zotero sync is already running."),
            timeout = 3,
        }))
        return
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            sync_alive_at = os.time()
            Trapper:setPausedText(_("Stop the Zotero sync?"), _("Stop"), _("Continue"))
            local progress, stopped = makeProgress()
            keepAwake(true)
            local ok, err = xpcall(function() fn(progress, stopped) end, debug.traceback)
            keepAwake(false)
            sync_alive_at = nil
            Trapper:setPausedText(nil, nil, nil)
            if not ok then
                logger.err("Zotero: sync failed:", tostring(err))
                Trapper:info(_("The Zotero sync failed unexpectedly. See crash.log for details.")
                    .. "\n" .. tostring(err):match("^[^\n]*"))
            end
        end)
    end)
end

--- "Sync document annotations": download what changed in Zotero, merge with
-- the open document, upload what changed here.
function Plugin:syncOpenDocumentAnnotations()
    if not self:checkInitialized() then return end
    local ui = self.ui
    if not ui or not ui.document then return end
    local key, file_path = AnnotationSync.identify(ui)
    if not key then
        UIManager:show(InfoMessage:new({
            text = _("This document is not known as a Zotero attachment.\nSynchronize the library first, or open the document from the Zotero browser."),
            timeout = 6,
            icon = "notice-warning",
        }))
        return
    end
    if not AnnotationSync.kindOf(file_path) then
        UIManager:show(InfoMessage:new({
            text = _("Annotation sync supports PDF, EPUB and web snapshots."),
            timeout = 4,
            icon = "notice-warning",
        }))
        return
    end
    self:runSync(function(progress, stopped)
        progress(_("Synchronizing annotations with Zotero…"))
        local lines = {}
        local online_error = ZoteroAPI.pull(progress)
        if stopped() then
            Trapper:info(ZoteroAPI.CANCELLED)
            return
        end
        if not ui.document then return end -- closed meanwhile
        if online_error then
            lines[#lines + 1] = _("Zotero could not be reached; nothing was uploaded.") .. "\n" .. readableStatus(online_error)
        end
        local can_push = online_error == nil and ZoteroAPI.canWrite()
        local ok, stats, repaired = pcall(AnnotationSync.openDocument, ui, function(fn) self:guarded(fn) end, { push = can_push })
        if not ok or not stats then
            logger.err("Zotero: document annotation sync failed:", tostring(stats))
            Trapper:info(_("Annotation sync failed. See crash.log for details."))
            return
        end
        self:afterAnnotationChanges(stats, repaired, true)
        -- reading position: Zotero's, if it is news; otherwise ours goes up
        local went = self:applyZoteroPosition(true)
        local sent = false
        if can_push and ui.document then
            local pok, res = pcall(Position.pushOpen, ui, key)
            if not pok then logger.warn("Zotero: sending the reading position failed:", tostring(res)) end
            sent = pok and res == "sent"
        end
        local done, problems = Sync.summary(stats)
        if #done == 0 and #problems == 0 and not online_error then
            lines[#lines + 1] = _("Annotations are up to date.")
        end
        if went then
            lines[#lines + 1] = string.format(_("Continued where Zotero was last read: page %s (Back returns)."), tostring(went))
        elseif sent then
            lines[#lines + 1] = _("Reading position sent to Zotero.")
        end
        for __, l in ipairs(done) do lines[#lines + 1] = l end
        for __, l in ipairs(problems) do lines[#lines + 1] = l end
        if online_error == nil and not ZoteroAPI.canWrite() and stats.pending > 0 then
            lines[#lines + 1] = _("The API key is read-only: changes made here were not uploaded.")
        end
        if stats.unsupported > 0 then
            lines[#lines + 1] = string.format(_("%d Zotero annotations of other kinds (notes, images, drawings) are not shown in KOReader."), stats.unsupported)
        end
        for i = 1, math.min(3, #stats.messages) do lines[#lines + 1] = "· " .. stats.messages[i] end
        Trapper:info(table.concat(lines, "\n"))
    end)
end

function Plugin:onCloseWidget()
    -- Intentionally no automatic Zotero write.
end
function Plugin:init()
    -- not sure when this is called, so I don't understand why some bits need to be
    -- re-initialised every time.
    -- But at least the ZoteroAPI only needs to be initialised once
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if #foreign_modules > 0 then
        logger.err("Zotero: modules of another plugin were loaded in place of this plugin's own:",
            table.concat(foreign_modules, ", "))
        self.initialized = false
        return
    end
    if not init_done then
        init_done = xpcall(self.initAPI, init_error, self)
    end
    xpcall(self.initBrowser, init_error, self)
    self.initialized = init_done
    logger.dbg("Zotero: initialized:", init_done)
end

function Plugin:checkInitialized()
    if #foreign_modules > 0 then
        UIManager:show(InfoMessage:new({
            text = _("Zotero Atelier cannot run: another Zotero plugin is installed that uses the same file names (zotero.koplugin, or a second copy of Zotero Atelier).\n\nRemove the other plugin's folder from koreader/plugins and restart KOReader.")
                .. "\n\n(" .. table.concat(foreign_modules, ", ") .. ")",
            icon = "notice-warning",
        }))
        return false
    end
    if not self.initialized or self.browser == nil then
        UIManager:show(InfoMessage:new({
            text = _(
                "Zotero Atelier could not start.\n"
                    .. "Restart KOReader after installing the plugin.\n"
                    .. "If the problem persists, check crash.log for 'zoteroatelier' or 'zoteroapi' errors."
            ),
            timeout = 6,
            icon = "notice-warning",
        }))
        return false
    end
    return true
end

function Plugin:initAPI()
    self.zotero_dir_path = DataStorage:getDataDir() .. "/zotero"
    lfs.mkdir(self.zotero_dir_path)
    ZoteroAPI.init(self.zotero_dir_path)
    -- the reader's highlight colours: Zotero's set, readable on this screen
    Colors.init(ZoteroAPI.getSettings())
    Colors.apply()
    -- a way out of the popup that follows a selection
    Highlight.install(ZoteroAPI.getSettings())
    -- highlights without a colour of their own are sent with the reader's default colour
    Annotations.setDefaultColor(G_reader_settings:readSetting("highlight_color") or "yellow")
end
function Plugin:initBrowser()
    self.small_font_face = Font:getFace("smallffont")
    self.browser = ZoteroBrowser:new({
        refresh_callback = function()
            UIManager:setDirty(self.zotero_dialog)
            self.ui:onRefresh()
        end,
        close_callback = function()
            UIManager:close(self.zotero_dialog)
        end,
        items_per_page = self:getItemsPerPage(),
    })
    self.zotero_dialog = FrameContainer:new({
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.browser,
    })
    self.browser.show_parent = self.zotero_dialog
    logger.dbg("Zotero: Browser initialized")
end
function Plugin:getZoteroSubMenu()
    return {
            {
                text = _("Browse"),
                callback = function()
                    self:onZoteroBrowserAction()
                end,
            },
            {
                text = _("Synchronize"),
                callback = function()
                    self:onZoteroSyncAction()
                end,
            },
            {
                text = _("Document annotations"),
                enabled_func = function()
                    return self.ui ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    AnnotationPanel.show(self.ui)
                end,
            },
            {
                text = _("Search annotations"),
                callback = function()
                    AnnotationSearch.show(self)
                end,
            },
            {
                text = _("Sync document annotations"),
                enabled_func = function()
                    return self.ui ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    self:syncOpenDocumentAnnotations()
                end,
            },
            {
                text = _("Maintenance"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Re-analyse local items"),
                        callback = function()
                            self:onZoteroReanalyzeAction()
                        end,
                    },
                    {
                        text = _("Re-scan storage for local items"),
                        callback = function()
                            self:onZoteroRescanAction()
                        end,
                    },
                    {
                        text = _("Resync entire collection"),
                        callback = function()
                            ZoteroAPI.resetSyncState()
                            self:onZoteroSyncAction()
                        end,
                    },
                },
            },
            {
                text = _("Settings"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Configure Zotero account"),
                        callback = function()
                            self:setAccount()
                        end,
                    },
                    {
                        text = _("Enable WebDAV storage"),
                        checked_func = function()
                            return ZoteroAPI.getWebDAVEnabled()
                        end,
                        callback = function()
                            ZoteroAPI.toggleWebDAVEnabled()
                        end,
                    },
                    {
                        text = _("Configure WebDAV account"),
                        callback = function()
                            self:setWebdavAccount()
                        end,
                    },
                    {
                        text = _("Check WebDAV connection"),
                        callback = function()
                            NetworkMgr:runWhenOnline(function()
                                local msg = nil
                                local result = ZoteroAPI.checkWebDAV()
                                if result == nil then
                                    msg = _("Success, WebDAV works!")
                                else
                                    msg = _("WebDAV could not connect: ") .. result
                                end
                                UIManager:show(InfoMessage:new({
                                    text = msg,
                                    timeout = 3,
                                    icon = "notice-info",
                                }))
                            end)
                        end,
                    },
                    {
                        text = _("Items per page"),
                        callback = function()
                            self:setItemsPerPage()
                        end,
                    },
                    {
                        text = _("Write highlights into PDF files"),
                        help_text = _("Off by default for Zotero documents: highlights are synchronized as Zotero annotations. Writing them into the PDF as well changes the file on this device only."),
                        checked_func = function()
                            return not pdfWritingDisabled()
                        end,
                        callback = function()
                            local disable = not pdfWritingDisabled()
                            ZoteroAPI.getSettings():saveSetting("auto_disable_pdf_writing", disable)
                            ZoteroAPI.saveSettingsToFile()
                            -- apply to the PDF that is open right now, if it is a Zotero attachment
                            local ui = self.ui
                            if ui and ui.document and ui.document.is_pdf and ui.highlight and AnnotationSync.identify(ui) then
                                ui.highlight.highlight_write_into_pdf = not disable
                            end
                        end,
                    },
                    {
                        text = _("Sync the reading position"),
                        help_text = _("Zotero remembers where each document was last read. With this on, a document opens here where Zotero was last (your previous place is one tap on Back away), and a sync sends the place reached here to Zotero."),
                        checked_func = function()
                            return Position.enabled()
                        end,
                        callback = function()
                            ZoteroAPI.getSettings():saveSetting("sync_reading_position", not Position.enabled())
                            ZoteroAPI.saveSettingsToFile()
                        end,
                    },
                    {
                        text = _("Profile per kind of document"),
                        help_text = _("One of KOReader's profiles (Tools > Profiles) for PDFs, one for EPUBs, one for web snapshots: its settings - font, margins, line spacing, zoom and so on - are applied when a Zotero document of that kind is opened. A document takes the profile once, and again after the profile has been changed; what you adjust in a single document in between stays. Other books are not affected."),
                        sub_item_table_func = function()
                            return self:getTypeProfileMenu()
                        end,
                    },
                    {
                        text = _("Highlight colours"),
                        sub_item_table_func = function()
                            return self:getColorMenu()
                        end,
                    },
                    {
                        text = _("\"Discard\" in the popup after selecting text"),
                        help_text = _("When KOReader is set to highlight a selection at once and to ask for the colour or style (Long-press on text: \"Highlight action: Highlight\" and a \"Highlight prompt\"), the list that pops up gets one more button: Discard. It drops the selection without highlighting anything, for a selection that went wrong. A tap beside the list still highlights in the current colour, as before.\n\nThis is the reader's popup, so it applies to every document."),
                        enabled_func = function() return Highlight.available() end,
                        checked_func = function() return Highlight.enabled() end,
                        callback = function()
                            Highlight.setEnabled(not Highlight.enabled())
                            ZoteroAPI.saveSettingsToFile()
                        end,
                    },
                    {
                        text = _("Local files"),
                        callback = function()
                            return nil
                        end,
                        sub_item_table = {
                            {
                                text = _("Enable linked files folder"),
                                checked_func = function()
                                    return ZoteroAPI.getLinkedFilesEnabled()
                                end,
                                callback = function()
                                    ZoteroAPI.toggleLinkedFilesEnabled()
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text_func = function()
                                    return _("Linked files folder: ")
                                        .. truncatePath(ZoteroAPI.getLinkedFilesBase())
                                end,
                                callback = function()
                                    self:chooseDirectory(
                                        "linked_files_base",
                                        _("Choose linked files folder"),
                                        function(path)
                                            ZoteroAPI.setLinkedFilesBase(path)
                                            ZoteroAPI.saveSettingsToFile()
                                        end
                                    )
                                end,
                            },
                            {
                                text = _("Enable external Zotero storage folder"),
                                checked_func = function()
                                    return ZoteroAPI.getExternalStorageEnabled()
                                end,
                                callback = function()
                                    ZoteroAPI.toggleExternalStorageEnabled()
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text_func = function()
                                    return _("External storage folder: ")
                                        .. truncatePath(ZoteroAPI.getExternalStorageDir())
                                end,
                                callback = function()
                                    self:chooseDirectory(
                                        "external_storage_dir",
                                        _("Choose Zotero storage folder"),
                                        function(path)
                                            ZoteroAPI.setExternalStorageDir(path)
                                            ZoteroAPI.saveSettingsToFile()
                                        end
                                    )
                                end,
                            },
                            {
                                text = _("Prefer local files when available"),
                                checked_func = function()
                                    return ZoteroAPI.getSettings():readSetting("prefer_local_files", true)
                                end,
                                callback = function()
                                    ZoteroAPI.getSettings():toggle("prefer_local_files")
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text = _("Allow opening outdated local files"),
                                checked_func = function()
                                    return ZoteroAPI.getAllowStaleLocal()
                                end,
                                callback = function()
                                    ZoteroAPI.toggleAllowStaleLocal()
                                    ZoteroAPI.saveSettingsToFile()
                                end,
                            },
                            {
                                text = _("Add search root folder"),
                                callback = function()
                                    self:chooseDirectory(
                                        "search_root_pick",
                                        _("Choose folder to search for files"),
                                        function(path)
                                            ZoteroAPI.addSearchRoot(path)
                                            ZoteroAPI.saveSettingsToFile()
                                        end
                                    )
                                end,
                            },
                            {
                                text = _("View search root folders"),
                                callback = function()
                                    self:showSearchRoots()
                                end,
                            },
                            {
                                text = _("Preview local path resolution"),
                                callback = function()
                                    self:showLocalPathPreview()
                                end,
                            },
                            {
                                text = _("Add path mapping"),
                                callback = function()
                                    self:addPathMapping()
                                end,
                            },
                            {
                                text = _("Suggest path mapping from Zotero path"),
                                callback = function()
                                    self:suggestPathMapping()
                                end,
                            },
                            {
                                text = _("View path mappings"),
                                callback = function()
                                    self:showPathMappings()
                                end,
                            },
                            {
                                text = _("Clear all path mappings"),
                                callback = function()
                                    ZoteroAPI.clearPathMappings()
                                    ZoteroAPI.saveSettingsToFile()
                                    UIManager:show(InfoMessage:new({
                                        text = _("Path mappings cleared."),
                                        timeout = 3,
                                        icon = "notice-info",
                                    }))
                                end,
                            },
                        },
                    },
                },
            },
            {
                text_func = function()
                    local waiting = installedNotRunning()
                    return waiting and string.format(_("Updates (%s waits for a restart)"), "v" .. waiting) or _("Updates")
                end,
                sub_item_table_func = function()
                    return self:getUpdateMenu()
                end,
            },
            {
                text = _("About/Info"),
                callback = function()
                    local version = ZoteroAPI.version
                    local stats = ZoteroAPI.getStats()
                    local write_pdf = (not pdfWritingDisabled()) and "Enabled" or "Disabled"
                    UIManager:show(InfoMessage:new({
                        text = _(
                            "Plugin version: \n"
                            .. version
                            .. "\n\nLibrary info:\n  Name:\t\t"
                            .. stats.name
                            .. "\n  Version:\t"
                            .. stats.libVersion
                            .. "\n  Last sync: "
                            .. stats.lastSync
                            .. "\n\nLibrary stats:\n\tCollections:\t\t"
                            .. stats.collections
                            .. "\n\tTotal items:\t\t"
                            .. stats.items
                            .. "\n\tAttachments:\t"
                            .. stats.attachments
                            .. "\n\tAnnotations:\t"
                            .. stats.annotations
                            .. "\n\nPDF Settings:\n\tWrite into PDF:\t"
                            .. write_pdf
                            .. "\n"
                        ),
                        --timeout = 10,
                        --icon = "notice"
                        show_icon = false,
                    }))
                    return nil
                end,
            },
    }
end

--- Colours changed: draw the open document's highlights again.
function Plugin:colorsChanged()
    Colors.apply()
    ZoteroAPI.saveSettingsToFile()
    local ui = self.ui
    if ui and ui.document and ui.view then
        pcall(function()
            ui.view:resetHighlightBoxesCache()
            if ui.highlight and ui.highlight.setSelectionColor then ui.highlight:setSelectionColor() end
        end)
        UIManager:setDirty(ui.dialog or "all", "ui")
    end
end

function Plugin:getColorMenu()
    local items = {
        {
            text = _("Colour menu like Zotero's (with magenta)"),
            help_text = _("The colour menu of the reader shows Zotero's eight colours (with magenta, without olive and cyan). Existing olive and cyan highlights stay as they are."),
            checked_func = function() return Colors.paletteEnabled() end,
            callback = function()
                Colors.setPaletteEnabled(not Colors.paletteEnabled())
                self:colorsChanged()
            end,
        },
        {
            text = _("Use the darkness values below"),
            help_text = _("On: every highlight is drawn as a grey, as dark as the value set for its colour below. This is what a screen without colour needs.\n\nOff: highlights are drawn in their real colours. On a grey screen that leaves only the brightness the colour happens to have: yellow is almost invisible, blue almost black.\n\nGray is not in the list: it follows the reader's own \"Gray highlight opacity\"."),
            checked_func = function() return Colors.tintsEnabled() end,
            callback = function()
                Colors.setTintsEnabled(not Colors.tintsEnabled())
                self:colorsChanged()
            end,
            separator = true,
        },
    }
    for __, name in ipairs(Colors.TINTED) do
        items[#items + 1] = {
            text_func = function()
                return string.format("%s: %d %%", Colors.label(name), Colors.level(name))
            end,
            enabled_func = function() return Colors.tintsEnabled() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new({
                    title_text = Colors.label(name),
                    info_text = _("How dark this colour's highlights are drawn, in percent. Higher is darker."),
                    value = Colors.level(name),
                    value_min = 0,
                    value_max = 90,
                    value_step = 1,
                    value_hold_step = 5,
                    callback = function(spin)
                        Colors.setLevel(name, spin.value)
                        self:colorsChanged()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                }))
            end,
        }
    end
    items[#items].separator = true
    items[#items + 1] = {
        text = _("Reset the darkness values"),
        enabled_func = function() return Colors.tintsEnabled() end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Colors.resetLevels()
            self:colorsChanged()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
    return items
end

function Plugin:addToMainMenu(menu_items)
    local sub_menu
    if #foreign_modules > 0 or not self.initialized or self.browser == nil then
        -- Nothing of the plugin can be relied on: the menu only explains why.
        sub_menu = {
            {
                text = _("Why is Zotero Atelier not running?"),
                keep_menu_open = true,
                callback = function()
                    self:checkInitialized()
                end,
            },
        }
    else
        sub_menu = self:getZoteroSubMenu()
    end
    menu_items.zoteroatelier = {
        text = _("Zotero Atelier"),
        sorting_hint = "search",
        sub_item_table = sub_menu,
    }
    menu_items.zoteroatelier_tools = {
        text = _("Zotero Atelier"),
        sorting_hint = "tools",
        sub_item_table = sub_menu,
    }
end
function Plugin:setAccount()
    self.account_dialog = MultiInputDialog:new({
        title = _("Edit User Info"),
        fields = {
            {
                text = ZoteroAPI.getUserID(),
                hint = _("User ID (integer)"),
            },
            {
                text = ZoteroAPI.getAPIKey(),
                hint = _("API Key"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                    end,
                },
                {
                    text = _("Update"),
                    callback = function()
                        local fields = self.account_dialog:getFields()
                        if not string.match(fields[1], "[0-9]+") then
                            UIManager:show(InfoMessage:new({
                                text = _("The User ID must be an integer number."),
                                timeout = 3,
                                icon = "notice-warning",
                            }))
                            return
                        end
                        ZoteroAPI.setUserID(fields[1])
                        ZoteroAPI.setAPIKey(fields[2])
                        ZoteroAPI.saveSettingsToFile()
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                    end,
                },
            },
        },
    })
    UIManager:show(self.account_dialog)
    self.account_dialog:onShowKeyboard()
end
function Plugin:setWebdavAccount()
    self.webdav_account_dialog = MultiInputDialog:new({
        title = _("Edit WebDAV credentials"),
        fields = {
            {
                text = ZoteroAPI.getWebDAVUrl(),
                hint = _("URL"),
            },
            {
                text = ZoteroAPI.getWebDAVUser(),
                hint = _("Username"),
            },
            {
                text = ZoteroAPI.getWebDAVPassword(),
                hint = _("Password"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end,
                },
                {
                    text = _("Update"),
                    callback = function()
                        local fields = self.webdav_account_dialog:getFields()
                        ZoteroAPI.setWebDAVUrl(fields[1])
                        ZoteroAPI.setWebDAVUser(fields[2])
                        ZoteroAPI.setWebDAVPassword(fields[3])
                        ZoteroAPI.saveSettingsToFile()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end,
                },
            },
        },
    })
    UIManager:show(self.webdav_account_dialog)
    self.webdav_account_dialog:onShowKeyboard()
end
function Plugin:chooseDirectory(setting_key, title, on_path_chosen)
    local current = ZoteroAPI.getSettings():readSetting(setting_key, "") or ""
    local start_dir = current
    if start_dir == "" then
        start_dir = Device.home_dir or "/"
    end
    local ok, PathChooser = pcall(require, "ui/widget/pathchooser")
    if ok and PathChooser then
        local path_chooser = PathChooser:new({
            title = title,
            path = start_dir,
            select_directory = true,
            select_file = false,
            show_files = false,
            onConfirm = function(dir)
                on_path_chosen(dir)
                ZoteroAPI.saveSettingsToFile()
                self:showLocalPathPreview(dir)
            end,
        })
        UIManager:show(path_chooser)
        return
    end
    local input_dialog
    input_dialog = InputDialog:new({
        title = title,
        input = current,
        input_hint = _("Full path to folder"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local path = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if path and path ~= "" then
                            on_path_chosen(path)
                            ZoteroAPI.saveSettingsToFile()
                            self:showLocalPathPreview(path)
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end
function Plugin:showLocalPathPreview(folder_hint)
    local probe = ZoteroAPI.getFirstLocalPathPreview()
    local text = ZoteroAPI.formatLocalPathPreview(probe)
    if folder_hint and folder_hint ~= "" then
        text = _("Folder set to:\n") .. folder_hint .. "\n\n" .. text
    end
    local preview_dialog
    preview_dialog = ButtonDialog:new({
        title = _("Local path preview") .. "\n\n" .. text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(preview_dialog)
                    end,
                },
                {
                    text = _("Test again"),
                    callback = function()
                        UIManager:close(preview_dialog)
                        self:showLocalPathPreview()
                    end,
                },
            },
        },
    })
    UIManager:show(preview_dialog)
end
function Plugin:addPathMapping()
    self.path_mapping_dialog = MultiInputDialog:new({
        title = _("Add path mapping"),
        description = _("Map a path prefix from your PC to the same location on this device."),
        fields = {
            {
                text = "",
                hint = _("From (PC prefix), e.g. D:\\Zotero"),
            },
            {
                text = "",
                hint = _("To (device prefix), e.g. /storage/emulated/0/Sync/Zotero"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.path_mapping_dialog)
                    end,
                },
                {
                    text = _("Add"),
                    callback = function()
                        local fields = self.path_mapping_dialog:getFields()
                        if fields[1] == "" or fields[2] == "" then
                            UIManager:show(InfoMessage:new({
                                text = _("Both path prefixes are required."),
                                timeout = 3,
                                icon = "notice-warning",
                            }))
                            return
                        end
                        ZoteroAPI.addPathMapping(fields[1], fields[2])
                        ZoteroAPI.saveSettingsToFile()
                        UIManager:close(self.path_mapping_dialog)
                        self:showLocalPathPreview()
                    end,
                },
            },
        },
    })
    UIManager:show(self.path_mapping_dialog)
    self.path_mapping_dialog:onShowKeyboard()
end
function Plugin:suggestPathMapping()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Suggest path mapping"),
        description = _("Paste a path as stored in Zotero, then choose the matching folder on this device."),
        fields = {
            {
                text = "",
                hint = _("Zotero path (from PC), e.g. D:\\Papers\\file.pdf"),
            },
            {
                text = ZoteroAPI.getLinkedFilesBase() or "",
                hint = _("Device folder containing the file"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Create mapping"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local from_path = ZoteroAPI.normalizePath(fields[1] or "")
                        local to_dir = ZoteroAPI.normalizePath(fields[2] or "")
                        if from_path == "" or to_dir == "" then
                            UIManager:show(InfoMessage:new({
                                text = _("Both paths are required."),
                                timeout = 3,
                                icon = "notice-warning",
                            }))
                            return
                        end
                        local basename = ZoteroAPI.basenameOfPath(from_path)
                        local from_prefix = from_path
                        if basename and #basename < #from_path then
                            from_prefix = from_path:sub(1, #from_path - #basename)
                            if from_prefix:sub(-1) == "/" then
                                from_prefix = from_prefix:sub(1, -2)
                            end
                        end
                        ZoteroAPI.addPathMapping(from_prefix, to_dir)
                        ZoteroAPI.saveSettingsToFile()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new({
                            text = _("Mapping added:\n") .. from_prefix .. "\n→\n" .. to_dir,
                            timeout = 4,
                            icon = "notice-info",
                        }))
                        self:showLocalPathPreview()
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end
function Plugin:showSearchRoots()
    local roots = ZoteroAPI.getSearchRoots()
    if #roots == 0 then
        UIManager:show(InfoMessage:new({
            text = _("No extra search roots configured."),
            timeout = 3,
            icon = "notice-info",
        }))
        return
    end
    local items = {}
    for i, root in ipairs(roots) do
        table.insert(items, {
            text = truncatePath(root, 60),
            index = i,
            path = root,
        })
    end
    local menu
    menu = Menu:new({
        title = _("Search root folders"),
        item_table = items,
        is_borderless = true,
        is_popout = true,
        onMenuHold = function(__, item)
            ZoteroAPI.removeSearchRoot(item.index)
            ZoteroAPI.saveSettingsToFile()
            UIManager:close(menu)
            UIManager:show(InfoMessage:new({
                text = _("Search root removed."),
                timeout = 2,
            }))
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
        end,
    })
    UIManager:show(menu)
end
function Plugin:showPathMappings()
    local mappings = ZoteroAPI.getPathMappings()
    if #mappings == 0 then
        UIManager:show(InfoMessage:new({
            text = _("No path mappings configured."),
            timeout = 3,
            icon = "notice-info",
        }))
        return
    end
    local lines = {}
    for i, m in ipairs(mappings) do
        table.insert(lines, i .. ". " .. m.from .. "\n   → " .. m.to)
    end
    local remove_dialog
    remove_dialog = ButtonDialog:new({
        title = _("Path mappings") .. "\n\n" .. table.concat(lines, "\n\n"),
        buttons = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(remove_dialog)
                    end,
                },
                {
                    text = _("Remove last"),
                    callback = function()
                        ZoteroAPI.removePathMapping(#mappings)
                        ZoteroAPI.saveSettingsToFile()
                        UIManager:close(remove_dialog)
                        self:showPathMappings()
                    end,
                },
            },
        },
    })
    UIManager:show(remove_dialog)
end
function Plugin:setItemsPerPage()
    assert(ZoteroAPI.getSettings ~= nil)
    self.items_per_page_dialog = SpinWidget:new({
        title_text = _("Set items per page"),
        value = self:getItemsPerPage(),
        value_min = 1,
        value_max = 1000,
        callback = function(d)
            ZoteroAPI.getSettings():saveSetting("items_per_page", d.value)
            ZoteroAPI.saveSettingsToFile()
            UIManager:show(InfoMessage:new({
                text = _("This change requires a restart of KOReader to take effect."),
                timeout = 3,
                icon = "notice",
            }))
        end,
    })
    UIManager:show(self.items_per_page_dialog)
end
function Plugin:getItemsPerPage()
    return ZoteroAPI.getSettings():readSetting("items_per_page", DEFAULT_LINES_PER_PAGE)
end

function Plugin:onZoteroBrowserAction()
    if not self:checkInitialized() then
        return
    end

    self.browser:init()
    UIManager:show(
        self.zotero_dialog,
        "full",
        Geom:new({
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        })
    )
    self.browser:displayCollection(nil)
end
function Plugin:onZoteroSyncAction()
    if not self:checkInitialized() then
        return
    end
    self:runSync(function(progress)
        progress("Synchronizing Zotero library.")
        local open_ui = (self.ui and self.ui.document) and self.ui or nil
        local e, summary = ZoteroAPI.syncAllItems(progress, {
            -- runs after the library has been downloaded
            annotations = function(report)
                local can_push = ZoteroAPI.canWrite()
                if open_ui and not open_ui.document then open_ui = nil end -- closed meanwhile
                local positions_sent, went = 0, nil
                local done, problems, stats = AnnotationSync.all(report, open_ui,
                    function(fn) self:guarded(fn) end, can_push,
                    function(key, path, is_open)
                        -- reading positions travel with the same sync
                        local result, page = Position.sync(open_ui, key, path, is_open, can_push)
                        went = page or went
                        if result == "sent" then positions_sent = positions_sent + 1 end
                    end)
                if positions_sent > 0 then
                    done[#done + 1] = string.format(positions_sent == 1 and "Reading position of %d document sent to Zotero"
                        or "Reading positions of %d documents sent to Zotero", positions_sent)
                end
                if went then
                    done[#done + 1] = string.format("Continued where Zotero was last read: page %s (Back returns)", tostring(went))
                end
                if open_ui and Sync.changedLocally(stats) then
                    UIManager:setDirty(open_ui.dialog or "all", "ui")
                end
                if not can_push and stats.pending > 0 then
                    problems[#problems + 1] = "The API key is read-only: changes made here were not uploaded."
                end
                return done, problems
            end,
        })

        local lines = {}
        if e == nil then
            lines[#lines + 1] = "Success"
        else
            lines[#lines + 1] = readableStatus(e)
        end
        for i = 1, #(summary or {}) do lines[#lines + 1] = summary[i] end
        -- a new version of the plugin, while the network is up
        if e == nil then
            local okc, note = pcall(self.autoUpdate, self, progress)
            if not okc then logger.warn("Zotero: update check failed:", tostring(note)) end
            if okc and note then lines[#lines + 1] = note end
        end
        Trapper:info(table.concat(lines, "\n"))
        if self.restart_for then
            local version = self.restart_for
            self.restart_for = nil
            UIManager:nextTick(function() offerRestart(version) end)
        end
    end)
end
function Plugin:onZoteroReanalyzeAction()
    if not self:checkInitialized() then
        return
    end
    Trapper:wrap(function()
        Trapper:info("Rebuilding the local index.")
        local progress = makeProgress(true)
        local e = ZoteroAPI.checkItemData(function(msg)
            progress(msg)
        end)
        sync_alive_at = nil

        if e == nil then
            Trapper:info("Success")
        else
            Trapper:info(readableStatus(e))
        end
    end)
end
function Plugin:onZoteroRescanAction()
    if not self:checkInitialized() then
        return
    end
    Trapper:wrap(function()
        Trapper:info("Scanning local Zotero storage.")
        local cnt = ZoteroAPI.scanStorage()

        Trapper:info("Found " .. cnt .. " local attachments.")
    end)
end

return Plugin
