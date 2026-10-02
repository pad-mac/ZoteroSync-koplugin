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
local ZoteroAPI = require("zoteroapi")
local itemInfoViewer = require("zoteroiteminfo")
local AnnotationPanel = require("annotation_panel")
local AnnotationSearch = require("annotation_search")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local DocSettings = require("docsettings")
local Trapper = require("frontend/ui/trapper")
local DEFAULT_LINES_PER_PAGE = 14

local init_done = false

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
-- Optionally disable writing highlights into the PDF file itself.
-- Default: leave KOReader's write-into-PDF setting alone (auto_disable = false).
-- When write-into-PDF is allowed (auto_disable false), enable it on Zotero PDFs.
local function configureZoteroDocumentSettings(file_path)
    if file_path and file_path:match("%.pdf$") then
        local auto_disable = ZoteroAPI.getSettings():readSetting("auto_disable_pdf_writing", false)
        local doc_settings = DocSettings:open(file_path)
        if auto_disable then
            logger.info("Zotero: Disabling PDF annotation writing for: " .. file_path)
            doc_settings:saveSetting("highlight_write_into_pdf", false)
        else
            logger.info("Zotero: Enabling PDF annotation writing for: " .. file_path)
            doc_settings:saveSetting("highlight_write_into_pdf", true)
        end
        doc_settings:flush()
    end
end
local function enableWriteIntoPdf(file_path)
    if file_path and file_path:match("%.pdf$") then
        local doc_settings = DocSettings:open(file_path)
        doc_settings:saveSetting("highlight_write_into_pdf", true)
        doc_settings:flush()
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
    local dir = table.remove(self.keys, #self.keys)
    if #self.keys == 0 then
        self:displayCollection(nil)
    else
        self:displayCollection(self.keys[#self.keys])
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
function ZoteroBrowser:onMenuSelect(item)
    if item.type == "collection" then
        table.insert(self.paths, item.text)
        table.insert(self.keys, item.key)
        self:displayCollection(item.key)
    elseif item.type == "wildcard_collection" then
        table.insert(self.paths, "All items")
        table.insert(self.keys, "all")
        self:displaySearchResults("")
    elseif item.type == "item" then
        local attachments = ZoteroAPI.getItemAttachments(item.key)
        if attachments == nil or table_empty(attachments) then
            UIManager:show(InfoMessage:new({
                text = _("The selected entry does not have any attachments."),
                timeout = 5,
                icon = "notice-warning",
            }))
            return
        end
        local pdf_attachment = nil
        for _, attachment in ipairs(attachments) do
            if attachment.is_pdf then
                pdf_attachment = attachment
                break
            end
        end
        if pdf_attachment then
            self:openAttachment(pdf_attachment.key)
        else
            self:openAttachment(attachments[#attachments].key)
        end
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
            path = "Search results: '" .. self.paths[#self.paths] .. "'"
        else
            path = "/" .. table.concat(self.paths, "")
        end
    end
    return path
end

function ZoteroBrowser:setItems(items, subtitle)
    local subtitle = self:zPath()
    self:switchItemTable("Zotero Browser", items, nil, nil, subtitle)
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
function Plugin:reloadReaderAnnotations(readerui)
    if readerui and readerui.reloadDocument then
        UIManager:scheduleIn(0.1, function()
            readerui:reloadDocument()
        end)
    end
end
function Plugin:syncOpenDocumentAnnotations(readerui, opts)
    opts = opts or {}
    if not init_done or not readerui or not readerui.document or not readerui.document.file then
        return
    end
    local file_path = readerui.document.file
    local key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    if not key then return end
    if not (Annotations.isPdfPath(file_path) or Annotations.isEpubPath(file_path)) then
        if opts.notify then
            UIManager:show(InfoMessage:new({
                text = _("Annotation sync currently supports PDF and EPUB only."),
                timeout = 4,
                icon = "notice-warning",
            }))
        end
        return
    end

    -- Flush live annotations to sidecar before an explicitly requested upload.
    if readerui.annotation and readerui.annotation.annotations and readerui.doc_settings then
        readerui.doc_settings:saveSetting("annotations", readerui.annotation.annotations)
        readerui.doc_settings:flush()
    end
    NetworkMgr:runWhenOnline(function()
        local ok, create_fails, delete_fails, update_fails, sync_err = pcall(
            ZoteroAPI.syncAnnotationsForAttachment, key, file_path
        )
        if not ok then
            logger.err("Zotero: syncAnnotationsForAttachment failed: ", create_fails)
            if opts.notify then
                UIManager:show(InfoMessage:new({text=_("Annotation sync failed: ") .. tostring(create_fails), timeout=5, icon="notice-warning"}))
            end
            return
        end
        local total=(create_fails or 0)+(delete_fails or 0)+(update_fails or 0)
        if opts.notify then
            if total>0 or sync_err then
                UIManager:show(InfoMessage:new({
                    text=string.format(_("Annotation sync finished with %d failed operation(s)."), total) .. (sync_err and ("\n"..tostring(sync_err)) or ""),
                    timeout=6,
                    icon="notice-warning",
                }))
            else
                UIManager:show(InfoMessage:new({text=_("Annotations synced to Zotero."), timeout=2, icon="notice-info"}))
            end
        end
    end)
end

function Plugin:onReaderReady(readerui)
    if not init_done or not readerui or not readerui.document or not readerui.document.file then
        return
    end
    local file_path = readerui.document.file
    local key = ZoteroAPI.findAttachmentKeyByFilePath(file_path)
    if not key then
        return
    end
    local item = ZoteroAPI.getItem(key)
    if not item then
        return
    end
    local doc_settings = DocSettings:open(file_path)
    local sidecar_lib_version = doc_settings:readSetting("zoteroLibVersion", 0)
    doc_settings:close()
    logger.info("Zotero: Matched open document to attachment " .. key)
    if sidecar_lib_version < ZoteroAPI.getUserLibraryVersion() then
        local ok, err = pcall(function()
            local result = ZoteroAPI.attachItemAnnotations(item, nil, file_path)
            if result and result:match("^Error") then
                logger.warn("Zotero: " .. tostring(result))
            else
                self:reloadReaderAnnotations(readerui)
            end
        end)
        if not ok then
            logger.err("Zotero: Failed to attach annotations on reader open: ", err)
        end
    end
    -- SAFETY: do not upload automatically on open. While PDF coordinate
    -- conversion is being validated, Zotero writes are manual only.
end
function Plugin:onCloseDocument()
    -- Intentionally no automatic Zotero write; use “Sync document annotations”.
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
    if not init_done then
        xpcall(self.initAPI, self.initError, self)
        init_done = true
    end
    xpcall(self.initBrowser, self.initError, self)
    self.initialized = init_done
    logger.dbg("Zotero: successfully initialized!")
end

function Plugin:initError(e)
    logger.err("Zotero: Could not initialize Zotero: " .. e)
end
function Plugin:checkInitialized()
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
    end
    return self.initialized
end

function Plugin:initAPI()
    self.zotero_dir_path = DataStorage:getDataDir() .. "/zotero"
    lfs.mkdir(self.zotero_dir_path)
    ZoteroAPI.init(self.zotero_dir_path)
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
                    self:syncOpenDocumentAnnotations(self.ui, { notify = true })
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
                        checked_func = function()
                            return not ZoteroAPI.getSettings():readSetting("auto_disable_pdf_writing", false)
                        end,
                        callback = function()
                            local cur = ZoteroAPI.getSettings():readSetting("auto_disable_pdf_writing", false)
                            ZoteroAPI.getSettings():saveSetting("auto_disable_pdf_writing", not cur)
                            ZoteroAPI.saveSettingsToFile()
                            if self.ui and self.ui.document and self.ui.document.file then
                                if not cur then
                                    configureZoteroDocumentSettings(self.ui.document.file)
                                else
                                    enableWriteIntoPdf(self.ui.document.file)
                                end
                            end
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
                text = _("About/Info"),
                callback = function()
                    local version = ZoteroAPI.version
                    local stats = ZoteroAPI.getStats()
                    local write_pdf = (not ZoteroAPI.getSettings():readSetting("auto_disable_pdf_writing", false))
                        and "Enabled"
                        or "Disabled"
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

function Plugin:addToMainMenu(menu_items)
    local sub_menu = self:getZoteroSubMenu()
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
        onMenuHold = function(_, item)
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
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Trapper:info("Synchronizing Zotero library.")
            local e = ZoteroAPI.syncAllItems(function(msg)
                Trapper:info(readableStatus(msg))
            end)

            if e == nil then
                Trapper:info("Success")
            else
                Trapper:info(readableStatus(e))
            end
        end)
    end)
end
function Plugin:onZoteroReanalyzeAction()
    if not self:checkInitialized() then
        return
    end
    Trapper:wrap(function()
        Trapper:info("Synchronizing Zotero library.")
        local e = ZoteroAPI.checkItemData(function(msg)
            Trapper:info(readableStatus(msg))
        end)

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
