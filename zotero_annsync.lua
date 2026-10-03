--[[--
Runs annotation sync for documents: one that is open in the reader, or all
attachments whose files are on this device.

This is the only place that ties together the three parts:

    zoteroapi    the local copy of the Zotero library, and the Zotero web API
    zotero_doc   the document's annotations and the position converters
    zotero_sync  the merge logic
]]

local Annotations = require("annotations")
local Doc = require("zotero_doc")
local DocSettings = require("docsettings")
local Sync = require("zotero_sync")
local ZoteroAPI = require("zoteroapi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Run = { fork = "0.6" }

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
        converter = Doc.epubConverter(ui and ui.document or nil)
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

--- Sync the annotations of every attachment that is on this device.
-- @param progress  function(message)
-- @param ui        the ReaderUI if a document is open (it is synced live;
--                  its sidecar file is never written behind the reader's back)
-- @param each      optional function(key, path, is_open), called for every
--                  attachment whose document is on this device
-- @return summary lines, problem lines, stats
function Run.all(progress, ui, guard, push, each)
    progress = progress or function() end
    local function visit(key, path, is_open)
        if not each then return end
        local ok, err = pcall(each, key, path, is_open)
        if not ok then logger.warn("Zotero: per-document step failed for", path, tostring(err)) end
    end
    local total = Sync.newStats()
    local open_file = ui and ui.document and ui.document.file or nil
    local open_done = false
    local list = ZoteroAPI.getLocalAttachments()
    local errors, shared = 0, 0
    local stopped = false
    for i, entry in ipairs(list) do
        local item = entry.item
        local path = ZoteroAPI.resolveAttachmentPath(item)
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
        if path and kind_of(path) then
            local is_open = open_file ~= nil and ZoteroAPI.pathsEqual(path, open_file)
            -- nothing to do for a document that has no annotations on either side
            local has_remote = next((ZoteroAPI.getAttachmentAnnotations(entry.key))) ~= nil
            if is_open or has_remote or DocSettings:hasSidecarFile(path) then
                if progress(string.format("Syncing annotations %d/%d", i, #list)) == false then
                    stopped = true
                    break
                end
                local stats, err
                if is_open then
                    open_done = true
                    stats, err = Run.attachment(entry.key, path, { ui = ui, guard = guard, push = push })
                else
                    stats, err = Run.attachment(entry.key, path, { push = push })
                end
                if stats then
                    Sync.addStats(total, stats)
                else
                    errors = errors + 1
                    logger.warn("Zotero: annotation sync failed for", path, tostring(err))
                end
            end
            visit(entry.key, path, is_open)
        end
    end
    -- the open document, when it was not in the list (opened from outside the plugin)
    if ui and not open_done and not stopped then
        local key, file_path = Run.identify(ui)
        if key and kind_of(file_path) then
            pcall(ZoteroAPI.markAttachmentPresent, key)
            local stats = Run.attachment(key, file_path, { ui = ui, guard = guard, push = push })
            if stats then Sync.addStats(total, stats) end
            visit(key, file_path, true)
        end
    end
    local done, problems = Sync.summary(total)
    if errors > 0 then
        problems[#problems + 1] = string.format("%d document(s) could not be processed (see crash.log)", errors)
    end
    if shared > 0 then
        problems[#problems + 1] = string.format("%d document(s) skipped: several Zotero attachments have a file of the same name (see crash.log)", shared)
    end
    logger.info("Zotero: annotation sync finished:", table.concat(done, "; "), "|", table.concat(problems, "; "))
    return done, problems, total
end

return Run
