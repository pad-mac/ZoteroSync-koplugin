local BaseUtil = require("ffi/util")
local LuaSettings = require("luasettings")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local sha2 = require("ffi/sha2")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local Annotations = require("annotations")
local Util = require("zotero_util")
local _ = require("gettext")
local DocSettings = require("docsettings")

local API = { version = "Zotero Atelier 2.0 fork v0.12 (2026-10-24)", fork = "0.6" }
-- what a sync that the user stopped reports
API.CANCELLED = "Sync stopped."
local ZOTERO_BASE_URL = "https://api.zotero.org"
local DB_VERSION = 2
local SUPPORTED_MEDIA_TYPES = {
    [1] = "application/pdf",
    [2] = "application/epub+zip",
    [3] = "text/html",
}
local SUPPORTED_LINK_MODES = {
    imported_file = true,
    imported_url = true,
    linked_file = true,
}

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS itemData (
    itemID INTEGER PRIMARY KEY,
    value BLOB,
    FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS items (
    itemID INTEGER PRIMARY KEY,
    itemTypeID INT NOT NULL,
    libraryID INT NOT NULL,
    key TEXT NOT NULL,
    version INT NOT NULL DEFAULT 0,
    synced INT NOT NULL DEFAULT 0,
    UNIQUE (libraryID, key),
    FOREIGN KEY (libraryID) REFERENCES libraries(libraryID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS libraries (
    libraryID INTEGER PRIMARY KEY,
    type TEXT NOT NULL,
    editable INT NOT NULL,
    name TEXT NOT NULL,
    userID INT NOT NULL DEFAULT 0,
    version INT NOT NULL DEFAULT 0,
    storageVersion INT NOT NULL DEFAULT 0,
    lastSync INT NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS collections (
    collectionID INTEGER PRIMARY KEY,
    collectionName TEXT NOT NULL,
    parentCollectionID INT DEFAULT NULL,
    libraryID INT NOT NULL,
    key TEXT NOT NULL,
    version INT NOT NULL DEFAULT 0,
    synced INT NOT NULL DEFAULT 0,
    UNIQUE (libraryID, key),
    FOREIGN KEY (libraryID) REFERENCES libraries(libraryID) ON DELETE CASCADE,
    FOREIGN KEY (parentCollectionID) REFERENCES collections(collectionID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS collectionItems (
    collectionID INT NOT NULL,
    itemID INT NOT NULL,
    PRIMARY KEY(collectionID, itemID),
    FOREIGN KEY (collectionID) REFERENCES collections(collectionID) ON DELETE CASCADE,
    FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS itemTypes (
    itemTypeID INTEGER PRIMARY KEY,
    typeName TEXT UNIQUE,
    display INT DEFAULT 1
);
CREATE TABLE IF NOT EXISTS itemAttachments (
    itemID INTEGER PRIMARY KEY,
    parentItemID INT,
    syncedVersion INT NOT NULL DEFAULT 0,
    lastSync INT NOT NULL DEFAULT 0,
    FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE,
    FOREIGN KEY (parentItemID) REFERENCES items(itemID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS itemAnnotations (
    itemID INTEGER PRIMARY KEY,
    parentItemID INT,
    syncedVersion INT NOT NULL DEFAULT 0,
    FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE,
    FOREIGN KEY (parentItemID) REFERENCES items(itemID) ON DELETE CASCADE
);
]]

local ITEM_TYPES = {
    "annotation", "artwork", "attachment", "audioRecording", "bill", "blogPost", "book",
    "bookSection", "case", "computerProgram", "conferencePaper", "dictionaryEntry", "document",
    "email", "encyclopediaArticle", "film", "forumPost", "hearing", "instantMessage", "interview",
    "journalArticle", "letter", "magazineArticle", "manuscript", "map", "newspaperArticle", "note",
    "patent", "podcast", "preprint", "presentation", "radioBroadcast", "report", "statute", "thesis",
    "tvBroadcast", "videoRecording", "webpage", "dataset", "standard"
}

local function file_exists(path)
    return path ~= nil and lfs.attributes(path) ~= nil
end

local function mkdir_p(path)
    if not path or path == "" or file_exists(path) then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path and not file_exists(parent) then
        mkdir_p(parent)
    end
    local ok = lfs.mkdir(path)
    return ok or file_exists(path)
end

local function table_contains(t, value)
    for __, v in pairs(t) do
        if v == value then return true end
    end
    return false
end

-- JSON `null` decodes to a sentinel that is truthy in Lua; Util.jsonDecode
-- removes those, so `item.data.x or default` behaves as written.
local function safe_decode(s)
    return (Util.jsonDecode(s))
end

local function copy_table(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function url_encode(s)
    if s == nil then return "" end
    return tostring(s):gsub("\n", "\r\n"):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function content_headers(headers, body)
    local h = copy_table(headers)
    h["content-type"] = "application/json"
    h["content-length"] = tostring(#body)
    return h
end

function API.openDB()
    if API.db then return API.db end
    API.db = SQ3.open(API.db_path)
    API.db:exec("PRAGMA foreign_keys=ON")
    local result = API.db:exec("PRAGMA user_version")
    local version = 0
    if result and result[1] and result[1][1] then version = tonumber(result[1][1]) or 0 end
    if version == 0 then
        logger.info("Zotero: db version is 0. Set up tables.")
        API.db:exec(SCHEMA)
        API.db:exec("INSERT INTO libraries(type,editable,name) SELECT 'user',1,'' WHERE NOT EXISTS(SELECT 1 FROM libraries);")
        local count = tonumber(API.db:rowexec("SELECT COUNT(*) FROM itemTypes")) or 0
        if count == 0 then
            local stmt = API.db:prepare("INSERT INTO itemTypes(itemTypeID,typeName) VALUES(?,?)")
            for i, type_name in ipairs(ITEM_TYPES) do
                stmt:reset():bind(i, type_name):step()
            end
            stmt:close()
        end
        API.db:exec("INSERT INTO collections(collectionName,libraryID,key) SELECT '',1,'/' WHERE NOT EXISTS(SELECT 1 FROM collections WHERE key='/');")
        API.db:exec("CREATE INDEX IF NOT EXISTS idx_itemkey ON items(key);")
        version = 1
    end
    -- Zotero's delete log (which items the server reported deleted, and what
    -- was last known of them), so that a local annotation is only ever
    -- removed on that evidence. Created here unconditionally: harmless when
    -- it exists, and never missing whatever version wrote the database.
    API.db:exec("CREATE TABLE IF NOT EXISTS syncDeleted (key TEXT PRIMARY KEY, at INT NOT NULL DEFAULT 0, value BLOB);")
    -- Zotero's synced settings that matter here: where each attachment was last read
    API.db:exec("CREATE TABLE IF NOT EXISTS syncSettings (name TEXT PRIMARY KEY, value TEXT, version INT NOT NULL DEFAULT 0);")
    if version < 2 then
        API.db:exec("CREATE INDEX IF NOT EXISTS idx_annotation_parent ON itemAnnotations(parentItemID);")
        API.db:exec("CREATE INDEX IF NOT EXISTS idx_attachment_parent ON itemAttachments(parentItemID);")
        -- Earlier versions could skip changes made in Zotero (they moved the
        -- library version forward after their own uploads) and never noticed
        -- items moved to the trash. Have the whole library checked against
        -- the server once (see fetchZoteroItems: versions are compared, only
        -- what differs is downloaded; nothing stored here is thrown away).
        API.db:exec("UPDATE libraries SET version=0 WHERE libraryID=1;")
        API.db:exec("PRAGMA user_version=" .. tostring(DB_VERSION))
        API.needs_storage_scan = true
        API.libVersion = nil
    end
    return API.db
end

function API.closeDB()
    if API.db then API.db:close() end
    API.db = nil
    API.libVersion = nil
end

function API.init(zotero_dir)
    API.zotero_dir = zotero_dir
    mkdir_p(zotero_dir)
    API.settings = LuaSettings:open(BaseUtil.joinPath(zotero_dir, "meta.lua"))
    API.storage_dir = BaseUtil.joinPath(zotero_dir, "storage")
    mkdir_p(API.storage_dir)
    API.db_path = BaseUtil.joinPath(zotero_dir, "zotero.db")
    logger.info("Zotero: opening db path ", API.db_path)
    API.openDB()
    if API.needs_storage_scan then
        -- Earlier versions forgot which attachments are on this device at
        -- every sync. Find them again once.
        API.needs_storage_scan = nil
        local ok, n = pcall(API.scanStorage)
        logger.info("Zotero: database upgraded; local attachments found:", ok and n or tostring(n))
    end
end

function API.getStats()
    local db = API.openDB()
    local c = tonumber(db:rowexec("SELECT COUNT(*) FROM collections")) or 0
    local i = tonumber(db:rowexec("SELECT COUNT(*) FROM items")) or 0
    local a = tonumber(db:rowexec("SELECT COUNT(*) FROM itemAttachments")) or 0
    local n = tonumber(db:rowexec("SELECT COUNT(*) FROM itemAnnotations")) or 0
    local sy, name = db:rowexec("SELECT lastSync,name FROM libraries WHERE libraryID=1")
    return {
        libVersion = API.getUserLibraryVersion(),
        name = name or "",
        lastSync = os.date("%Y-%m-%d %X", tonumber(sy) or 0),
        collections = c,
        items = i,
        attachments = a,
        annotations = n,
    }
end

function API.getAPIKey() return API.settings:readSetting("api_key", "") or "" end
function API.setAPIKey(v) API.settings:saveSetting("api_key", v or ""); API.zoteroAcessVerified = false; API.access = nil end
function API.getUserID() return API.settings:readSetting("user_id", "") or "" end
function API.setUserID(v) API.settings:saveSetting("user_id", v or ""); API.zoteroAcessVerified = false; API.access = nil end
function API.getWebDAVEnabled() return API.settings:isTrue("webdav_enabled") end
function API.toggleWebDAVEnabled() API.settings:toggle("webdav_enabled") end
function API.getWebDAVUser() return API.settings:readSetting("webdav_user", "") or "" end
function API.setWebDAVUser(v) API.settings:saveSetting("webdav_user", v or "") end
function API.getWebDAVPassword() return API.settings:readSetting("webdav_password", "") or "" end
function API.setWebDAVPassword(v) API.settings:saveSetting("webdav_password", v or "") end
function API.getWebDAVUrl() return API.settings:readSetting("webdav_url", "") or "" end
function API.setWebDAVUrl(v) API.settings:saveSetting("webdav_url", v or "") end
function API.getSettings() return API.settings end
function API.saveSettingsToFile() return API.settings:flush() end

function API.getDatabaseVersion()
    local r = API.openDB():exec("PRAGMA user_version")
    return tonumber(r and r[1] and r[1][1]) or 0
end
function API.setDatabaseVersion(v) API.openDB():exec("PRAGMA user_version=" .. tostring(tonumber(v) or 0)) end
function API.getUserLibraryVersion()
    if API.libVersion == nil then
        API.libVersion = tonumber(API.openDB():rowexec("SELECT version FROM libraries WHERE libraryID=1")) or 0
    end
    return API.libVersion
end
function API.setUserLibraryVersion(v)
    v = tonumber(v) or API.getUserLibraryVersion()
    API.libVersion = v
    local stmt = API.openDB():prepare("UPDATE libraries SET version=?,lastSync=unixepoch('now') WHERE libraryID=1")
    stmt:bind(v):step(); stmt:close()
end

function API.getLinkedFilesEnabled() return API.settings:isTrue("linked_files_enabled") end
function API.toggleLinkedFilesEnabled() API.settings:toggle("linked_files_enabled") end
function API.getLinkedFilesBase() return API.settings:readSetting("linked_files_base", "") or "" end
function API.setLinkedFilesBase(v) API.settings:saveSetting("linked_files_base", v or "") end
function API.getExternalStorageEnabled() return API.settings:isTrue("external_storage_enabled") end
function API.toggleExternalStorageEnabled() API.settings:toggle("external_storage_enabled") end
function API.getExternalStorageDir() return API.settings:readSetting("external_storage_dir", "") or "" end
function API.setExternalStorageDir(v) API.settings:saveSetting("external_storage_dir", v or "") end
function API.getAllowStaleLocal() return API.settings:readSetting("allow_stale_local", true) ~= false end
function API.toggleAllowStaleLocal() API.settings:saveSetting("allow_stale_local", not API.getAllowStaleLocal()) end
function API.getPathMappings()
    local t = API.settings:readSetting("path_mappings")
    return type(t) == "table" and t or {}
end
function API.setPathMappings(t) API.settings:saveSetting("path_mappings", t or {}) end
function API.addPathMapping(from_prefix, to_prefix)
    local t = API.getPathMappings(); table.insert(t, { from = from_prefix, to = to_prefix }); API.setPathMappings(t)
end
function API.removePathMapping(i)
    local t = API.getPathMappings(); if i >= 1 and i <= #t then table.remove(t, i); API.setPathMappings(t); return true end; return false
end
function API.clearPathMappings() API.setPathMappings({}) end
function API.getSearchRoots()
    local t = API.settings:readSetting("search_roots")
    return type(t) == "table" and t or {}
end
function API.setSearchRoots(t) API.settings:saveSetting("search_roots", t or {}) end
function API.addSearchRoot(path)
    if not path or path == "" then return end
    local t = API.getSearchRoots()
    for __, v in ipairs(t) do if API.pathsEqual(v, path) then return end end
    table.insert(t, path); API.setSearchRoots(t)
end
function API.removeSearchRoot(i)
    local t = API.getSearchRoots(); if i >= 1 and i <= #t then table.remove(t, i); API.setSearchRoots(t); return true end; return false
end
function API.getLinkedFilesBases()
    local out = {}
    local saved = API.settings:readSetting("linked_files_bases")
    if type(saved) == "table" then for __, v in ipairs(saved) do table.insert(out, v) end end
    local primary = API.getLinkedFilesBase()
    if primary ~= "" then
        local found = false
        for __, v in ipairs(out) do if API.pathsEqual(v, primary) then found = true break end end
        if not found then table.insert(out, 1, primary) end
    end
    return out
end
function API.normalizePath(p)
    if not p or p == "" then return p end
    p = p:gsub("\\", "/"):gsub("/+", "/")
    if #p > 1 and p:sub(-1) == "/" then p = p:sub(1, -2) end
    return p
end
function API.normalizePathForCompare(p)
    if not p or p == "" then return nil end
    local ok, real = pcall(BaseUtil.realpath, p)
    if ok and real then p = real end
    return API.normalizePath(p)
end
function API.pathsEqual(a, b)
    local aa, bb = API.normalizePathForCompare(a), API.normalizePathForCompare(b)
    return aa ~= nil and bb ~= nil and aa == bb
end
function API.basenameOfPath(p)
    p = API.normalizePath(p); return p and p:match("([^/]+)$") or nil
end
function API.isAbsolutePath(p)
    if not p or p == "" then return false end
    p = p:gsub("\\", "/")
    return p:match("^/") ~= nil or p:match("^%a:/") ~= nil
end
function API.applyPathMappings(p, mappings)
    if not p or p == "" then return p end
    mappings = mappings or API.getPathMappings()
    local sorted = {}
    for __, m in ipairs(mappings) do if m.from and m.from ~= "" then table.insert(sorted, m) end end
    table.sort(sorted, function(a, b) return #a.from > #b.from end)
    p = API.normalizePath(p)
    local lower = string.lower(p)
    for __, m in ipairs(sorted) do
        local from = API.normalizePath(m.from)
        if lower:sub(1,#from) == string.lower(from) then
            local rest = p:sub(#from + 1):gsub("^/", "")
            local to = API.normalizePath(m.to or "")
            if to == "" then return rest ~= "" and rest or p end
            return rest == "" and to or API.normalizePath(BaseUtil.joinPath(to, rest))
        end
    end
    return p
end
--- Look for a file by name below a folder.
-- @param reject optional function(path): true for a file that must not be taken
function API.findFileByBasename(root, basename, depth, reject)
    depth = depth or 0
    if not root or root == "" or not basename or basename == "" or depth > 8 or not file_exists(root) then return nil end
    local want = string.lower(basename)
    local ok, iter, state = pcall(lfs.dir, root)
    if not ok then return nil end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local p = BaseUtil.joinPath(root, name)
            local mode = lfs.attributes(p, "mode")
            if mode == "file" and string.lower(name) == want and not (reject and reject(p)) then return API.normalizePath(p) end
            if mode == "directory" then local f = API.findFileByBasename(p, basename, depth + 1, reject); if f then return f end end
        end
    end
    return nil
end
function API.collectSearchRoots()
    local out = {}
    local function add(v) if v and v ~= "" then table.insert(out, v) end end
    for __, v in ipairs(API.getLinkedFilesBases()) do add(v) end
    if API.getExternalStorageEnabled() then add(API.getExternalStorageDir()) end
    for __, v in ipairs(API.getSearchRoots()) do add(v) end
    add(API.storage_dir)
    return out
end
--- The attachment whose Zotero storage folder (<folder>/<KEY>/<file>) a
-- file sits in, or nil. `norm` is a path as normalizePathForCompare gives it.
local function key_by_folder(norm)
    if not norm or norm == "" then return nil end
    local function under(dir)
        if not dir or dir == "" then return nil end
        local d = API.normalizePathForCompare(dir) or API.normalizePath(dir)
        if d and norm:sub(1, #d + 1) == d .. "/" then
            local key = norm:sub(#d + 2):match("^([^/]+)/[^/]+$")
            if Util.isValidKey(key) then
                local item = API.getItem(key)
                if item and item.data and item.data.itemType == "attachment" then return key end
            end
        end
        return nil
    end
    local key = under(API.storage_dir)
    if not key and API.getExternalStorageEnabled() then key = under(API.getExternalStorageDir()) end
    return key
end

--- Look for a file by name in all the configured folders.
-- @param for_key the attachment the file is wanted for: a file that sits in
--        the storage folder of ANOTHER attachment is that attachment's file,
--        however alike the names are, and is not taken.
function API.findAttachmentByBasename(name, for_key)
    local base = API.basenameOfPath(name) or name
    local reject
    if for_key then
        reject = function(path)
            local owner = key_by_folder(API.normalizePathForCompare(path) or API.normalizePath(path))
            return owner ~= nil and owner ~= for_key
        end
    end
    for __, root in ipairs(API.collectSearchRoots()) do local f = API.findFileByBasename(root, base, 0, reject); if f then return f end end
    return nil
end
--- @param strict only the place the path itself names: no search by file name
-- @param for_key see findAttachmentByBasename
function API.resolveLinkedPath(raw, linkedBase, mappings, strict, for_key)
    if not raw or raw == "" then return nil end
    mappings = mappings or API.getPathMappings()
    local skey, sfile = raw:match("^storage:(%w+)/(.+)$")
    if skey and sfile and API.getExternalStorageEnabled() and API.getExternalStorageDir() ~= "" then
        return API.normalizePath(BaseUtil.joinPath(API.getExternalStorageDir(), skey, sfile))
    end
    local attach = raw:match("^attachments:(.+)$")
    if attach then
        local rel = API.applyPathMappings(attach, mappings)
        local bases = {}
        if linkedBase and linkedBase ~= "" then table.insert(bases, linkedBase) end
        for __, b in ipairs(API.getLinkedFilesBases()) do table.insert(bases, b) end
        for __, b in ipairs(bases) do
            local p = API.normalizePath(BaseUtil.joinPath(b, rel)); if file_exists(p) then return p end
            p = API.normalizePath(BaseUtil.joinPath(b, attach)); if file_exists(p) then return p end
        end
        if strict then return nil end
        return API.findAttachmentByBasename(attach, for_key)
    end
    local p = API.applyPathMappings(raw, mappings)
    if API.isAbsolutePath(p) then return API.normalizePath(p) end
    local bases = {}
    if linkedBase and linkedBase ~= "" then table.insert(bases, linkedBase) end
    for __, b in ipairs(API.getLinkedFilesBases()) do table.insert(bases, b) end
    for __, b in ipairs(bases) do local c = API.normalizePath(BaseUtil.joinPath(b,p)); if file_exists(c) then return c end end
    if strict then return nil end
    return API.findAttachmentByBasename(p, for_key) or (linkedBase and linkedBase ~= "" and API.normalizePath(BaseUtil.joinPath(linkedBase,p)) or nil)
end
function API.isSupportedAttachmentLinkMode(mode) return SUPPORTED_LINK_MODES[mode] == true end

local TYPE_KIND = { ["application/pdf"] = "pdf", ["application/epub+zip"] = "epub", ["text/html"] = "html", ["application/xhtml+xml"] = "html" }
local EXT_KIND = { pdf = "pdf", epub = "epub", html = "html", htm = "html", xhtml = "html" }
--- What the reader can open of an attachment: "pdf", "epub", "html" - or nil
-- for a link to a web page (Zotero's "linked URL", such as a Google Books
-- link) and for files of other kinds.
-- @param d the attachment's data
function API.attachmentKind(d)
    if type(d) ~= "table" or not SUPPORTED_LINK_MODES[d.linkMode] then return nil end
    local kind = TYPE_KIND[d.contentType]
    if not kind and (d.contentType == nil or d.contentType == "" or d.contentType == "application/octet-stream") then
        -- no usable content type: go by the file name
        local name = d.filename or API.basenameOfPath(d.path) or ""
        kind = EXT_KIND[(tostring(name):match("%.(%w+)$") or ""):lower()]
    end
    return kind
end
local KIND_ORDER = { pdf = 1, epub = 2, html = 3 }

function API.getDirAndPath(item)
    if not item or not item.data or not item.key then return nil, nil end
    local dir = BaseUtil.joinPath(API.storage_dir, item.key)
    local filename = item.data.filename or API.basenameOfPath(item.data.path) or (item.key .. ".pdf")
    return dir, BaseUtil.joinPath(dir, filename)
end

local function cached_current(path, item)
    if not file_exists(path) then return false end
    -- read only: DocSettings:close() would write the sidecar back
    local ds = DocSettings:open(path)
    local v = tonumber(ds:readSetting("zoteroItemVersion", 0)) or 0
    return v >= (tonumber(item.version) or 0)
end

--- Where is this attachment's file on this device?
-- @param strict only the places that are this attachment's own (its storage
--        folder, the path a linked file names): no search by file name
function API.resolveAttachmentPath(item, strict)
    if not item or not item.data or not API.isSupportedAttachmentLinkMode(item.data.linkMode) then return nil end
    local allow_stale = API.getAllowStaleLocal()
    if item.data.linkMode == "linked_file" and API.getLinkedFilesEnabled() then
        local p = API.resolveLinkedPath(item.data.path, API.getLinkedFilesBase(), API.getPathMappings(), strict, item.key)
        if p and file_exists(p) then return p end
        if not strict and item.data.filename then local f = API.findAttachmentByBasename(item.data.filename, item.key); if f then return f end end
    end
    if item.data.linkMode == "imported_file" or item.data.linkMode == "imported_url" then
        if API.getExternalStorageEnabled() and API.getExternalStorageDir() ~= "" and item.data.filename then
            local p = API.normalizePath(BaseUtil.joinPath(API.getExternalStorageDir(), item.key, item.data.filename))
            if file_exists(p) and (allow_stale or cached_current(p,item)) then return p end
        end
        local __, p = API.getDirAndPath(item)
        if p and file_exists(p) and (allow_stale or cached_current(p,item)) then return p end
        if not strict and item.data.filename then local f = API.findAttachmentByBasename(item.data.filename, item.key); if f then return f end end
    end
    return nil
end

local function probe_entry(label, path)
    return { label = label, path = path, exists = path ~= nil and file_exists(path) or false }
end
function API.probeAttachmentResolution(item)
    local probe = { key=item.key, filename=item.data.filename or "?", linkMode=item.data.linkMode or "?", contentType=item.data.contentType, zoteroPath=item.data.path, probes={}, foundPath=nil }
    if item.data.linkMode == "linked_file" then
        local p = API.resolveLinkedPath(item.data.path, API.getLinkedFilesBase(), API.getPathMappings())
        table.insert(probe.probes, probe_entry("Linked file", p)); if p and file_exists(p) then probe.foundPath=p end
    else
        if API.getExternalStorageEnabled() and item.data.filename then
            local p = BaseUtil.joinPath(API.getExternalStorageDir(), item.key, item.data.filename)
            table.insert(probe.probes, probe_entry("External storage", p)); if file_exists(p) then probe.foundPath=p end
        end
        local __, p = API.getDirAndPath(item); table.insert(probe.probes, probe_entry("Plugin cache", p)); if not probe.foundPath and file_exists(p) then probe.foundPath=p end
    end
    if not probe.foundPath and item.data.filename then
        local p = API.findAttachmentByBasename(item.data.filename, item.key)
        if p then table.insert(probe.probes, probe_entry("Basename search", p)); probe.foundPath=p end
    end
    return probe
end
function API.getFirstLocalPathPreview()
    local db = API.openDB()
    local stmt = db:prepare("SELECT itemData.value FROM itemData JOIN items USING(itemID) WHERE items.itemTypeID=3")
    local row = stmt:reset():step()
    while row do
        local item = safe_decode(row[1])
        if item and item.data and API.attachmentKind(item.data) then
            local p = API.probeAttachmentResolution(item)
            stmt:close(); return p
        end
        row = stmt:step(row)
    end
    stmt:close()
    return { probes={}, note="No attachments in the local library. Synchronize with Zotero first." }
end
function API.formatLocalPathPreview(probe)
    if not probe then return "No local path information." end
    local lines = {}
    if probe.note then table.insert(lines, probe.note); table.insert(lines, "") end
    if probe.key then table.insert(lines, "Attachment: " .. tostring(probe.filename or probe.key)); table.insert(lines, "Key: " .. tostring(probe.key)); table.insert(lines, "Link mode: " .. tostring(probe.linkMode)); if probe.zoteroPath then table.insert(lines,"Zotero path field: "..probe.zoteroPath) end; table.insert(lines,"") end
    if #probe.probes > 0 then
        table.insert(lines,"Paths checked:")
        for __,p in ipairs(probe.probes) do table.insert(lines,(p.exists and "[OK] " or "[missing] ") .. tostring(p.label) .. ":"); table.insert(lines,"  "..tostring(p.path or "?")) end
    else table.insert(lines,"No paths to check for this item.") end
    table.insert(lines,"")
    table.insert(lines, probe.foundPath and ("First local file found:\n"..probe.foundPath) or "No local file found yet for this test.")
    return table.concat(lines,"\n")
end
--- Attachments whose file is called `base` (compared without regard to
-- case). The database is filtered on a piece of the name first; which piece
-- must not depend on how the stored JSON escapes characters.
local function attachments_named(base)
    local want = string.lower(base)
    local probe = ""
    for piece in base:gmatch("[A-Za-z0-9 _%-%.%(%)%[%],;!@#%$%%&%+='~]+") do
        if #piece > #probe then probe = piece end
    end
    local db = API.openDB()
    local stmt
    if #probe >= 3 then
        stmt = db:prepare("SELECT d.value FROM itemData d JOIN items i ON i.itemID=d.itemID WHERE i.itemTypeID=3 AND instr(d.value,?)>0")
        stmt:bind(probe)
    else
        stmt = db:prepare("SELECT d.value FROM itemData d JOIN items i ON i.itemID=d.itemID WHERE i.itemTypeID=3")
    end
    local out = {}
    local row = stmt:step()
    while row do
        local item = safe_decode(row[1])
        if item and item.key and type(item.data) == "table" and API.isSupportedAttachmentLinkMode(item.data.linkMode) then
            local d = item.data
            local leaf = type(d.path) == "string" and d.path:match("([^/\\:]+)$") or nil
            if (type(d.filename) == "string" and string.lower(d.filename) == want)
                or (leaf and string.lower(leaf) == want) then
                out[#out + 1] = item
            end
        end
        row = stmt:step(row)
    end
    stmt:close()
    return out
end

--- Which attachment is this file? Called for every document that is opened,
-- so it must be quick and must not walk the file system.
--
-- Annotation sync depends on the answer being right: annotations of one
-- attachment must never end up in the file of another. So a file is only
-- attributed when there is no doubt:
--   1. it sits in a Zotero storage folder named after the attachment's key;
--   2. it is the file a linked attachment names (if two attachments name the
--      same file, the one noted in the document before, else the first);
--   3. it merely has an attachment's file name (found by name in one of the
--      configured folders), and no other attachment has a file of that name.
-- @param hint the key stored in the document's sidecar by an earlier match
function API.findAttachmentKeyByFilePath(file_path, hint)
    if not file_path or file_path == "" then return nil end
    local norm = API.normalizePathForCompare(file_path) or API.normalizePath(file_path)
    local key = key_by_folder(norm)
    if key then return key end

    local function own_file(item)
        local ok, p = pcall(API.resolveAttachmentPath, item, true)
        if not ok then return nil end
        return p
    end
    if Util.isValidKey(hint) then
        local item = API.getItem(hint)
        if item and item.data and item.data.itemType == "attachment" then
            local p = own_file(item)
            if p and API.pathsEqual(p, file_path) then return hint end
        end
    end

    -- Most documents a reader opens have nothing to do with Zotero. Outside
    -- the folders configured for attachments only a linked file can be one.
    local in_root = false
    for __, root in ipairs(API.collectSearchRoots()) do
        local r = API.normalizePathForCompare(root) or API.normalizePath(root)
        if r and r ~= "" and norm:sub(1, #r + 1) == r .. "/" then in_root = true break end
    end
    if not in_root and not API.getLinkedFilesEnabled() then return nil end

    local base = API.basenameOfPath(norm)
    if not base or base == "" then return nil end
    local candidates = attachments_named(base)
    if #candidates == 0 then return nil end
    local exact, homeless = {}, {}
    for __, item in ipairs(candidates) do
        local p = own_file(item)
        if p and API.pathsEqual(p, file_path) then
            exact[#exact + 1] = item.key
        elseif not p then
            homeless[#homeless + 1] = item.key -- its own file is not where it should be
        end
    end
    if #exact > 0 then
        table.sort(exact)
        for __, k in ipairs(exact) do if k == hint then return k end end
        return exact[1]
    end
    if #candidates == 1 and #homeless == 1 then
        -- the only attachment with this file name, and this file is in one of
        -- the folders that are searched for attachments
        return in_root and homeless[1] or nil
    end
    if #homeless > 0 then
        logger.info("Zotero:", #candidates, "attachments are called", base, "- not attributing", file_path, "to any of them")
    end
    return nil
end
--- Why an attachment cannot be opened, in words.
function API.whyNotOpenable(d)
    d=type(d)=="table" and d or {}
    if d.linkMode=="linked_url" then return "This attachment is a link to a web page, not a file." end
    if not SUPPORTED_LINK_MODES[d.linkMode] then return "This kind of attachment ("..tostring(d.linkMode)..") cannot be opened." end
    local what=d.contentType
    if what==nil or what=="" then what=d.filename or "unknown type" end
    return "Only PDF, EPUB and web snapshots can be opened; this attachment is "..tostring(what).."."
end
function API.tryResolveLocalAttachment(key)
    local item=API.getItem(key)
    if not item then return nil,"Error: the requested file can not be found in the database" end
    if not item.data or item.data.itemType ~= "attachment" then return nil,"Error: this item is not an attachment" end
    if not API.attachmentKind(item.data) then return nil,API.whyNotOpenable(item.data) end
    local p=API.resolveAttachmentPath(item)
    if p and file_exists(p) then return p,nil end
    return nil,nil
end

function API.getHeaders(api_key)
    return { ["zotero-api-key"] = api_key, ["zotero-api-version"] = "3" }
end
function API.verifyResponse(r, c, allowed)
    if r ~= 1 then return "Error: "..tostring(c) end
    c=tonumber(c)
    if allowed then for __,v in ipairs(allowed) do if c==v then return nil end end end
    if not c or c < 200 or c >= 300 then return "Error: API responded with status code "..tostring(c) end
    return nil
end
local function readable_value(value)
    if value == nil then return "nil" end
    if type(value) ~= "table" then return tostring(value) end
    local ok, encoded = pcall(JSON.encode, value)
    if ok and encoded then return encoded end
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

-- KOReader's socket helpers give requests a timeout; without them a dead
-- connection blocks the whole reader.
local socketutil
do
    local ok, mod = pcall(require, "socketutil")
    if ok and type(mod) == "table" and mod.set_timeout then socketutil = mod end
end

local function nap(seconds)
    seconds = math.max(0, math.min(tonumber(seconds) or 0, 20))
    if seconds > 0 then pcall(BaseUtil.sleep, seconds) end
end

--- One request to the Zotero API.
-- opts = { method, url, headers, body (string) }
-- @return status code, response headers (lower-case names), response body
--         or nil, error message when the request did not get an answer
function API.request(opts)
    local tries = 0
    while true do
        tries = tries + 1
        if API.backoff_until then
            nap(API.backoff_until - os.time())
            API.backoff_until = nil
        end
        local headers = copy_table(opts.headers)
        local req = { method = opts.method or "GET", url = opts.url, headers = headers }
        if opts.body then
            headers["content-type"] = headers["content-type"] or "application/json"
            headers["content-length"] = tostring(#opts.body)
            req.source = ltn12.source.string(opts.body)
        end
        local chunks = {}
        if socketutil then
            socketutil:set_timeout(20, 180)
            req.sink = socketutil.table_sink(chunks)
        else
            req.sink = ltn12.sink.table(chunks)
        end
        local ok, r, c, h = pcall(https.request, req)
        if socketutil then socketutil:reset_timeout() end
        if not ok then return nil, tostring(r) end
        if r ~= 1 then return nil, tostring(c) end
        local code = tonumber(c)
        h = h or {}
        if h["backoff"] then
            -- the server asks clients to slow down
            API.backoff_until = os.time() + math.min(tonumber(h["backoff"]) or 0, 20)
        end
        if (code == 429 or code == 503) and tries < 3 then
            nap(tonumber(h["retry-after"]) or 5)
        else
            return code, h, table.concat(chunks)
        end
    end
end

--- GET a JSON document. @return decoded value, response headers  or  nil, error
function API.getZoteroData(url)
    if not API.zoteroHeader then return nil,"Error: Zotero header not set. Check user ID and API key" end
    local code, h, raw = API.request{ method = "GET", url = url, headers = API.zoteroHeader }
    if not code then
        logger.warn("Zotero: GET failed", url, h)
        return nil, "Error: " .. tostring(h)
    end
    if code < 200 or code >= 300 then
        local e = "Error: API responded with status code " .. tostring(code)
        if code == 403 then e = e .. " (access denied: check the API key and its permissions)" end
        logger.warn("Zotero: GET failed", url, e)
        return nil, e
    end
    local result, decode_err = Util.jsonDecode(raw)
    if result == nil then
        local msg = "Error: Zotero returned an empty or undecodable JSON response: " .. tostring(decode_err)
        logger.warn("Zotero:", msg, "URL:", url, "body:", tostring(raw):sub(1, 300))
        return nil, msg
    end
    return result, h or {}
end
function API.checkZoteroKey(url)
    if API.access then return API.access end
    local result,e=API.getZoteroData(url); if not result then return nil,e end
    API.access=result.access or {}
    local db=API.openDB(); local uid=tonumber(db:rowexec("SELECT userID FROM libraries WHERE libraryID=1")) or 0
    if uid==0 then
        -- FIX: bound SQL parameters; Zotero usernames must never be interpolated as quoted identifiers.
        local stmt=db:prepare("UPDATE libraries SET userID=?,name=?,editable=? WHERE libraryID=1")
        stmt:bind(tonumber(result.userID) or tonumber(API.getUserID()) or 0,result.username or "",0):step(); stmt:close()
    end
    return API.access
end
function API.verifyZoteroAccess()
    if API.zoteroAcessVerified then return nil end
    local uid, key=API.getUserID(),API.getAPIKey()
    if uid=="" then return "Error: must set User ID" end
    if key=="" then return "Error: must set API Key" end
    API.zoteroHeader=API.getHeaders(key)
    API.userLibraryURL=ZOTERO_BASE_URL.."/users/"..tostring(uid)
    local __, e=API.checkZoteroKey(ZOTERO_BASE_URL.."/keys/current")
    if e then return e end
    API.zoteroAcessVerified=true
    return nil
end
--- May this API key change the library?
function API.canWrite()
    local a = API.access
    return type(a) == "table" and type(a.user) == "table" and a.user.write == true
end
function API.fetchCollectionSize(url, headers)
    local code, h = API.request{ method = "HEAD", url = url, headers = headers }
    if not code then return nil, "Error: " .. tostring(h) end
    if code < 200 or code >= 300 then return nil, "Error: API responded with status code " .. tostring(code) end
    local n=tonumber(h and h["total-results"]); if not n then return nil,"Error: could not determine number of items in library" end
    return n,nil,tonumber(h["last-modified-version"])
end
--- Fetch a listing page by page.
-- @return (with callback) the lowest Last-Modified-Version any of the
--   requests reported: the library version this listing is known to be
--   complete for. An empty listing is complete for the version its (only)
--   request reported.
function API.fetchCollectionPaginated(url, headers, callback)
    local size,e,head_version=API.fetchCollectionSize(url,headers); if e then return nil,e end
    local all, version, step = {}, head_version, 100
    if size==0 then
        if callback then callback({},100) end
        return callback and (version or API.getUserLibraryVersion()) or all,nil
    end
    for start=0,size-1,step do
        local sep=url:find("?",1,true) and "&" or "?"
        local page_url=url..sep.."limit="..step.."&start="..start
        local result,h=API.getZoteroData(page_url); if not result then return nil,h end
        local v=tonumber(h["last-modified-version"])
        if v and (not version or v < version) then version = v end
        local pct=math.min(100,100*(start+#result)/size)
        if callback then
            if callback(result,pct)==false then return nil,API.CANCELLED end
        else
            for __,v2 in ipairs(result) do table.insert(all,v2) end
        end
    end
    return callback and (version or API.getUserLibraryVersion()) or all,nil
end
function API.checkWebDAV()
    local url=API.getWebDAVUrl(); if url=="" then return "No WebDAV URL provided" end
    local r,c=https.request{method="PROPFIND",url=url,headers=API.getWebDAVHeaders()}
    if r~=1 then return "WebDAV error: "..tostring(c) end
    c=tonumber(c); if not c or c<200 or c>=400 then return "WebDAV responded with status code "..tostring(c) end
    return nil
end
function API.getWebDAVHeaders()
    return { ["Authorization"]="Basic "..sha2.bin_to_base64(API.getWebDAVUser()..":"..API.getWebDAVPassword()) }
end

local type_ids = {}
local function type_id(type_name)
    local id = type_ids[type_name]
    if id == nil then
        id = tonumber(API.openDB():rowexec("SELECT itemTypeID FROM itemTypes WHERE typeName='"..tostring(type_name):gsub("'","''").."'")) or false
        type_ids[type_name] = id
    end
    return id or nil
end
local function upsert_item(item)
    if not item or not item.key or not item.data then return end
    local db=API.openDB(); local tid=type_id(item.data.itemType) or type_id("document") or 13
    local stmt=db:prepare([[INSERT INTO items(itemTypeID,libraryID,key,version) VALUES(?,1,?,?) ON CONFLICT(libraryID,key) DO UPDATE SET itemTypeID=excluded.itemTypeID,version=excluded.version]])
    stmt:bind(tid,item.key,tonumber(item.version) or 0):step(); stmt:close()
    stmt=db:prepare([[INSERT INTO itemData(itemID,value) SELECT itemID,? FROM items WHERE key=? ON CONFLICT(itemID) DO UPDATE SET value=excluded.value]])
    stmt:bind(JSON.encode(item),item.key):step(); stmt:close()
    -- it exists (again): no longer "deleted on the server"
    stmt=db:prepare("DELETE FROM syncDeleted WHERE key=?"); stmt:bind(item.key):step(); stmt:close()
    if (tonumber(db:rowexec("SELECT changes()")) or 0) > 0 then
        -- it had been reported deleted (moved to the trash) and is back: its
        -- children did not come with it, see relink_orphans
        API.restored_seen = true
    end
end
--- Remove an item from the local library.
-- @param reported true when the server said it was deleted. That is kept as
--        evidence, together with what was last known of an annotation: a
--        local annotation linked to it is only removed if it still is what
--        Zotero had.
-- @param last the item as the server sent it now (in the trash), if any
local function delete_item(key, reported, last)
    local db=API.openDB()
    if reported then
        local value
        local stmt=db:prepare("SELECT d.value FROM itemData d JOIN items i ON i.itemID=d.itemID WHERE i.key=? AND i.itemTypeID=1")
        local row=stmt:bind(key):step(); if row then value=row[1] end; stmt:close()
        if not value and type(last)=="table" and type(last.data)=="table" and last.data.itemType=="annotation" then
            local ok,encoded=pcall(JSON.encode,last); if ok then value=encoded end
        end
        stmt=db:prepare("INSERT INTO syncDeleted(key,at,value) VALUES(?,unixepoch('now'),?) ON CONFLICT(key) DO UPDATE SET at=excluded.at,value=COALESCE(excluded.value,syncDeleted.value)")
        stmt:bind(key,value):step(); stmt:close()
    end
    local stmt=db:prepare("DELETE FROM items WHERE key=?"); stmt:bind(key):step(); stmt:close()
end

--- Did the server report this item deleted (or moved to the trash)?
-- @return true and the item as it was last known here (if it was an
--         annotation that had been downloaded), or false
function API.wasDeleted(key)
    local stmt=API.openDB():prepare("SELECT value FROM syncDeleted WHERE key=?")
    local row=stmt:bind(key):step()
    local found,value=row ~= nil,row and row[1] or nil
    stmt:close()
    if not found then return false end
    return true, type(value)=="string" and safe_decode(value) or nil
end
function API.markDeleted(key)
    delete_item(key, true)
end
function API.forgetItem(key)
    delete_item(key, false)
end

--- Items the server lists again after having reported them deleted (restored
-- from the trash) come without their children: the server only lists what
-- changed. Children that are still stored here are attached again.
local function relink_orphans()
    local db=API.openDB()
    local attachments,annotations={},{}
    local st=db:prepare("SELECT i.key,d.value FROM items i JOIN itemData d ON d.itemID=i.itemID WHERE i.itemTypeID=3 AND i.itemID NOT IN (SELECT itemID FROM itemAttachments)")
    local row=st:step()
    while row do
        local item=safe_decode(row[2]); local d=item and item.data
        if d and (table_contains(SUPPORTED_MEDIA_TYPES,d.contentType) or API.attachmentKind(d)) then attachments[row[1]]=d.parentItem or row[1] end
        row=st:step(row)
    end
    st:close()
    if next(attachments) then API.setItemAttachments(attachments) end
    st=db:prepare("SELECT i.key,d.value FROM items i JOIN itemData d ON d.itemID=i.itemID WHERE i.itemTypeID=1 AND i.itemID NOT IN (SELECT itemID FROM itemAnnotations)")
    row=st:step()
    while row do
        local item=safe_decode(row[2]); local d=item and item.data
        if d and d.parentItem then annotations[row[1]]=d.parentItem end
        row=st:step(row)
    end
    st:close()
    if next(annotations) then API.setAnnotations(annotations) end
end

function API.setItemAttachments(map)
    local db=API.openDB(); local stmt=db:prepare([[INSERT INTO itemAttachments(itemID,parentItemID) SELECT a.itemID,p.itemID FROM items a,items p WHERE a.key=? AND p.key=? ON CONFLICT(itemID) DO UPDATE SET parentItemID=excluded.parentItemID]])
    for child,parent in pairs(map or {}) do stmt:reset():bind(child,parent):step() end
    stmt:close()
end
function API.setAnnotations(map)
    local db=API.openDB(); local stmt=db:prepare([[INSERT INTO itemAnnotations(itemID,parentItemID) SELECT a.itemID,p.itemID FROM items a,items p WHERE a.key=? AND p.key=? ON CONFLICT(itemID) DO UPDATE SET parentItemID=excluded.parentItemID]])
    for child,parent in pairs(map or {}) do stmt:reset():bind(child,parent):step() end
    stmt:close()
end

function API.fetchZoteroCollections(since, progress_callback)
    since=tonumber(since) or API.getUserLibraryVersion(); local e=API.verifyZoteroAccess(); if e then return nil,e end
    local callback=progress_callback or function() end
    local url=API.userLibraryURL.."/collections?since="..since.."&format=json"
    local nested={}
    local version,err=API.fetchCollectionPaginated(url,API.zoteroHeader,function(entries, pct)
        if callback(string.format("Syncing collections %.0f%%",pct))==false then return false end
        local db=API.openDB()
        for __,entry in ipairs(entries) do
            local c=entry.data or entry
            if c.deleted then
                local st=db:prepare("DELETE FROM collections WHERE key=?"); st:bind(c.key or entry.key):step(); st:close()
            else
                local key=c.key or entry.key; local parent=c.parentCollection or "/"
                if parent~="/" then nested[key]=parent; parent="/" end
                local st=db:prepare([[INSERT INTO collections(collectionName,parentCollectionID,libraryID,key,version) SELECT ?,collectionID,1,?,? FROM collections WHERE key=? ON CONFLICT(libraryID,key) DO UPDATE SET collectionName=excluded.collectionName,version=excluded.version,parentCollectionID=excluded.parentCollectionID]])
                st:bind(c.name or "",key,tonumber(c.version or entry.version) or 0,parent):step(); st:close()
            end
        end
    end)
    -- (also when the download stopped half-way: what was stored gets its place)
    local db=API.openDB(); local st=db:prepare("UPDATE collections SET parentCollectionID=(SELECT collectionID FROM collections WHERE key=?) WHERE key=? AND EXISTS(SELECT 1 FROM collections WHERE key=?)")
    for child,parent in pairs(nested) do st:reset():bind(parent,child,parent):step() end; st:close()
    if err then return nil,err end
    return tonumber(version) or since,nil
end

function API.fetchZoteroItems(since, progress_callback)
    since=tonumber(since) or API.getUserLibraryVersion(); local e=API.verifyZoteroAccess(); if e then return nil,e end
    local callback=progress_callback or function() end
    local db=API.openDB()
    local lowest
    local function seen(v) v=tonumber(v); if v and (not lowest or v<lowest) then lowest=v end end

    local attachments,annotations={},{}
    local seen_keys={} -- listed as existing by this very download
    API.restored_seen=nil
    local colstmt_del=db:prepare("DELETE FROM collectionItems WHERE itemID=(SELECT itemID FROM items WHERE key=?)")
    local colstmt=db:prepare([[INSERT OR IGNORE INTO collectionItems(collectionID,itemID) SELECT collections.collectionID,items.itemID FROM collections,items WHERE collections.key=? AND items.key=?]])
    local function close_statements() colstmt_del:close(); colstmt:close() end

    --- Store a batch of items as the server sent them. One transaction per
    -- batch: far fewer disk syncs. @return nil, or an error message
    local function store(entries)
        db:exec("BEGIN")
        local done,perr=pcall(function()
            for __,item in ipairs(entries) do
                if item.key then
                    local d=item.data
                    if d and d.deleted and d.deleted~=0 then
                        delete_item(item.key,true,item)
                    elseif d then
                        seen_keys[item.key]=true
                        item.links=nil; item.library=nil; upsert_item(item)
                        -- This item's place in the index. Only what changed is
                        -- touched: no rebuild of the whole library's index.
                        colstmt_del:reset():bind(item.key):step()
                        local cols=type(d.collections)=="table" and d.collections or {}
                        if #cols==0 then
                            colstmt:reset():bind("/",item.key):step()
                        else
                            for __,c in ipairs(cols) do colstmt:reset():bind(c,item.key):step() end
                        end
                        if d.itemType=="attachment" and (table_contains(SUPPORTED_MEDIA_TYPES,d.contentType) or API.attachmentKind(d)) then
                            attachments[item.key]=d.parentItem or item.key
                        elseif d.itemType=="annotation" and d.parentItem then
                            annotations[item.key]=d.parentItem
                        end
                    end
                end
            end
        end)
        db:exec(done and "COMMIT" or "ROLLBACK")
        if not done then return tostring(perr) end
        return nil
    end

    -- A library that is already stored here is not downloaded again from the
    -- start: its item versions are compared with the server's, and only what
    -- differs is fetched. (This is the case after an update of the plugin,
    -- which asks for the whole library to be checked once.)
    local trashed
    local compared=false
    if since==0 and (tonumber(db:rowexec("SELECT COUNT(*) FROM items")) or 0)>0 then
        if callback("Comparing with the Zotero library…")==false then close_statements(); return nil,API.CANCELLED end
        local live,h1=API.getZoteroData(API.userLibraryURL.."/items?format=versions")
        if type(live)~="table" then close_statements(); return nil,h1 end
        local all,h2=API.getZoteroData(API.userLibraryURL.."/items?format=versions&includeTrashed=1")
        if type(all)~="table" then close_statements(); return nil,h2 end
        local n_live,n_all=0,0
        for __ in pairs(live) do n_live=n_live+1 end
        for __ in pairs(all) do n_all=n_all+1 end
        local t1,t2=tonumber(h1["total-results"]),tonumber(h2["total-results"])
        if (t1==nil or t1==n_live) and (t2==nil or t2==n_all) and n_all>=n_live then
            compared=true
            seen(h1["last-modified-version"]); seen(h2["last-modified-version"])
            local have={}
            local st=db:prepare("SELECT key,version FROM items")
            local row=st:step()
            while row do have[row[1]]=tonumber(row[2]) or 0; row=st:step(row) end
            st:close()
            local wanted={}
            for key,version in pairs(live) do
                if Util.isValidKey(key) and have[key]~=tonumber(version) then wanted[#wanted+1]=key end
            end
            table.sort(wanted)
            trashed={}
            for key in pairs(all) do
                if live[key]==nil then trashed[#trashed+1]=key end
            end
            logger.info("Zotero: library compared:", n_live, "items on the server,", #wanted, "to fetch,", #trashed, "in the trash")
            local BATCH=50
            for start=1,#wanted,BATCH do
                if callback(string.format("Syncing items %.0f%%",100*(start-1)/#wanted))==false then close_statements(); return nil,API.CANCELLED end
                local keys={}
                for i=start,math.min(start+BATCH-1,#wanted) do keys[#keys+1]=wanted[i] end
                local result,h=API.getZoteroData(API.userLibraryURL.."/items?format=json&includeTrashed=1&itemKey="..table.concat(keys,","))
                if type(result)~="table" then close_statements(); return nil,h end
                seen(h["last-modified-version"])
                local serr=store(result)
                if serr then close_statements(); return nil,"Error: could not store items: "..serr end
            end
        else
            logger.warn("Zotero: the server's item list looks incomplete (", n_live, t1, n_all, t2, "); downloading the library page by page instead")
        end
    end

    if not compared then
        -- Items in the trash are only listed on request. Without them, an item
        -- (or annotation) moved to the trash in Zotero would stay here forever.
        local url=API.userLibraryURL.."/items?since="..since.."&format=json&includeTrashed=1"
        local page_error
        local ok,version,err=pcall(API.fetchCollectionPaginated,url,API.zoteroHeader,function(entries, pct)
            if callback(string.format("Syncing items %.0f%%",pct))==false then return false end
            if page_error then return end
            page_error=store(entries)
        end)
        if not ok then close_statements(); return nil,"Error: "..tostring(version) end
        if err then close_statements(); return nil,err end
        if page_error then close_statements(); return nil,"Error: could not store items: "..page_error end
        seen(version)
    end

    local deleted,dh=API.getZoteroData(API.userLibraryURL.."/deleted?since="..since)
    if type(deleted)~="table" then close_statements(); return nil,dh end
    seen(type(dh)=="table" and dh["last-modified-version"])

    callback("Updating local index…")
    db:exec("BEGIN")
    local done,ierr=pcall(function()
        -- (an item this download listed as existing is not deleted on the
        -- word of the delete log read just after it)
        for __,key in ipairs(deleted.items or {}) do if not seen_keys[key] then delete_item(key,true) end end
        -- items the comparison found in Zotero's trash
        for __,key in ipairs(trashed or {}) do if not seen_keys[key] then delete_item(key,true) end end
        local st=db:prepare("DELETE FROM collections WHERE key=?")
        for __,key in ipairs(deleted.collections or {}) do st:reset():bind(key):step() end
        st:close()
        -- parents exist now, whatever order the pages came in
        API.setItemAttachments(attachments)
        API.setAnnotations(annotations)
        -- after a comparison: also index what an earlier version left out
        if API.restored_seen or compared then relink_orphans() end
        db:exec("DELETE FROM syncDeleted WHERE at < unixepoch('now') - 34560000") -- older than 400 days
    end)
    db:exec(done and "COMMIT" or "ROLLBACK")
    close_statements()
    if not done then return nil,"Error: could not update the local index: "..tostring(ierr) end
    if API.restored_seen then
        API.restored_seen=nil
        pcall(API.scanStorage) -- which of the restored attachments have their file here
    end
    return lowest or since,nil
end

--- Rebuild the whole local index from the stored items. Not part of a normal
-- sync any more; available from the Maintenance menu.
function API.checkItemData(progress_callback)
    local db=API.openDB()
    local total=tonumber(db:rowexec("SELECT COUNT(*) FROM itemData")) or 0
    if progress_callback then progress_callback("Rebuilding local index…") end

    -- Which attachments are on this device is not derivable from the items:
    -- keep it across the rebuild.
    local present={}
    do
        local ps=db:prepare("SELECT i.key,a.syncedVersion,a.lastSync FROM itemAttachments a JOIN items i ON i.itemID=a.itemID WHERE a.syncedVersion>0 OR a.lastSync>0")
        local row=ps:reset():step()
        while row do present[row[1]]={tonumber(row[2]) or 0,tonumber(row[3]) or 0}; row=ps:step(row) end
        ps:close()
    end

    -- Rebuilding these relationship tables can involve thousands of INSERTs.
    -- Do them in one transaction; otherwise SQLite may fsync each write
    -- individually, which is extremely slow on e-ink/Android storage.
    db:exec("BEGIN IMMEDIATE")
    local ok, err = pcall(function()
        db:exec("DELETE FROM collectionItems")
        db:exec("DELETE FROM itemAttachments")
        db:exec("DELETE FROM itemAnnotations")

        local stmt=db:prepare("SELECT value FROM itemData JOIN items USING(itemID)")
        local colstmt=db:prepare([[INSERT OR IGNORE INTO collectionItems(collectionID,itemID) SELECT collections.collectionID,items.itemID FROM collections,items WHERE collections.key=? AND items.key=?]])
        local attachments,annotations={},{}
        local row=stmt:reset():step()
        local count=0
        local progress_step=math.max(math.floor(total/100),10)
        while row do
            local item=safe_decode(row[1])
            if item and item.data then
                local cols=type(item.data.collections)=="table" and item.data.collections or {}
                if #cols==0 then
                    colstmt:reset():bind("/",item.key):step()
                else
                    for __,c in ipairs(cols) do colstmt:reset():bind(c,item.key):step() end
                end
                if item.data.itemType=="attachment" and (table_contains(SUPPORTED_MEDIA_TYPES,item.data.contentType) or API.attachmentKind(item.data)) then
                    attachments[item.key]=item.data.parentItem or item.key
                end
                if item.data.itemType=="annotation" and item.data.parentItem then
                    annotations[item.key]=item.data.parentItem
                end
            end
            count=count+1
            if progress_callback and total>0 and (count%progress_step==0 or count==total) then
                progress_callback(string.format("Rebuilding local index %.0f%%",100*count/total))
            end
            row=stmt:step(row)
        end
        stmt:close()
        colstmt:close()
        API.setItemAttachments(attachments)
        API.setAnnotations(annotations)
        local rs=db:prepare("UPDATE itemAttachments SET syncedVersion=?,lastSync=? WHERE itemID=(SELECT itemID FROM items WHERE key=?)")
        for key,v in pairs(present) do rs:reset():bind(v[1],v[2],key):step() end
        rs:close()
    end)

    if ok then
        db:exec("COMMIT")
        if progress_callback then progress_callback("Rebuilding local index 100%") end
        return nil
    end
    db:exec("ROLLBACK")
    return tostring(err)
end

function API.getItem(key)
    local stmt=API.openDB():prepare("SELECT value FROM itemData JOIN items USING(itemID) WHERE items.key=?")
    local row=stmt:bind(key):step(); local out=row and safe_decode(row[1]) or nil; stmt:close(); return out
end
function API.getItemAttachments(key)
    local db=API.openDB(); local stmt=db:prepare([[SELECT i.key,d.value FROM itemAttachments a JOIN items i ON i.itemID=a.itemID JOIN itemData d ON d.itemID=i.itemID WHERE a.parentItemID IN (SELECT itemID FROM items WHERE key=?) ]])
    local out={}; local row=stmt:bind(key):step()
    while row do
        local item=safe_decode(row[2]); local d=item and item.data or {}
        -- kind: what the reader can open ("pdf", "epub", "html"); nil for a
        -- link to a web page, which is listed but cannot be opened
        local kind=API.attachmentKind(d)
        table.insert(out,{key=row[1],text=d.filename or d.title or row[1],type="attachment",kind=kind,is_pdf=kind=="pdf",contentType=d.contentType,linkMode=d.linkMode,title=d.title or d.filename or row[1],version=item and item.version or 0})
        row=stmt:step(row)
    end
    stmt:close()
    -- what can be opened first (PDF, then EPUB, then web snapshots), links last
    table.sort(out,function(a, b)
        local ka,kb=KIND_ORDER[a.kind] or 9,KIND_ORDER[b.kind] or 9
        if ka~=kb then return ka<kb end
        return (a.text or "")<(b.text or "")
    end)
    return out
end
--- The attachment to open when an entry is tapped: the only one of the best
-- kind it has (PDF before EPUB before web snapshot).
-- @return the attachment, or nil and the list of those that can be opened
--         (empty: links only, or nothing; several: the user has to choose)
function API.pickAttachment(key)
    local usable={}
    for __,a in ipairs(API.getItemAttachments(key) or {}) do
        if a.kind then usable[#usable+1]=a end
    end
    if #usable==0 then return nil,usable end
    local best=0
    for __,a in ipairs(usable) do if a.kind==usable[1].kind then best=best+1 end end
    if best==1 then return usable[1],usable end
    return nil,usable
end
--- For the browser: the kind of file a tap on this entry opens, and whether
-- that file is on this device (every one of them, where the entry has several
-- of that kind and asks which). A copy that is older than Zotero's counts as
-- not there, as it does when the entry is opened.
-- @param standalone the entry is itself an attachment
-- @return kind ("pdf" | "epub" | "html") or nil, on this device?
function API.entryFileState(key, standalone)
    local candidates={}
    if standalone then
        local item=API.getItem(key)
        local kind=item and item.data and API.attachmentKind(item.data)
        if not kind then return nil,false end
        candidates[1]={item=item,kind=kind}
    else
        local list=API.getItemAttachments(key) or {}
        local best=list[1] and list[1].kind
        if not best then return nil,false end
        for __,a in ipairs(list) do
            if a.kind==best then candidates[#candidates+1]={item=API.getItem(a.key),kind=best} end
        end
    end
    local kind=candidates[1].kind
    for __,c in ipairs(candidates) do
        local p=c.item and API.resolveAttachmentPath(c.item,true)
        if not (p and file_exists(p)) then return kind,false end
    end
    return kind,true
end
function API.getItemWithAttachments(key)
    local item=API.getItem(key); if not item then return nil end
    local list=API.getItemAttachments(key); local attachments={}
    for __,x in ipairs(list) do local ai=API.getItem(x.key); if ai and ai.data then local d=ai.data; local sv,ls=API.getAttachmentVersion(x.key); d.syncedVersion=sv; d.lastSync=ls; d.kind=x.kind; table.insert(attachments,d) end end
    item.attachments=attachments; return item
end

local function is_child(d)
    return type(d.parentItem)=="string" and d.parentItem~=""
end
function API.displayCollection(key)
    key=key or "/"; local db=API.openDB(); local out={}
    local cid=tonumber(db:rowexec("SELECT collectionID FROM collections WHERE key='"..key:gsub("'","''").."'")); if not cid then return out end
    local st=db:prepare("SELECT key,collectionName,synced FROM collections WHERE parentCollectionID=? ORDER BY collectionName COLLATE NOCASE"); local row=st:bind(cid):step()
    -- (offline: a collection whose files a sync downloads)
    while row do table.insert(out,{key=row[1],text=row[2] or "",type="collection",offline=(tonumber(row[3]) or 0)>0}); row=st:step(row) end; st:close()
    st=db:prepare([[SELECT i.key,d.value,t.typeName FROM collectionItems ci JOIN items i ON i.itemID=ci.itemID JOIN itemData d ON d.itemID=i.itemID JOIN itemTypes t ON t.itemTypeID=i.itemTypeID WHERE ci.collectionID=? AND t.typeName NOT IN ('annotation')]])
    row=st:bind(cid):step()
    while row do
        local item=safe_decode(row[2]); local d=item and item.data or {}; local meta=item and item.meta or {}; local text=d.title or d.filename or row[1]; if meta.creatorSummary and meta.creatorSummary~="" then text=meta.creatorSummary.." - "..text end
        -- (the files, links and notes of an entry belong to no collection of
        -- their own and are stored under the top level: they are reached
        -- through their entry, not listed beside it)
        local tp=row[3]=="attachment" and "attachment" or "item"; if not is_child(d) then table.insert(out,{key=row[1],text=text,type=tp,is_pdf=d.contentType=="application/pdf"}) end; row=st:step(row)
    end
    st:close(); return out
end
function API.displaySearchResults(query)
    query=string.lower(query or ""); local db=API.openDB(); local out={}; local st=db:prepare([[SELECT i.key,d.value,t.typeName FROM items i JOIN itemData d USING(itemID) JOIN itemTypes t USING(itemTypeID) WHERE t.typeName NOT IN ('annotation')]])
    local row=st:reset():step(); while row do local item=safe_decode(row[2]); local d=item and item.data or {}; local meta=item and item.meta or {}; local text=d.title or d.filename or row[1]; if meta.creatorSummary and meta.creatorSummary~="" then text=meta.creatorSummary.." - "..text end; if (query=="" or string.lower(text):find(query,1,true)) and not is_child(d) then table.insert(out,{key=row[1],text=text,type=row[3]=="attachment" and "attachment" or "item"}) end; row=st:step(row) end; st:close(); table.sort(out,function(a, b) return a.text<b.text end); return out
end

function API.getAttachmentVersion(key)
    local st=API.openDB():prepare([[SELECT a.syncedVersion,a.lastSync,i.version,i.itemID FROM itemAttachments a JOIN items i ON i.itemID=a.itemID WHERE i.key=?]])
    local row=st:bind(key):step(); if not row then st:close(); return nil end
    local a,b,c,d=tonumber(row[1]),tonumber(row[2]),tonumber(row[3]),tonumber(row[4]); st:close(); return a,b,c,d
end
function API.setAttachmentVersion(id, v)
    local st=API.openDB():prepare("UPDATE itemAttachments SET syncedVersion=?,lastSync=unixepoch('now') WHERE itemID=?"); st:bind(v,id):step(); st:close()
end
function API.setAttachmentVersionByKey(key, v)
    local st=API.openDB():prepare("UPDATE itemAttachments SET syncedVersion=? WHERE itemID IN (SELECT itemID FROM items WHERE key=?)"); st:bind(v,key):step(); st:close()
end
function API.getItemVersion(key)
    local st=API.openDB():prepare("SELECT version FROM items WHERE key=?"); local row=st:bind(key):step(); local v=row and tonumber(row[1]) or nil; st:close(); return v
end
function API.isOfflineCollection(key)
    local st=API.openDB():prepare("SELECT synced FROM collections WHERE key=?"); local row=st:bind(key):step(); local yes=row and tonumber(row[1])>0 or false; st:close(); return yes
end
function API.addOfflineCollection(key) local st=API.openDB():prepare("UPDATE collections SET synced=1 WHERE key=?"); st:bind(key):step(); st:close() end
function API.removeOfflineCollection(key) local st=API.openDB():prepare("UPDATE collections SET synced=0 WHERE key=?"); st:bind(key):step(); st:close() end
function API.resetSyncState()
    API.closeDB(); local bak=BaseUtil.joinPath(API.zotero_dir,"zotero.db.old"); os.remove(bak); if not os.rename(API.db_path,bak) then os.remove(API.db_path) end; API.openDB()
end

--- Unpack a zip file into a folder. @return true or false
local function extract_zip(zip, dir)
    -- the reader's own archive library (works on every device)
    local ok_lib,Archiver=pcall(require,"ffi/archiver")
    if ok_lib and type(Archiver)=="table" and Archiver.Reader then
        local done=false
        local ok=pcall(function()
            local arc=Archiver.Reader:new()
            if arc:open(zip) then
                local all=true
                for entry in arc:iterate() do
                    local path=entry.path
                    if type(path)=="string" and path~="" and not path:find("..",1,true) and path:sub(1,1)~="/" then
                        if entry.mode=="file" then
                            local dest=BaseUtil.joinPath(dir,path)
                            local parent=dest:match("^(.*)/[^/]+$"); if parent then mkdir_p(parent) end
                            if not arc:extractToPath(path,dest) then all=false; break end
                        end
                    end
                end
                arc:close()
                done=all
            end
        end)
        if ok and done then return true end
    end
    if BaseUtil.extractArchive and pcall(BaseUtil.extractArchive,zip,dir) then return true end
    local cmd=string.format("unzip -o %q -d %q >/dev/null 2>&1",zip,dir)
    local res=os.execute(cmd)
    return res==0 or res==true
end
API._extractZip=extract_zip

function API.downloadWebDAV(key, targetDir, targetPath)
    local base=API.getWebDAVUrl(); if base=="" then return nil,"WebDAV url not set" end
    mkdir_p(targetDir); local zip=BaseUtil.joinPath(targetDir,key..".zip"); local f=io.open(zip,"wb"); if not f then return nil,"Could not create WebDAV zip" end
    if socketutil then socketutil:set_timeout(30,-1) end
    local ok,r,c=pcall(https.request,{method="GET",url=base:gsub("/$","").."/"..key..".zip",headers=API.getWebDAVHeaders(),sink=ltn12.sink.file(f)})
    if socketutil then socketutil:reset_timeout() end
    local e=(not ok) and ("Error: "..tostring(r)) or API.verifyResponse(r,c); if e then os.remove(zip); return nil,e end
    ok=extract_zip(zip,targetDir)
    os.remove(zip); if not ok then return nil,"Unzipping failed" end
    if file_exists(targetPath) then return targetPath end
    return API.findFileByBasename(targetDir,API.basenameOfPath(targetPath)) or targetPath
end
--- Remember that this attachment's file is on this device (annotation sync
-- only looks at those).
function API.markAttachmentPresent(key)
    local st=API.openDB():prepare([[UPDATE itemAttachments SET syncedVersion=MAX(1,(SELECT version FROM items WHERE items.itemID=itemAttachments.itemID))
        WHERE syncedVersion<=0 AND itemID IN (SELECT itemID FROM items WHERE key=?)]])
    st:bind(key):step(); st:close()
end
--- A web snapshot, before KOReader opens it.
-- KOReader's engine ends a tag at the first ">" even inside a quoted
-- attribute value, and saved pages are full of those (the inline document of
-- every frame, pictures written as markup): what follows is shown as text, or
-- the rest of the page is not shown at all. The plugin's copy of the page is
-- rewritten so that the engine reads it as a browser does (zotero_html.lua,
-- engineCopy: the tree Zotero builds from it stays the same, which is checked).
-- Never touched: a linked file, a file in Zotero's own storage folder, the
-- document that is open, and a copy that already carries highlights made in
-- KOReader on the page as the engine read it before.
-- @return true when the file was rewritten
function API.prepareSnapshot(path)
    if type(path) ~= "string" or not API.storage_dir or path:sub(1, #API.storage_dir + 1) ~= API.storage_dir .. "/" then return false end
    local size = lfs.attributes(path, "size")
    if not size or size == 0 then return false end
    local ds = DocSettings:open(path)
    local checked = ds:readSetting("zotero_snapshot_checked")
    if checked == size then return false end
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local open_doc = ReaderUI and ReaderUI.instance and ReaderUI.instance.document
    if open_doc and open_doc.file == path then return false end
    local anns = ds:readSetting("annotations")
    if checked == nil and type(anns) == "table" and next(anns) ~= nil then return false end
    local f = io.open(path, "rb"); if not f then return false end
    local src = f:read("*a"); f:close()
    if type(src) ~= "string" then return false end
    local Html = require("zotero_html")
    local copy, n = Html.engineCopy(src)
    local rewritten = false
    if copy then
        local part = path .. ".part"
        local out = io.open(part, "wb")
        if out then
            local wrote = out:write(copy); out:close()
            if wrote and os.rename(part, path) then
                rewritten = true
                size = lfs.attributes(path, "size") or #copy
                logger.info("Zotero: snapshot rewritten for the reading engine:", path, n, "attribute values")
                -- where the page was last read was a place in the page as it was read before
                if ds:has("last_xpointer") then
                    local share = tonumber(ds:readSetting("percent_finished"))
                    ds:delSetting("last_xpointer")
                    if share then ds:saveSetting("last_percent", share) end
                end
            else
                os.remove(part)
                return false
            end
        else
            return false
        end
    elseif n then
        logger.info("Zotero: snapshot left as it is:", path, tostring(n))
    end
    ds:saveSetting("zotero_snapshot_checked", size); ds:flush()
    return rewritten
end
local function prepare_snapshot(path)
    local ok, err = pcall(API.prepareSnapshot, path)
    if not ok then logger.warn("Zotero: snapshot not prepared:", tostring(path), tostring(err)) end
end

function API.downloadAndGetPath(key, download_callback)
    local item=API.getItem(key); if not item then return nil,"Error: the requested file can not be found in the database" end
    if not item.data or item.data.itemType~="attachment" then return nil,"Error: this item is not an attachment" end
    local kind=API.attachmentKind(item.data)
    if not kind then return nil,API.whyNotOpenable(item.data) end
    local local_path=API.resolveAttachmentPath(item)
    if local_path and file_exists(local_path) then
        if kind=="html" then prepare_snapshot(local_path) end
        API.getAttachmentInfo(item,local_path); API.markAttachmentPresent(key)
        return local_path,nil
    end
    if item.data.linkMode=="linked_file" then return nil,"Linked file not found locally" end
    local e=API.verifyZoteroAccess(); if e then return nil,e end
    local dir,path=API.getDirAndPath(item); mkdir_p(dir); if download_callback then download_callback() end
    if API.getWebDAVEnabled() then local p,err=API.downloadWebDAV(key,dir,path); if not p then return nil,err end; path=p
    else
        -- Download next to the target and rename when complete, so that an
        -- interrupted download never leaves a truncated file that looks valid.
        local part=path..".part"
        local f=io.open(part,"wb"); if not f then return nil,"Could not create attachment file" end
        if socketutil then socketutil:set_timeout(30,-1) end
        local ok,r,c=pcall(https.request,{url=API.userLibraryURL.."/items/"..key.."/file",headers=API.zoteroHeader,sink=ltn12.sink.file(f)})
        if socketutil then socketutil:reset_timeout() end
        local err=(not ok) and ("Error: "..tostring(r)) or API.verifyResponse(r,c)
        if err then os.remove(part); return nil,err end
        -- A web snapshot that consists of several files (older snapshots)
        -- is stored by Zotero as a zip of its folder.
        local zipped=false
        if kind=="html" then
            local pf=io.open(part,"rb")
            if pf then zipped=pf:read(4)=="PK\3\4"; pf:close() end
        end
        if zipped then
            local unpacked=extract_zip(part,dir)
            os.remove(part)
            if not unpacked then return nil,"Could not unpack the snapshot" end
            if not file_exists(path) then path=API.findFileByBasename(dir,API.basenameOfPath(path)) or path end
            if not file_exists(path) then return nil,"The snapshot's main file was not found in what Zotero stores for it" end
        else
            os.remove(path)
            if not os.rename(part,path) then os.remove(part); return nil,"Could not store attachment file" end
        end
    end
    if kind=="html" then prepare_snapshot(path) end
    API.getAttachmentInfo(item,path)
    API.setAttachmentVersionByKey(key,math.max(1,tonumber(item.version) or 1)); return path,nil
end
function API.batchDownload(progress_callback)
    progress_callback=progress_callback or function() end; local db=API.openDB(); local st=db:prepare([[SELECT i.key,d.value FROM itemAttachments a JOIN items i ON i.itemID=a.itemID JOIN itemData d ON d.itemID=i.itemID WHERE a.parentItemID IN (SELECT ci.itemID FROM collectionItems ci JOIN collections c ON c.collectionID=ci.collectionID WHERE c.synced=1)]])
    local rows={}; local row=st:reset():step()
    while row do
        -- only what is a file the reader can open: links to web pages are not downloads
        local item=safe_decode(row[2])
        if item and API.attachmentKind(item.data) then table.insert(rows,{row[1],row[2]}) end
        row=st:step(row)
    end
    st:close(); local fails,details=0,{}
    for i,v in ipairs(rows) do
        local item=safe_decode(v[2]); local filename=item and item.data and item.data.filename or v[1]
        if progress_callback(string.format(_("Checking attachment %i/%i"),i,#rows))==false then break end
        local __, err=API.downloadAndGetPath(v[1])
        if err then
            fails=fails+1; table.insert(details,{filename=filename,error=err})
            logger.warn("Zotero: attachment", v[1], tostring(filename), "not downloaded:", tostring(err))
        end
    end
    return fails,details
end

-- ---------------------------------------------------------------------------
-- Writing annotations to Zotero
--
-- Every object carries its own key and version. A new annotation is sent with
-- a key chosen here and version 0, so sending it twice cannot create two; an
-- existing one is sent with the version last seen, so a newer edit made in
-- Zotero is never overwritten (the server answers 412 for that object).
-- The library version is deliberately NOT sent as a precondition, and the
-- local library version is NOT advanced from the answer: both would let
-- changes made elsewhere slip through unseen.
-- ---------------------------------------------------------------------------

local WRITE_FIELDS = {
    "key", "version", "itemType", "parentItem", "annotationType", "annotationText", "annotationComment",
    "annotationColor", "annotationPageLabel", "annotationSortIndex", "annotationPosition",
    "dateAdded", "dateModified",
}

local function encode_object(obj)
    local parts = {}
    for __, k in ipairs(WRITE_FIELDS) do
        local v = obj[k]
        if v ~= nil then
            if type(v) == "number" then
                parts[#parts + 1] = Util.jsonString(k) .. ":" .. string.format("%d", v)
            else
                parts[#parts + 1] = Util.jsonString(k) .. ":" .. Util.jsonString(Util.fixUtf8(tostring(v)))
            end
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
API._encodeObject = encode_object

--- Send up to 50 objects.
-- @return results (results[i] = { ok = item } | { unchanged = true } | { code, message }), or nil, error
function API.writeObjects(objects)
    local e = API.verifyZoteroAccess(); if e then return nil, e end
    if not API.canWrite() then return nil, "this API key may not change the library (read-only key)" end
    if #objects == 0 then return {} end
    if #objects > 50 then return nil, "too many objects in one request" end
    local encoded = {}
    for i, obj in ipairs(objects) do encoded[i] = encode_object(obj) end
    local code, h, raw = API.request{
        method = "POST", url = API.userLibraryURL .. "/items", headers = API.zoteroHeader,
        body = "[" .. table.concat(encoded, ",") .. "]",
    }
    if not code then return nil, "no answer from Zotero (" .. tostring(h) .. ")" end
    if code ~= 200 then
        local detail = type(raw) == "string" and raw ~= "" and (": " .. raw:sub(1, 200)) or ""
        if code == 403 then detail = " (write access denied)" .. detail end
        return nil, "Zotero answered " .. tostring(code) .. detail
    end
    local result = Util.jsonDecode(raw)
    if type(result) ~= "table" then return nil, "unreadable answer from Zotero" end
    local out = {}
    for i = 1, #objects do
        local idx = tostring(i - 1)
        local done = type(result.successful) == "table" and result.successful[idx]
        local same = type(result.unchanged) == "table" and result.unchanged[idx]
        local fail = type(result.failed) == "table" and result.failed[idx]
        if type(done) == "table" and done.key then
            out[i] = { ok = done }
        elseif same then
            out[i] = { unchanged = true }
        elseif type(fail) == "table" then
            out[i] = { code = tonumber(fail.code) or 0, message = fail.message }
        else
            out[i] = { code = 0, message = "no result reported for this object" }
        end
    end
    return out
end

--- Fetch one item. @return item, or nil and the status code (404 = it does not exist)
function API.fetchItem(key)
    local e = API.verifyZoteroAccess(); if e then return nil, e end
    local code, h, raw = API.request{ method = "GET", url = API.userLibraryURL .. "/items/" .. key, headers = API.zoteroHeader }
    if not code then return nil, h end
    if code ~= 200 then return nil, code end
    local item = Util.jsonDecode(raw)
    if type(item) ~= "table" or not item.key then return nil, "unreadable answer" end
    if type(item.data) == "table" and item.data.deleted and item.data.deleted ~= 0 then
        return nil, 404 -- in the trash: as good as gone
    end
    return item
end

--- Delete one item, unless it changed after `version`.
-- @return true, or nil and the status code (412: changed or already gone)
function API.deleteRemoteItem(key, version)
    local e = API.verifyZoteroAccess(); if e then return nil, e end
    if not API.canWrite() then return nil, 403 end
    local headers = copy_table(API.zoteroHeader)
    headers["If-Unmodified-Since-Version"] = string.format("%d", tonumber(version) or 0)
    local code, h = API.request{ method = "DELETE", url = API.userLibraryURL .. "/items/" .. key, headers = headers }
    if not code then return nil, h end
    if code == 204 then return true end
    return nil, code
end

--- Keep an item the server returned (after a write) in the local library.
function API.storeItem(item)
    if type(item) ~= "table" or not item.key or type(item.data) ~= "table" then return end
    item.links = nil; item.library = nil
    upsert_item(item)
    if item.data.itemType == "annotation" and item.data.parentItem then
        API.setAnnotations({ [item.key] = item.data.parentItem })
    end
end

--- The Zotero annotations of an attachment, from the local library.
-- @return { [key] = item } for highlights and underlines, and the number of
--         annotations of other kinds (notes, images, ink, text)
function API.getAttachmentAnnotations(key)
    local st = API.openDB():prepare([[SELECT i.key,d.value FROM itemAnnotations a JOIN items i ON i.itemID=a.itemID JOIN itemData d ON d.itemID=i.itemID WHERE a.parentItemID IN (SELECT itemID FROM items WHERE key=?)]])
    local out, others = {}, 0
    local row = st:reset():bind(key):step()
    while row do
        local item = safe_decode(row[2])
        if item and type(item.data) == "table" and item.key then
            if Annotations.isSupportedZoteroType(item.data.annotationType) then
                out[item.key] = item
            else
                others = others + 1
            end
        end
        row = st:step(row)
    end
    st:close()
    return out, others
end

--- Attachments whose file is on this device: { { key =, item = }, ... }
function API.getLocalAttachments()
    local st = API.openDB():prepare([[SELECT i.key,d.value FROM itemAttachments a JOIN items i ON i.itemID=a.itemID JOIN itemData d ON d.itemID=i.itemID WHERE a.syncedVersion>0]])
    local out = {}
    local row = st:reset():step()
    while row do
        local item = safe_decode(row[2])
        if item and item.data then out[#out + 1] = { key = row[1], item = item } end
        row = st:step(row)
    end
    st:close()
    return out
end

--- Record a finished annotation sync of an attachment.
function API.touchAttachmentSync(key)
    local q=API.openDB():prepare("UPDATE itemAttachments SET lastSync=unixepoch('now') WHERE itemID IN (SELECT itemID FROM items WHERE key=?)")
    q:bind(key):step(); q:close()
end

--- Note in the document's sidecar which attachment it is, and the title and
-- authors Zotero has for it. Only for a file that is this attachment's beyond
-- doubt, and only written when something actually changed.
function API.getAttachmentInfo(item, targetPath)
    if not item or not item.data or not targetPath then return end
    if API.findAttachmentKeyByFilePath(targetPath,item.key)~=item.key then return end
    local parent=item.data.parentItem and API.getItem(item.data.parentItem) or nil; local data=parent and parent.data or item.data
    local ds=DocSettings:open(targetPath)
    local authors={}; for __,v in ipairs(data.creators or {}) do local name=v.name or ((v.firstName or "").." "..(v.lastName or "")):gsub("^%s+",""):gsub("%s+$",""); if name~="" then table.insert(authors,name) end end
    local tags={}; for __,v in ipairs(data.tags or {}) do if v.tag then table.insert(tags,v.tag) end end
    local props={title=data.title,authors=table.concat(authors,", "),description=data.abstractNote,series=data.series,keywords=table.concat(tags,", "),language=data.language}
    local version=tonumber(item.version) or 0
    local old=ds:readSetting("doc_props")
    local same=type(old)=="table" and ds:readSetting("zotero_attachment_key")==item.key
        and (tonumber(ds:readSetting("zoteroItemVersion")) or -1)==version
    if same then
        for k,v in pairs(props) do if old[k]~=v then same=false; break end end
    end
    if same then return end
    if type(old)=="table" then
        -- keep what the reader itself recorded about the document (page count, …)
        for k,v in pairs(old) do if props[k]==nil then props[k]=v end end
    end
    ds:saveSetting("doc_props",props)
    ds:saveSetting("zoteroItemVersion",version); ds:saveSetting("zoteroLibVersion",API.getUserLibraryVersion())
    ds:saveSetting("zotero_attachment_key",item.key); ds:flush()
end

function API.scanStorageDir(storage_dir, use_external_paths)
    if not storage_dir or storage_dir=="" or not file_exists(storage_dir) then return 0,{} end
    local found,extra=0,{}
    for name in lfs.dir(storage_dir) do if name~="." and name~=".." then local dir=BaseUtil.joinPath(storage_dir,name); if lfs.attributes(dir,"mode")=="directory" then local __, __, version, id=API.getAttachmentVersion(name); if id then local item=API.getItem(name); local path; if use_external_paths and item and item.data and item.data.filename then path=BaseUtil.joinPath(dir,item.data.filename) elseif item then local __, p=API.getDirAndPath(item); path=p end; if path and file_exists(path) then found=found+1; API.setAttachmentVersion(id,version or 1) end else table.insert(extra,name) end end end end
    return found,extra
end
function API.scanStorage()
    local a=select(1,API.scanStorageDir(API.storage_dir,false)); local b=0; if API.getExternalStorageEnabled() then b=select(1,API.scanStorageDir(API.getExternalStorageDir(),true)) end; return (a or 0)+(b or 0)
end

function API.searchAnnotations(query)
    query=string.lower(query or ""); local db=API.openDB(); local out={}; local st=db:prepare([[SELECT ai.key,ad.value,att.key,pd.value FROM itemAnnotations ia JOIN items ai ON ai.itemID=ia.itemID JOIN itemData ad ON ad.itemID=ai.itemID JOIN items att ON att.itemID=ia.parentItemID JOIN itemAttachments a ON a.itemID=att.itemID LEFT JOIN items parent ON parent.itemID=a.parentItemID LEFT JOIN itemData pd ON pd.itemID=parent.itemID]])
    local row=st:reset():step(); while row do local ann=safe_decode(row[2]); local parent=safe_decode(row[4]); local d=ann and ann.data or {}; local title=parent and parent.data and parent.data.title or ""; local text=d.annotationText or ""; local comment=d.annotationComment or ""; local hay=string.lower(text.." "..comment.." "..title); if (text~="" or comment~="") and (query=="" or hay:find(query,1,true)) then local page=""; local pos=safe_decode(d.annotationPosition); if pos and pos.pageIndex~=nil then page=tostring(pos.pageIndex+1) elseif d.annotationPageLabel then page=tostring(d.annotationPageLabel) end; table.insert(out,{key=row[1],attachmentKey=row[3],parentTitle=title,text=text,comment=comment,page=page,color=d.annotationColor,type=d.annotationType}) end; row=st:step(row) end; st:close(); return out
end

--- Download what changed in the Zotero library since the last sync.
-- @return nil on success, or an error message
function API.pull(progress_callback)
    local callback=progress_callback or function() end
    local e=API.verifyZoteroAccess(); if e then return e end
    local since=API.getUserLibraryVersion()
    logger.info("Zotero: syncing from library version", since)
    logger.info("Zotero: sync stage: collections")
    callback("Synchronizing collections…")
    local cv,err=API.fetchZoteroCollections(since,callback); if err then return type(err)=="string" and err or ("Error during collection sync: "..readable_value(err)) end
    logger.info("Zotero: sync stage: items")
    callback("Synchronizing items…")
    local iv; iv,err=API.fetchZoteroItems(since,callback); if err then return type(err)=="string" and err or ("Error during item sync: "..readable_value(err)) end
    -- The version this copy is complete for is the LOWEST the server
    -- reported during these requests: anything changed in between is then
    -- simply fetched again next time.
    local version=math.min(tonumber(cv) or since,tonumber(iv) or since)
    if version<since then version=since end
    API.setUserLibraryVersion(version)
    if since==0 then pcall(API.scanStorage) end
    logger.info("Zotero: library is at version", API.getUserLibraryVersion())
    -- reading positions; a failure here does not undo the library download
    local settings=API.getSettings()
    if not settings or settings:readSetting("sync_reading_position")~=false then
        local sok,serr=pcall(API.fetchSettings)
        if not sok then logger.warn("Zotero: reading positions not downloaded:", tostring(serr)) end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Reading positions (Zotero's synced setting "lastPageIndex_u_<attachment>")
-- ---------------------------------------------------------------------------

--- Download the reading positions that changed since the last time.
-- @return number of positions stored, or nil and an error
function API.fetchSettings()
    local e=API.verifyZoteroAccess(); if e then return nil,e end
    local db=API.openDB()
    local since=tonumber(db:rowexec("SELECT version FROM syncSettings WHERE name='#version'")) or 0
    local result,h=API.getZoteroData(API.userLibraryURL.."/settings?since="..string.format("%d",since))
    if type(result)~="table" then
        logger.warn("Zotero: reading positions not downloaded:", tostring(h))
        return nil,h
    end
    local n=0
    db:exec("BEGIN")
    local ok,err=pcall(function()
        local st=db:prepare("INSERT INTO syncSettings(name,value,version) VALUES(?,?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value,version=excluded.version")
        for name,entry in pairs(result) do
            if type(name)=="string" and name:match("^lastPageIndex_u_[A-Z0-9]+$") and type(entry)=="table" then
                local t=type(entry.value)
                if t=="number" or t=="string" then
                    -- kept with its type: a number is a page index, a string an EPUB position
                    st:reset():bind(name,(t=="number" and "n" or "s")..tostring(entry.value),tonumber(entry.version) or 0):step()
                    n=n+1
                end
            end
        end
        local v=tonumber(type(h)=="table" and h["last-modified-version"])
        if v then st:reset():bind("#version","",v):step() end
        st:close()
    end)
    db:exec(ok and "COMMIT" or "ROLLBACK")
    if not ok then return nil,tostring(err) end
    if n>0 then logger.info("Zotero: reading positions updated:", n) end
    return n
end

--- Where Zotero last read this attachment.
-- @return value (page index or EPUB position) and its version, or nil
function API.getRemotePosition(key)
    local st=API.openDB():prepare("SELECT value,version FROM syncSettings WHERE name=?")
    local row=st:bind("lastPageIndex_u_"..tostring(key)):step()
    local raw,version=row and row[1],row and tonumber(row[2]) or 0
    st:close()
    if type(raw)~="string" or raw=="" then return nil end
    local kind,rest=raw:sub(1,1),raw:sub(2)
    if kind=="n" then
        local num=tonumber(rest); if not num then return nil end
        return num,version
    end
    return rest,version
end

--- Tell Zotero where this attachment was last read.
-- @param value page index (integer) or EPUB position (string)
-- @param version the version of Zotero's value this replaces (0: there is none)
-- @return the new version, or nil and the status code (412: Zotero's value changed meanwhile)
function API.putRemotePosition(key,value,version)
    local e=API.verifyZoteroAccess(); if e then return nil,e end
    if not API.canWrite() then return nil,403 end
    if not Util.isValidKey(key) then return nil,"invalid key" end
    local body
    if type(value)=="number" then
        -- an integer, written as one: a decimal would mean a scroll percentage
        body=string.format('{"value":%d,"version":%d}',value,tonumber(version) or 0)
    elseif type(value)=="string" and value~="" then
        body='{"value":'..Util.jsonString(Util.fixUtf8(value))..string.format(',"version":%d}',tonumber(version) or 0)
    else
        return nil,"invalid value"
    end
    local name="lastPageIndex_u_"..key
    local code,h=API.request{ method="PUT", url=API.userLibraryURL.."/settings/"..name, headers=API.zoteroHeader, body=body }
    if not code then return nil,h end
    if code~=204 and code~=200 then return nil,code end
    local new_version=tonumber(type(h)=="table" and h["last-modified-version"]) or tonumber(version) or 0
    local st=API.openDB():prepare("INSERT INTO syncSettings(name,value,version) VALUES(?,?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value,version=excluded.version")
    st:bind(name,(type(value)=="number" and "n" or "s")..tostring(value),new_version):step(); st:close()
    return new_version
end

--- Full sync: library first, then annotations (which need the fresh library
-- state to merge against), then offline attachments.
-- @param opts.annotations function(progress) -> summary lines, problem lines
-- @return an error message when the sync could not be carried out (nil
--         otherwise), and the lines to show the user (what was done; what
--         needs attention)
function API.syncAllItems(progress_callback, opts)
    opts = opts or {}
    -- a progress callback that returns false asks for the sync to stop; it is
    -- honoured between two complete pieces of work, never in the middle of one
    local stopped=false
    local function callback(msg)
        if stopped then return false end
        if progress_callback and progress_callback(msg)==false then stopped=true; return false end
        return true
    end
    local function stage(msg)
        logger.info("Zotero: sync stage:", msg)
        return callback(msg)
    end
    local lines = {}

    stage("Checking Zotero access…")
    local e=API.verifyZoteroAccess(); if e then return type(e)=="string" and e or readable_value(e) end

    e=API.pull(callback); if e then return e end
    if stopped then return API.CANCELLED end

    if opts.annotations then
        stage("Synchronizing annotations…")
        local ok,done,problems=pcall(opts.annotations,callback)
        if not ok then
            logger.err("Zotero: annotation sync failed:", tostring(done))
            table.insert(lines,"Annotation sync failed: "..tostring(done))
        else
            for __,l in ipairs(type(done)=="table" and done or {}) do table.insert(lines,l) end
            for __,l in ipairs(type(problems)=="table" and problems or {}) do table.insert(lines,l) end
        end
    end

    if stopped then return API.CANCELLED, lines end

    stage("Checking offline attachments…")
    local df=API.batchDownload(callback); if df>0 then table.insert(lines,"Attachment download errors: "..df) end
    if stopped then return API.CANCELLED, lines end
    logger.info("Zotero: sync completed; library version", API.getUserLibraryVersion())
    return nil, lines
end

return API
