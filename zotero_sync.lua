--[[--
Two-way annotation sync between one KOReader document and one Zotero
attachment.

The engine works on three things:

  * the local annotations of the document (through a small "list" adapter, so
    the same code serves an open document and a closed sidecar file),
  * the Zotero annotation items of the attachment, as stored in the local
    database by the last download from Zotero,
  * what both sides looked like the last time they agreed. That state travels
    inside each annotation:

        zoteroKey      the Zotero item it is linked to
        zoteroVersion  the item version last merged (0 = upload not confirmed)
        zoteroSync     { l = {...}, r = {...} } fingerprints of the local and
                       the remote fields at that time

With that base, every field is merged three ways: changed only in Zotero ->
applied here; changed only here -> uploaded; changed on both sides -> notes
are joined, everything else goes to the more recent edit.

Safety rules the code keeps to:

  * nothing is deleted on either side on the strength of an absence: a local
    annotation is removed only when Zotero's delete log names it, and a Zotero
    annotation only when the user deleted its counterpart in the reader
    (recorded in the document's delete log at that moment);
  * an annotation that cannot be placed verifiably is not written at all;
  * uploads carry the key and version of each object, so a retry can never
    create a duplicate and a newer remote edit is never overwritten.
]]

local Annotations = require("annotations")
local Util = require("zotero_util")
local logger = require("logger")

local Sync = { fork = "0.6" }

local FIELDS = { "text", "note", "color", "type", "pos" }

-- ---------------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------------

function Sync.newStats()
    return {
        imported = 0,        -- Zotero annotations added here
        updated_local = 0,   -- local annotations changed to follow Zotero
        replaced = 0,        -- local annotations moved to their correct place
        removed_local = 0,   -- local annotations removed (deleted in Zotero)
        linked = 0,          -- local and Zotero annotations recognised as the same
        created_remote = 0,
        updated_remote = 0,
        deleted_remote = 0,
        pending = 0,         -- changes waiting for an upload
        unplaced = 0,        -- Zotero annotations that could not be placed here
        deferred = 0,        -- work that needs the document to be open
        unsupported = 0,     -- Zotero annotation types the reader cannot show
        conflicts = 0,       -- uploads refused because Zotero has a newer version
        failed = 0,          -- uploads refused for another reason
        kept = 0,            -- deleted on one side but edited on the other: kept
        messages = {},       -- human-readable notes (first few are shown)
    }
end

local function note(stats, msg)
    if #stats.messages < 40 then
        stats.messages[#stats.messages + 1] = msg
    end
    logger.info("Zotero sync:", msg)
end

--- Add the counters of `from` to `into`.
function Sync.addStats(into, from)
    for k, v in pairs(from) do
        if type(v) == "number" then
            into[k] = (into[k] or 0) + v
        end
    end
    for _, m in ipairs(from.messages or {}) do
        if #into.messages < 40 then into.messages[#into.messages + 1] = m end
    end
    return into
end

--- Did anything change on this device?
function Sync.changedLocally(stats)
    return stats.imported + stats.updated_local + stats.replaced + stats.removed_local + stats.linked > 0
end

--- One-paragraph summary for the user.
function Sync.summary(stats)
    local parts = {}
    local function add(n, one, many)
        if n and n > 0 then
            parts[#parts + 1] = string.format(n == 1 and one or many, n)
        end
    end
    add(stats.imported, "%d annotation added from Zotero", "%d annotations added from Zotero")
    add(stats.updated_local, "%d updated from Zotero", "%d updated from Zotero")
    add(stats.replaced, "%d moved to its correct place", "%d moved to their correct place")
    add(stats.removed_local, "%d removed (deleted in Zotero)", "%d removed (deleted in Zotero)")
    add(stats.created_remote, "%d sent to Zotero", "%d sent to Zotero")
    add(stats.updated_remote, "%d updated in Zotero", "%d updated in Zotero")
    add(stats.deleted_remote, "%d deleted in Zotero", "%d deleted in Zotero")
    add(stats.linked, "%d matched with an existing Zotero annotation", "%d matched with existing Zotero annotations")
    local problems = {}
    local function warn(n, one, many)
        if n and n > 0 then
            problems[#problems + 1] = string.format(n == 1 and one or many, n)
        end
    end
    warn(stats.unplaced, "%d Zotero annotation could not be placed in the document", "%d Zotero annotations could not be placed in the document")
    warn(stats.failed, "%d upload was refused by Zotero", "%d uploads were refused by Zotero")
    warn(stats.conflicts, "%d change will be merged at the next sync (edited in Zotero meanwhile)", "%d changes will be merged at the next sync (edited in Zotero meanwhile)")
    warn(stats.pending, "%d change has not been uploaded yet", "%d changes have not been uploaded yet")
    warn(stats.deferred, "%d annotation of an EPUB or web snapshot will be completed when the document is opened",
        "%d annotations of EPUBs or web snapshots will be completed when the document is opened")
    return parts, problems
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function is_highlight(ann)
    return type(ann) == "table" and ann.drawer ~= nil and ann.pos0 ~= nil and ann.pos1 ~= nil
end

local function has_text(s)
    return type(s) == "string" and s ~= ""
end

local function local_epoch(ann)
    return Util.localToEpoch(ann.datetime_updated) or Util.localToEpoch(ann.datetime)
end

local function remote_epoch(item)
    local d = item.data or {}
    return Util.utcToEpoch(d.dateModified) or Util.utcToEpoch(d.dateAdded)
end

local function unlink(ann)
    ann.zoteroKey = nil
    ann.zoteroVersion = nil
    ann.zoteroSync = nil
    ann.zoteroPos = nil
    ann.zoteroFail = nil
    -- fields written by earlier versions of the plugin
    ann.zoteroSortIndex = nil
    ann.zoteroAnnotationPosition = nil
    ann.zoteroCfi = nil
end

local function join_notes(a, b)
    a, b = a or "", b or ""
    if a == b or b == "" then return a end
    if a == "" then return b end
    if a:find(b, 1, true) then return a end
    if b:find(a, 1, true) then return b end
    return a .. "\n\n" .. b
end

--- Section number (EPUB) or page index (PDF) of a Zotero sort index.
local function sort_index_head(sort_index)
    return tonumber(tostring(sort_index or ""):match("^(%d+)|"))
end

-- ---------------------------------------------------------------------------
-- Applying a Zotero item to a local annotation
-- ---------------------------------------------------------------------------

local function apply_remote_field(env, ann, item, field)
    local d = item.data or {}
    if field == "text" then
        ann.text = d.annotationText or ""
    elseif field == "note" then
        ann.note = has_text(d.annotationComment) and d.annotationComment or nil
    elseif field == "color" then
        ann.color = Annotations.zoteroColorToKOReader(d.annotationColor)
    elseif field == "type" then
        ann.drawer = Annotations.zoteroTypeToDrawer(d.annotationType)
    end
end

--- Move a local annotation to where Zotero says it is.
-- @return true, or false and a reason
local function apply_remote_position(env, ann, item)
    local conv = env.converter
    if not conv.available then return false, "deferred" end
    local placed, how = conv.to_local(item)
    if not placed then return false, how or "not placed" end
    env.list:reposition(ann, function(a)
        a.page = placed.page
        a.pos0 = placed.pos0
        a.pos1 = placed.pos1
        a.pboxes = placed.pboxes
        a.ext = placed.ext
        a.zoteroPos = nil
    end)
    return true
end

-- ---------------------------------------------------------------------------
-- Building upload objects
-- ---------------------------------------------------------------------------

--- Zotero position of a local annotation: { position, sortIndex, pageLabel }.
local function remote_position(env, ann)
    local conv = env.converter
    local sig = Annotations.localPositionSignature(ann)
    if conv.available then
        local res, err = conv.to_remote(ann)
        if res then
            -- remember it: a closed document cannot compute it again (EPUB)
            ann.zoteroPos = { sig = sig, position = res.position, sortIndex = res.sortIndex, pageLabel = res.pageLabel }
            return res
        end
        return nil, err
    end
    local cached = ann.zoteroPos
    if type(cached) == "table" and cached.sig == sig and cached.position and cached.sortIndex then
        return cached
    end
    return nil, "deferred"
end

local function clean_text(s)
    return Util.fixUtf8(Util.cleanText(s or ""))
end

local function create_object(env, ann, key, pos)
    local obj = {
        key = key,
        version = 0,
        itemType = "annotation",
        parentItem = env.attachment_key,
        annotationType = Annotations.drawerToZoteroType(ann.drawer),
        annotationText = clean_text(ann.text),
        annotationComment = Util.fixUtf8(ann.note or ""),
        annotationColor = Annotations.koreaderColorToZotero(ann.color),
        annotationPageLabel = pos.pageLabel or "",
        annotationSortIndex = pos.sortIndex,
        annotationPosition = pos.position,
    }
    obj.dateAdded = Util.localToUtcIso(ann.datetime)
    obj.dateModified = Util.localToUtcIso(ann.datetime_updated or ann.datetime)
    return obj
end

-- ---------------------------------------------------------------------------
-- First contact with an annotation written by an earlier plugin version
-- (linked to a Zotero item, but without the fingerprints)
-- ---------------------------------------------------------------------------

local UNKNOWN = "?"

--- Build the base fingerprints of a pre-0.6 annotation.
-- @return base, or nil when that needs the document to be open
local function legacy_base(env, ann, item)
    local lf, rf = Annotations.localFields(ann), Annotations.remoteFields(item)
    local d = item.data or {}
    local base = { l = {}, r = {} }
    local remote_untouched = tonumber(ann.zoteroVersion) ~= nil
        and tonumber(ann.zoteroVersion) == tonumber(item.version)

    local function same(field)
        base.l[field], base.r[field] = lf[field], rf[field]
    end
    local function differs(field)
        if remote_untouched then
            -- Zotero has not changed since this was imported: the difference
            -- is an edit made here
            base.l[field], base.r[field] = UNKNOWN, rf[field]
        elseif ann.zoteroVersion == nil then
            -- no record of what was imported: Zotero is the reference
            base.l[field], base.r[field] = lf[field], UNKNOWN
        else
            base.l[field], base.r[field] = UNKNOWN, UNKNOWN
        end
    end

    -- note: whatever happened, no text is dropped on either side. A note that
    -- exists on one side only goes to the other; two different notes are joined.
    local local_note, remote_note = ann.note or "", d.annotationComment or ""
    if local_note == remote_note then
        same("note")
    elseif local_note == "" then
        base.l.note, base.r.note = lf.note, UNKNOWN
    elseif remote_note == "" then
        base.l.note, base.r.note = UNKNOWN, rf.note
    else
        base.l.note, base.r.note = UNKNOWN, UNKNOWN
    end
    -- colour: equal if it is what this or an earlier version maps the Zotero colour to
    local name = ann.color and tostring(ann.color):lower() or ""
    if name == Annotations.zoteroColorToKOReader(d.annotationColor)
        or name == Annotations.legacyColorName(d.annotationColor) then
        same("color")
    else
        differs("color")
    end
    -- text
    if Util.normText(ann.text or "") == Util.normText(d.annotationText or "") then same("text") else differs("text") end
    -- type
    same("type")
    if lf.type ~= rf.type then base.r.type = UNKNOWN end -- follow Zotero
    -- position: earlier versions placed imported highlights wrongly. Keep a
    -- position that selects the annotation's own text; otherwise take Zotero's.
    local ok = env.converter.verify_local(ann, item)
    if ok == nil then return nil end
    if ok then
        same("pos")
    else
        base.l.pos, base.r.pos = lf.pos, UNKNOWN
        base.replacing = true
    end
    return base
end

-- ---------------------------------------------------------------------------
-- Reconcile
-- ---------------------------------------------------------------------------

--- Are a local annotation and a Zotero item the same highlight? Used only to
-- avoid creating a duplicate of something that exists on both sides already.
local function same_highlight(env, ann, pos, item)
    local d = item.data or {}
    local a, b = Util.normText(ann.text or ""), Util.normText(d.annotationText or "")
    if a == "" or a ~= b then return false end
    if pos.position == d.annotationPosition then return true end
    if env.kind ~= "pdf" then
        return pos.sortIndex == d.annotationSortIndex
    end
    -- PDF: same page, and about the same height on it
    local p1, _, t1 = tostring(pos.sortIndex or ""):match("^(%d+)|(%d+)|(%d+)$")
    local p2, _, t2 = tostring(d.annotationSortIndex or ""):match("^(%d+)|(%d+)|(%d+)$")
    if not p1 or not p2 or p1 ~= p2 then return false end
    return math.abs(tonumber(t1) - tonumber(t2)) <= 20
end

--- Compare one linked annotation with its Zotero item and merge.
-- Appends an update operation to plan when something has to be uploaded.
local function merge_linked(env, plan, ann, item)
    local stats = env.stats
    local base = ann.zoteroSync
    if type(base) ~= "table" or type(base.l) ~= "table" or type(base.r) ~= "table" then
        base = legacy_base(env, ann, item)
        if not base then
            stats.deferred = stats.deferred + 1
            return
        end
        ann.zoteroSync = base
        -- drop fields earlier versions kept
        ann.zoteroSortIndex, ann.zoteroAnnotationPosition, ann.zoteroCfi = nil, nil, nil
    end
    local replacing = base.replacing
    base.replacing = nil

    local upload = {}      -- field -> true
    local changed_local = false
    local before           -- the annotation as it was, once its content is changed here
    local modified = Util.utcIsoToLocal((item.data or {}).dateModified)

    -- A colour the reader had no name for when this annotation was imported
    -- (Zotero's magenta) and that nobody changed since: give it its own name
    -- now. This is not an edit and is not uploaded.
    do
        local better = Annotations.betterColorName(ann.color, (item.data or {}).annotationColor)
        if better and Annotations.localFields(ann).color == base.l.color
            and Annotations.remoteFields(item).color == base.r.color then
            before = Util.copy(ann)
            ann.color = better
            base.l.color = Annotations.localFields(ann).color
            changed_local = true
        end
    end

    local lf, rf = Annotations.localFields(ann), Annotations.remoteFields(item)

    for _, f in ipairs(FIELDS) do
        local lc = lf[f] ~= base.l[f]
        local rc = rf[f] ~= base.r[f]
        if f == "type" and lc then
            -- Zotero does not allow the type of an annotation to change, so a
            -- change of drawing style made here stays here
            base.l.type = lf.type
            lc = false
        end
        if rc and lc then
            if f == "note" then
                local merged = join_notes(ann.note, (item.data or {}).annotationComment)
                if merged ~= (ann.note or "") then
                    before = before or Util.copy(ann)
                    ann.note = has_text(merged) and merged or nil
                    changed_local = true
                end
                base.r.note = rf.note
                if merged ~= ((item.data or {}).annotationComment or "") then
                    upload.note = true
                else
                    base.l.note = Annotations.localFields(ann).note
                end
            else
                local lt, rt = local_epoch(ann), remote_epoch(item)
                if lt and rt and lt > rt then
                    base.r[f] = rf[f] -- Zotero's edit is older: ours goes up
                    upload[f] = true
                else
                    lc = false -- Zotero's edit wins: handled as a remote change below
                end
            end
        end
        if rc and not lc then
            if f == "pos" then
                if before then
                    -- content changes first, while the annotation is still
                    -- where the reader knows it
                    env.list:changed(ann, before, modified)
                    before = nil
                end
                local ok, why = apply_remote_position(env, ann, item)
                if ok then
                    base.l.pos = Annotations.localFields(ann).pos
                    base.r.pos = rf.pos
                    if replacing then
                        stats.replaced = stats.replaced + 1
                    else
                        changed_local = true
                        -- moved in Zotero, at the time Zotero recorded
                        if modified then ann.datetime_updated = modified end
                    end
                elseif why == "deferred" then
                    stats.deferred = stats.deferred + 1
                else
                    -- keep what is there; try again when Zotero changes it
                    base.r.pos = rf.pos
                    stats.unplaced = stats.unplaced + 1
                    note(stats, string.format("A highlight on %s could not be moved: %s",
                        tostring(ann.pageno or ann.page or "?"), tostring(why)))
                end
            else
                before = before or Util.copy(ann)
                apply_remote_field(env, ann, item, f)
                base.l[f] = Annotations.localFields(ann)[f]
                base.r[f] = rf[f]
                changed_local = true
            end
        elseif lc and not rc then
            upload[f] = true
        end
    end

    if before then
        env.list:changed(ann, before, modified)
    end
    if changed_local then
        stats.updated_local = stats.updated_local + 1
    end

    if next(upload) == nil then
        ann.zoteroVersion = tonumber(item.version) or ann.zoteroVersion
        ann.zoteroFail = nil
        return
    end

    -- Something to upload. A refusal by the server is not retried until the
    -- annotation changes again.
    local sig = table.concat({ lf.text, lf.note, lf.color, lf.type, lf.pos }, "|")
    if type(ann.zoteroFail) == "table" and ann.zoteroFail.sig == sig then
        stats.failed = stats.failed + 1
        return
    end
    local obj = { key = item.key, version = tonumber(item.version) or 0 }
    local fields = {}
    if upload.pos then
        local pos, why = remote_position(env, ann)
        if pos then
            obj.annotationPosition = pos.position
            obj.annotationSortIndex = pos.sortIndex
            obj.annotationPageLabel = pos.pageLabel or ""
            fields[#fields + 1] = "pos"
        elseif why == "deferred" then
            stats.deferred = stats.deferred + 1
        else
            stats.pending = stats.pending + 1
            note(stats, string.format("A moved highlight on %s cannot be sent to Zotero: %s",
                tostring(ann.pageno or ann.page or "?"), tostring(why)))
        end
    end
    if upload.text then obj.annotationText = clean_text(ann.text); fields[#fields + 1] = "text" end
    if upload.note then obj.annotationComment = Util.fixUtf8(ann.note or ""); fields[#fields + 1] = "note" end
    if upload.color then obj.annotationColor = Annotations.koreaderColorToZotero(ann.color); fields[#fields + 1] = "color" end
    if #fields == 0 then return end
    obj.dateModified = Util.localToUtcIso(ann.datetime_updated)
    plan.ops[#plan.ops + 1] = { kind = "update", ann = ann, object = obj, fields = fields, sig = sig }
end

--- Work out what has to change on both sides. Changes that only concern this
-- device are applied at once; uploads are returned as a plan for Sync.push.
--
-- env = {
--   kind            "pdf" | "epub"
--   attachment_key  Zotero key of the attachment
--   list            adapter over the local annotations (see zotero_list)
--   remote          { [key] = item }  highlight/underline items of the attachment
--   other_remote    number of annotations of other types (not shown in the reader)
--   deleted         function(key) -> true when Zotero's delete log names it
--   tomb            { [key] = version } the document's own delete log (updated)
--   converter       { available, to_local(item), to_remote(ann), verify_local(ann) }
--   stats           Sync.newStats()
-- }
function Sync.reconcile(env)
    local stats = env.stats
    local plan = { ops = {} }
    local remote = env.remote or {}
    local tomb = env.tomb or {}
    env.tomb = tomb
    stats.unsupported = stats.unsupported + (env.other_remote or 0)

    -- 1. local annotations that are linked to a Zotero item
    local linked = {}
    local unlinked = {}
    for _, ann in ipairs(env.list:snapshot()) do
        if is_highlight(ann) then
            local key = ann.zoteroKey
            if key ~= nil and not Util.isValidKey(key) then
                unlink(ann)
                key = nil
            end
            if key and linked[key] then
                -- two local annotations claim the same item: the second one
                -- is either a copy (dropped) or something of its own
                local first = linked[key]
                if Annotations.localPositionSignature(first) == Annotations.localPositionSignature(ann)
                    and (first.text or "") == (ann.text or "") and (first.note or "") == (ann.note or "") then
                    env.list:remove(ann)
                else
                    unlink(ann)
                    unlinked[#unlinked + 1] = ann
                end
            elseif key then
                linked[key] = ann
            else
                unlinked[#unlinked + 1] = ann
            end
        end
    end

    for key, ann in pairs(linked) do
        local item = remote[key]
        local gone, last = false, nil
        if not item then gone, last = env.deleted(key) end
        if item then
            if tomb[key] then tomb[key] = nil end -- it is here: not deleted
            merge_linked(env, plan, ann, item)
        elseif gone then
            -- deleted in Zotero
            local base = ann.zoteroSync
            local edited = false
            if type(base) == "table" and type(base.l) == "table" then
                local lf = Annotations.localFields(ann)
                edited = lf.text ~= base.l.text or lf.note ~= base.l.note or lf.pos ~= base.l.pos
            elseif has_text(ann.note) then
                -- An annotation from an earlier version of the plugin: there
                -- is no record of what it was synced with. Its note may have
                -- been written here, and a note is not removed unless Zotero
                -- is known to have had the same one. Without that knowledge,
                -- "changed in the reader after it was imported" decides.
                local known = type(last) == "table" and type(last.data) == "table" and last.data.annotationComment or nil
                if known ~= nil then
                    edited = Util.cleanText(known) ~= Util.cleanText(ann.note)
                else
                    edited = ann.datetime_updated ~= nil
                end
            end
            if edited then
                unlink(ann)
                unlinked[#unlinked + 1] = ann
                stats.kept = stats.kept + 1
                note(stats, "A highlight deleted in Zotero was edited here afterwards; it is kept and will be sent again.")
            else
                env.list:remove(ann)
                stats.removed_local = stats.removed_local + 1
            end
        elseif (tonumber(ann.zoteroVersion) or 0) == 0 then
            -- its upload was never confirmed: send it (again) under the same key
            unlinked[#unlinked + 1] = ann
        else
            -- unknown to the local database and not reported deleted: leave it
            logger.info("Zotero sync: annotation", key, "is not in the local library; left untouched")
        end
    end

    -- 2. the document's delete log
    for key, version in pairs(tomb) do
        local item = remote[key]
        if not item then
            -- Not in the local library. Gone, if Zotero's delete log says so;
            -- otherwise the library copy is incomplete (it is being
            -- downloaded again, say) and the entry waits.
            if env.deleted(key) then tomb[key] = nil end
        elseif (tonumber(item.version) or 0) > (tonumber(version) or 0) and tonumber(version) ~= nil and tonumber(version) > 0 then
            -- edited in Zotero after it was deleted here: Zotero's edit stands
            tomb[key] = nil
            stats.kept = stats.kept + 1
            note(stats, "A highlight deleted here was edited in Zotero afterwards; it is kept.")
        else
            plan.ops[#plan.ops + 1] = { kind = "delete", key = key, version = tonumber(item.version) or 0 }
        end
    end

    -- 3. local highlights Zotero does not have yet
    local claimed = {}
    for key in pairs(linked) do claimed[key] = true end
    -- Zotero annotations nothing here is linked to, by their text: one of them
    -- may be the same highlight as an unlinked local one
    local free_by_text
    local function candidates_for(ann)
        if free_by_text == nil then
            free_by_text = {}
            for key, item in pairs(remote) do
                if not claimed[key] and not tomb[key] then
                    local t = Util.normText((item.data or {}).annotationText or "")
                    if t ~= "" then
                        local l = free_by_text[t]
                        if not l then l = {}; free_by_text[t] = l end
                        l[#l + 1] = item
                    end
                end
            end
        end
        return free_by_text[Util.normText(ann.text or "")]
    end
    for _, ann in ipairs(unlinked) do
        local sig = Annotations.localPositionSignature(ann)
        local candidates = (not ann.zoteroKey) and has_text(ann.text) and candidates_for(ann) or nil
        if type(ann.zoteroFail) == "table" and ann.zoteroFail.sig == sig .. "|" .. (ann.text or "") then
            stats.failed = stats.failed + 1
        elseif not has_text(ann.text) then
            -- nothing Zotero could show
            logger.dbg("Zotero sync: highlight without text skipped")
        elseif env.uploads == false and not candidates then
            -- Nothing is sent now and there is nothing to compare it with: its
            -- Zotero position (which costs reading the page) is not needed yet.
            stats.pending = stats.pending + 1
        else
            local pos, why = remote_position(env, ann)
            if not pos then
                if why == "deferred" then
                    stats.deferred = stats.deferred + 1
                else
                    stats.pending = stats.pending + 1
                    note(stats, string.format("A highlight on %s cannot be sent to Zotero: %s",
                        tostring(ann.pageno or ann.page or "?"), tostring(why)))
                end
            else
                -- the same highlight may already exist in Zotero
                local twin
                for _, item in ipairs(candidates or {}) do
                    if not claimed[item.key] and same_highlight(env, ann, pos, item) then
                        twin = item
                        break
                    end
                end
                if twin then
                    claimed[twin.key] = true
                    ann.zoteroKey = twin.key
                    ann.zoteroVersion = tonumber(twin.version) or 0
                    local lf, rf = Annotations.localFields(ann), Annotations.remoteFields(twin)
                    local base = { l = Util.copy(lf), r = Util.copy(rf) }
                    -- a note or colour that differs counts as edited on both sides
                    if (ann.note or "") ~= ((twin.data or {}).annotationComment or "") then
                        base.l.note, base.r.note = UNKNOWN, UNKNOWN
                    end
                    ann.zoteroSync = base
                    stats.linked = stats.linked + 1
                    merge_linked(env, plan, ann, twin)
                else
                    plan.ops[#plan.ops + 1] = { kind = "create", ann = ann, pos = pos,
                        sig = sig .. "|" .. (ann.text or "") }
                end
            end
        end
    end

    -- 4. Zotero annotations this document does not have yet
    local to_import = {}
    for key, item in pairs(remote) do
        if not claimed[key] and not tomb[key] then
            to_import[#to_import + 1] = item
        end
    end
    table.sort(to_import, function(a, b)
        local sa, sb = tostring((a.data or {}).annotationSortIndex or ""), tostring((b.data or {}).annotationSortIndex or "")
        if sa ~= sb then return sa < sb end
        return tostring(a.key) < tostring(b.key)
    end)
    for _, item in ipairs(to_import) do
        if not env.converter.available then
            stats.deferred = stats.deferred + 1
        else
            local ann, how = env.converter.to_local(item)
            if ann then
                ann.zoteroKey = item.key
                ann.zoteroVersion = tonumber(item.version) or 0
                ann.zoteroSync = { l = Annotations.localFields(ann), r = Annotations.remoteFields(item) }
                env.list:add(ann)
                stats.imported = stats.imported + 1
                if how == "text" or how == "geometry-unverified" or how == "cfi-unverified" or how == "rects"
                    or how == "position-unverified" then
                    logger.info("Zotero sync: annotation", item.key, "placed by", how)
                end
            else
                stats.unplaced = stats.unplaced + 1
                local d = item.data or {}
                local where
                local head = sort_index_head(d.annotationSortIndex)
                if env.kind == "html" then
                    where = "in the page"
                elseif env.kind == "epub" then
                    where = head and string.format("in part %d of the book", head + 1) or "in the book"
                elseif d.annotationPageLabel and d.annotationPageLabel ~= "" then
                    where = "on page " .. tostring(d.annotationPageLabel)
                else
                    where = head and string.format("on page %d", head + 1) or "in the document"
                end
                note(stats, string.format("Zotero annotation %s (\"%s\") could not be placed: %s",
                    where, Util.cleanText(d.annotationText or ""):sub(1, 40), tostring(how)))
            end
        end
    end

    return plan
end

-- ---------------------------------------------------------------------------
-- Push
-- ---------------------------------------------------------------------------

local function adopt(env, ann, item)
    ann.zoteroKey = item.key
    ann.zoteroVersion = tonumber(item.version) or 0
    ann.zoteroSync = { l = Annotations.localFields(ann), r = Annotations.remoteFields(item) }
    ann.zoteroFail = nil
end

--- An update was accepted: the fields that were sent now agree on both
-- sides. Fields that were not sent (a new position that could not be
-- computed yet, say) keep their old record, so they are still seen as
-- changed here next time.
local function confirm_update(ann, item, fields)
    local base = ann.zoteroSync
    if type(base) ~= "table" or type(base.l) ~= "table" or type(base.r) ~= "table" then
        base = { l = {}, r = {} }
        ann.zoteroSync = base
    end
    local lf, rf = Annotations.localFields(ann), Annotations.remoteFields(item)
    for _, f in ipairs(fields or {}) do
        base.l[f], base.r[f] = lf[f], rf[f]
    end
    ann.zoteroVersion = tonumber(item.version) or ann.zoteroVersion
    ann.zoteroFail = nil
end

--- Upload a plan.
--
-- api = {
--   write(objects)        -> results, err   results[i] = { ok = item } | { unchanged = true } | { code =, message = }
--   get(key)              -> item | nil, code
--   delete(key, version)  -> true | nil, code
--   store(item)           keep an item the server returned in the local database
--   forget(key)           remove an item from the local database (deleted remotely by us)
--   mark_deleted(key)     record that the server no longer has an item
-- }
-- Everything the server confirms is recorded in the annotations immediately;
-- the caller saves the list afterwards.
function Sync.push(env, plan, api)
    local stats = env.stats
    local tomb = env.tomb or {}

    -- deletions first: they are independent of everything else
    for _, op in ipairs(plan.ops) do
        if op.kind == "delete" then
            local ok, code = api.delete(op.key, op.version)
            if ok then
                tomb[op.key] = nil
                api.forget(op.key)
                stats.deleted_remote = stats.deleted_remote + 1
            elseif code == 412 or code == 404 then
                -- either gone already, or changed in Zotero since: look
                local item, gcode = api.get(op.key)
                if not item and gcode == 404 then
                    tomb[op.key] = nil
                    api.forget(op.key)
                elseif item then
                    tomb[op.key] = nil
                    api.store(item)
                    stats.kept = stats.kept + 1
                    note(stats, "A highlight deleted here was edited in Zotero meanwhile; it is kept.")
                else
                    stats.pending = stats.pending + 1
                end
            else
                stats.pending = stats.pending + 1
                note(stats, "Deleting an annotation in Zotero failed (" .. tostring(code) .. "); it will be retried.")
            end
        end
    end

    -- creations and updates, in batches
    local writes = {}
    for _, op in ipairs(plan.ops) do
        if op.kind == "create" then
            local ann = op.ann
            if not ann.zoteroKey then
                ann.zoteroKey = Util.newItemKey()
                ann.zoteroVersion = 0
            end
            op.object = create_object(env, ann, ann.zoteroKey, op.pos)
            writes[#writes + 1] = op
        elseif op.kind == "update" then
            writes[#writes + 1] = op
        end
    end
    if #writes == 0 then return true end

    -- The keys of new annotations are on disk before anything is sent: if the
    -- answer gets lost, the next sync finds them and does not create copies.
    env.list:flush()

    local BATCH = 50
    for start = 1, #writes, BATCH do
        local batch, objects = {}, {}
        for i = start, math.min(start + BATCH - 1, #writes) do
            batch[#batch + 1] = writes[i]
            objects[#objects + 1] = writes[i].object
        end
        local results, err = api.write(objects)
        if not results then
            stats.pending = stats.pending + #writes - start + 1
            note(stats, "Upload to Zotero failed: " .. tostring(err))
            return false, err
        end
        for i, op in ipairs(batch) do
            local res = results[i] or {}
            local ann = op.ann
            if res.ok then
                api.store(res.ok)
                if op.kind == "create" then
                    adopt(env, ann, res.ok)
                    stats.created_remote = stats.created_remote + 1
                else
                    confirm_update(ann, res.ok, op.fields)
                    stats.updated_remote = stats.updated_remote + 1
                end
            elseif res.unchanged then
                -- the server already has exactly this
                local item = api.get(op.object.key)
                if item then
                    api.store(item)
                    if op.kind == "create" then
                        adopt(env, ann, item)
                    else
                        confirm_update(ann, item, op.fields)
                    end
                end
            elseif res.code == 412 and op.kind == "create" then
                -- the key exists already: an earlier upload whose answer was lost?
                local item = api.get(op.object.key)
                local d = item and item.data or {}
                if item and d.itemType == "annotation" and d.parentItem == env.attachment_key
                    and Util.normText(d.annotationText or "") == Util.normText(ann.text or "") then
                    api.store(item)
                    adopt(env, ann, item)
                    stats.created_remote = stats.created_remote + 1
                else
                    -- somebody else's key: take a new one next time
                    unlink(ann)
                    stats.pending = stats.pending + 1
                end
            elseif res.code == 412 then
                -- changed in Zotero since the last download: merge next time
                stats.conflicts = stats.conflicts + 1
            elseif res.code == 404 and op.kind == "update" then
                -- deleted in Zotero meanwhile
                api.mark_deleted(op.object.key)
                api.forget(op.object.key)
                stats.conflicts = stats.conflicts + 1
            else
                stats.failed = stats.failed + 1
                if res.code == 400 or res.code == 413 then
                    -- the server will not take this as it is: do not send it
                    -- again until the annotation changes
                    ann.zoteroFail = { sig = op.sig, code = res.code, message = res.message }
                end
                if op.kind == "create" then
                    -- nothing was created; do not keep the reserved key
                    ann.zoteroKey = nil
                    ann.zoteroVersion = nil
                end
                note(stats, string.format("Zotero refused an annotation on %s: %s",
                    tostring(ann.pageno or ann.page or "?"), tostring(res.message or res.code)))
            end
        end
    end
    return true
end

--- Count what a plan would upload (used when uploading is not possible).
function Sync.countPending(env, plan)
    env.stats.pending = env.stats.pending + #plan.ops
end

return Sync
