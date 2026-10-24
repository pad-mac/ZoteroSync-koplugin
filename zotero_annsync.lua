--[[--
Runs annotation sync for documents: one that is open in the reader, or all
attachments whose files are on this device.

This is the only place that ties together the three parts:

    zoteroapi    the local copy of the Zotero library, and the Zotero web API
    zotero_doc   the document's annotations and the position converters
    zotero_sync  the merge logic
]]

local Annotations = require("annotations")
local Bg = require("zotero_bg")
local Doc = require("zotero_doc")
local DocSettings = require("docsettings")
local Sync = require("zotero_sync")
local ZoteroAPI = require("zoteroapi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local sha2 = require("ffi/sha2")

local Run = { fork = "0.6" }

-- ---------------------------------------------------------------------------
-- A document neither side changed since its last complete sync is not looked
-- at again: what both sides were then is noted (the state of Zotero's
-- annotations of the attachment and of its reading position; the size and
-- time of the document's settings file, which holds its annotations and the
-- place it was read to), and compared at the next sync.
-- ---------------------------------------------------------------------------

-- (a new version of the plugin looks at every document once more)
local FINGERPRINT = "1:" .. tostring(ZoteroAPI.version)

local function remote_fingerprint(key)
    local list = ZoteroAPI.annotationVersions(key)
    local pos, pver = ZoteroAPI.getRemotePosition(key)
    -- (and whether reading positions are synced at all)
    local settings = ZoteroAPI.getSettings()
    local positions = settings and settings:readSetting("sync_reading_position") ~= false
    return sha2.md5(FINGERPRINT .. "|" .. tostring(positions) .. "|" .. list .. "|" .. tostring(pos) .. "@" .. tostring(pver))
end

--- @return the fingerprint, and the file's time (nil: no settings file)
local function local_fingerprint(path)
    local file = DocSettings:findSidecarFile(path)
    if not file then return "none|" .. tostring(path) end
    local a = lfs.attributes(file) or {}
    return string.format("%s|%s|%s", file, tostring(a.modification), tostring(a.size)), tonumber(a.modification)
end

--- Has nothing changed on either side since the last complete sync?
-- (File times count in whole seconds: a settings file written in the second
-- its state was noted could have been written again unseen. Its note is not
-- trusted; the document is looked at once more.)
function Run.unchanged(key, path)
    local st = ZoteroAPI.attachmentState(key)
    if not st.annLocal or not st.annRemote then return false end
    local fp, noted_at = st.annLocal:match("^(.*)|@(%d+)$")
    noted_at = tonumber(noted_at)
    if not fp or not noted_at then return false end
    local now, mtime = local_fingerprint(path)
    if now ~= fp then return false end
    if mtime and mtime >= noted_at - 1 then return false end
    return st.annRemote == remote_fingerprint(key)
end

--- Note both sides as they are now (after a sync that left nothing to do).
function Run.noteSynced(key, path)
    ZoteroAPI.setAttachmentState(key, { annLocal = local_fingerprint(path) .. "|@" .. os.time(), annRemote = remote_fingerprint(key) })
end
function Run.forgetSynced(key)
    ZoteroAPI.setAttachmentState(key, { annLocal = false, annRemote = false })
end

local function settled(stats)
    return stats ~= nil and stats.pending == 0 and stats.failed == 0 and stats.conflicts == 0
end

local remote_api = {
    write = function(objects) return ZoteroAPI.writeObjects(objects) end,
    get = function(key) return ZoteroAPI.fetchItem(key) end,
    delete = function(key, version) return ZoteroAPI.deleteRemoteItem(key, version) end,
    store = function(item) return ZoteroAPI.storeItem(item) end,
    forget = function(key) return ZoteroAPI.forgetItem(key) end,
    mark_deleted = function(key) return ZoteroAPI.markDeleted(key) end,
}

local function kind_of(file_path)
    if Annotations.isPdfPath(file_path) then return "pdf" end
    if Annotations.isEpubPath(file_path) then return "epub" end
    if Annotations.isHtmlPath(file_path) then return "html" end
    return nil
end
Run.kindOf = kind_of

--- Sync the annotations of one attachment.
-- @param key        attachment key
-- @param file_path  the attachment's file on this device
-- @param opts.ui    the ReaderUI, when this very document is open in it
-- @param opts.guard see zotero_doc.openList
-- @param opts.push  upload local changes (needs the network and a key with write access)
-- @return stats (see zotero_sync), or nil and a reason
function Run.attachment(key, file_path, opts)
    opts = opts or {}
    local kind = kind_of(file_path)
    if not kind then return nil, "unsupported file type" end
    local remote, others = ZoteroAPI.getAttachmentAnnotations(key)
    local ui = opts.ui
    local list = ui and Doc.openList(ui, opts.guard) or Doc.closedList(file_path)
    local converter
    if kind == "pdf" then
        converter = Doc.pdfConverter(file_path, ui and ui.document or nil, remote)
    else
        converter = Doc.epubConverter(ui and ui.document or nil, kind)
    end
    local stored_tomb = list:get("zotero_deleted")
    local tomb = {}
    if type(stored_tomb) == "table" then
        for k, v in pairs(stored_tomb) do tomb[k] = v end
    end
    local env = {
        kind = kind,
        attachment_key = key,
        list = list,
        remote = remote,
        other_remote = others,
        deleted = function(k) return ZoteroAPI.wasDeleted(k) end,
        tomb = tomb,
        converter = converter,
        uploads = opts.push and true or false,
        stats = Sync.newStats(),
    }
    local ok, plan = pcall(Sync.reconcile, env)
    if not ok then
        logger.err("Zotero: annotation merge failed for", file_path, tostring(plan))
        pcall(converter.close)
        pcall(list.close, list)
        return nil, tostring(plan)
    end
    local pushed = false
    if #plan.ops > 0 then
        if opts.push then
            local pok, perr = pcall(Sync.push, env, plan, remote_api)
            if not pok then
                logger.err("Zotero: annotation upload failed for", file_path, tostring(perr))
                env.stats.pending = env.stats.pending + 1
            end
            pushed = true
        else
            Sync.countPending(env, plan)
        end
    end
    -- the document's delete log, when it changed
    local tomb_changed = type(stored_tomb) ~= "table" and next(env.tomb) ~= nil
    if type(stored_tomb) == "table" then
        for k, v in pairs(stored_tomb) do
            if env.tomb[k] ~= v then tomb_changed = true break end
        end
        for k in pairs(env.tomb) do
            if stored_tomb[k] == nil then tomb_changed = true break end
        end
    end
    if tomb_changed then
        if next(env.tomb) ~= nil then
            list:set("zotero_deleted", env.tomb)
        else
            list:set("zotero_deleted", nil)
        end
    end
    if list:get("zotero_attachment_key") ~= key then
        list:set("zotero_attachment_key", key)
    end
    pcall(converter.close)
    if ui then
        if pushed then list:flush() end
    else
        list:close() -- writes the sidecar only if something changed
    end
    if opts.push then pcall(ZoteroAPI.touchAttachmentSync, key) end
    return env.stats
end

--- The open document, if it is a Zotero attachment.
-- @return key, file path  (or nil)
function Run.identify(ui)
    if not ui or not ui.document or not ui.document.file then return nil end
    local file_path = ui.document.file
    local hint = ui.doc_settings and ui.doc_settings:readSetting("zotero_attachment_key")
    local ok, key = pcall(ZoteroAPI.findAttachmentKeyByFilePath, file_path, hint)
    if not ok then
        logger.warn("Zotero: attachment lookup failed:", tostring(key))
        return nil
    end
    if not key then return nil end
    return key, file_path
end

--- Bring the open document up to date with the local copy of the library.
-- No network: this is what runs when a document is opened.
-- @return stats or nil, and the number of repaired entries
function Run.openDocument(ui, guard, opts)
    opts = opts or {}
    local key, file_path = Run.identify(ui)
    if not key then return nil end
    pcall(ZoteroAPI.markAttachmentPresent, key)
    if not kind_of(file_path) then return nil end
    local removed, restored = 0, 0
    if ui.rolling then
        local ok, a, b = pcall(Doc.repairRolling, ui)
        if ok then removed, restored = a or 0, b or 0 end
    end
    local stats, err = Run.attachment(key, file_path, { ui = ui, guard = guard, push = opts.push })
    if not stats then
        logger.warn("Zotero: annotation import failed:", tostring(err))
    end
    return stats, removed + restored
end

--- The document open in the reader now (it may change while a sync runs in
-- the background), with a guard for changes made to it.
local function open_reader(ui)
    if type(ui) == "function" then ui = ui() end
    if not ui or not ui.document or not ui.document.file then return nil end
    return ui
end
local function guard_of(ui, guard)
    if type(guard) == "function" then return guard end
    local plugin = ui and ui.zoteroatelier
    if plugin and plugin.guarded then return function(fn) return plugin:guarded(fn) end end
    return nil
end

--- Sync the annotations of every attachment that is on this device.
-- Each document is one piece of work that nothing the user does can come in
-- between (zotero_bg: a critical section); between two documents the reader
-- gets its turn, and the sync can be stopped.
-- @param progress  function(message, fraction) -> false to stop
-- @param ui        the ReaderUI if a document is open, or a function that
--                  returns the one open now (it is synced live; its sidecar
--                  file is never written behind the reader's back)
-- @param guard     function(fn) for changes to the open document (default:
--                  that reader's plugin's)
-- @param push      upload local changes (where the key may write)
-- @param each      optional function(key, path, is_open) -> result, called for
--                  every attachment whose document is on this device (the
--                  reading position); a result "failed" counts as unsettled
-- @return summary lines, problem lines, stats
function Run.all(progress, ui, guard, push, each)
    progress = progress or function() end
    local function visit(key, path, is_open, reader)
        if not each then return nil end
        local ok, res = pcall(each, key, path, is_open, reader)
        if not ok then logger.warn("Zotero: per-document step failed for", path, tostring(res)); return "failed" end
        return res
    end
    local total = Sync.newStats()
    local open_done = false
    local list = ZoteroAPI.getLocalAttachments()
    local errors, shared, skipped, read_only = 0, 0, 0, 0
    local stopped = false
    ZoteroAPI.beginFileIndex()
    local function one(entry, i)
        local item = entry.item
        local path = ZoteroAPI.resolveAttachmentPath(item, true) or ZoteroAPI.resolveAttachmentPath(item)
        if not path then
            local _, p = ZoteroAPI.getDirAndPath(item)
            if p and lfs.attributes(p, "mode") == "file" then path = p end
        end
        if path and kind_of(path) and ZoteroAPI.findAttachmentKeyByFilePath(path, entry.key) ~= entry.key then
            -- The file found for this attachment cannot be told apart from
            -- another attachment's file (same file name, not in a folder of
            -- its own). Its annotations are left alone rather than risk
            -- putting them into the wrong document.
            logger.warn("Zotero: annotation sync skipped for attachment", entry.key, "- its file is not unambiguous:", path)
            shared = shared + 1
            path = nil
        end
        if not (path and kind_of(path)) then return end
        local reader = open_reader(ui)
        local is_open = reader ~= nil and ZoteroAPI.pathsEqual(path, reader.document.file)
        if not is_open and Run.unchanged(entry.key, path) then
            skipped = skipped + 1
            return
        end
        -- nothing to do for a document that has no annotations on either side
        -- (and no settings file is made for one that was never opened here)
        if not is_open and ZoteroAPI.annotationVersions(entry.key) == "" and not DocSettings:hasSidecarFile(path) then
            visit(entry.key, path, false, reader)
            return
        end
        local can_push = push and ZoteroAPI.canWrite(entry.key)
        local stats, err
        if is_open then
            open_done = true
            stats, err = Run.attachment(entry.key, path, { ui = reader, guard = guard_of(reader, guard), push = can_push })
        else
            stats, err = Run.attachment(entry.key, path, { push = can_push })
        end
        local held = false
        if stats then
            if push and not can_push and stats.pending > 0 then
                -- (a library this key may only read: the document is looked
                -- at again next time)
                held = true
                if ZoteroAPI.libraryOfKey(entry.key).type == "group" then read_only = read_only + stats.pending end
            end
            Sync.addStats(total, stats)
        else
            errors = errors + 1
            logger.warn("Zotero: annotation sync failed for", path, tostring(err))
        end
        local result = visit(entry.key, path, is_open, reader)
        if not is_open then
            if settled(stats) and not held and result ~= "failed" then
                Run.noteSynced(entry.key, path)
            else
                Run.forgetSynced(entry.key)
            end
        end
    end
    local ok, perr = pcall(function()
        for i, entry in ipairs(list) do
            if progress(string.format("Syncing annotations %d/%d", i, #list), #list > 0 and i / #list or nil) == false or Bg.stopped() then
                stopped = true
                break
            end
            Bg.critical(one, entry, i)
        end
    end)
    ZoteroAPI.endFileIndex()
    if not ok then error(perr, 0) end
    -- the open document, when it was not in the list (opened from outside the plugin)
    local reader = open_reader(ui)
    if reader and not open_done and not stopped then
        Bg.critical(function()
            reader = open_reader(ui)
            if not reader then return end
            local key, file_path = Run.identify(reader)
            if key and kind_of(file_path) then
                pcall(ZoteroAPI.markAttachmentPresent, key)
                local stats = Run.attachment(key, file_path, { ui = reader, guard = guard_of(reader, guard), push = push and ZoteroAPI.canWrite(key) })
                if stats then Sync.addStats(total, stats) end
                visit(key, file_path, true, reader)
            end
        end)
    end
    local done, problems = Sync.summary(total)
    if errors > 0 then
        problems[#problems + 1] = string.format("%d document(s) could not be processed (see crash.log)", errors)
    end
    if shared > 0 then
        problems[#problems + 1] = string.format("%d document(s) skipped: several Zotero attachments have a file of the same name (see crash.log)", shared)
    end
    if read_only > 0 then
        problems[#problems + 1] = string.format("%d change(s) in group libraries not uploaded: the API key (or your role in the group) does not allow writing there", read_only)
    end
    total.skipped_unchanged = skipped
    total.stopped = stopped
    logger.info("Zotero: annotation sync finished:", table.concat(done, "; "), "|", table.concat(problems, "; "), "|", skipped, "unchanged documents skipped")
    return done, problems, total
end

return Run
