--[[--
Updates of the plugin itself, from its GitHub releases.

A release is a tag (v0.13) with one file attached: zoteroatelier.koplugin.zip,
the plugin's folder as it is installed. An update:

1. asks GitHub for the latest release and compares its version with this one;
2. downloads the zip (GitHub hands it over through a second address) and
   checks it against the size and SHA-256 GitHub lists for it;
3. unpacks it beside the plugin's data and checks what came: the plugin's
   folder with its main files, every Lua file readable by the Lua compiler,
   and the version inside the files equal to the release's;
4. keeps a copy of the plugin as it is now, then puts the new files in place
   one by one (each written beside the old one first, then renamed over it).

The new version runs after KOReader has been restarted: what is loaded now
stays in memory until then. "Restore the previous version" puts the copy
back.

@module zotero_update
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local JSON = require("json")
local _ = require("gettext")

local Update = { fork = "0.6" }

Update.REPO = "pad-mac/ZoteroSync-koplugin"
Update.ASSET = "zoteroatelier.koplugin.zip"
Update.FOLDER = "zoteroatelier.koplugin"
-- files a release must have
local REQUIRED = { "_meta.lua", "main.lua", "zoteroapi.lua" }
local CHECK_INTERVAL = 20 * 3600 -- automatic checks: at most this often

-- ---------------------------------------------------------------------------
-- versions
-- ---------------------------------------------------------------------------

--- "0.12" from "Zotero Atelier 2.0 fork v0.12 (2026-10-24)", "v0.12", "0.12".
function Update.versionOf(text)
    if type(text) ~= "string" then return nil end
    return text:match("fork v(%d+[%.%d]*)") or text:match("^v?(%d+[%.%d]*)$")
end

--- Is version a newer than version b? (numbers, part by part: 0.10 > 0.9)
function Update.newer(a, b)
    if not a then return false end
    if not b then return true end
    local pa, pb = {}, {}
    for n in a:gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
    for n in b:gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- network
-- ---------------------------------------------------------------------------

local function socketutil()
    local ok, mod = pcall(require, "socketutil")
    return ok and type(mod) == "table" and mod.set_timeout and mod or nil
end

--- A GET request that follows redirects itself (the reader's HTTPS library
-- does not), into a sink. @return code, headers   or nil, error
local function get(url, sink_factory, accept)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local su = socketutil()
    for __ = 1, 6 do
        local sink, finish = sink_factory()
        if su then su:set_timeout(20, 120) end
        local ok, r, code, headers = pcall(https.request, {
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "zoteroatelier.koplugin updater",
                ["Accept"] = accept or "application/octet-stream",
            },
            sink = sink or ltn12.sink.null(),
            redirect = false,
        })
        if su then su:reset_timeout() end
        if finish then finish() end
        if not ok then return nil, tostring(r) end
        if r ~= 1 then return nil, tostring(code) end
        code = tonumber(code)
        local location = headers and (headers.location or headers.Location)
        if code and code >= 300 and code < 400 and location then
            url = location
        else
            return code, headers
        end
    end
    return nil, "too many redirects"
end

local function get_text(url, accept)
    local chunks = {}
    local code, headers = get(url, function()
        chunks = {}
        local sink = require("ltn12").sink.table(chunks) -- (it returns the table as well)
        return sink
    end, accept)
    if not code then return nil, headers end
    return code, table.concat(chunks)
end

local function get_file(url, path)
    local handle
    local function close()
        -- (the sink closes the file when the transfer ends; not when it breaks off)
        if handle then pcall(handle.close, handle) end
        handle = nil
    end
    local code, err = get(url, function()
        close()
        handle = io.open(path, "wb")
        if not handle then return nil end
        return require("ltn12").sink.file(handle), close
    end)
    close()
    return code, err
end

--- The latest release. @return { version, tag, url, size, digest, notes, page }   or nil, reason
function Update.latest()
    local code, body = get_text("https://api.github.com/repos/" .. Update.REPO .. "/releases/latest",
        "application/vnd.github+json")
    if not code then return nil, _("GitHub could not be reached") .. " (" .. tostring(body) .. ")" end
    if code == 404 then return nil, _("No release has been published yet") end
    if code == 403 or code == 429 then return nil, _("GitHub asks to wait before the next check (too many requests)") end
    if code ~= 200 then return nil, _("GitHub answered") .. " " .. tostring(code) end
    local ok, release = pcall(JSON.decode, body)
    if not ok or type(release) ~= "table" then return nil, _("GitHub's answer could not be read") end
    local version = Update.versionOf(release.tag_name)
    if not version then return nil, _("The latest release has no version number") .. " (" .. tostring(release.tag_name) .. ")" end
    local asset
    for __, a in ipairs(type(release.assets) == "table" and release.assets or {}) do
        if type(a) == "table" and a.name == Update.ASSET then asset = a end
    end
    if not asset or type(asset.browser_download_url) ~= "string" then
        return nil, _("The latest release has no plugin file") .. " (" .. Update.ASSET .. ")"
    end
    local digest = type(asset.digest) == "string" and asset.digest:match("^sha256:(%x+)$") or nil
    return {
        version = version,
        tag = release.tag_name,
        url = asset.browser_download_url,
        size = tonumber(asset.size),
        digest = digest and digest:lower() or nil,
        notes = type(release.body) == "string" and release.body or "",
        page = release.html_url,
    }
end

-- ---------------------------------------------------------------------------
-- files
-- ---------------------------------------------------------------------------

local function join(a, b) return a:gsub("/+$", "") .. "/" .. b end

local function mkdir_p(path)
    local acc = path:sub(1, 1) == "/" and "" or "."
    for part in path:gmatch("[^/]+") do
        acc = acc .. "/" .. part
        if lfs.attributes(acc, "mode") == nil then lfs.mkdir(acc) end
    end
    return lfs.attributes(path, "mode") == "directory"
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove_tree(join(path, name)) end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    local ok = f:write(data)
    f:close()
    return ok ~= nil
end

--- The plugin's files (it has no folders of its own). @return { name, ... }
local function list_files(dir)
    local out = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and lfs.attributes(join(dir, name), "mode") == "file" then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

--- Put the files of `from` into `to`, each written beside its old self first.
-- @return true   or nil, reason
local function put_files(from, to, names)
    for __, name in ipairs(names) do
        local data = read_file(join(from, name))
        if not data then return nil, "could not read " .. name end
        local tmp = join(to, name .. ".update-part")
        if not write_file(tmp, data) then
            os.remove(tmp)
            return nil, "could not write " .. name
        end
        if not os.rename(tmp, join(to, name)) then
            os.remove(tmp)
            return nil, "could not replace " .. name
        end
    end
    return true
end

local function version_in(dir)
    local api = read_file(join(dir, "zoteroapi.lua"))
    return api and Update.versionOf(api:match('version%s*=%s*"([^"]*)"'))
end

-- ---------------------------------------------------------------------------
-- install, restore
-- ---------------------------------------------------------------------------

--- Download, check and install a release.
-- @param release   from Update.latest()
-- @param plugin_dir the plugin's folder (the one KOReader loads)
-- @param work_dir   a folder of the plugin's data for the download and the copy
-- @return true   or nil, reason (and then nothing in plugin_dir was touched)
function Update.install(release, plugin_dir, work_dir)
    if type(release) ~= "table" or not release.url then return nil, "no release" end
    if lfs.attributes(join(plugin_dir, "main.lua"), "mode") ~= "file" then
        return nil, _("The plugin's folder was not found") .. " (" .. tostring(plugin_dir) .. ")"
    end
    if not mkdir_p(work_dir) then return nil, _("Could not create the update folder") end
    local zip = join(work_dir, "download.zip")
    local unpacked = join(work_dir, "unpacked")
    os.remove(zip)
    remove_tree(unpacked)

    -- 1. the file, as GitHub lists it
    local code, err = get_file(release.url, zip)
    if not code then
        os.remove(zip)
        return nil, _("The download failed") .. " (" .. tostring(err) .. ")"
    end
    if code ~= 200 then
        os.remove(zip)
        return nil, _("The download failed") .. " (" .. tostring(code) .. ")"
    end
    local data = read_file(zip)
    if not data or #data == 0 then return nil, _("The download is empty") end
    if release.size and #data ~= release.size then
        os.remove(zip)
        return nil, string.format(_("The download is incomplete (%d of %d bytes)"), #data, release.size)
    end
    if release.digest then
        local got = require("ffi/sha2").sha256(data):lower()
        if got ~= release.digest then
            os.remove(zip)
            return nil, _("The download does not match the checksum GitHub lists for it")
        end
    end
    data = nil -- luacheck: ignore

    -- 2. what is in it
    mkdir_p(unpacked)
    local extract = require("zoteroapi")._extractZip
    if not extract or not extract(zip, unpacked) then
        return nil, _("The download could not be unpacked")
    end
    local new_dir = join(unpacked, Update.FOLDER)
    if lfs.attributes(new_dir, "mode") ~= "directory" then
        return nil, _("The download does not contain the plugin's folder")
    end
    for __, name in ipairs(REQUIRED) do
        if lfs.attributes(join(new_dir, name), "mode") ~= "file" then
            return nil, _("The download lacks") .. " " .. name
        end
    end
    local names = list_files(new_dir)
    for __, name in ipairs(names) do
        if name:match("%.lua$") then
            local chunk, perr = loadfile(join(new_dir, name))
            if not chunk then
                return nil, _("A file of the download is damaged") .. " (" .. name .. ": " .. tostring(perr) .. ")"
            end
        end
    end
    local inside = version_in(new_dir)
    if inside ~= release.version then
        return nil, string.format(_("The download says it is version %s, the release %s"), tostring(inside), release.version)
    end

    -- 3. a copy of what is there now, then the new files
    local previous = join(work_dir, "previous")
    local current_names = list_files(plugin_dir)
    local backup_tmp = previous .. ".part"
    remove_tree(backup_tmp)
    mkdir_p(backup_tmp)
    local ok, cerr = put_files(plugin_dir, backup_tmp, current_names)
    if not ok then
        remove_tree(backup_tmp)
        return nil, _("Could not keep a copy of the current version") .. " (" .. tostring(cerr) .. ")"
    end
    remove_tree(previous)
    os.rename(backup_tmp, previous)
    ok, cerr = put_files(new_dir, plugin_dir, names)
    if not ok then
        -- (put back what was there; the copy is complete)
        put_files(previous, plugin_dir, current_names)
        return nil, _("The new files could not be put in place; the plugin is as it was") .. " (" .. tostring(cerr) .. ")"
    end
    os.remove(zip)
    remove_tree(unpacked)
    logger.info("Zotero: plugin updated to", release.version, "in", plugin_dir)
    return true
end

--- The version kept by the last update, if any.
function Update.previousVersion(work_dir)
    local previous = join(work_dir, "previous")
    if lfs.attributes(join(previous, "main.lua"), "mode") ~= "file" then return nil end
    return version_in(previous)
end

--- Put the kept version back. @return true   or nil, reason
function Update.restore(plugin_dir, work_dir)
    local previous = join(work_dir, "previous")
    if lfs.attributes(join(previous, "main.lua"), "mode") ~= "file" then
        return nil, _("There is no previous version")
    end
    local ok, err = put_files(previous, plugin_dir, list_files(previous))
    if not ok then return nil, err end
    return true
end

-- ---------------------------------------------------------------------------
-- when
-- ---------------------------------------------------------------------------

--- Is an automatic check due? (settings: the plugin's LuaSettings)
function Update.due(settings, now)
    if settings:readSetting("update_auto") == false then return false end
    local last = tonumber(settings:readSetting("update_last_check")) or 0
    return (now or os.time()) - last >= CHECK_INTERVAL
end

return Update
