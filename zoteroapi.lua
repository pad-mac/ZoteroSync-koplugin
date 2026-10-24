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
local Bg = require("zotero_bg")
local Dav = require("zotero_webdav")

local API = { version = "Zotero Atelier 2.0 fork v0.13 (2026-10-24)", fork = "0.6" }
-- what a sync that the user stopped reports
API.CANCELLED = "Sync stopped."
local ZOTERO_BASE_URL = "https://api.zotero.org"
local DB_VERSION = 3
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

local http_plain = require("socket.http")
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
        API.db:exec("PRAGMA user_version=2")
        API.needs_storage_scan = true
        API.libVersion = nil
        version = 2
    end
    if version < 3 then
        -- group libraries: a row in libraries each, with the group's ID
        if not API.db:rowexec("SELECT 1 FROM pragma_table_info('libraries') WHERE name='groupID'") then
            API.db:exec("ALTER TABLE libraries ADD COLUMN groupID INT NOT NULL DEFAULT 0;")
        end
        API.db:exec("CREATE INDEX IF NOT EXISTS idx_items_library ON items(libraryID);")
        API.db:exec("PRAGMA user_version=" .. tostring(DB_VERSION))
    end
    -- What this device knows about each attachment beyond the library itself
    -- (zoteroapi: attachment state): when its file's details were last noted
    -- in the document, the state of both sides after the last complete
    -- annotation sync (a document neither side changed since is skipped), a
    -- download that failed because the server has no file.
    API.db:exec("CREATE TABLE IF NOT EXISTS attachmentState (key TEXT PRIMARY KEY, info TEXT, annLocal TEXT, annRemote TEXT, failVersion INT NOT NULL DEFAULT 0, failCode INT NOT NULL DEFAULT 0, failAt INT NOT NULL DEFAULT 0);")
    return API.db
end

function API.closeDB()
    if API.db then API.db:close() end
    API.db = nil
    API.libVersion = nil
    API.forgetLibraries()
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
        groups = tonumber(db:rowexec("SELECT COUNT(*) FROM libraries WHERE type='group'")) or 0,
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
    API.forgetLibraries()
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
--- The folders searched for a file by its name: those the user configured
-- (linked file folders, search folders). The storage folders are not among
-- them: a file there sits in its attachment's own folder, where it is found
-- without a search.
function API.nameSearchRoots()
    local out = {}
    local function add(v) if v and v ~= "" then table.insert(out, v) end end
    for __, v in ipairs(API.getLinkedFilesBases()) do add(v) end
    for __, v in ipairs(API.getSearchRoots()) do add(v) end
    return out
end

-- While a sync looks for many files, each folder is walked once: file name
-- (lower case) -> paths, in the order a search would meet them.
local file_index, file_index_depth = nil, 0
function API.beginFileIndex()
    file_index_depth = file_index_depth + 1
    if file_index_depth == 1 then file_index = {} end
end
function API.endFileIndex()
    file_index_depth = math.max(0, file_index_depth - 1)
    if file_index_depth == 0 then file_index = nil end
end
local function index_folder(root)
    local idx = {}
    local function walk(dir, depth)
        if depth > 8 then return end
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, state do
            if name ~= "." and name ~= ".." then
                local p = BaseUtil.joinPath(dir, name)
                local mode = lfs.attributes(p, "mode")
                if mode == "file" then
                    local k = string.lower(name)
                    idx[k] = idx[k] or {}
                    table.insert(idx[k], API.normalizePath(p))
                elseif mode == "directory" then
                    walk(p, depth + 1)
                end
            end
        end
    end
    if file_exists(root) then walk(root, 0) end
    return idx
end

function API.findAttachmentByBasename(name, for_key)
    local base = API.basenameOfPath(name) or name
    local reject
    if for_key then
        reject = function(path)
            local owner = key_by_folder(API.normalizePathForCompare(path) or API.normalizePath(path))
            return owner ~= nil and owner ~= for_key
        end
    end
    for __, root in ipairs(API.nameSearchRoots()) do
        if file_index then
            file_index[root] = file_index[root] or index_folder(root)
            for __, p in ipairs(file_index[root][string.lower(base)] or {}) do
                if not (reject and reject(p)) and file_exists(p) then return p end
            end
        else
            local f = API.findFileByBasename(root, base, 0, reject); if f then return f end
        end
    end
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

--- One HTTP exchange, as plain data in and out: it runs here, or in a child
-- process while a background job waits for it (zotero_bg.lua).
-- spec = { method, url, headers, body (string),
--          file = path the body is written to (else it is returned),
--          redirect = false (a redirect is returned, not followed),
--          block_timeout, total_timeout (seconds; -1: none) }
-- @return { code =, headers = (lower-case names), body = }  or  { err = }
function API.exchange(spec)
    local headers = copy_table(spec.headers)
    local req = { method = spec.method or "GET", url = spec.url, headers = headers }
    if spec.redirect == false then req.redirect = false end
    if spec.body then
        headers["content-type"] = headers["content-type"] or "application/json"
        headers["content-length"] = tostring(#spec.body)
        req.source = ltn12.source.string(spec.body)
    end
    if socketutil then socketutil:set_timeout(spec.block_timeout or 20, spec.total_timeout or 180) end
    local chunks, f = {}, nil
    if spec.file then
        f = io.open(spec.file, "wb")
        if not f then
            if socketutil then socketutil:reset_timeout() end
            return { err = "could not create " .. tostring(spec.file) }
        end
        req.sink = socketutil and socketutil.file_sink(f) or ltn12.sink.file(f)
    else
        req.sink = socketutil and socketutil.table_sink(chunks) or ltn12.sink.table(chunks)
    end
    -- (a WebDAV server may well be reached without TLS)
    local module = tostring(spec.url):lower():match("^http://") and http_plain or https
    local ok, r, c, h = pcall(module.request, req)
    if socketutil then socketutil:reset_timeout() end
    if f then pcall(f.close, f) end -- (the sink closes it when the body is complete)
    if not ok then return { err = tostring(r) } end
    if r ~= 1 then return { err = tostring(c) } end
    local out = { code = tonumber(c) or 0, headers = {} }
    for k, v in pairs(h or {}) do out.headers[string.lower(tostring(k))] = tostring(v) end
    if not spec.file then out.body = table.concat(chunks) end
    return out
end

local function wait_backoff()
    if API.backoff_until then
        local wait = API.backoff_until - os.time()
        API.backoff_until = nil
        if wait > 0 then Bg.sleep(math.min(wait, 20)) end
    end
end

local function note_backoff(res)
    local b = res.headers and tonumber(res.headers["backoff"])
    if b then
        -- the server asks clients to slow down
        API.backoff_until = os.time() + math.min(b, 20)
    end
end

--- Several requests, up to `limit` at once (in a background job; one after
-- the other otherwise). A request the server refuses for being busy (429,
-- 503) is repeated, up to twice.
-- @return the answers, as API.exchange gives them, in order
function API.requestMany(specs, limit)
    wait_backoff()
    local tasks = {}
    for i, spec in ipairs(specs) do tasks[i] = { fn = API.exchange, args = { spec, n = 1 }, poll = spec.poll } end
    local results = Bg.run(tasks, limit or 4)
    for i, res in ipairs(results) do
        local tries = 1
        note_backoff(res)
        while (res.code == 429 or res.code == 503) and tries < 3 do
            tries = tries + 1
            Bg.sleep(math.max(0, math.min(tonumber(res.headers and res.headers["retry-after"]) or 5, 20)))
            if Bg.stopped() then break end
            res = Bg.call(API.exchange, specs[i])
            note_backoff(res)
        end
        results[i] = res
    end
    return results
end

--- One request to the Zotero API.
-- opts = { method, url, headers, body (string) }
-- @return status code, response headers (lower-case names), response body
--         or nil, error message when the request did not get an answer
function API.request(opts)
    local res = API.requestMany({ opts }, 1)[1]
    if res.err then return nil, res.err end
    return res.code, res.headers or {}, res.body
end

--- An answer as JSON. @return decoded value, response headers  or  nil, error, status code
local function decode_answer(res, url)
    if res.err then
        logger.warn("Zotero: request failed", url, res.err)
        return nil, "Error: " .. tostring(res.err)
    end
    local code = res.code or 0
    if code < 200 or code >= 300 then
        local e = "Error: API responded with status code " .. tostring(code)
        if code == 403 then e = e .. " (access denied: check the API key and its permissions)" end
        logger.warn("Zotero: GET failed", url, e)
        return nil, e, code
    end
    local result, decode_err = Util.jsonDecode(res.body)
    if result == nil then
        local msg = "Error: Zotero returned an empty or undecodable JSON response: " .. tostring(decode_err)
        logger.warn("Zotero:", msg, "URL:", url, "body:", tostring(res.body):sub(1, 300))
        return nil, msg
    end
    return result, res.headers or {}
end

--- GET a JSON document. @return decoded value, response headers  or  nil, error
function API.getZoteroData(url)
    if not API.zoteroHeader then return nil,"Error: Zotero header not set. Check user ID and API key" end
    local res = API.requestMany({ { method = "GET", url = url, headers = API.zoteroHeader } }, 1)[1]
    return decode_answer(res, url)
end

--- GET several JSON documents, up to four at once.
-- @return { { value =, headers = } | { err =, code = } ... }
function API.getMany(urls)
    if not API.zoteroHeader then
        local out = {}
        for i = 1, #urls do out[i] = { err = "Error: Zotero header not set. Check user ID and API key" } end
        return out
    end
    local specs = {}
    for i, url in ipairs(urls) do specs[i] = { method = "GET", url = url, headers = API.zoteroHeader } end
    local out = {}
    for i, res in ipairs(API.requestMany(specs, 4)) do
        local value, h, code = decode_answer(res, urls[i])
        if value == nil then out[i] = { err = h, code = code } else out[i] = { value = value, headers = h } end
    end
    return out
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
-- ---------------------------------------------------------------------------
-- Libraries: the user's own (libraryID 1, root collection "/") and the group
-- libraries the API key can read (root collection "/g<groupID>"). Item and
-- collection keys are drawn at random from 32^8: the same key in two
-- libraries does not happen, so objects are looked up by key alone.
-- ---------------------------------------------------------------------------

local libs_by_id
function API.forgetLibraries() libs_by_id = nil end
local function load_libraries()
    libs_by_id = {}
    local st = API.openDB():prepare("SELECT libraryID,type,groupID,name,version,editable FROM libraries ORDER BY libraryID")
    local row = st:step()
    while row do
        local lid, gid = tonumber(row[1]), tonumber(row[3]) or 0
        local lib = { id = lid, type = row[2], groupID = gid, name = row[4] or "", version = tonumber(row[5]) or 0,
            editable = (tonumber(row[6]) or 0) ~= 0 }
        if lib.type == "group" and gid > 0 then
            lib.root = "/g" .. gid
            lib.prefix = "/groups/" .. gid
            lib.setting_prefix = "lastPageIndex_g" .. gid .. "_"
        else
            lib.root = "/"
            lib.setting_prefix = "lastPageIndex_u_"
        end
        libs_by_id[lid] = lib
        row = st:step(row)
    end
    st:close()
end
--- A library by its ID (1: the user's own).
function API.library(lid)
    if not libs_by_id then load_libraries() end
    return libs_by_id[tonumber(lid) or 1] or libs_by_id[1]
end
--- All libraries: the user's own first, then the groups by name.
function API.libraries()
    if not libs_by_id then load_libraries() end
    local out = {}
    for _, lib in pairs(libs_by_id) do out[#out + 1] = lib end
    table.sort(out, function(a, b)
        if (a.type == "group") ~= (b.type == "group") then return a.type ~= "group" end
        if a.type ~= "group" then return a.id < b.id end
        local na, nb = string.lower(a.name), string.lower(b.name)
        if na ~= nb then return na < nb end
        return a.id < b.id
    end)
    return out
end
function API.groupLibraries()
    local out = {}
    for _, lib in ipairs(API.libraries()) do if lib.type == "group" then out[#out + 1] = lib end end
    return out
end
--- The library of a group, or nil.
function API.groupLibrary(gid)
    for _, lib in ipairs(API.groupLibraries()) do if lib.groupID == tonumber(gid) then return lib end end
    return nil
end
--- The address of a library in the web API.
function API.libraryURL(lib)
    lib = lib or API.library(1)
    if lib.prefix then return ZOTERO_BASE_URL .. lib.prefix end
    return API.userLibraryURL or (ZOTERO_BASE_URL .. "/users/" .. tostring(API.getUserID()))
end
--- The library an item (or collection) belongs to; the user's own if it is
-- not known here.
function API.libraryOfKey(key)
    local db = API.openDB()
    local st = db:prepare("SELECT libraryID FROM items WHERE key=? UNION ALL SELECT libraryID FROM collections WHERE key=? LIMIT 1")
    local row = st:bind(key, key):step()
    local lid = row and tonumber(row[1]) or 1
    st:close()
    return API.library(lid)
end
local function set_library_version(lib, v)
    local st = API.openDB():prepare("UPDATE libraries SET version=?,lastSync=unixepoch('now') WHERE libraryID=?")
    st:bind(tonumber(v) or 0, lib.id):step(); st:close()
    lib.version = tonumber(v) or 0
    if lib.id == 1 then API.libVersion = lib.version end
end

--- May this API key change the library (the user's own, if none is named)?
-- @param lib a library, or an item key
function API.canWrite(lib)
    local a = API.access
    if type(a) ~= "table" then return false end
    if type(lib) == "string" then lib = API.libraryOfKey(lib) end
    if not lib or lib.type ~= "group" then
        return type(a.user) == "table" and a.user.write == true
    end
    local g = type(a.groups) == "table" and (a.groups[tostring(lib.groupID)] or a.groups.all) or nil
    return type(g) == "table" and g.write == true and lib.editable
end
--- May this API key read group libraries at all?
local function group_access()
    local a = API.access
    return type(a) == "table" and type(a.groups) == "table" and next(a.groups) ~= nil
end
local function may_read_group(gid)
    local g = API.access.groups[tostring(gid)] or API.access.groups.all
    return type(g) == "table" and g.library ~= false
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
local warned_collision = {}
--- Store an item as the server sent it.
-- @param lid its library (default: the library it is stored in already, else
--        the library of its parent, else the user's)
-- @return false if it was not stored (its key belongs to another library here)
local function upsert_item(item, lid)
    if not item or not item.key or not item.data then return false end
    local db=API.openDB(); local tid=type_id(item.data.itemType) or type_id("document") or 13
    local here=tonumber(db:rowexec("SELECT libraryID FROM items WHERE key='"..tostring(item.key):gsub("'","''").."' LIMIT 1"))
    if lid==nil then
        lid=here
        if not lid and type(item.data.parentItem)=="string" then lid=API.libraryOfKey(item.data.parentItem).id end
        lid=lid or 1
    elseif here and here~=lid then
        -- (32^8 possible keys: this does not happen, but if it did, the two
        -- items must not be mixed up)
        if not warned_collision[item.key] then
            warned_collision[item.key]=true
            logger.warn("Zotero: item key", item.key, "exists in two libraries; the one in library", lid, "is left out")
        end
        return false
    end
    local stmt=db:prepare([[INSERT INTO items(itemTypeID,libraryID,key,version) VALUES(?,?,?,?) ON CONFLICT(libraryID,key) DO UPDATE SET itemTypeID=excluded.itemTypeID,version=excluded.version]])
    stmt:bind(tid,lid,item.key,tonumber(item.version) or 0):step(); stmt:close()
    stmt=db:prepare([[INSERT INTO itemData(itemID,value) SELECT itemID,? FROM items WHERE key=? ON CONFLICT(itemID) DO UPDATE SET value=excluded.value]])
    stmt:bind(JSON.encode(item),item.key):step(); stmt:close()
    -- it exists (again): no longer "deleted on the server"
    stmt=db:prepare("DELETE FROM syncDeleted WHERE key=?"); stmt:bind(item.key):step(); stmt:close()
    if (tonumber(db:rowexec("SELECT changes()")) or 0) > 0 then
        -- it had been reported deleted (moved to the trash) and is back: its
        -- children did not come with it, see relink_orphans
        API.restored_seen = true
    end
    return true
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

-- ---------------------------------------------------------------------------
-- Downloading what changed
--
-- One round of requests, all at once: for every library the versions of the
-- items changed since its last sync (a library nothing happened to answers
-- with its old version: done), the list of groups, the reading positions.
-- Then, for the libraries that changed, what changed in their collections and
-- what was deleted; then the changed objects themselves, 50 per request, four
-- requests at a time. A library's version only moves forward when all of its
-- requests succeeded, to the lowest version any of them reported: whatever
-- changed meanwhile is fetched again next time.
-- ---------------------------------------------------------------------------

local BATCH = 50 -- objects per request: the most the API takes by key

local function lmv(headers)
    return tonumber(type(headers) == "table" and headers["last-modified-version"])
end
local function count_keys(t)
    local n = 0
    for __ in pairs(t) do n = n + 1 end
    return n
end
--- Is a version list the whole answer? (it is not paged; the header says how
-- many there are)
local function complete(map, headers)
    if type(map) ~= "table" then return false end
    local total = tonumber(type(headers) == "table" and headers["total-results"])
    return total == nil or total == count_keys(map)
end

local function new_ctx(lib)
    return { lib = lib, seen = {}, attachments = {}, annotations = {}, nested = {}, lowest = nil }
end
local function seen_version(ctx, v)
    v = tonumber(v)
    if v and (not ctx.lowest or v < ctx.lowest) then ctx.lowest = v end
end

--- Store collections of a library as the server sent them.
local function store_collections(ctx, entries)
    local lib, db = ctx.lib, API.openDB()
    db:exec("BEGIN")
    local ok, err = pcall(function()
        local del = db:prepare("DELETE FROM collections WHERE key=? AND libraryID=?")
        local ins = db:prepare([[INSERT INTO collections(collectionName,parentCollectionID,libraryID,key,version) SELECT ?,collectionID,?,?,? FROM collections WHERE key=? ON CONFLICT(libraryID,key) DO UPDATE SET collectionName=excluded.collectionName,version=excluded.version,parentCollectionID=excluded.parentCollectionID]])
        for __, entry in ipairs(entries) do
            local c = entry.data or entry
            local key = c.key or entry.key
            if key and c.deleted then
                del:reset():bind(key, lib.id):step()
            elseif key then
                local parent = c.parentCollection
                if type(parent) ~= "string" or parent == "" then parent = lib.root end
                if parent ~= lib.root then ctx.nested[key] = parent; parent = lib.root end
                ins:reset():bind(c.name or "", lib.id, key, tonumber(c.version or entry.version) or 0, parent):step()
            end
        end
        del:close(); ins:close()
    end)
    db:exec(ok and "COMMIT" or "ROLLBACK")
    if not ok then return tostring(err) end
    return nil
end

--- Place nested collections under their parents (whatever order they came in).
local function place_collections(ctx)
    if next(ctx.nested) == nil then return end
    local st = API.openDB():prepare("UPDATE collections SET parentCollectionID=(SELECT collectionID FROM collections WHERE key=?) WHERE key=? AND EXISTS(SELECT 1 FROM collections WHERE key=?)")
    for child, parent in pairs(ctx.nested) do st:reset():bind(parent, child, parent):step() end
    st:close()
end

--- Store a batch of items as the server sent them. One transaction per
-- batch: far fewer disk syncs. @return nil, or an error message
local function store_items(ctx, entries)
    local lib, db = ctx.lib, API.openDB()
    db:exec("BEGIN")
    local done, perr = pcall(function()
        local del = db:prepare("DELETE FROM collectionItems WHERE itemID=(SELECT itemID FROM items WHERE key=?)")
        local ins = db:prepare([[INSERT OR IGNORE INTO collectionItems(collectionID,itemID) SELECT collections.collectionID,items.itemID FROM collections,items WHERE collections.key=? AND items.key=?]])
        for __, item in ipairs(entries) do
            if type(item) == "table" and item.key then
                local d = item.data
                if type(d) == "table" and d.deleted and d.deleted ~= 0 then
                    delete_item(item.key, true, item)
                elseif type(d) == "table" then
                    ctx.seen[item.key] = true
                    local enclosure = type(item.links) == "table" and item.links.enclosure
                    local length = type(enclosure) == "table" and tonumber(enclosure.length) or nil
                    item.links = nil; item.library = nil
                    if length then item.fileLength = length end
                    if upsert_item(item, lib.id) then
                        -- this item's place in the index; only what changed is touched
                        del:reset():bind(item.key):step()
                        local cols = type(d.collections) == "table" and d.collections or {}
                        if #cols == 0 then
                            ins:reset():bind(lib.root, item.key):step()
                        else
                            for __, c in ipairs(cols) do ins:reset():bind(c, item.key):step() end
                        end
                        if d.itemType == "attachment" and (table_contains(SUPPORTED_MEDIA_TYPES, d.contentType) or API.attachmentKind(d)) then
                            ctx.attachments[item.key] = d.parentItem or item.key
                        elseif d.itemType == "annotation" and d.parentItem then
                            ctx.annotations[item.key] = d.parentItem
                        end
                    end
                end
            end
        end
        del:close(); ins:close()
    end)
    db:exec(done and "COMMIT" or "ROLLBACK")
    if not done then return tostring(perr) end
    return nil
end

--- After all of a library's objects are in: deletions, the index.
-- @param gone keys of items the server does not have at all (a complete
--        comparison found them), or nil
local function finish_library(ctx, deleted, trashed, gone)
    local lib, db = ctx.lib, API.openDB()
    db:exec("BEGIN")
    local done, ierr = pcall(function()
        -- (an item this download listed as existing is not deleted on the
        -- word of the delete log read alongside)
        for __, key in ipairs(type(deleted) == "table" and deleted.items or {}) do
            if not ctx.seen[key] then delete_item(key, true) end
        end
        for __, key in ipairs(trashed or {}) do if not ctx.seen[key] then delete_item(key, true) end end
        for __, key in ipairs(gone or {}) do if not ctx.seen[key] then delete_item(key, true) end end
        local st = db:prepare("DELETE FROM collections WHERE key=? AND libraryID=?")
        for __, key in ipairs(type(deleted) == "table" and deleted.collections or {}) do st:reset():bind(key, lib.id):step() end
        st:close()
        place_collections(ctx)
        -- parents exist now, whatever order the batches came in
        API.setItemAttachments(ctx.attachments)
        API.setAnnotations(ctx.annotations)
        -- after a comparison: also index what an earlier version left out
        if API.restored_seen or ctx.compared then relink_orphans() end
        db:exec("DELETE FROM syncDeleted WHERE at < unixepoch('now') - 34560000") -- older than 400 days
    end)
    db:exec(done and "COMMIT" or "ROLLBACK")
    if not done then return "Error: could not update the local index: " .. tostring(ierr) end
    return nil
end

--- The versions of a library's items stored here: { key = version }
local function local_versions(lib, what)
    local out = {}
    local st = API.openDB():prepare(what == "collections"
        and "SELECT key,version FROM collections WHERE libraryID=? AND key NOT LIKE '/%'"
        or "SELECT key,version FROM items WHERE libraryID=?")
    local row = st:bind(lib.id):step()
    while row do out[row[1]] = tonumber(row[2]) or 0; row = st:step(row) end
    st:close()
    return out
end

-- ---------------------------------------------------------------------------
-- Group libraries
-- ---------------------------------------------------------------------------

--- Sync group libraries at all? (setting; and the key must allow it)
function API.groupsWanted()
    if API.settings and API.settings:readSetting("sync_groups") == false then return false end
    return group_access()
end
--- Groups left out by the user: { ["<groupID>"] = true }
function API.skippedGroups()
    local t = API.settings and API.settings:readSetting("groups_skipped")
    return type(t) == "table" and t or {}
end
function API.setGroupSkipped(gid, skip)
    local t = API.skippedGroups()
    t[tostring(gid)] = skip and true or nil
    API.settings:saveSetting("groups_skipped", t)
end
--- Groups the key can read, as last listed: { { id =, name = } } by name
function API.knownGroups()
    local names = API.settings and API.settings:readSetting("group_names")
    local out = {}
    for gid, name in pairs(type(names) == "table" and names or {}) do out[#out + 1] = { id = tonumber(gid), name = tostring(name) } end
    table.sort(out, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return out
end

local function remove_library(lib)
    local db = API.openDB()
    db:exec("BEGIN")
    local ok, err = pcall(function()
        local st = db:prepare("DELETE FROM collections WHERE libraryID=?"); st:bind(lib.id):step(); st:close()
        st = db:prepare("DELETE FROM items WHERE libraryID=?"); st:bind(lib.id):step(); st:close()
        st = db:prepare("DELETE FROM libraries WHERE libraryID=?"); st:bind(lib.id):step(); st:close()
    end)
    db:exec(ok and "COMMIT" or "ROLLBACK")
    API.forgetLibraries()
    if ok then logger.info("Zotero: group library", lib.groupID, lib.name, "removed from this device") end
    return ok, err
end
API._removeLibrary = remove_library

--- A group's details as the API sends them (GET /groups/<id>) into its library.
-- @return the library (created if new)
local function store_group(gid, info)
    local d = type(info) == "table" and (info.data or info) or {}
    local db = API.openDB()
    local uid = tonumber(API.getUserID()) or 0
    local editable = true
    if d.libraryEditing == "admins" then
        editable = tonumber(d.owner) == uid
        for __, a in ipairs(type(d.admins) == "table" and d.admins or {}) do if tonumber(a) == uid then editable = true end end
    end
    local name = type(d.name) == "string" and d.name ~= "" and d.name or ("Group " .. gid)
    local version = tonumber(info and info.version or d.version) or 0
    local lib = API.groupLibrary(gid)
    if lib then
        local st = db:prepare("UPDATE libraries SET name=?,editable=?,storageVersion=? WHERE libraryID=?")
        st:bind(name, editable and 1 or 0, version, lib.id):step(); st:close()
        st = db:prepare("UPDATE collections SET collectionName=? WHERE key=? AND libraryID=?")
        st:bind(name, "/g" .. gid, lib.id):step(); st:close()
    else
        local st = db:prepare("INSERT INTO libraries(type,editable,name,userID,version,storageVersion,groupID) VALUES('group',?,?,?,0,?,?)")
        st:bind(editable and 1 or 0, name, uid, version, gid):step(); st:close()
        local lid = tonumber(db:rowexec("SELECT last_insert_rowid()"))
        st = db:prepare("INSERT INTO collections(collectionName,libraryID,key) VALUES(?,?,?) ON CONFLICT(libraryID,key) DO NOTHING")
        st:bind(name, lid, "/g" .. gid):step(); st:close()
        logger.info("Zotero: group library", gid, name, "added")
    end
    API.forgetLibraries()
    local names = API.settings:readSetting("group_names")
    if type(names) ~= "table" then names = {} end
    names[tostring(gid)] = name
    API.settings:saveSetting("group_names", names)
    return API.groupLibrary(gid)
end

--- The groups listing (GET /users/<id>/groups?format=versions: { id = version })
-- against the libraries here: groups no longer there (or left out) go, new
-- ones and those whose details changed are fetched.
-- @return error message or nil
local function update_groups(listing)
    local skipped = API.skippedGroups()
    local wanted = {}
    for gid, version in pairs(listing) do
        gid = tonumber(gid)
        if gid and may_read_group(gid) and not skipped[tostring(gid)] then wanted[gid] = tonumber(version) or 0 end
    end
    -- names of all groups, for the settings (also those left out)
    local fetch = {}
    for __, lib in ipairs(API.groupLibraries()) do
        if wanted[lib.groupID] == nil then
            remove_library(lib)
        end
    end
    local names = API.settings:readSetting("group_names")
    if type(names) ~= "table" then names = {} end
    for gid in pairs(listing) do
        gid = tonumber(gid)
        if gid then
            local lib = API.groupLibrary(gid)
            local stored = lib and tonumber(API.openDB():rowexec("SELECT storageVersion FROM libraries WHERE libraryID=" .. lib.id)) or -1
            if (wanted[gid] and stored ~= wanted[gid]) or (not wanted[gid] and names[tostring(gid)] == nil) then
                fetch[#fetch + 1] = gid
            end
        end
    end
    -- forget names of groups the key no longer lists
    for gid in pairs(names) do if listing[gid] == nil and listing[tonumber(gid)] == nil then names[gid] = nil end end
    API.settings:saveSetting("group_names", names)
    if #fetch == 0 then return nil end
    table.sort(fetch)
    local urls = {}
    for i, gid in ipairs(fetch) do urls[i] = ZOTERO_BASE_URL .. "/groups/" .. gid end
    local answers = API.getMany(urls)
    for i, gid in ipairs(fetch) do
        local a = answers[i]
        if a.value then
            if wanted[gid] then
                store_group(gid, a.value)
            else
                local d = a.value.data or a.value
                names[tostring(gid)] = type(d.name) == "string" and d.name or ("Group " .. gid)
                API.settings:saveSetting("group_names", names)
            end
        elseif wanted[gid] and not API.groupLibrary(gid) then
            return a.err
        elseif not wanted[gid] then
            -- (a name to show; not asked for again at every sync)
            names[tostring(gid)] = names[tostring(gid)] or ("Group " .. gid)
            API.settings:saveSetting("group_names", names)
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------

--- The objects of one kind a library is missing, fetched in batches and
-- stored. @return error or nil
local function fetch_objects(jobs, report)
    -- in chunks, so that a large first download is never all in memory at once
    local CHUNK = 8
    local total = #jobs
    for start = 1, total, CHUNK do
        local chunk, urls = {}, {}
        for i = start, math.min(start + CHUNK - 1, total) do
            chunk[#chunk + 1] = jobs[i]
            urls[#urls + 1] = jobs[i].url
        end
        if not report(jobs[start], start) then return API.CANCELLED end
        local answers = API.getMany(urls)
        for i, job in ipairs(chunk) do
            local a = answers[i]
            if not a.value then return a.err or "Error: no answer" end
            if type(a.value) ~= "table" then return "Error: unexpected answer from Zotero" end
            seen_version(job.ctx, lmv(a.headers))
            local serr
            if job.kind == "collections" then
                serr = store_collections(job.ctx, a.value)
            else
                serr = store_items(job.ctx, a.value)
            end
            if serr then return "Error: could not store items: " .. serr end
            -- (every stored batch is a point where the sync may stop)
            if not report(jobs[start + i] or job, start + i) then return API.CANCELLED end
        end
        Bg.pause()
    end
    return nil
end

--- The old way, for a library whose version list cannot be trusted: every
-- changed object, page by page. @return error or nil
local function fetch_paged(ctx, kind, since, report)
    local base = API.libraryURL(ctx.lib)
    local url = kind == "collections" and (base .. "/collections?since=" .. since .. "&format=json")
        or (base .. "/items?since=" .. since .. "&format=json&includeTrashed=1")
    local label = kind == "collections" and "Syncing collections %.0f%%" or "Syncing items %.0f%%"
    local page_error
    local ok, version, err = pcall(API.fetchCollectionPaginated, url, API.zoteroHeader, function(entries, pct)
        if report(string.format(label, pct)) == false then return false end
        if page_error then return end
        page_error = kind == "collections" and store_collections(ctx, entries) or store_items(ctx, entries)
    end)
    if not ok then return "Error: " .. tostring(version) end
    if err then return err end
    if page_error then return "Error: could not store items: " .. page_error end
    seen_version(ctx, version)
    return nil
end

--- Download what changed in the Zotero libraries since the last sync.
-- @return nil on success, or an error message
function API.pull(progress_callback)
    local callback = progress_callback or function() end
    local stopped = false
    local function go(msg, fraction)
        if stopped then return false end
        if callback(msg, fraction) == false then stopped = true; return false end
        return true
    end
    local e = API.verifyZoteroAccess(); if e then return e end
    if not go("Asking Zotero what changed…") then return API.CANCELLED end
    local db = API.openDB()
    local settings = API.getSettings()
    local positions = not settings or settings:readSetting("sync_reading_position") ~= false
    local settings_since = tonumber(db:rowexec("SELECT version FROM syncSettings WHERE name='#version'")) or 0
    local groups = API.groupsWanted()

    -- 1. one round: which libraries changed, the groups, the positions
    local urls, slots = {}, {}
    local function ask(url, slot) urls[#urls + 1] = url; slots[#slots + 1] = slot end
    local function ask_all(lib)
        ask(API.libraryURL(lib) .. "/items?since=" .. string.format("%d", lib.version) .. "&format=versions&includeTrashed=1", { lib = lib, what = "all" })
    end
    for __, lib in ipairs(API.libraries()) do
        if lib.type ~= "group" or groups then ask_all(lib) end
    end
    if groups then ask(API.libraryURL() .. "/groups?format=versions", { what = "groups" }) end
    if positions then ask(API.libraryURL() .. "/settings?since=" .. string.format("%d", settings_since), { what = "settings" }) end
    local answers = API.getMany(urls)
    if stopped or Bg.stopped() then return API.CANCELLED end

    local libs = {}  -- the libraries to download into, in order
    local by_lib = {}
    local function entry(lib)
        if not by_lib[lib.id] then
            by_lib[lib.id] = { ctx = new_ctx(lib) }
            libs[#libs + 1] = lib
        end
        return by_lib[lib.id]
    end
    -- (the groups first: a group that is gone answers with an error)
    local order = {}
    for i, slot in ipairs(slots) do order[#order + 1] = { i = i, first = slot.what ~= "all" and 0 or 1 } end
    table.sort(order, function(a, b) if a.first ~= b.first then return a.first < b.first end return a.i < b.i end)
    for __, o in ipairs(order) do
        local i, slot = o.i, slots[o.i]
        local a = answers[i]
        if slot.what == "all" then
            local lib = API.library(slot.lib.id)
            if lib and lib.id == slot.lib.id then
                if a.value then
                    local x = entry(slot.lib)
                    x.all, x.all_headers = a.value, a.headers
                elseif lib.type == "group" and (a.code == 403 or a.code == 404) then
                    -- a group this key cannot read (any more): left as it is
                    logger.warn("Zotero: group library", lib.groupID, "cannot be read:", tostring(a.err))
                else
                    return a.err
                end
            end
        elseif slot.what == "groups" then
            if a.value and type(a.value) == "table" then
                local gerr = update_groups(a.value)
                if gerr then logger.warn("Zotero: group libraries not updated:", tostring(gerr)) end
            else
                logger.warn("Zotero: groups not listed:", tostring(a.err))
            end
        elseif slot.what == "settings" then
            local sok, serr = pcall(API.storeSettings, a.value, a.headers)
            if not sok or (a.err and not a.value) then
                logger.warn("Zotero: reading positions not downloaded:", tostring(a.err or serr))
            end
        end
    end
    -- the user's library, then groups added just now
    if groups then
        local fresh = {}
        for __, lib in ipairs(API.groupLibraries()) do
            if not by_lib[lib.id] then fresh[#fresh + 1] = lib end
        end
        if #fresh > 0 then
            local more = {}
            for i, lib in ipairs(fresh) do
                more[i] = API.libraryURL(lib) .. "/items?since=0&format=versions&includeTrashed=1"
            end
            local more_answers = API.getMany(more)
            for i, lib in ipairs(fresh) do
                local a = more_answers[i]
                if not a.value then return a.err end
                local x = entry(lib)
                x.all, x.all_headers = a.value, a.headers
            end
        end
    end
    -- (the libraries' records again: a group's name may have changed)
    for __, lib in ipairs(libs) do
        local now = API.library(lib.id)
        if now and now ~= lib then by_lib[lib.id].ctx.lib = now end
    end

    -- 2. for the libraries that changed: collections, the items not in the
    -- trash, deletions
    local changed = {}
    for __, lib in ipairs(libs) do
        local x = by_lib[lib.id]
        local v = lmv(x.all_headers)
        if lib.version == 0 or v == nil or v ~= lib.version or next(x.all) ~= nil then
            changed[#changed + 1] = lib
        else
            seen_version(x.ctx, v)
            x.unchanged = true
        end
    end
    if #changed > 0 then
        local urls2, slots2 = {}, {}
        for __, lib in ipairs(changed) do
            local base, since = API.libraryURL(lib), string.format("%d", lib.version)
            urls2[#urls2 + 1] = base .. "/collections?since=" .. since .. "&format=versions"; slots2[#slots2 + 1] = { lib = lib, what = "collections" }
            urls2[#urls2 + 1] = base .. "/items?since=" .. since .. "&format=versions"; slots2[#slots2 + 1] = { lib = lib, what = "live" }
            urls2[#urls2 + 1] = base .. "/deleted?since=" .. since; slots2[#slots2 + 1] = { lib = lib, what = "deleted" }
        end
        if not go("Asking Zotero what changed…") then return API.CANCELLED end
        local answers2 = API.getMany(urls2)
        if stopped or Bg.stopped() then return API.CANCELLED end
        for i, slot in ipairs(slots2) do
            local a = answers2[i]
            if not a.value then return a.err end
            local x = by_lib[slot.lib.id]
            x[slot.what], x[slot.what .. "_headers"] = a.value, a.headers
        end
    end

    -- 3. what is missing here, in batches, for all libraries together
    local jobs = {}
    local comparing = false
    for __, lib in ipairs(changed) do
        local x = by_lib[lib.id]
        local ctx = x.ctx
        local base = API.libraryURL(lib)
        for __, h in ipairs({ x.all_headers, x.collections_headers, x.live_headers, x.deleted_headers }) do seen_version(ctx, lmv(h)) end
        -- collections
        if complete(x.collections, x.collections_headers) then
            local have = local_versions(lib, "collections")
            local wanted = {}
            for key, version in pairs(x.collections) do
                if have[key] ~= tonumber(version) then wanted[#wanted + 1] = key end
            end
            table.sort(wanted)
            for start = 1, #wanted, BATCH do
                local keys = {}
                for j = start, math.min(start + BATCH - 1, #wanted) do keys[#keys + 1] = wanted[j] end
                jobs[#jobs + 1] = { ctx = ctx, kind = "collections", label = "Syncing collections…",
                    url = base .. "/collections?format=json&collectionKey=" .. table.concat(keys, ",") }
            end
        else
            x.paged_collections = true
        end
        -- items
        if complete(x.all, x.all_headers) and complete(x.live, x.live_headers) and count_keys(x.all) >= count_keys(x.live) then
            local have = local_versions(lib, "items")
            if lib.version == 0 and next(have) ~= nil then
                -- already stored here (after an update of the plugin, or
                -- "Resync"): compared, not downloaded again
                ctx.compared = true
                comparing = true
            end
            local wanted = {}
            for key, version in pairs(x.live) do
                if Util.isValidKey(key) and have[key] ~= tonumber(version) then wanted[#wanted + 1] = key end
            end
            table.sort(wanted)
            x.trashed = {}
            for key in pairs(x.all) do if x.live[key] == nil then x.trashed[#x.trashed + 1] = key end end
            if ctx.compared then
                x.gone = {}
                for key in pairs(have) do if x.all[key] == nil then x.gone[#x.gone + 1] = key end end
            end
            logger.info("Zotero: library", lib.id, lib.name, ":", count_keys(x.live), "changed items listed,", #wanted, "to fetch,", #x.trashed, "in the trash")
            for start = 1, #wanted, BATCH do
                local keys = {}
                for j = start, math.min(start + BATCH - 1, #wanted) do keys[#keys + 1] = wanted[j] end
                jobs[#jobs + 1] = { ctx = ctx, kind = "items", label = "Syncing items %.0f%%", n = #keys,
                    url = base .. "/items?format=json&includeTrashed=1&itemKey=" .. table.concat(keys, ",") }
            end
        else
            logger.warn("Zotero: the server's item list for library", lib.id, "looks incomplete; downloading page by page instead")
            x.paged_items = true
        end
    end
    if comparing and not go("Comparing with the Zotero library…") then return API.CANCELLED end
    -- collections first: items are placed in them
    table.sort(jobs, function(a, b)
        if a.kind ~= b.kind then return a.kind == "collections" end
        return false
    end)
    local total_items = 0
    for __, j in ipairs(jobs) do if j.kind == "items" then total_items = total_items + j.n end end
    local ferr = fetch_objects(jobs, function(job, index)
        local label = job.label
        local fraction
        if job.kind == "items" then
            local n = 0
            for k = 1, index - 1 do if jobs[k].kind == "items" then n = n + jobs[k].n end end
            fraction = total_items > 0 and n / total_items or 1
            label = string.format(label, 100 * fraction)
        end
        return go(label, fraction)
    end)
    if ferr then return ferr end
    for __, lib in ipairs(changed) do
        local x = by_lib[lib.id]
        if x.paged_collections then
            local perr = fetch_paged(x.ctx, "collections", lib.version, go)
            if perr then return perr end
        end
        if x.paged_items then
            local perr = fetch_paged(x.ctx, "items", lib.version, go)
            if perr then return perr end
        end
    end
    if stopped or Bg.stopped() then return API.CANCELLED end

    -- 4. deletions and the index, per library; then its version
    if #changed > 0 then go("Updating local index…") end
    local first_time = false
    for __, lib in ipairs(changed) do if lib.version == 0 then first_time = true end end
    for __, lib in ipairs(libs) do
        local x = by_lib[lib.id]
        if not x.unchanged then
            local ierr = finish_library(x.ctx, x.deleted, x.trashed, x.gone)
            if ierr then return ierr end
        end
        local version = x.ctx.lowest or lib.version
        if version < lib.version then version = lib.version end
        if version ~= lib.version or not x.unchanged then set_library_version(x.ctx.lib, version) end
        Bg.pause()
    end
    API.forgetLibraries()
    if API.restored_seen then
        API.restored_seen = nil
        pcall(API.scanStorage) -- which of the restored attachments have their file here
    end
    if first_time then pcall(API.scanStorage) end
    logger.info("Zotero: libraries synced:", #libs, "(", #changed, "changed)")
    return nil
end
API.setLibraryVersion = set_library_version

--- Kept for compatibility: the user's library only, through API.pull.
function API.fetchZoteroItems()
    local err = API.pull()
    if err then return nil, err end
    return API.getUserLibraryVersion(), nil
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

-- ---------------------------------------------------------------------------
-- The browser's lists, and their order
-- ---------------------------------------------------------------------------

local SORTS = { added = true, modified = true, author = true, title = true }
--- How entries are ordered: { by = "added" | "modified" | "author" | "title", desc = bool }
-- (default: date added, newest first)
function API.getSort()
    local s = API.settings and API.settings:readSetting("browser_sort")
    if type(s) ~= "table" or not SORTS[s.by] then return { by = "added", desc = true } end
    return { by = s.by, desc = s.desc and true or false }
end
function API.setSort(by, desc)
    if not SORTS[by] then return end
    API.settings:saveSetting("browser_sort", { by = by, desc = desc and true or false })
end

--- A name for sorting: lower case, without accents.
local function fold(s)
    s = Dav.nfd(tostring(s or "")):gsub("\204[\128-\191]", ""):gsub("\205[\128-\175]", "")
    s = s:gsub("^[%s%p]+", "")
    return string.lower(s)
end
API._fold = fold

local function first_creator(d, meta)
    if type(meta) == "table" and type(meta.creatorSummary) == "string" and meta.creatorSummary ~= "" then
        return meta.creatorSummary
    end
    for __, c in ipairs(type(d.creators) == "table" and d.creators or {}) do
        local name = c.lastName or c.name
        if type(name) == "string" and name ~= "" then return name end
    end
    return nil
end

--- An entry of a list, from an item as stored.
local function entry_of(key, item, type_name)
    local d = item and item.data or {}
    local meta = item and item.meta or {}
    local title = d.title or d.filename or key
    local creator = first_creator(d, meta)
    local text = title
    if type(meta.creatorSummary) == "string" and meta.creatorSummary ~= "" then text = meta.creatorSummary .. " - " .. title end
    return {
        key = key, text = text, type = type_name == "attachment" and "attachment" or "item",
        is_pdf = d.contentType == "application/pdf",
        added = type(d.dateAdded) == "string" and d.dateAdded or "",
        modified = type(d.dateModified) == "string" and d.dateModified or "",
        author = creator and fold(creator) or nil,
        year = type(meta.parsedDate) == "string" and meta.parsedDate:sub(1, 4) or "",
        title_key = fold(title),
    }
end

--- Put entries in the order chosen (sort = API.getSort() if not given).
-- Entries that lack what is sorted by (no author, say) come last.
function API.sortEntries(entries, sort)
    sort = sort or API.getSort()
    local by, desc = sort.by, sort.desc
    local function value(e)
        if by == "added" then return e.added ~= "" and e.added or nil end
        if by == "modified" then return e.modified ~= "" and e.modified or nil end
        if by == "author" then return e.author and (e.author .. "\0" .. (e.year or "")) or nil end
        return e.title_key ~= "" and e.title_key or nil
    end
    for _, e in ipairs(entries) do e._v = value(e) end
    table.sort(entries, function(a, b)
        local va, vb = a._v, b._v
        if va ~= vb then
            if va == nil then return false end
            if vb == nil then return true end
            if desc then return va > vb end
            return va < vb
        end
        if a.title_key ~= b.title_key then return (a.title_key or "") < (b.title_key or "") end
        return a.key < b.key
    end)
    for _, e in ipairs(entries) do e._v = nil end
    return entries
end

--- A collection's subcollections (by name) and entries (in the order chosen).
-- @param key the collection; nil: the top of the user's library; "/g<id>":
--        the top of a group library
function API.displayCollection(key, sort)
    key=key or "/"; local db=API.openDB(); local out={}
    local cid=tonumber(db:rowexec("SELECT collectionID FROM collections WHERE key='"..key:gsub("'","''").."'")); if not cid then return out end
    local st=db:prepare("SELECT key,collectionName,synced FROM collections WHERE parentCollectionID=?"); local row=st:bind(cid):step()
    -- (offline: a collection whose files a sync downloads)
    while row do table.insert(out,{key=row[1],text=row[2] or "",type="collection",offline=(tonumber(row[3]) or 0)>0,name_key=fold(row[2])}); row=st:step(row) end; st:close()
    table.sort(out,function(a,b) if a.name_key~=b.name_key then return a.name_key<b.name_key end return a.key<b.key end)
    st=db:prepare([[SELECT i.key,d.value,t.typeName FROM collectionItems ci JOIN items i ON i.itemID=ci.itemID JOIN itemData d ON d.itemID=i.itemID JOIN itemTypes t ON t.itemTypeID=i.itemTypeID WHERE ci.collectionID=? AND t.typeName NOT IN ('annotation')]])
    row=st:bind(cid):step()
    local entries={}
    while row do
        local item=safe_decode(row[2]); local d=item and item.data or {}
        -- (the files, links and notes of an entry belong to no collection of
        -- their own and are stored under the top level: they are reached
        -- through their entry, not listed beside it)
        if not is_child(d) then entries[#entries+1]=entry_of(row[1],item,row[3]) end
        row=st:step(row)
    end
    st:close()
    API.sortEntries(entries,sort)
    for __,e in ipairs(entries) do out[#out+1]=e end
    return out
end
--- The group libraries, as entries of the browser's top level.
function API.displayLibraries()
    local out={}
    for __,lib in ipairs(API.groupLibraries()) do
        out[#out+1]={key=lib.root,text=lib.name,type="library",library=lib.id,groupID=lib.groupID}
    end
    return out
end
--- Entries whose title or first author contains the query ("": all), in the
-- order chosen. @param lid only those of this library (nil: all libraries)
function API.displaySearchResults(query, lid, sort)
    query=string.lower(query or ""); local db=API.openDB(); local out={}
    local st
    if lid then
        st=db:prepare([[SELECT i.key,d.value,t.typeName FROM items i JOIN itemData d USING(itemID) JOIN itemTypes t USING(itemTypeID) WHERE t.typeName NOT IN ('annotation') AND i.libraryID=?]])
        st:bind(tonumber(lid))
    else
        st=db:prepare([[SELECT i.key,d.value,t.typeName FROM items i JOIN itemData d USING(itemID) JOIN itemTypes t USING(itemTypeID) WHERE t.typeName NOT IN ('annotation')]])
    end
    local row=st:step()
    while row do
        local item=safe_decode(row[2]); local d=item and item.data or {}
        if not is_child(d) then
            local e=entry_of(row[1],item,row[3])
            if query=="" or string.lower(e.text):find(query,1,true) then out[#out+1]=e end
        end
        row=st:step(row)
    end
    st:close()
    return API.sortEntries(out,sort)
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

-- ---------------------------------------------------------------------------
-- What this device knows about an attachment (table attachmentState)
-- ---------------------------------------------------------------------------

local STATE_FIELDS = { "info", "annLocal", "annRemote", "failVersion", "failCode", "failAt" }
function API.attachmentState(key)
    local st = API.openDB():prepare("SELECT info,annLocal,annRemote,failVersion,failCode,failAt FROM attachmentState WHERE key=?")
    local row = st:bind(key):step()
    local out = {}
    if row then for i, f in ipairs(STATE_FIELDS) do out[f] = row[i] end end
    st:close()
    out.failVersion, out.failCode, out.failAt = tonumber(out.failVersion) or 0, tonumber(out.failCode) or 0, tonumber(out.failAt) or 0
    return out
end
--- Change some of an attachment's state; a field set to false is cleared.
function API.setAttachmentState(key, fields)
    local cur = API.attachmentState(key)
    for k, v in pairs(fields) do
        if v == false then cur[k] = (k == "failVersion" or k == "failCode" or k == "failAt") and 0 or nil else cur[k] = v end
    end
    local st = API.openDB():prepare([[INSERT INTO attachmentState(key,info,annLocal,annRemote,failVersion,failCode,failAt) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(key) DO UPDATE SET info=excluded.info,annLocal=excluded.annLocal,annRemote=excluded.annRemote,failVersion=excluded.failVersion,failCode=excluded.failCode,failAt=excluded.failAt]])
    st:bind(key, cur.info, cur.annLocal, cur.annRemote, cur.failVersion or 0, cur.failCode or 0, cur.failAt or 0):step()
    st:close()
end
--- Forget what the annotation sync noted about every attachment (the next
-- sync looks at every document again).
function API.forgetAnnotationState()
    API.openDB():exec("UPDATE attachmentState SET annLocal=NULL,annRemote=NULL")
end
--- Forget download failures (the next sync tries those files again).
function API.forgetDownloadFailures()
    API.openDB():exec("UPDATE attachmentState SET failVersion=0,failCode=0,failAt=0")
end

-- ---------------------------------------------------------------------------
-- Downloading files
--
-- A file is downloaded next to its place and renamed when complete, so that
-- an interrupted download never leaves a truncated file that looks valid. In
-- a background job the transfer runs in a child process (the reader stays
-- usable); the job only watches the file grow.
--
-- Where a file comes from:
--   the user's library  Zotero's storage (the API answers with a redirect to
--                       the file, which is fetched without the API key), or
--                       the user's WebDAV storage (<KEY>.zip), as configured
--   a group library     Zotero's storage; or, for a group whose files are in
--                       a shared WebDAV folder (Group Linked Files), that
--                       folder, falling back to Zotero's storage for a file
--                       the folder does not have
-- ---------------------------------------------------------------------------

--- How a group's files are reached: { mode = "zotero" | "webdav", server, path, user, password }
function API.groupFiles(gid)
    local t = API.settings:readSetting("group_files")
    local cfg = type(t) == "table" and t[tostring(gid)] or nil
    if type(cfg) ~= "table" then return { mode = "zotero" } end
    return cfg
end
function API.setGroupFiles(gid, cfg)
    local t = API.settings:readSetting("group_files")
    if type(t) ~= "table" then t = {} end
    t[tostring(gid)] = cfg
    API.settings:saveSetting("group_files", t)
    API.dav_listings = nil
end

--- The files in a group's shared WebDAV folder (reused for a minute).
-- @return { { name, isDir, size } } or nil, error
function API.davListing(cfg, fresh)
    local url = Dav.folderURL(cfg)
    if not url then return nil, "the WebDAV address is not set" end
    API.dav_listings = API.dav_listings or {}
    local hit = API.dav_listings[url]
    if not fresh and hit and os.time() - hit.at < Dav.LIST_TTL then return hit.entries end
    local res = API.requestMany({ {
        method = "PROPFIND", url = url, body = Dav.PROPFIND_BODY,
        headers = { Authorization = Dav.authHeader(cfg, sha2.bin_to_base64), Depth = "1", ["content-type"] = "application/xml; charset=utf-8" },
    } }, 1)[1]
    if res.err then return nil, "WebDAV: " .. tostring(res.err) end
    if res.code == 401 or res.code == 403 then return nil, "WebDAV: the login was refused (user name, WebDAV password)" end
    if res.code == 404 then return nil, "WebDAV: the folder was not found" end
    if res.code ~= 207 then return nil, "WebDAV answered with status " .. tostring(res.code) end
    local entries = Dav.parseMultistatus(res.body, url)
    API.dav_listings[url] = { at = os.time(), entries = entries }
    return entries
end

--- Check a group's WebDAV folder. @return number of files, number of folders  or nil, error
function API.checkGroupDav(cfg)
    local entries, err = API.davListing(cfg, true)
    if not entries then return nil, err end
    local files, folders = 0, 0
    for __, e in ipairs(entries) do if e.isDir then folders = folders + 1 else files = files + 1 end end
    return files, folders
end

--- Fetch a file into `part`, trying the sources in order; a source that
-- answers 404 passes on to the next. Redirects are followed by hand, without
-- the headers of the first request (the API key stays with Zotero).
-- Runs in a child process: plain data in, plain data out.
-- @return { code =, source = } or { err = }
local function fetch_file(sources, part)
    local last = { err = "no source" }
    for __, src in ipairs(sources) do
        local url, headers = src.url, src.headers
        local res
        for __ = 1, 4 do
            res = API.exchange{ method = "GET", url = url, headers = headers, file = part, redirect = false, block_timeout = 30, total_timeout = -1 }
            if res.err or not (res.code >= 300 and res.code < 400 and res.headers.location) then break end
            local loc = res.headers.location
            if not loc:match("^%a[%w+.-]*://") then
                loc = url:match("^(%a[%w+.-]*://[^/]+)") .. (loc:sub(1, 1) == "/" and "" or "/") .. loc
            end
            url, headers = loc, src.redirect_headers or {}
        end
        if res.err then return { err = res.err, source = src.name } end
        last = { code = res.code, source = src.name }
        if res.code ~= 404 then return last end
    end
    return last
end
API._fetchFile = fetch_file

-- downloads running now: key -> true (one at a time for each file)
local downloading = {}

--- Everything needed to download an attachment's file.
-- @return d = { key, item, kind, dir, path, part, sources, total }, or nil and an error
local function prepare_download(item)
    local key, d = item.key, item.data
    local kind = API.attachmentKind(d)
    if not kind then return nil, API.whyNotOpenable(d) end
    if d.linkMode == "linked_file" then return nil, "Linked file not found locally" end
    local e = API.verifyZoteroAccess(); if e then return nil, e end
    local lib = API.libraryOfKey(key)
    local dir, path = API.getDirAndPath(item)
    local dl = { key = key, item = item, kind = kind, dir = dir, path = path, part = path .. ".part",
        total = tonumber(item.fileLength), sources = {} }
    local zotero = { name = "zotero", url = API.libraryURL(lib) .. "/items/" .. key .. "/file", headers = API.zoteroHeader }
    if lib.type == "group" then
        local cfg = API.groupFiles(lib.groupID)
        if cfg.mode == "webdav" and Dav.usable(cfg) then
            local name = d.filename or API.basenameOfPath(path)
            local entries, lerr = API.davListing(cfg)
            local hit = entries and Dav.find(entries, name)
            if entries and not hit then
                -- (refreshed once: the file may have been added since)
                entries = API.davListing(cfg, true)
                hit = entries and Dav.find(entries, name)
            end
            if hit or not entries then
                if lerr then logger.warn("Zotero: WebDAV folder of group", lib.groupID, "not listed:", tostring(lerr)) end
                local auth = { Authorization = Dav.authHeader(cfg, sha2.bin_to_base64) }
                table.insert(dl.sources, { name = "webdav", url = Dav.folderURL(cfg) .. Dav.encode(hit and hit.name or name), headers = auth, redirect_headers = auth })
                if hit and hit.size then dl.total = hit.size end
                dl.dav_error = lerr
            end
        end
        table.insert(dl.sources, zotero)
    elseif API.getWebDAVEnabled() then
        local base = API.getWebDAVUrl()
        if base == "" then return nil, "WebDAV url not set" end
        local auth = API.getWebDAVHeaders()
        dl.zipped = true
        dl.part = BaseUtil.joinPath(dir, key .. ".zip")
        table.insert(dl.sources, { name = "webdav", url = base:gsub("/$", "") .. "/" .. key .. ".zip", headers = auth, redirect_headers = auth })
    else
        table.insert(dl.sources, zotero)
    end
    return dl
end

local function info_signature(item, path)
    local parent = item.data.parentItem and API.getItemVersion(item.data.parentItem) or 0
    return string.format("%d:%d:%d", tonumber(item.version) or 0, tonumber(parent) or 0, tonumber(lfs.attributes(path, "size")) or 0)
end

--- A file that is here: note it in the document (title, authors), prepare a
-- snapshot - only when something changed since the last time.
local function note_present(item, path, kind)
    local sig = info_signature(item, path)
    local state = API.attachmentState(item.key)
    if state.info == sig then return end
    if kind == "html" then prepare_snapshot(path) end
    API.getAttachmentInfo(item, path)
    API.markAttachmentPresent(item.key)
    API.setAttachmentState(item.key, { info = info_signature(item, path), failVersion = false, failCode = false, failAt = false })
end

--- The downloaded file in its place. @return path, or nil and an error
local function complete_download(dl, res)
    local key, item = dl.key, dl.item
    if res.err or res.code ~= 200 then
        os.remove(dl.part)
        local err = res.err and ("Error: " .. tostring(res.err)) or ("Error: API responded with status code " .. tostring(res.code))
        if res.code == 404 then
            -- no source has it: not asked for again until the attachment changes
            API.setAttachmentState(key, { failVersion = tonumber(item.version) or 0, failCode = 404, failAt = os.time() })
            if dl.dav_error then err = err .. " (" .. tostring(dl.dav_error) .. ")" end
        end
        return nil, err
    end
    local path = dl.path
    if dl.zipped then
        local ok = extract_zip(dl.part, dl.dir)
        os.remove(dl.part)
        if not ok then return nil, "Unzipping failed" end
        if not file_exists(path) then path = API.findFileByBasename(dl.dir, API.basenameOfPath(path)) or path end
    else
        -- A web snapshot that consists of several files (older snapshots)
        -- is stored by Zotero as a zip of its folder.
        local zipped = false
        if dl.kind == "html" then
            local pf = io.open(dl.part, "rb")
            if pf then zipped = pf:read(4) == "PK\3\4"; pf:close() end
        end
        if zipped then
            local unpacked = extract_zip(dl.part, dl.dir)
            os.remove(dl.part)
            if not unpacked then return nil, "Could not unpack the snapshot" end
            if not file_exists(path) then path = API.findFileByBasename(dl.dir, API.basenameOfPath(path)) or path end
            if not file_exists(path) then return nil, "The snapshot's main file was not found in what Zotero stores for it" end
        else
            os.remove(path)
            if not os.rename(dl.part, path) then os.remove(dl.part); return nil, "Could not store attachment file" end
        end
    end
    if not file_exists(path) then return nil, "The downloaded file is missing" end
    if dl.kind == "html" then prepare_snapshot(path) end
    API.getAttachmentInfo(item, path)
    API.setAttachmentVersionByKey(key, math.max(1, tonumber(item.version) or 1))
    API.setAttachmentState(key, { info = info_signature(item, path), failVersion = false, failCode = false, failAt = false })
    logger.info("Zotero: downloaded", key, "from", tostring(res.source), path)
    return path, nil
end

local function wait_for_other_download(key)
    while downloading[key] do
        if Bg.current() then Bg.sleep(0.3) else return false end
        if Bg.stopped() then return false end
    end
    return true
end

--- The file of an attachment, downloaded if it is not here.
-- @param download_callback called before a download starts
-- @param opts.progress function(bytes, total or nil) while downloading
-- @param opts.batch part of a sync: no search by file name outside the
--        attachment's own places, except in the folder index (beginFileIndex)
-- @return path, or nil and an error
function API.downloadAndGetPath(key, download_callback, opts)
    opts = opts or {}
    local item=API.getItem(key); if not item then return nil,"Error: the requested file can not be found in the database" end
    if not item.data or item.data.itemType~="attachment" then return nil,"Error: this item is not an attachment" end
    local kind=API.attachmentKind(item.data)
    if not kind then return nil,API.whyNotOpenable(item.data) end
    local local_path=API.resolveAttachmentPath(item, true) or API.resolveAttachmentPath(item)
    if local_path and file_exists(local_path) then
        Bg.critical(note_present, item, local_path, kind)
        return local_path,nil
    end
    if not wait_for_other_download(key) then return nil, API.CANCELLED end
    local_path=API.resolveAttachmentPath(item, true)
    if local_path and file_exists(local_path) then return local_path,nil end -- (it came meanwhile)
    local dl, err = prepare_download(item)
    if not dl then return nil, err end
    mkdir_p(dl.dir)
    if download_callback then download_callback() end
    downloading[key] = true
    local ok, res = pcall(function()
        return Bg.run({ { fn = fetch_file, args = { dl.sources, dl.part, n = 2 },
            poll = opts.progress and function() opts.progress(lfs.attributes(dl.part, "size") or 0, dl.total) end } }, 1)[1]
    end)
    if not ok then downloading[key] = nil; os.remove(dl.part); return nil, tostring(res) end
    if res.err == "stopped" then downloading[key] = nil; os.remove(dl.part); return nil, API.CANCELLED end
    local path, cerr = Bg.critical(complete_download, dl, res)
    downloading[key] = nil
    return path, cerr
end

--- Is the file of this attachment being downloaded right now?
function API.isDownloading(key) return downloading[key] == true end

--- Download the files of the offline collections that are not here yet, two
-- at a time; files that are here are noted in their documents if anything
-- changed. A file the server does not have is not asked for again until
-- the attachment changes (or a day has passed).
-- @return number of failures, { { filename, error } }, number downloaded
function API.batchDownload(progress_callback)
    progress_callback=progress_callback or function() end
    local function report(msg, fraction) return progress_callback(msg, fraction) ~= false end
    local db=API.openDB(); local st=db:prepare([[SELECT i.key,d.value FROM itemAttachments a JOIN items i ON i.itemID=a.itemID JOIN itemData d ON d.itemID=i.itemID WHERE a.parentItemID IN (SELECT ci.itemID FROM collectionItems ci JOIN collections c ON c.collectionID=ci.collectionID WHERE c.synced=1)]])
    local rows={}; local row=st:reset():step()
    while row do
        -- only what is a file the reader can open: links to web pages are not downloads
        local item=safe_decode(row[2])
        if item and API.attachmentKind(item.data) then table.insert(rows,item) end
        row=st:step(row)
    end
    st:close()
    local fails,details,downloaded=0,{},0
    local todo={}
    API.beginFileIndex()
    local ok,err=pcall(function()
        for i,item in ipairs(rows) do
            if (i==1 or i%25==0) and not report(string.format(_("Checking attachment %i/%i"),i,#rows), i/#rows) then return end
            local path=API.resolveAttachmentPath(item,true) or API.resolveAttachmentPath(item)
            if path and file_exists(path) then
                Bg.critical(note_present,item,path,API.attachmentKind(item.data))
            elseif item.data.linkMode=="linked_file" then
                fails=fails+1; table.insert(details,{filename=item.data.filename or item.key,error="Linked file not found locally"})
            elseif not downloading[item.key] then
                local state=API.attachmentState(item.key)
                if state.failCode==404 and state.failVersion==(tonumber(item.version) or 0) and os.time()-state.failAt<86400 then
                    fails=fails+1; table.insert(details,{filename=item.data.filename or item.key,error="not on the server",known=true,key=item.key,code=404})
                else
                    todo[#todo+1]=item
                end
            end
            Bg.pause()
        end
    end)
    API.endFileIndex()
    if not ok then error(err) end
    if #todo==0 then return fails,details,0 end
    -- the downloads, two at a time
    local tasks,dls={},{}
    local bytes,total_known={}, 0
    for __,item in ipairs(todo) do
        local dl,perr=prepare_download(item)
        if dl then
            mkdir_p(dl.dir)
            dls[#dls+1]=dl
        else
            fails=fails+1; table.insert(details,{filename=item.data.filename or item.key,error=perr})
        end
        if Bg.stopped() then break end
    end
    local finished=0
    local function show()
        local got=0
        for i,dl in ipairs(dls) do got=got+(bytes[i] or 0) end
        report(string.format(_("Downloading %i/%i (%.1f MB)"),math.min(finished+1,#dls),#dls,got/1e6), #dls>0 and finished/#dls or nil)
    end
    for i,dl in ipairs(dls) do
        downloading[dl.key]=true
        tasks[i]={ fn=fetch_file, args={ dl.sources, dl.part, n=2 },
            poll=function()
                bytes[i]=lfs.attributes(dl.part,"size") or bytes[i] or 0
                show()
            end,
            done=function(res)
                local path,cerr
                if res.err=="stopped" then
                    os.remove(dl.part)
                else
                    path,cerr=Bg.critical(complete_download,dl,res)
                end
                downloading[dl.key]=nil
                finished=finished+1
                if path then
                    downloaded=downloaded+1
                elseif res.err~="stopped" then
                    fails=fails+1; table.insert(details,{filename=dl.item.data.filename or dl.key,error=cerr,key=dl.key,code=res.code})
                    logger.warn("Zotero: attachment", dl.key, tostring(dl.item.data.filename), "not downloaded:", tostring(cerr))
                end
                show()
            end }
    end
    show()
    Bg.run(tasks,2)
    for __,dl in ipairs(dls) do downloading[dl.key]=nil end
    return fails,details,downloaded
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
--- The library objects to be written belong to: that of their parent
-- (annotations), else their own. All of one request must be in one library.
local function library_of_objects(objects)
    local lib
    for _, obj in ipairs(objects) do
        local key = type(obj.parentItem) == "string" and obj.parentItem or obj.key
        local l = API.libraryOfKey(key)
        if lib and l.id ~= lib.id then return nil end
        lib = l
    end
    return lib or API.library(1)
end

function API.writeObjects(objects)
    local e = API.verifyZoteroAccess(); if e then return nil, e end
    if #objects == 0 then return {} end
    if #objects > 50 then return nil, "too many objects in one request" end
    local lib = library_of_objects(objects)
    if not lib then return nil, "objects of several libraries in one request" end
    if not API.canWrite(lib) then
        return nil, lib.type == "group" and ("this API key may not change the group library " .. lib.name) or "this API key may not change the library (read-only key)"
    end
    local encoded = {}
    for i, obj in ipairs(objects) do encoded[i] = encode_object(obj) end
    local code, h, raw = API.request{
        method = "POST", url = API.libraryURL(lib) .. "/items", headers = API.zoteroHeader,
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
    local code, h, raw = API.request{ method = "GET", url = API.libraryURL(API.libraryOfKey(key)) .. "/items/" .. key, headers = API.zoteroHeader }
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
    local lib = API.libraryOfKey(key)
    if not API.canWrite(lib) then return nil, 403 end
    local headers = copy_table(API.zoteroHeader)
    headers["If-Unmodified-Since-Version"] = string.format("%d", tonumber(version) or 0)
    local code, h = API.request{ method = "DELETE", url = API.libraryURL(lib) .. "/items/" .. key, headers = headers }
    if not code then return nil, h end
    if code == 204 then return true end
    return nil, code
end

--- Keep an item the server returned (after a write) in the local library.
function API.storeItem(item)
    if type(item) ~= "table" or not item.key or type(item.data) ~= "table" then return end
    item.links = nil; item.library = nil
    if not upsert_item(item) then return end
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

--- The keys and versions of an attachment's Zotero annotations, as one
-- string (what changes when any of them changes).
function API.annotationVersions(key)
    local st = API.openDB():prepare([[SELECT i.key,i.version FROM itemAnnotations a JOIN items i ON i.itemID=a.itemID WHERE a.parentItemID IN (SELECT itemID FROM items WHERE key=?) ORDER BY i.key]])
    local parts = {}
    local row = st:bind(key):step()
    while row do parts[#parts + 1] = row[1] .. ":" .. tostring(row[2]); row = st:step(row) end
    st:close()
    return table.concat(parts, ",")
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

-- ---------------------------------------------------------------------------
-- Reading positions (Zotero's synced setting "lastPageIndex_u_<attachment>")
-- ---------------------------------------------------------------------------

--- Keep the reading positions of an answer to GET <user>/settings?since=…
-- (also those of group attachments: lastPageIndex_g<group>_<key>).
-- @return number of positions stored
function API.storeSettings(result, h)
    if type(result) ~= "table" then return 0 end
    local db=API.openDB()
    local n=0
    db:exec("BEGIN")
    local ok,err=pcall(function()
        local st=db:prepare("INSERT INTO syncSettings(name,value,version) VALUES(?,?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value,version=excluded.version")
        for name,entry in pairs(result) do
            if type(name)=="string" and (name:match("^lastPageIndex_u_[A-Z0-9]+$") or name:match("^lastPageIndex_g%d+_[A-Z0-9]+$")) and type(entry)=="table" then
                local t=type(entry.value)
                if t=="number" or t=="string" then
                    -- kept with its type: a number is a page index, a string an EPUB position
                    st:reset():bind(name,(t=="number" and "n" or "s")..tostring(entry.value),tonumber(entry.version) or 0):step()
                    n=n+1
                end
            end
        end
        local v=lmv(h)
        if v then st:reset():bind("#version","",v):step() end
        st:close()
    end)
    db:exec(ok and "COMMIT" or "ROLLBACK")
    if not ok then error(err) end
    if n>0 then logger.info("Zotero: reading positions updated:", n) end
    return n
end

--- Download the reading positions that changed since the last time.
-- @return number of positions stored, or nil and an error
function API.fetchSettings()
    local e=API.verifyZoteroAccess(); if e then return nil,e end
    local since=tonumber(API.openDB():rowexec("SELECT version FROM syncSettings WHERE name='#version'")) or 0
    local result,h=API.getZoteroData(API.libraryURL().."/settings?since="..string.format("%d",since))
    if type(result)~="table" then
        logger.warn("Zotero: reading positions not downloaded:", tostring(h))
        return nil,h
    end
    local ok,n=pcall(API.storeSettings,result,h)
    if not ok then return nil,tostring(n) end
    return n
end

local function setting_name(key)
    return API.libraryOfKey(key).setting_prefix..tostring(key)
end

--- Where Zotero last read this attachment.
-- @return value (page index or EPUB position) and its version, or nil
function API.getRemotePosition(key)
    local st=API.openDB():prepare("SELECT value,version FROM syncSettings WHERE name=?")
    local row=st:bind(setting_name(key)):step()
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
    if not Util.isValidKey(key) then return nil,"invalid key" end
    if not API.canWrite(key) then return nil,403 end
    local body
    if type(value)=="number" then
        -- an integer, written as one: a decimal would mean a scroll percentage
        body=string.format('{"value":%d,"version":%d}',value,tonumber(version) or 0)
    elseif type(value)=="string" and value~="" then
        body='{"value":'..Util.jsonString(Util.fixUtf8(value))..string.format(',"version":%d}',tonumber(version) or 0)
    else
        return nil,"invalid value"
    end
    -- (the positions of group attachments, too, are settings of the user's library)
    local name=setting_name(key)
    local code,h=API.request{ method="PUT", url=API.libraryURL().."/settings/"..name, headers=API.zoteroHeader, body=body }
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
--         otherwise), the lines to show the user (what was done, then what
--         needs attention), and the number of those that need attention
function API.syncAllItems(progress_callback, opts)
    opts = opts or {}
    -- a progress callback that returns false asks for the sync to stop; it is
    -- honoured between two complete pieces of work, never in the middle of one
    local stopped=false
    local function callback(msg, fraction)
        if stopped then return false end
        if progress_callback and progress_callback(msg, fraction)==false then stopped=true; return false end
        if Bg.stopped() then stopped=true; return false end
        return true
    end
    local function stage(msg)
        logger.info("Zotero: sync stage:", msg)
        return callback(msg)
    end
    local lines, problems = {}, {}
    local function result(e)
        for __,l in ipairs(problems) do lines[#lines+1]=l end
        return e, lines, #problems
    end

    stage("Checking Zotero access…")
    local e=API.verifyZoteroAccess(); if e then return result(type(e)=="string" and e or readable_value(e)) end

    e=API.pull(callback); if e then return result(e) end
    if stopped then return result(API.CANCELLED) end

    if opts.annotations then
        stage("Synchronizing annotations…")
        local ok,done,trouble=pcall(opts.annotations,callback)
        if not ok then
            logger.err("Zotero: annotation sync failed:", tostring(done))
            table.insert(problems,"Annotation sync failed: "..tostring(done))
        else
            for __,l in ipairs(type(done)=="table" and done or {}) do table.insert(lines,l) end
            for __,l in ipairs(type(trouble)=="table" and trouble or {}) do table.insert(problems,l) end
        end
    end

    if stopped then return result(API.CANCELLED) end

    stage("Checking offline attachments…")
    local df,details,downloaded=API.batchDownload(callback)
    if (downloaded or 0)>0 then
        table.insert(lines,string.format(downloaded==1 and "%d file downloaded" or "%d files downloaded",downloaded))
    end
    local new,known={},0
    for __,d in ipairs(details or {}) do
        if d.known then known=known+1 else new[#new+1]=d end
    end
    if #new>0 then
        table.insert(problems,string.format(#new==1 and "%d file could not be downloaded:" or "%d files could not be downloaded:",#new))
        for i=1,math.min(5,#new) do table.insert(problems,"· "..tostring(new[i].filename)..": "..tostring(new[i].error)) end
    end
    if known>0 then
        table.insert(lines,string.format("%d file(s) of offline collections are not on the server (tried again when they change)",known))
    end
    -- files of a group missing in Zotero's storage: perhaps the group keeps them in a shared folder
    local hint
    for __,d in ipairs(details or {}) do
        if d.code==404 and d.key then
            local lib=API.libraryOfKey(d.key)
            if lib.type=="group" and API.groupFiles(lib.groupID).mode~="webdav" then hint=lib.name break end
        end
    end
    if hint then
        table.insert(#new>0 and problems or lines,string.format("Files of the group \"%s\" are not in Zotero's storage. If the group keeps them in a shared WebDAV folder (Group Linked Files), set it up under Settings > Group libraries.",hint))
    end
    if stopped then return result(API.CANCELLED) end
    logger.info("Zotero: sync completed; library version", API.getUserLibraryVersion())
    if API.settings then API.settings:saveSetting("last_sync_at", os.time()) end
    return result(nil)
end

return API
