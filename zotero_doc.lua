--[[--
The document side of annotation sync: access to a document's annotations
(open in the reader, or closed and stored in its sidecar file), and the
position converters for PDF and EPUB.

Both list types offer the same small interface to zotero_sync:

    list:snapshot()                 the annotations, as a plain array
    list:add(ann)                   insert a new annotation in reading order
    list:remove(ann)
    list:reposition(ann, fn)        move an annotation (fn changes its position)
    list:changed(ann, before, ts)   an annotation's content changed in place
    list:flush()                    write to disk now
    list:get(key) / list:set(key, value)   document-level settings
]]

local Annotations = require("annotations")
local DocSettings = require("docsettings")
local Epub = require("zotero_epub")
local Event = require("ui/event")
local Util = require("zotero_util")
local logger = require("logger")

local Doc = { fork = "0.6" }

-- ---------------------------------------------------------------------------
-- A closed document: its sidecar file
-- ---------------------------------------------------------------------------

local ClosedList = {}
ClosedList.__index = ClosedList

--- A canonical text form of a value, with table keys in a fixed order. Used
-- only to tell whether the annotations changed: the order in which a Lua
-- table yields its keys can change when the table is merely touched.
local function serialize(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "table" then
        if depth > 16 then return "{...}" end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta < tb end
            if ta == "number" or ta == "string" then return a < b end
            return tostring(a) < tostring(b)
        end)
        local parts = {}
        for i, k in ipairs(keys) do
            parts[i] = "[" .. (type(k) == "string" and string.format("%q", k) or tostring(k)) .. "]="
                .. serialize(v[k], depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "number" then
        return string.format("%.17g", v)
    end
    return tostring(v)
end

--- @param file_path the document (not the sidecar) path
function Doc.closedList(file_path)
    local ds = DocSettings:open(file_path)
    local anns = ds:readSetting("annotations")
    if type(anns) ~= "table" then anns = {} end
    local self = setmetatable({
        ds = ds,
        anns = anns,
        paging = Annotations.isPdfPath(file_path),
        structural = false,
        settings_dirty = false,
    }, ClosedList)
    self.before = serialize(anns)
    return self
end

function ClosedList:snapshot()
    local out = {}
    for i, a in ipairs(self.anns) do out[i] = a end
    return out
end

--- Reading-order key of a PDF annotation (KOReader sorts again when the
-- document is opened, see flush()).
local function paging_key(a)
    local page = tonumber(a.page) or tonumber(type(a.pos0) == "table" and a.pos0.page) or 0
    local y = type(a.pos0) == "table" and tonumber(a.pos0.y) or -1
    local x = type(a.pos0) == "table" and tonumber(a.pos0.x) or -1
    return page, y, x
end

function ClosedList:add(ann)
    if self.paging then
        ann.pageno = ann.pageno or ann.page
        local p, y, x = paging_key(ann)
        local index = #self.anns + 1
        for i, other in ipairs(self.anns) do
            local op, oy, ox = paging_key(other)
            if op > p or (op == p and (oy > y or (oy == y and ox > x))) then
                index = i
                break
            end
        end
        table.insert(self.anns, index, ann)
    else
        table.insert(self.anns, ann)
    end
    self.structural = true
end

function ClosedList:remove(ann)
    for i, a in ipairs(self.anns) do
        if a == ann then
            table.remove(self.anns, i)
            self.structural = true
            return true
        end
    end
    return false
end

function ClosedList:reposition(ann, fn)
    self:remove(ann)
    fn(ann)
    ann.pageno = nil
    self:add(ann)
end

function ClosedList:changed(ann, _, modified)
    if modified then ann.datetime_updated = modified end
end

function ClosedList:get(key)
    return self.ds:readSetting(key)
end

function ClosedList:set(key, value)
    if value == nil then
        self.ds:delSetting(key)
    else
        self.ds:saveSetting(key, value)
    end
    self.settings_dirty = true
end

--- Write the sidecar, but only if something actually changed.
function ClosedList:flush()
    local now = serialize(self.anns)
    local changed = self.structural or self.settings_dirty or now == nil or now ~= self.before
    if not changed then return false end
    self.ds:saveSetting("annotations", self.anns)
    if self.structural then
        -- have KOReader recompute page numbers and order when it opens the document
        self.ds:saveSetting("annotations_externally_modified", true)
    end
    self.ds:flush()
    self.before = now
    self.structural = false
    self.settings_dirty = false
    return true
end

function ClosedList:close()
    self:flush()
end

-- ---------------------------------------------------------------------------
-- A document open in the reader
-- ---------------------------------------------------------------------------

local OpenList = {}
OpenList.__index = OpenList

--- @param ui the ReaderUI
-- @param guard function(fn): runs fn while the plugin ignores the
--        annotation events these changes cause (they are not user actions)
function Doc.openList(ui, guard)
    return setmetatable({
        ui = ui,
        guard = guard or function(fn) return fn() end,
        touched = false,
    }, OpenList)
end

function OpenList:snapshot()
    local out = {}
    for i, a in ipairs(self.ui.annotation.annotations) do out[i] = a end
    return out
end

function OpenList:add(ann)
    local ui = self.ui
    self.guard(function()
        if ann.chapter == nil and ui.toc then
            local ok, title = pcall(ui.toc.getTocTitleByPage, ui.toc, ann.page)
            if ok and type(title) == "string" and title ~= "" then ann.chapter = title end
        end
        if ui.paging and ui.highlight and ui.highlight.writePdfAnnotation then
            -- only does something when the user has "write highlights into PDF" on
            pcall(ui.highlight.writePdfAnnotation, ui.highlight, "save", ann)
        end
        local index = ui.annotation:addItem(ann)
        local ev = { ann, index_modified = index }
        if ann.note then ev.nb_notes_added = 1 else ev.nb_highlights_added = 1 end
        ui:handleEvent(Event:new("AnnotationsModified", ev))
    end)
    self.touched = true
end

function OpenList:remove(ann)
    local ui = self.ui
    local index
    for i, a in ipairs(ui.annotation.annotations) do
        if a == ann then index = i break end
    end
    if not index then return false end
    self.guard(function()
        if ann.drawer and ui.highlight and ui.highlight.deleteHighlight then
            ui.highlight:deleteHighlight(index)
        else
            ui.bookmark:removeItemByIndex(index)
        end
    end)
    self.touched = true
    return true
end

function OpenList:reposition(ann, fn)
    self:remove(ann)
    fn(ann)
    ann.pageno, ann.pageref, ann.chapter = nil, nil, nil
    self:add(ann)
end

function OpenList:changed(ann, before, modified)
    local ui = self.ui
    local keep = ann.datetime_updated
    self.guard(function()
        local ev = { ann, before }
        if before and (before.note ~= nil) ~= (ann.note ~= nil) then
            -- a highlight became a note or the reverse (reading statistics count them)
            if ann.note then
                ev.nb_highlights_added, ev.nb_notes_added = -1, 1
            else
                ev.nb_highlights_added, ev.nb_notes_added = 1, -1
            end
        end
        ui:handleEvent(Event:new("AnnotationsModified", ev))
        if ui.paging and before and before.note ~= ann.note and ui.highlight and ui.highlight.writePdfAnnotation then
            pcall(ui.highlight.writePdfAnnotation, ui.highlight, "content", ann, ann.note or "")
        end
    end)
    -- KOReader has just stamped it "modified now"; the change was made in
    -- Zotero, at the time Zotero recorded
    ann.datetime_updated = modified or keep
    self.touched = true
end

function OpenList:get(key)
    return self.ui.doc_settings:readSetting(key)
end

function OpenList:set(key, value)
    if value == nil then
        self.ui.doc_settings:delSetting(key)
    else
        self.ui.doc_settings:saveSetting(key, value)
    end
end

function OpenList:flush()
    local ui = self.ui
    local ok, err = pcall(ui.saveSettings, ui)
    if not ok then
        logger.warn("Zotero: saving document settings failed:", tostring(err))
        return false
    end
    return true
end

function OpenList:close()
end

-- ---------------------------------------------------------------------------
-- EPUB documents damaged by earlier plugin versions
-- ---------------------------------------------------------------------------

local function is_rolling_annotation(a)
    if type(a) ~= "table" or type(a.page) ~= "string" then return false end
    if a.drawer then
        return type(a.pos0) == "string" and type(a.pos1) == "string"
    end
    return true
end

--- Earlier versions wrote Zotero annotations into EPUB sidecars in the PDF
-- format. KOReader cannot display those, and when one of them happened to be
-- first in the list it set the whole list aside (as "annotations_paging"),
-- hiding the user's real highlights. Remove the broken entries (they are
-- imported again properly) and bring the real ones back.
-- @return number removed, number restored
function Doc.repairRolling(ui)
    if not ui or not ui.rolling or not ui.annotation then return 0, 0 end
    local doc = ui.document
    local anns = ui.annotation.annotations
    if type(anns) ~= "table" then return 0, 0 end
    local removed, restored = 0, 0
    for i = #anns, 1, -1 do
        local a = anns[i]
        if not is_rolling_annotation(a)
            and type(a) == "table" and (a.zoteroKey or a.zoteroCfi or a.zoteroAnnotationPosition) then
            table.remove(anns, i)
            removed = removed + 1
        end
    end
    local ds = ui.doc_settings
    local aside = ds and ds:readSetting("annotations_paging")
    if type(aside) == "table" then
        local keep = {}
        for _, a in ipairs(aside) do
            if is_rolling_annotation(a) then
                local valid = doc:isXPointerInDocument(a.page) and (not a.pos1 or doc:isXPointerInDocument(a.pos1))
                if valid then
                    local dup = false
                    for _, b in ipairs(anns) do
                        if b.page == a.page and b.pos1 == a.pos1 and (not a.drawer) == (not b.drawer) then
                            dup = true
                            break
                        end
                    end
                    if not dup then
                        local ok = pcall(ui.annotation.addItem, ui.annotation, a)
                        if ok then restored = restored + 1 else keep[#keep + 1] = a end
                    end
                else
                    keep[#keep + 1] = a
                end
            elseif type(a) == "table" and (a.zoteroKey or a.zoteroCfi or a.zoteroAnnotationPosition) then
                removed = removed + 1 -- ours, and broken: gone
            else
                keep[#keep + 1] = a
            end
        end
        if #keep == 0 then
            ds:delSetting("annotations_paging")
        else
            ds:saveSetting("annotations_paging", keep)
        end
    end
    if removed + restored > 0 then
        pcall(function() ui.view:resetHighlightBoxesCache() end)
        logger.info("Zotero: repaired EPUB annotation list:", removed, "broken entries removed,", restored, "highlights restored")
    end
    return removed, restored
end

-- ---------------------------------------------------------------------------
-- Converters
-- ---------------------------------------------------------------------------

--- PDF. Works with or without the reader: the file is opened on demand.
-- @param document an open PdfDocument, or nil
-- @param remote_items the attachment's Zotero annotations (page label numbering)
function Doc.pdfConverter(file_path, document, remote_items)
    local ctx = Annotations.newPdfContext(file_path, document)
    local label_for = Annotations.labelGuesser(remote_items)
    local conv = { available = true }

    function conv.to_local(item)
        local ok, ann, how = pcall(Annotations.zoteroToKOReaderPdf, item, ctx)
        if not ok then
            logger.warn("Zotero: PDF annotation conversion failed:", tostring(ann))
            return nil, "conversion error"
        end
        return ann, how
    end

    function conv.to_remote(ann)
        local ok, res, err = pcall(Annotations.koreaderToZoteroPdf, ann, ctx, { label_for = label_for })
        if not ok then
            logger.warn("Zotero: PDF position conversion failed:", tostring(res))
            return nil, "conversion error"
        end
        return res, err
    end

    --- Does the annotation's position select the annotation's own text?
    -- true / false, or nil when that cannot be determined.
    function conv.verify_local(ann, item)
        if type(ann.pos0) ~= "table" or type(ann.pos1) ~= "table" then return false end
        local page = tonumber(ann.pos0.page) or tonumber(ann.page)
        if not page then return false end
        if tonumber(ann.pos1.page) and tonumber(ann.pos1.page) ~= page then
            return true -- a highlight across pages: leave it alone
        end
        local ok, res = pcall(Annotations.pdfPositionMatchesText, ann, ctx)
        if not ok then
            logger.warn("Zotero: PDF position check failed:", tostring(res))
            return nil
        end
        if res ~= nil then return res end
        -- No text on this page to check against (a scan): compare with where
        -- Zotero's own position falls.
        if not item then return true end
        local placed = conv.to_local(item)
        if not placed or type(placed.pos0) ~= "table" then return true end
        local function far(p, q)
            return math.abs((tonumber(p.x) or 0) - (tonumber(q.x) or 0)) > 12
                or math.abs((tonumber(p.y) or 0) - (tonumber(q.y) or 0)) > 12
        end
        return not (placed.page ~= page or far(placed.pos0, ann.pos0) or far(placed.pos1, ann.pos1))
    end

    function conv.close()
        ctx:close()
    end
    return conv
end

--- EPUB. Positions can only be converted while the book is open in the
-- reader (the conversion needs crengine's rendered document).
-- @param document the open CreDocument, or nil
function Doc.epubConverter(document)
    if not document then
        return {
            available = false,
            to_local = function() return nil, "deferred" end,
            to_remote = function() return nil, "deferred" end,
            verify_local = function() return nil end,
            close = function() end,
        }
    end
    local session = Epub.newSession(document)
    local conv = { available = true }

    function conv.to_local(item)
        local d = item.data or {}
        local ok, xp0, xp1, how = pcall(session.fromZotero, session, d.annotationPosition, d.annotationText, d.annotationSortIndex)
        if not ok then
            logger.warn("Zotero: EPUB annotation conversion failed:", tostring(xp0))
            return nil, "conversion error"
        end
        if not xp0 then return nil, xp1 end
        local ann = {
            page = xp0,
            pos0 = xp0,
            pos1 = xp1,
            text = d.annotationText or "",
            color = Annotations.zoteroColorToKOReader(d.annotationColor),
            drawer = Annotations.zoteroTypeToDrawer(d.annotationType),
        }
        if d.annotationComment and d.annotationComment ~= "" then ann.note = d.annotationComment end
        Annotations.applyRemoteDates(ann, item)
        return ann, how
    end

    function conv.to_remote(ann)
        if type(ann.pos0) ~= "string" or type(ann.pos1) ~= "string" then
            return nil, "not an EPUB highlight"
        end
        local ok, res, err = pcall(session.toZotero, session, ann.pos0, ann.pos1)
        if not ok then
            logger.warn("Zotero: EPUB position conversion failed:", tostring(res))
            return nil, "conversion error"
        end
        return res, err
    end

    function conv.verify_local(ann)
        if type(ann.pos0) ~= "string" or type(ann.pos1) ~= "string" then return false end
        local ok0, in0 = pcall(document.isXPointerInDocument, document, ann.pos0)
        local ok1, in1 = pcall(document.isXPointerInDocument, document, ann.pos1)
        if not (ok0 and in0 and ok1 and in1) then return false end
        local needle = Util.normText(ann.text or "")
        if needle == "" then return true end
        local okt, got = pcall(document.getTextFromXPointers, document, ann.pos0, ann.pos1)
        got = okt and type(got) == "string" and Util.normText(got) or ""
        if got == "" then return false end
        return Util.samePassage(got, needle)
    end

    function conv.close()
        session:close()
    end
    return conv
end

--- Work out and store the Zotero positions of EPUB highlights that still
-- have to be uploaded, while the book is open. A later sync can then send
-- them without opening the book.
-- @return number of positions stored
function Doc.cacheEpubPositions(ui)
    if not ui or not ui.rolling or not ui.annotation then return 0 end
    local conv
    local n = 0
    for _, ann in ipairs(ui.annotation.annotations) do
        if type(ann) == "table" and ann.drawer and type(ann.pos0) == "string" and type(ann.pos1) == "string" then
            local sig = Annotations.localPositionSignature(ann)
            local base = type(ann.zoteroSync) == "table" and ann.zoteroSync.l
            local needs
            if not ann.zoteroKey or (tonumber(ann.zoteroVersion) or 0) == 0 then
                needs = true -- not in Zotero yet
            elseif type(base) == "table" then
                needs = base.pos ~= Annotations.localFields(ann).pos -- moved since the last sync
            end
            if needs and not (type(ann.zoteroPos) == "table" and ann.zoteroPos.sig == sig) then
                conv = conv or Doc.epubConverter(ui.document)
                local res = conv.to_remote(ann)
                if res then
                    ann.zoteroPos = { sig = sig, position = res.position, sortIndex = res.sortIndex, pageLabel = res.pageLabel }
                    n = n + 1
                end
            end
        end
    end
    if conv then conv.close() end
    return n
end

return Doc
