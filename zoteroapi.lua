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
local _ = require("gettext")
local DocSettings = require("docsettings")

local API = { version = "Zotero Atelier 2.0 fork v0.2 (2026-10-02)" }
local ZOTERO_BASE_URL = "https://api.zotero.org"
local DB_VERSION = 1
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
    for _, v in pairs(t) do
        if v == value then return true end
    end
    return false
end

local function safe_decode(s)
    if not s or s == "" then return nil end
    local ok, v = pcall(JSON.decode, s)
    if ok then return v end
    return nil
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
        API.db:exec("PRAGMA user_version=" .. tostring(DB_VERSION))
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
    for _, v in ipairs(t) do if API.pathsEqual(v, path) then return end end
    table.insert(t, path); API.setSearchRoots(t)
end
function API.removeSearchRoot(i)
    local t = API.getSearchRoots(); if i >= 1 and i <= #t then table.remove(t, i); API.setSearchRoots(t); return true end; return false
end
function API.getLinkedFilesBases()
    local out = {}
    local saved = API.settings:readSetting("linked_files_bases")
    if type(saved) == "table" then for _, v in ipairs(saved) do table.insert(out, v) end end
    local primary = API.getLinkedFilesBase()
    if primary ~= "" then
        local found = false
        for _, v in ipairs(out) do if API.pathsEqual(v, primary) then found = true break end end
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
    for _, m in ipairs(mappings) do if m.from and m.from ~= "" then table.insert(sorted, m) end end
    table.sort(sorted, function(a,b) return #a.from > #b.from end)
    p = API.normalizePath(p)
    local lower = string.lower(p)
    for _, m in ipairs(sorted) do
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
function API.findFileByBasename(root, basename, depth)
    depth = depth or 0
    if not root or root == "" or not basename or basename == "" or depth > 8 or not file_exists(root) then return nil end
    local want = string.lower(basename)
    local ok, iter, state = pcall(lfs.dir, root)
    if not ok then return nil end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local p = BaseUtil.joinPath(root, name)
            local mode = lfs.attributes(p, "mode")
            if mode == "file" and string.lower(name) == want then return API.normalizePath(p) end
            if mode == "directory" then local f = API.findFileByBasename(p, basename, depth + 1); if f then return f end end
        end
    end
    return nil
end
function API.collectSearchRoots()
    local out = {}
    local function add(v) if v and v ~= "" then table.insert(out, v) end end
    for _, v in ipairs(API.getLinkedFilesBases()) do add(v) end
    if API.getExternalStorageEnabled() then add(API.getExternalStorageDir()) end
    for _, v in ipairs(API.getSearchRoots()) do add(v) end
    add(API.storage_dir)
    return out
end
function API.findAttachmentByBasename(name)
    local base = API.basenameOfPath(name) or name
    for _, root in ipairs(API.collectSearchRoots()) do local f = API.findFileByBasename(root, base); if f then return f end end
    return nil
end
function API.resolveLinkedPath(raw, linkedBase, mappings)
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
        for _, b in ipairs(API.getLinkedFilesBases()) do table.insert(bases, b) end
        for _, b in ipairs(bases) do
            local p = API.normalizePath(BaseUtil.joinPath(b, rel)); if file_exists(p) then return p end
            p = API.normalizePath(BaseUtil.joinPath(b, attach)); if file_exists(p) then return p end
        end
        return API.findAttachmentByBasename(attach)
    end
    local p = API.applyPathMappings(raw, mappings)
    if API.isAbsolutePath(p) then return API.normalizePath(p) end
    local bases = {}
    if linkedBase and linkedBase ~= "" then table.insert(bases, linkedBase) end
    for _, b in ipairs(API.getLinkedFilesBases()) do table.insert(bases, b) end
    for _, b in ipairs(bases) do local c = API.normalizePath(BaseUtil.joinPath(b,p)); if file_exists(c) then return c end end
    return API.findAttachmentByBasename(p) or (linkedBase and linkedBase ~= "" and API.normalizePath(BaseUtil.joinPath(linkedBase,p)) or nil)
end
function API.isSupportedAttachmentLinkMode(mode) return SUPPORTED_LINK_MODES[mode] == true end

function API.getDirAndPath(item)
    if not item or not item.data or not item.key then return nil, nil end
    local dir = BaseUtil.joinPath(API.storage_dir, item.key)
    local filename = item.data.filename or API.basenameOfPath(item.data.path) or (item.key .. ".pdf")
    return dir, BaseUtil.joinPath(dir, filename)
end

local function cached_current(path, item)
    if not file_exists(path) then return false end
    local ds = DocSettings:open(path)
    local v = tonumber(ds:readSetting("zoteroItemVersion", 0)) or 0
    ds:close()
    return v >= (tonumber(item.version) or 0)
end

function API.resolveAttachmentPath(item)
    if not item or not item.data or not API.isSupportedAttachmentLinkMode(item.data.linkMode) then return nil end
    local allow_stale = API.getAllowStaleLocal()
    if item.data.linkMode == "linked_file" and API.getLinkedFilesEnabled() then
        local p = API.resolveLinkedPath(item.data.path, API.getLinkedFilesBase(), API.getPathMappings())
        if p and file_exists(p) then return p end
        if item.data.filename then local f = API.findAttachmentByBasename(item.data.filename); if f then return f end end
    end
    if item.data.linkMode == "imported_file" or item.data.linkMode == "imported_url" then
        if API.getExternalStorageEnabled() and API.getExternalStorageDir() ~= "" and item.data.filename then
            local p = API.normalizePath(BaseUtil.joinPath(API.getExternalStorageDir(), item.key, item.data.filename))
            if file_exists(p) and (allow_stale or cached_current(p,item)) then return p end
        end
        local _, p = API.getDirAndPath(item)
        if p and file_exists(p) and (allow_stale or cached_current(p,item)) then return p end
        if item.data.filename then local f = API.findAttachmentByBasename(item.data.filename); if f then return f end end
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
        local _, p = API.getDirAndPath(item); table.insert(probe.probes, probe_entry("Plugin cache", p)); if not probe.foundPath and file_exists(p) then probe.foundPath=p end
    end
    if not probe.foundPath and item.data.filename then
        local p = API.findAttachmentByBasename(item.data.filename)
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
        if item and item.data and API.isSupportedAttachmentLinkMode(item.data.linkMode) and table_contains(SUPPORTED_MEDIA_TYPES,item.data.contentType) then
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
        for _,p in ipairs(probe.probes) do table.insert(lines,(p.exists and "[OK] " or "[missing] ") .. tostring(p.label) .. ":"); table.insert(lines,"  "..tostring(p.path or "?")) end
    else table.insert(lines,"No paths to check for this item.") end
    table.insert(lines,"")
    table.insert(lines, probe.foundPath and ("First local file found:\n"..probe.foundPath) or "No local file found yet for this test.")
    return table.concat(lines,"\n")
end
function API.findAttachmentKeyByFilePath(file_path)
    if not file_path or file_path == "" then return nil end
    local db=API.openDB(); local stmt=db:prepare("SELECT itemData.value FROM itemData JOIN items USING(itemID) WHERE items.itemTypeID=3")
    local row=stmt:reset():step()
    while row do
        local item=safe_decode(row[1])
        if item and item.data then
            local probe=API.probeAttachmentResolution(item)
            if probe.foundPath and API.pathsEqual(probe.foundPath,file_path) then stmt:close(); return item.key end
            for _,e in ipairs(probe.probes) do if e.path and API.pathsEqual(e.path,file_path) then stmt:close(); return item.key end end
        end
        row=stmt:step(row)
    end
    stmt:close(); return nil
end
function API.tryResolveLocalAttachment(key)
    local item=API.getItem(key)
    if not item then return nil,"Error: the requested file can not be found in the database" end
    if not item.data or item.data.itemType ~= "attachment" then return nil,"Error: this item is not an attachment" end
    if not API.isSupportedAttachmentLinkMode(item.data.linkMode) then return nil,"Error: this item is not a supported attachment" end
    local p=API.resolveAttachmentPath(item)
    if p and file_exists(p) then return p,nil end
    return nil,nil
end

function API.getHeaders(api_key)
    return { ["zotero-api-key"] = api_key, ["zotero-api-version"] = "3" }
end
function API.verifyResponse(r,c,allowed)
    if r ~= 1 then return "Error: "..tostring(c) end
    c=tonumber(c)
    if allowed then for _,v in ipairs(allowed) do if c==v then return nil end end end
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

function API.getZoteroData(url)
    if not API.zoteroHeader then return nil,"Error: Zotero header not set. Check user ID and API key" end
    local body={}
    local r,c,h=https.request{method="GET",url=url,headers=API.zoteroHeader,sink=ltn12.sink.table(body)}
    local e=API.verifyResponse(r,c); if e then
        logger.warn("Zotero: GET failed", url, e)
        return nil,e
    end
    local raw=table.concat(body,"")
    local ok,result,decode_err=pcall(JSON.decode,raw)
    if not ok then
        local msg="Error: failed to parse Zotero JSON response: "..tostring(result)
        logger.warn("Zotero:",msg,"URL:",url,"body:",raw:sub(1,300))
        return nil,msg
    end
    if result == nil then
        local msg="Error: Zotero returned an empty or undecodable JSON response"
        if decode_err ~= nil then msg=msg..": "..readable_value(decode_err) end
        logger.warn("Zotero:",msg,"URL:",url,"body:",raw:sub(1,300))
        return nil,msg
    end
    return result,h or {}
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
    local _,e=API.checkZoteroKey(ZOTERO_BASE_URL.."/keys/current")
    if e then return e end
    API.zoteroAcessVerified=true
    return nil
end
function API.fetchCollectionSize(url,headers)
    local r,c,h=https.request{method="HEAD",url=url,headers=headers}
    local e=API.verifyResponse(r,c); if e then return nil,e end
    local n=tonumber(h and h["total-results"]); if not n then return nil,"Error: could not determine number of items in library" end
    -- Success follows the plugin's (value, error) convention.
    -- Returning the response headers as the second value made the caller treat
    -- every successful HEAD request as an error.
    return n,nil
end
function API.fetchCollectionPaginated(url,headers,callback)
    local size,e=API.fetchCollectionSize(url,headers); if e then return nil,e end
    local all, version, step = {}, API.getUserLibraryVersion(), 100
    if size==0 then
        if callback then callback({},100) end
        return callback and version or all,nil
    end
    for start=0,size-1,step do
        local sep=url:find("?",1,true) and "&" or "?"
        local page_url=url..sep.."limit="..step.."&start="..start
        local result,h=API.getZoteroData(page_url); if not result then return nil,h end
        version=tonumber(h["last-modified-version"]) or version
        local pct=math.min(100,100*(start+#result)/size)
        if callback then callback(result,pct) else for _,v in ipairs(result) do table.insert(all,v) end end
    end
    return callback and version or all,nil
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

local function type_id(type_name)
    return tonumber(API.openDB():rowexec("SELECT itemTypeID FROM itemTypes WHERE typeName='"..tostring(type_name):gsub("'","''").."'"))
end
local function upsert_item(item)
    if not item or not item.key or not item.data then return end
    local db=API.openDB(); local tid=type_id(item.data.itemType) or type_id("document") or 13
    local stmt=db:prepare([[INSERT INTO items(itemTypeID,libraryID,key,version) VALUES(?,1,?,?) ON CONFLICT(libraryID,key) DO UPDATE SET itemTypeID=excluded.itemTypeID,version=excluded.version]])
    stmt:bind(tid,item.key,tonumber(item.version) or 0):step(); stmt:close()
    stmt=db:prepare([[INSERT INTO itemData(itemID,value) SELECT itemID,? FROM items WHERE key=? ON CONFLICT(itemID) DO UPDATE SET value=excluded.value]])
    stmt:bind(JSON.encode(item),item.key):step(); stmt:close()
end
local function delete_item(key)
    local stmt=API.openDB():prepare("DELETE FROM items WHERE key=?"); stmt:bind(key):step(); stmt:close()
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

function API.fetchZoteroCollections(since,progress_callback)
    since=tonumber(since) or API.getUserLibraryVersion(); local e=API.verifyZoteroAccess(); if e then return nil,e end
    local callback=progress_callback or function() end
    local url=API.userLibraryURL.."/collections?since="..since.."&format=json"
    local nested={}
    local version,err=API.fetchCollectionPaginated(url,API.zoteroHeader,function(entries,pct)
        callback(string.format("Syncing collections %.0f%%",pct))
        local db=API.openDB()
        for _,entry in ipairs(entries) do
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
    if err then return nil,err end
    local db=API.openDB(); local st=db:prepare("UPDATE collections SET parentCollectionID=(SELECT collectionID FROM collections WHERE key=?) WHERE key=?")
    for child,parent in pairs(nested) do st:reset():bind(parent,child):step() end; st:close()
    return tonumber(version) or since,nil
end

function API.fetchZoteroItems(since,progress_callback)
    since=tonumber(since) or API.getUserLibraryVersion(); local e=API.verifyZoteroAccess(); if e then return nil,e end
    local callback=progress_callback or function() end
    local deleted=API.getZoteroData(API.userLibraryURL.."/deleted?since="..since)
    if type(deleted)=="table" then
        for _,key in ipairs(deleted.items or {}) do delete_item(key) end
        local db=API.openDB(); local st=db:prepare("DELETE FROM collections WHERE key=?"); for _,key in ipairs(deleted.collections or {}) do st:reset():bind(key):step() end; st:close()
    end
    local attachments,annotations={},{}
    local annotation_types=Annotations.supportedZoteroTypes()
    local url=API.userLibraryURL.."/items?since="..since.."&format=json"
    local version,err=API.fetchCollectionPaginated(url,API.zoteroHeader,function(entries,pct)
        callback(string.format("Syncing items %.0f%%",pct))
        for _,item in ipairs(entries) do
            if item.data and item.data.deleted then delete_item(item.key)
            else
                item.links=nil; item.library=nil; upsert_item(item)
                if item.data then
                    if item.data.itemType=="attachment" and table_contains(SUPPORTED_MEDIA_TYPES,item.data.contentType) then attachments[item.key]=item.data.parentItem or item.key
                    elseif item.data.itemType=="annotation" and table_contains(annotation_types,item.data.annotationType) then annotations[item.key]=item.data.parentItem end
                end
            end
        end
    end)
    if err then return nil,err end
    local index_err=API.checkItemData(callback)
    if index_err then return nil,index_err end
    -- checkItemData rebuilt attachment/annotation relationships for the whole
    -- local library, so no second partial relationship pass is needed here.
    return tonumber(version) or since,nil
end

function API.checkItemData(progress_callback)
    local db=API.openDB()
    local total=tonumber(db:rowexec("SELECT COUNT(*) FROM itemData")) or 0
    if progress_callback then progress_callback("Rebuilding local index…") end

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
        local types=Annotations.supportedZoteroTypes()
        local row=stmt:reset():step()
        local count=0
        local progress_step=math.max(math.floor(total/100),10)
        while row do
            local item=safe_decode(row[1])
            if item and item.data then
                local cols=item.data.collections or {}
                if #cols==0 then
                    colstmt:reset():bind("/",item.key):step()
                else
                    for _,c in ipairs(cols) do colstmt:reset():bind(c,item.key):step() end
                end
                if item.data.itemType=="attachment" and table_contains(SUPPORTED_MEDIA_TYPES,item.data.contentType) then
                    attachments[item.key]=item.data.parentItem or item.key
                end
                if item.data.itemType=="annotation" and table_contains(types,item.data.annotationType) then
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
    while row do local item=safe_decode(row[2]); local d=item and item.data or {}; table.insert(out,{key=row[1],text=d.filename or d.title or row[1],type="attachment",is_pdf=d.contentType=="application/pdf",contentType=d.contentType,title=d.title or d.filename or row[1],version=item and item.version or 0}); row=stmt:step(row) end
    stmt:close(); table.sort(out,function(a,b) if a.is_pdf~=b.is_pdf then return a.is_pdf end return (a.text or "")<(b.text or "") end); return out
end
function API.getItemWithAttachments(key)
    local item=API.getItem(key); if not item then return nil end
    local list=API.getItemAttachments(key); local attachments={}
    for _,x in ipairs(list) do local ai=API.getItem(x.key); if ai and ai.data then local d=ai.data; local sv,ls=API.getAttachmentVersion(x.key); d.syncedVersion=sv; d.lastSync=ls; table.insert(attachments,d) end end
    item.attachments=attachments; return item
end

function API.displayCollection(key)
    key=key or "/"; local db=API.openDB(); local out={}
    local cid=tonumber(db:rowexec("SELECT collectionID FROM collections WHERE key='"..key:gsub("'","''").."'")); if not cid then return out end
    local st=db:prepare("SELECT key,collectionName FROM collections WHERE parentCollectionID=? ORDER BY collectionName COLLATE NOCASE"); local row=st:bind(cid):step()
    while row do table.insert(out,{key=row[1],text=(row[2] or "").."/",type="collection"}); row=st:step(row) end; st:close()
    st=db:prepare([[SELECT i.key,d.value,t.typeName FROM collectionItems ci JOIN items i ON i.itemID=ci.itemID JOIN itemData d ON d.itemID=i.itemID JOIN itemTypes t ON t.itemTypeID=i.itemTypeID WHERE ci.collectionID=? AND t.typeName NOT IN ('annotation')]])
    row=st:bind(cid):step()
    while row do
        local item=safe_decode(row[2]); local d=item and item.data or {}; local meta=item and item.meta or {}; local text=d.title or d.filename or row[1]; if meta.creatorSummary and meta.creatorSummary~="" then text=meta.creatorSummary.." - "..text end
        local tp=row[3]=="attachment" and "attachment" or "item"; table.insert(out,{key=row[1],text=text,type=tp,is_pdf=d.contentType=="application/pdf"}); row=st:step(row)
    end
    st:close(); return out
end
function API.displaySearchResults(query)
    query=string.lower(query or ""); local db=API.openDB(); local out={}; local st=db:prepare([[SELECT i.key,d.value,t.typeName FROM items i JOIN itemData d USING(itemID) JOIN itemTypes t USING(itemTypeID) WHERE t.typeName NOT IN ('annotation')]])
    local row=st:reset():step(); while row do local item=safe_decode(row[2]); local d=item and item.data or {}; local meta=item and item.meta or {}; local text=d.title or d.filename or row[1]; if meta.creatorSummary and meta.creatorSummary~="" then text=meta.creatorSummary.." - "..text end; if query=="" or string.lower(text):find(query,1,true) then table.insert(out,{key=row[1],text=text,type=row[3]=="attachment" and "attachment" or "item"}) end; row=st:step(row) end; st:close(); table.sort(out,function(a,b) return a.text<b.text end); return out
end

function API.getAttachmentVersion(key)
    local st=API.openDB():prepare([[SELECT a.syncedVersion,a.lastSync,i.version,i.itemID FROM itemAttachments a JOIN items i ON i.itemID=a.itemID WHERE i.key=?]])
    local row=st:bind(key):step(); if not row then st:close(); return nil end
    local a,b,c,d=tonumber(row[1]),tonumber(row[2]),tonumber(row[3]),tonumber(row[4]); st:close(); return a,b,c,d
end
function API.setAttachmentVersion(id,v)
    local st=API.openDB():prepare("UPDATE itemAttachments SET syncedVersion=?,lastSync=unixepoch('now') WHERE itemID=?"); st:bind(v,id):step(); st:close()
end
function API.setAttachmentVersionByKey(key,v)
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

local function write_doc_metadata(path,item)
    local ds=DocSettings:open(path); ds:saveSetting("zoteroItemVersion",tonumber(item.version) or 0); ds:saveSetting("zoteroLibVersion",API.getUserLibraryVersion()); ds:flush(); ds:close()
end
function API.downloadWebDAV(key,targetDir,targetPath)
    local base=API.getWebDAVUrl(); if base=="" then return nil,"WebDAV url not set" end
    mkdir_p(targetDir); local zip=BaseUtil.joinPath(targetDir,key..".zip"); local f=io.open(zip,"wb"); if not f then return nil,"Could not create WebDAV zip" end
    local r,c=https.request{method="GET",url=base:gsub("/$","").."/"..key..".zip",headers=API.getWebDAVHeaders(),sink=ltn12.sink.file(f)}
    local e=API.verifyResponse(r,c); if e then os.remove(zip); return nil,e end
    local ok=false
    if BaseUtil.extractArchive then ok=pcall(BaseUtil.extractArchive,zip,targetDir) end
    if not ok then
        local cmd=string.format("unzip -o %q -d %q >/dev/null 2>&1",zip,targetDir); ok=(os.execute(cmd)==0 or os.execute(cmd)==true)
    end
    os.remove(zip); if not ok then return nil,"Unzipping failed" end
    if file_exists(targetPath) then return targetPath end
    return API.findFileByBasename(targetDir,API.basenameOfPath(targetPath)) or targetPath
end
function API.downloadAndGetPath(key,download_callback)
    local item=API.getItem(key); if not item then return nil,"Error: the requested file can not be found in the database" end
    if not item.data or item.data.itemType~="attachment" then return nil,"Error: this item is not an attachment" end
    if not API.isSupportedAttachmentLinkMode(item.data.linkMode) then return nil,"Error: this item has unsupported link mode" end
    if not table_contains(SUPPORTED_MEDIA_TYPES,item.data.contentType) then return nil,"Error: this item has an unsupported content type ("..tostring(item.data.contentType)..")" end
    local local_path=API.resolveAttachmentPath(item); if local_path and file_exists(local_path) then API.getAttachmentInfo(item,local_path); pcall(API.attachItemAnnotations,item,nil,local_path); return local_path,nil end
    if item.data.linkMode=="linked_file" then return nil,"Linked file not found locally" end
    local e=API.verifyZoteroAccess(); if e then return nil,e end
    local dir,path=API.getDirAndPath(item); mkdir_p(dir); if download_callback then download_callback() end
    if API.getWebDAVEnabled() then local p,err=API.downloadWebDAV(key,dir,path); if not p then return nil,err end; path=p
    else
        local f=io.open(path,"wb"); if not f then return nil,"Could not create attachment file" end
        local r,c=https.request{url=API.userLibraryURL.."/items/"..key.."/file",headers=API.zoteroHeader,sink=ltn12.sink.file(f)}
        local err=API.verifyResponse(r,c); if err then os.remove(path); return nil,err end
    end
    write_doc_metadata(path,item); API.getAttachmentInfo(item,path); pcall(API.attachItemAnnotations,item,nil,path); API.setAttachmentVersionByKey(key,item.version or 0); return path,nil
end
function API.batchDownload(progress_callback)
    progress_callback=progress_callback or function() end; local db=API.openDB(); local st=db:prepare([[SELECT i.key,d.value FROM itemAttachments a JOIN items i ON i.itemID=a.itemID JOIN itemData d ON d.itemID=i.itemID WHERE a.parentItemID IN (SELECT ci.itemID FROM collectionItems ci JOIN collections c ON c.collectionID=ci.collectionID WHERE c.synced=1)]])
    local rows={}; local row=st:reset():step(); while row do table.insert(rows,{row[1],row[2]}); row=st:step(row) end; st:close(); local fails,details=0,{}
    for i,v in ipairs(rows) do local item=safe_decode(v[2]); local filename=item and item.data and item.data.filename or v[1]; progress_callback(string.format(_("Downloading attachment %i/%i"),i,#rows)); local _,err=API.downloadAndGetPath(v[1]); if err then fails=fails+1; table.insert(details,{filename=filename,error=err}) end end
    return fails,details
end

function API.createItems(items)
    if #items==0 then return {},nil end; local e=API.verifyZoteroAccess(); if e then return nil,e end
    local created, fails={},{}; local max=50
    for start=1,#items,max do
        local batch={}; for i=start,math.min(start+max-1,#items) do table.insert(batch,items[i]) end
        local body=JSON.encode(batch); local headers=content_headers(API.zoteroHeader,body); headers["If-Unmodified-Since-Version"]=tostring(API.getUserLibraryVersion())
        local response={}; local r,c,h=https.request{method="POST",url=API.userLibraryURL.."/items",headers=headers,source=ltn12.source.string(body),sink=ltn12.sink.table(response)}
        local err=API.verifyResponse(r,c); if err then return created,err end
        local result=safe_decode(table.concat(response,"")) or {}; for k,v in pairs(result.successful or {}) do created[start+tonumber(k)]=v end; for k,v in pairs(result.unchanged or {}) do created[start+tonumber(k)]={key=v} end; for _,v in pairs(result.failed or {}) do table.insert(fails,v) end
        if h and h["last-modified-version"] then API.setUserLibraryVersion(h["last-modified-version"]) end
    end
    return created,#fails>0 and fails or nil
end
function API.updateItems(items)
    if #items==0 then return {},nil end; local e=API.verifyZoteroAccess(); if e then return nil,e end
    local updated,fails={},{}; local max=50
    for start=1,#items,max do
        local batch={}; for i=start,math.min(start+max-1,#items) do table.insert(batch,items[i]) end
        local body=JSON.encode(batch); local headers=content_headers(API.zoteroHeader,body); headers["If-Unmodified-Since-Version"]=tostring(API.getUserLibraryVersion())
        local response={}; local r,c,h=https.request{method="POST",url=API.userLibraryURL.."/items",headers=headers,source=ltn12.source.string(body),sink=ltn12.sink.table(response)}
        local err=API.verifyResponse(r,c); if err then return updated,err end
        local result=safe_decode(table.concat(response,"")) or {}; for k,v in pairs(result.successful or {}) do updated[start+tonumber(k)]=v end; for k,v in pairs(result.unchanged or {}) do updated[start+tonumber(k)]={key=v} end; for _,v in pairs(result.failed or {}) do table.insert(fails,v) end
        if h and h["last-modified-version"] then API.setUserLibraryVersion(h["last-modified-version"]) end
    end
    return updated,#fails>0 and fails or nil
end
function API.deleteItems(items)
    if #items==0 then return 0,{} end; local e=API.verifyZoteroAccess(); if e then return #items,{} end
    local fails,ok=0,{}
    for _,entry in ipairs(items) do
        local key=type(entry)=="table" and entry.key or entry; local version=type(entry)=="table" and entry.version or API.getItemVersion(key)
        local headers=copy_table(API.zoteroHeader); headers["If-Unmodified-Since-Version"]=tostring(version or API.getUserLibraryVersion())
        local r,c=https.request{method="DELETE",url=API.userLibraryURL.."/items/"..key,headers=headers}
        c=tonumber(c); if r==1 and (c==204 or c==404) then table.insert(ok,key) else fails=fails+1 end
    end
    return fails,ok
end

function API.syncAnnotationsForAttachment(key,file_path)
    -- Annotation round-trip is currently supported only for PDF and EPUB.
    -- HTML/snapshot files must not be fed through the EPUB position converter.
    if not (Annotations.isPdfPath(file_path) or Annotations.isEpubPath(file_path)) then
        logger.warn("Zotero: skipping annotation sync for unsupported file type: " .. tostring(file_path))
        return 0,0,0,"unsupported file type"
    end

    local ds=DocSettings:open(file_path)
    local local_anns=ds:readSetting("annotations",{}) or {}
    ds:close()

    -- SAFETY: Remote deletion propagation is intentionally disabled for now.
    -- A failed/shifted import can make a valid Zotero annotation absent from the
    -- KOReader sidecar, and absence is not sufficient proof that the user deleted it.
    local delete_fails=0

    local upload_fails, create_err=Annotations.createAnnotations(file_path,key,API.createItems)
    upload_fails=upload_fails or 0
    local update_fails, update_err=Annotations.updateAnnotations(file_path,key,API.updateItems,API.getItem)
    update_fails=update_fails or 0

    if upload_fails==0 and delete_fails==0 and update_fails==0 then
        local q=API.openDB():prepare("UPDATE itemAttachments SET lastSync=unixepoch('now') WHERE itemID IN (SELECT itemID FROM items WHERE key=?)")
        q:bind(key):step(); q:close()
    end
    return upload_fails,delete_fails,update_fails,create_err or update_err
end

function API.syncAnnotations(progress_callback)
    progress_callback=progress_callback or function() end
    local db=API.openDB()
    local st=db:prepare([[SELECT i.key,d.value FROM itemAttachments a JOIN items i ON i.itemID=a.itemID JOIN itemData d ON d.itemID=i.itemID WHERE a.syncedVersion>0]])
    local rows={}
    local row=st:reset():step()
    while row do table.insert(rows,{row[1],row[2]}); row=st:step(row) end
    st:close()

    local uf,df,upf=0,0,0
    local skipped,errors=0,0
    for i,v in ipairs(rows) do
        progress_callback(string.format("Syncing annotations %d/%d",i,#rows))
        local item=safe_decode(v[2])
        local path=item and API.resolveAttachmentPath(item)
        if not path and item then
            local _,p=API.getDirAndPath(item)
            if file_exists(p) then path=p end
        end
        if path then
            if not (Annotations.isPdfPath(path) or Annotations.isEpubPath(path)) then
                skipped=skipped+1
                logger.warn("Zotero: global annotation sync skipping unsupported attachment: " .. tostring(path))
            else
                local ok,a,b,c,e=pcall(API.syncAnnotationsForAttachment,v[1],path)
                if ok then
                    uf=uf+(a or 0); df=df+(b or 0); upf=upf+(c or 0)
                    if e and e ~= "unsupported file type" then logger.warn("Zotero: annotation sync warning: " .. tostring(e)) end
                else
                    errors=errors+1
                    logger.err("Zotero: annotation sync failed for " .. tostring(path) .. ": " .. tostring(a))
                end
            end
        end
    end
    logger.info(string.format("Zotero: annotation sync completed; skipped=%d errors=%d create_fail=%d delete_fail=%d update_fail=%d", skipped, errors, uf, df, upf))
    return uf,df,upf,errors,skipped
end


function API.attachItemAnnotations(item, progress_callback, file_path)
    if not item or not item.key then return "Error: attachment item missing" end
    file_path=file_path or API.resolveAttachmentPath(item); if not file_path then local _,p=API.getDirAndPath(item); file_path=p end
    if not file_path or not file_exists(file_path) then return "Error: attachment file not found" end
    if not (Annotations.isPdfPath(file_path) or Annotations.isEpubPath(file_path)) then
        return "Error: annotation import supports PDF and EPUB only"
    end
    local db=API.openDB(); local st=db:prepare([[SELECT i.key,d.value FROM itemAnnotations a JOIN items i ON i.itemID=a.itemID JOIN itemData d ON d.itemID=i.itemID WHERE a.parentItemID IN (SELECT itemID FROM items WHERE key=?) ]])
    local zot={}; local row=st:bind(item.key):step(); while row do local ann=safe_decode(row[2]); if ann then zot[row[1]]=ann end; row=st:step(row) end; st:close()
    local ds=DocSettings:open(file_path); local local_anns=ds:readSetting("annotations",{}) or {}; local bykey={}; for idx,a in ipairs(local_anns) do if a.zoteroKey then bykey[a.zoteroKey]=idx end end
    local is_pdf=Annotations.isPdfPath(file_path); local pages={}; if is_pdf then for _,ann in pairs(zot) do local pos=safe_decode(ann.data and ann.data.annotationPosition); if pos and pos.pageIndex~=nil then pages[pos.pageIndex+1]=true end end end
    local dims=is_pdf and Annotations.getPageDimensions(file_path,pages) or {}
    for k,ann in pairs(zot) do
        local converted
        if is_pdf then local pos=safe_decode(ann.data.annotationPosition); local pg=pos and pos.pageIndex and pos.pageIndex+1; if pg and dims and dims[pg] then converted=Annotations.convertZoteroToKOReader(ann,dims[pg]) end
        else converted=Annotations.convertZoteroToKOReaderEpub(ann) end
        if converted then if bykey[k] then local_anns[bykey[k]]=converted else table.insert(local_anns,converted) end end
    end
    ds:saveSetting("annotations",local_anns); ds:saveSetting("zoteroLibVersion",API.getUserLibraryVersion()); ds:flush(); ds:close(); return nil
end

function API.getAttachmentInfo(item,targetPath)
    if not item or not item.data or not targetPath then return end
    local parent=item.data.parentItem and API.getItem(item.data.parentItem) or nil; local data=parent and parent.data or item.data
    local ds=DocSettings:open(targetPath)
    local authors={}; for _,v in ipairs(data.creators or {}) do local name=v.name or ((v.firstName or "").." "..(v.lastName or "")):gsub("^%s+",""):gsub("%s+$",""); if name~="" then table.insert(authors,name) end end
    local tags={}; for _,v in ipairs(data.tags or {}) do if v.tag then table.insert(tags,v.tag) end end
    ds:saveSetting("doc_props",{title=data.title,authors=table.concat(authors,", "),description=data.abstractNote,series=data.series,keywords=table.concat(tags,", "),language=data.language})
    ds:saveSetting("zoteroItemVersion",tonumber(item.version) or 0); ds:saveSetting("zoteroLibVersion",API.getUserLibraryVersion()); ds:flush(); ds:close()
end

function API.scanStorageDir(storage_dir,use_external_paths)
    if not storage_dir or storage_dir=="" or not file_exists(storage_dir) then return 0,{} end
    local found,extra=0,{}
    for name in lfs.dir(storage_dir) do if name~="." and name~=".." then local dir=BaseUtil.joinPath(storage_dir,name); if lfs.attributes(dir,"mode")=="directory" then local _,_,version,id=API.getAttachmentVersion(name); if id then local item=API.getItem(name); local path; if use_external_paths and item and item.data and item.data.filename then path=BaseUtil.joinPath(dir,item.data.filename) elseif item then local _,p=API.getDirAndPath(item); path=p end; if path and file_exists(path) then found=found+1; API.setAttachmentVersion(id,version or 1) end else table.insert(extra,name) end end end end
    return found,extra
end
function API.scanStorage()
    local a=select(1,API.scanStorageDir(API.storage_dir,false)); local b=0; if API.getExternalStorageEnabled() then b=select(1,API.scanStorageDir(API.getExternalStorageDir(),true)) end; return (a or 0)+(b or 0)
end

function API.searchAnnotations(query)
    query=string.lower(query or ""); local db=API.openDB(); local out={}; local st=db:prepare([[SELECT ai.key,ad.value,att.key,pd.value FROM itemAnnotations ia JOIN items ai ON ai.itemID=ia.itemID JOIN itemData ad ON ad.itemID=ai.itemID JOIN items att ON att.itemID=ia.parentItemID JOIN itemAttachments a ON a.itemID=att.itemID LEFT JOIN items parent ON parent.itemID=a.parentItemID LEFT JOIN itemData pd ON pd.itemID=parent.itemID]])
    local row=st:reset():step(); while row do local ann=safe_decode(row[2]); local parent=safe_decode(row[4]); local d=ann and ann.data or {}; local title=parent and parent.data and parent.data.title or ""; local text=d.annotationText or ""; local comment=d.annotationComment or ""; local hay=string.lower(text.." "..comment.." "..title); if query=="" or hay:find(query,1,true) then local page=""; local pos=safe_decode(d.annotationPosition); if pos and pos.pageIndex~=nil then page=tostring(pos.pageIndex+1) elseif d.annotationPageLabel then page=tostring(d.annotationPageLabel) end; table.insert(out,{key=row[1],attachmentKey=row[3],parentTitle=title,text=text,comment=comment,page=page,color=d.annotationColor,type=d.annotationType}) end; row=st:step(row) end; st:close(); return out
end

function API.syncAllItems(progress_callback)
    local callback=progress_callback or function() end
    local function stage(msg)
        logger.info("Zotero: sync stage:", msg)
        callback(msg)
    end
    local function errtext(stage_name, err)
        if type(err) == "string" then return err end
        local msg = "Error during " .. stage_name .. ": " .. readable_value(err)
        logger.warn("Zotero:", msg)
        return msg
    end

    stage("Checking Zotero access…")
    local e=API.verifyZoteroAccess(); if e then return errtext("access check", e) end
    local since=API.getUserLibraryVersion(); local warnings={}
    logger.info("Zotero: syncing from library version", since)

    if since>0 and API.access and API.access.user and API.access.user.write then
        stage("Synchronizing annotations…")
        local u,d,up=API.syncAnnotations(callback)
        if (u or 0)+(d or 0)+(up or 0)>0 then table.insert(warnings,string.format("Annotation sync errors: create %d, delete %d, update %d",u or 0,d or 0,up or 0)) end
    end

    stage("Synchronizing collections…")
    local cv,err=API.fetchZoteroCollections(since,callback); if err then return errtext("collection sync", err) end
    stage("Synchronizing items…")
    local iv; iv,err=API.fetchZoteroItems(since,callback); if err then return errtext("item sync", err) end
    API.setUserLibraryVersion(math.max(tonumber(cv) or since,tonumber(iv) or since))

    stage("Checking offline attachments…")
    local df,details=API.batchDownload(callback); if df>0 then table.insert(warnings,"Attachment download errors: "..df) end
    logger.info("Zotero: sync completed; library version", API.getUserLibraryVersion())
    return #warnings>0 and table.concat(warnings,"\n") or nil
end

return API
