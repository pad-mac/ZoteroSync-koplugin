--[[--
Conversion between Zotero annotation items and KOReader annotations.

PDF positions
-------------
Zotero stores highlight rectangles in PDF user space. KOReader does not draw
stored rectangles at all: it stores two points (pos0/pos1) and re-derives the
highlight from the *words* between them in the page's reading order. So an
imported highlight is only right if those two points sit inside the first and
the last highlighted word.

This module therefore
  1. converts the Zotero rectangles with the page's real transform
     (CropBox origin, /Rotate, /UserUnit: see zotero_pdfgeom),
  2. finds the words MuPDF reports under those rectangles and anchors
     pos0/pos1 on the centres of the first and last of them,
  3. cross-checks the resulting text against Zotero's `annotationText`, and
     if the geometry disagrees (e.g. a page box it could not read), locates
     the passage by its text instead.

The reverse direction turns KOReader's line boxes back into PDF user space.

EPUB positions are handled by zotero_epub; this module only maps the
non-positional fields for them.
]]

local Geom = require("zotero_pdfgeom")
local Util = require("zotero_util")
local logger = require("logger")

local Annotations = { fork = "0.6" }

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------

-- Zotero's reader palette.
local ZOTERO_COLORS = {
    yellow  = "#ffd400",
    red     = "#ff6666",
    green   = "#5fb236",
    blue    = "#2ea8e5",
    purple  = "#a28ae5",
    magenta = "#e56eee",
    orange  = "#f19837",
    gray    = "#aaaaaa",
}

-- KOReader colour name -> hex sent to Zotero. Always lowercase: the Zotero
-- server rejects anything that does not match ^#[0-9a-z]{6}$.
local K2Z_COLORS = {
    red    = ZOTERO_COLORS.red,
    orange = ZOTERO_COLORS.orange,
    yellow = ZOTERO_COLORS.yellow,
    green  = ZOTERO_COLORS.green,
    olive  = "#88ff77",
    cyan   = "#00ffee",
    blue   = ZOTERO_COLORS.blue,
    purple = ZOTERO_COLORS.purple,
    magenta = ZOTERO_COLORS.magenta, -- not a KOReader colour; see zotero_colors
    gray   = ZOTERO_COLORS.gray,
}

-- Exact Zotero hex -> KOReader colour name.
local Z2K_EXACT = {
    ["#ffd400"] = "yellow",
    ["#ff6666"] = "red",
    ["#5fb236"] = "green",
    ["#2ea8e5"] = "blue",
    ["#a28ae5"] = "purple",
    ["#e56eee"] = "magenta", -- made a colour of the reader by zotero_colors
    ["#f19837"] = "orange",
    ["#aaaaaa"] = "gray",
    ["#88ff77"] = "olive",
    ["#00ffee"] = "cyan",
    ["#0066ff"] = "blue",   -- written by earlier versions of this plugin
}

-- Reference RGB values for nearest-colour matching of custom Zotero colours.
local NEAREST = {
    { "yellow", 255, 212, 0 },   { "yellow", 255, 255, 51 },
    { "red", 255, 102, 102 },    { "red", 255, 51, 0 },
    { "green", 95, 178, 54 },    { "green", 0, 170, 102 },
    { "blue", 46, 168, 229 },    { "blue", 0, 102, 255 },
    { "purple", 162, 138, 229 }, { "magenta", 229, 110, 238 }, { "purple", 238, 0, 255 },
    { "orange", 241, 152, 55 },  { "orange", 255, 136, 0 },
    { "olive", 136, 255, 119 },
    { "cyan", 0, 255, 238 },
    { "gray", 170, 170, 170 },
}

-- What the pre-0.6 import wrote for a given Zotero colour. Needed once, to
-- recognise "unchanged" colours on annotations imported by older versions.
local LEGACY_Z2K = {
    ["#ffd400"] = "yellow", ["#ff6666"] = "red", ["#5fb236"] = "green",
    ["#2ea8e5"] = "blue", ["#a28ae5"] = "purple", ["#e56eee"] = "red",
    ["#f19837"] = "orange", ["#aaaaaa"] = "gray",
}

local default_upload_color = ZOTERO_COLORS.gray

--- Colour used for KOReader highlights that carry no colour of their own.
function Annotations.setDefaultColor(name)
    if type(name) == "string" and K2Z_COLORS[name:lower()] then
        default_upload_color = K2Z_COLORS[name:lower()]
    end
end

local function normalize_hex(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:lower()
    if hex:match("^#%x%x%x%x%x%x$") then return hex end
    if hex:match("^%x%x%x%x%x%x$") then return "#" .. hex end
    return nil
end
Annotations.normalizeHex = normalize_hex

--- Zotero hex colour -> KOReader colour name (never nil).
function Annotations.zoteroColorToKOReader(hex)
    hex = normalize_hex(hex)
    if not hex then return "yellow" end
    local exact = Z2K_EXACT[hex]
    if exact then return exact end
    local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
    local best, best_d
    for _, ref in ipairs(NEAREST) do
        local d = (r - ref[2]) ^ 2 + (g - ref[3]) ^ 2 + (b - ref[4]) ^ 2
        if not best_d or d < best_d then best, best_d = ref[1], d end
    end
    return best or "yellow"
end

--- KOReader colour name -> lowercase Zotero hex.
function Annotations.koreaderColorToZotero(name)
    if type(name) ~= "string" or name == "" then return default_upload_color end
    return K2Z_COLORS[name:lower()] or ZOTERO_COLORS.yellow
end

--- A better colour name for a local annotation whose colour was imported
-- before the reader had a name for it (Zotero's magenta used to become
-- purple, or red in older versions).
-- @return the name, or nil when the local name is fine
function Annotations.betterColorName(name, hex)
    if type(name) ~= "string" or name == "" then return nil end
    name = name:lower()
    hex = normalize_hex(hex)
    if not hex or not K2Z_COLORS[name] then return nil end
    if K2Z_COLORS[name] == hex then return nil end -- says exactly what Zotero has
    local exact = Z2K_EXACT[hex]
    if exact and exact ~= name then return exact end
    return nil
end

--- The colour name older plugin versions stored for this Zotero colour.
function Annotations.legacyColorName(hex)
    hex = normalize_hex(hex)
    return hex and (LEGACY_Z2K[hex] or "yellow") or "yellow"
end

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

local K2Z_TYPE = { underscore = "underline", lighten = "highlight", strikeout = "highlight", invert = "highlight" }
local Z2K_TYPE = { underline = "underscore", highlight = "lighten" }

function Annotations.supportedZoteroTypes()
    return { "highlight", "underline" }
end

function Annotations.isSupportedZoteroType(t)
    return Z2K_TYPE[t] ~= nil
end

function Annotations.drawerToZoteroType(drawer)
    return K2Z_TYPE[tostring(drawer or ""):lower()] or "highlight"
end

function Annotations.zoteroTypeToDrawer(t)
    return Z2K_TYPE[t] or "lighten"
end

function Annotations.isPdfPath(file_path)
    return file_path ~= nil and string.lower(file_path):match("%.pdf$") ~= nil
end

function Annotations.isEpubPath(file_path)
    return file_path ~= nil and string.lower(file_path):match("%.epub$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Field views used by the sync engine
-- ---------------------------------------------------------------------------

--- A compact signature of where a local annotation sits. Changes when the
-- user moves the highlight's boundaries in KOReader.
function Annotations.localPositionSignature(ann)
    if type(ann.pos0) == "table" then
        local p0, p1 = ann.pos0, ann.pos1 or ann.pos0
        return string.format("%s:%.1f,%.1f;%s:%.1f,%.1f",
            tostring(p0.page or ann.page), tonumber(p0.x) or 0, tonumber(p0.y) or 0,
            tostring(p1.page or ann.page), tonumber(p1.x) or 0, tonumber(p1.y) or 0)
    end
    return tostring(ann.pos0 or ann.page or "") .. ";" .. tostring(ann.pos1 or "")
end

--- Comparable values of a local annotation.
function Annotations.localFields(ann)
    return {
        text = Util.hash(ann.text or ""),
        note = Util.hash(ann.note or ""),
        color = ann.color and tostring(ann.color):lower() or "",
        type = Annotations.drawerToZoteroType(ann.drawer),
        pos = Util.hash(Annotations.localPositionSignature(ann)),
    }
end

--- Comparable values of a Zotero annotation item.
function Annotations.remoteFields(item)
    local d = item.data or {}
    return {
        text = Util.hash(d.annotationText or ""),
        note = Util.hash(d.annotationComment or ""),
        color = normalize_hex(d.annotationColor) or "",
        type = d.annotationType or "",
        pos = Util.hash(d.annotationPosition or ""),
    }
end

-- ---------------------------------------------------------------------------
-- Timestamps
-- ---------------------------------------------------------------------------

--- Fill datetime / datetime_updated of a KOReader annotation from a Zotero item.
function Annotations.applyRemoteDates(ann, item)
    local d = item.data or {}
    local added = Util.utcIsoToLocal(d.dateAdded) or Util.utcIsoToLocal(d.dateModified)
    local modified = Util.utcIsoToLocal(d.dateModified)
    if not ann.datetime then
        ann.datetime = added or Util.nowLocal()
    end
    if modified and modified ~= ann.datetime then
        ann.datetime_updated = modified
    end
end

-- ---------------------------------------------------------------------------
-- PDF page context
-- ---------------------------------------------------------------------------

local PdfContext = {}
PdfContext.__index = PdfContext

--- Create a context for converting annotations of one PDF file.
-- @param file_path path of the PDF
-- @param document an already open KOReader PdfDocument, or nil to open the
--        file lazily (and only if something actually needs MuPDF)
function Annotations.newPdfContext(file_path, document)
    return setmetatable({
        file = file_path,
        doc = document,
        owns_doc = false,
        pages = {},
        boxes = {},
    }, PdfContext)
end

function PdfContext:document()
    if self.doc then return self.doc end
    if self.doc_failed then return nil end
    local ok, doc = pcall(function()
        local DocumentRegistry = require("document/documentregistry")
        return DocumentRegistry:openDocument(self.file)
    end)
    if ok and doc and not doc.is_locked then
        self.doc = doc
        self.owns_doc = true
        return doc
    end
    if ok and doc then pcall(doc.close, doc) end
    self.doc_failed = true
    logger.warn("Zotero: could not open", self.file, "for annotation conversion")
    return nil
end

function PdfContext:geometry()
    if self.geom ~= nil then return self.geom or nil end
    local geom, err = Geom.open(self.file)
    if not geom then
        logger.info("Zotero: page boxes not readable for", self.file, "-", tostring(err))
        self.geom = false
        return nil
    end
    self.geom = geom
    return geom
end

--- Page transform and size for a 1-based page number:
-- { ctm, inv, w, h, pdf_h, exact } or nil.
function PdfContext:pageInfo(pageno)
    local cached = self.pages[pageno]
    if cached ~= nil then return cached or nil end
    local result
    local geom = self:geometry()
    local ginfo = geom and geom:pageInfo(pageno) or nil
    local ctm, gw, gh
    if ginfo then
        ctm, gw, gh = Geom.pageMatrix(ginfo)
    end
    -- MuPDF's own page size, when a document is at hand, validates what was
    -- read from the file.
    local w, h
    local doc = self.doc or (not ctm and self:document()) or nil
    if doc then
        local ok, dims = pcall(doc.getNativePageDimensions, doc, pageno)
        if ok and dims then w, h = dims.w, dims.h end
    end
    if ctm and w and (math.abs(gw - w) > 1 or math.abs(gh - h) > 1) then
        logger.warn(string.format("Zotero: page %d box mismatch (%.1fx%.1f vs MuPDF %.1fx%.1f), using fallback",
            pageno, gw, gh, w, h))
        ctm = nil
    end
    if ctm then
        local mb = ginfo.mediabox
        local box = { math.min(mb[1], mb[3]), math.min(mb[2], mb[4]), math.max(mb[1], mb[3]), math.max(mb[2], mb[4]) }
        if ginfo.cropbox then
            local cb = ginfo.cropbox
            box = {
                math.max(box[1], math.min(cb[1], cb[3])), math.max(box[2], math.min(cb[2], cb[4])),
                math.min(box[3], math.max(cb[1], cb[3])), math.min(box[4], math.max(cb[2], cb[4])),
            }
        end
        result = { ctm = ctm, inv = Geom.invert(ctm), w = gw, h = gh, pdf_h = box[4] - box[2], exact = true }
    elseif w and h then
        ctm = Geom.defaultMatrix(w, h)
        result = { ctm = ctm, inv = Geom.invert(ctm), w = w, h = h, pdf_h = h, exact = false }
    end
    if result and not result.inv then result = nil end
    self.pages[pageno] = result or false
    return result
end

--- Word boxes of a page (lines of words, MuPDF reading order), or nil.
function PdfContext:textBoxes(pageno)
    local cached = self.boxes[pageno]
    if cached ~= nil then return cached or nil end
    local doc = self:document()
    local boxes
    if doc then
        local saved = doc.configurable and doc.configurable.text_wrap
        if doc.configurable then doc.configurable.text_wrap = 0 end -- native coordinates
        local ok, res = pcall(doc.getTextBoxes, doc, pageno)
        if doc.configurable then doc.configurable.text_wrap = saved end
        if ok and type(res) == "table" and #res > 0 then boxes = res end
    end
    self.boxes[pageno] = boxes or false
    return boxes
end

--- The line boxes KOReader itself would draw between two positions.
function PdfContext:lineBoxes(pageno, pos0, pos1)
    local doc = self:document()
    if not doc then return nil end
    local saved = doc.configurable and doc.configurable.text_wrap
    if doc.configurable then doc.configurable.text_wrap = 0 end
    local ok, res = pcall(doc.getPageBoxesFromPositions, doc, pageno, pos0, pos1)
    if doc.configurable then doc.configurable.text_wrap = saved end
    if not ok or type(res) ~= "table" or #res == 0 then return nil end
    local out = {}
    for i, b in ipairs(res) do
        out[i] = { x = b.x, y = b.y, w = b.w, h = b.h }
    end
    return out
end

function PdfContext:pageLabel(pageno)
    local geom = self:geometry()
    if not geom then return nil end
    local ok, label = pcall(geom.pageLabel, geom, pageno)
    if ok then return label end
    return nil
end

function PdfContext:close()
    if self.geom then
        self.geom:close()
    end
    self.geom = nil
    if self.owns_doc and self.doc then
        pcall(self.doc.close, self.doc)
    end
    self.doc = nil
    self.owns_doc = false
end

-- ---------------------------------------------------------------------------
-- Matching rectangles to words
-- ---------------------------------------------------------------------------

local function word_center(w)
    return (w.x0 + w.x1) / 2, (w.y0 + w.y1) / 2
end

--- Words covered by a set of page-space rectangles.
-- A word counts as covered when its centre lies inside a rectangle. That is
-- the "at least half the word is selected" rule, and it does not care which
-- way the text runs (pages with /Rotate have vertical lines in page space).
-- Returns first {i,j}, last {i,j}, number of covered words, words in the span.
local function cover_words(boxes, rects)
    local first_i, first_j, last_i, last_j
    local covered = 0
    local best_i, best_j, best_overlap = nil, nil, 0
    for i = 1, #boxes do
        local line = boxes[i]
        for j = 1, #line do
            local w = line[j]
            if w.x1 > w.x0 and w.y1 > w.y0 then
                local cx, cy = word_center(w)
                for r = 1, #rects do
                    local rc = rects[r]
                    local tol = math.min(rc.w, rc.h) * 0.1
                    if cx >= rc.x - tol and cx <= rc.x + rc.w + tol
                        and cy >= rc.y - tol and cy <= rc.y + rc.h + tol then
                        covered = covered + 1
                        if not first_i then first_i, first_j = i, j end
                        last_i, last_j = i, j
                        break
                    end
                    local ow = math.min(w.x1, rc.x + rc.w) - math.max(w.x0, rc.x)
                    local oh = math.min(w.y1, rc.y + rc.h) - math.max(w.y0, rc.y)
                    if ow > 0 and oh > 0 and ow * oh > best_overlap then
                        best_i, best_j, best_overlap = i, j, ow * oh
                    end
                end
            end
        end
    end
    if not first_i and best_i then
        -- a selection smaller than half of any word: take the word it touches most
        first_i, first_j, last_i, last_j, covered = best_i, best_j, best_i, best_j, 1
    end
    if not first_i then return nil end
    local span = 0
    for i = first_i, last_i do
        local from = i == first_i and first_j or 1
        local to = i == last_i and last_j or #boxes[i]
        span = span + math.max(0, to - from + 1)
    end
    return { first_i, first_j }, { last_i, last_j }, covered, span
end

local function span_text(boxes, first, last)
    local parts = {}
    for i = first[1], last[1] do
        local from = i == first[1] and first[2] or 1
        local to = i == last[1] and last[2] or #boxes[i]
        for j = from, to do
            local word = boxes[i][j].word
            if word then parts[#parts + 1] = word end
        end
    end
    return table.concat(parts, " ")
end

local function common_prefix(a, b)
    local n = math.min(#a, #b)
    for i = 1, n do
        if a:byte(i) ~= b:byte(i) then return i - 1 end
    end
    return n
end

local function common_suffix(a, b)
    local n = math.min(#a, #b)
    for i = 0, n - 1 do
        if a:byte(#a - i) ~= b:byte(#b - i) then return i end
    end
    return n
end

--- Is the run of words first..last the passage `text`?
-- Zotero selects characters and KOReader whole words, so the two may differ
-- by a partly selected word at either end, but by no more than that: a run
-- that merely *contains* the passage is not the passage.
local function span_matches(boxes, first, last, text)
    local needle = Util.normText(text or "")
    if needle == "" then return true end -- nothing to compare against
    local got = Util.normText(span_text(boxes, first, last))
    if got == "" then return false end
    if got == needle then return true end
    local p = got:find(needle, 1, true)
    if p then
        -- the run is longer: only by the rest of its first and its last word
        local first_len = #Util.normText(boxes[first[1]][first[2]].word or "")
        local last_len = #Util.normText(boxes[last[1]][last[2]].word or "")
        return (p - 1) < math.max(first_len, 1) and (#got - (p - 1 + #needle)) < math.max(last_len, 1)
    end
    p = needle:find(got, 1, true)
    if p then
        -- the passage is longer: only by a partial word at each end
        local first_token = text:match("^%s*(%S+)") or ""
        local last_token = text:match("(%S+)%s*$") or ""
        return (p - 1) < math.max(#Util.normText(first_token), 1)
            and (#needle - (p - 1 + #got)) < math.max(#Util.normText(last_token), 1)
    end
    -- Neither contains the other: the two text extractors disagree somewhere
    -- inside (a ligature, a hyphen). Same beginning, same end, same length.
    local longer = math.max(#got, #needle)
    if math.abs(#got - #needle) > math.max(4, math.floor(longer * 0.05)) then return false end
    local need = math.max(3, math.min(12, math.floor(math.min(#got, #needle) * 0.4)))
    return common_prefix(got, needle) >= need and common_suffix(got, needle) >= need
end

--- Build the page's normalised character stream with a map back to words.
local function page_stream(boxes)
    local parts, owners = {}, {}
    local pos = 0
    for i = 1, #boxes do
        local line = boxes[i]
        for j = 1, #line do
            local word = line[j].word
            if word then
                local n = Util.normText(word)
                if n ~= "" then
                    parts[#parts + 1] = n
                    owners[#owners + 1] = { start = pos + 1, stop = pos + #n, i = i, j = j }
                    pos = pos + #n
                end
            end
        end
    end
    return table.concat(parts), owners
end

local function owner_at(owners, charpos)
    local lo, hi = 1, #owners
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local o = owners[mid]
        if charpos < o.start then hi = mid - 1
        elseif charpos > o.stop then lo = mid + 1
        else return o end
    end
    return nil
end

--- Locate a passage on a page by its text. Several occurrences are told
-- apart by `hint`: { x =, y = } (distance to a point in page space) or
-- { offset = } (character offset in the page text, from Zotero's sort index;
-- used when the page transform is not trustworthy).
-- Returns first {i,j}, last {i,j} or nil.
local function find_by_text(boxes, needle, hint)
    if #needle < 3 then return nil end
    local stream, owners = page_stream(boxes)
    if stream == "" then return nil end
    hint = hint or {}
    local best, best_d
    local from = 1
    local guard = 0
    while guard < 500 do
        guard = guard + 1
        local s, e = stream:find(needle, from, true)
        if not s then break end
        local o1, o2 = owner_at(owners, s), owner_at(owners, e)
        if o1 and o2 then
            local d = 0
            if hint.offset then
                d = math.abs(s - hint.offset)
            elseif hint.x then
                local cx, cy = word_center(boxes[o1.i][o1.j])
                d = (cx - hint.x) ^ 2 + (cy - hint.y) ^ 2
            end
            if not best_d or d < best_d then
                best, best_d = { { o1.i, o1.j }, { o2.i, o2.j } }, d
            end
        end
        from = s + 1
    end
    if best then return best[1], best[2] end
    return nil
end

-- ---------------------------------------------------------------------------
-- Zotero -> KOReader (PDF)
-- ---------------------------------------------------------------------------

local function page_rects(info, raw_rects)
    local rects = {}
    if type(raw_rects) ~= "table" then return rects end
    for _, r in ipairs(raw_rects) do
        if type(r) == "table" and tonumber(r[1]) and tonumber(r[2]) and tonumber(r[3]) and tonumber(r[4]) then
            local x0, y0, x1, y1 = Geom.applyRect(info.ctm, r[1], r[2], r[3], r[4])
            if x1 - x0 > 0.01 and y1 - y0 > 0.01 then
                rects[#rects + 1] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
            end
        end
    end
    return rects
end

--- Convert a Zotero PDF annotation item to a KOReader annotation.
-- @return annotation table, or nil and a reason string
function Annotations.zoteroToKOReaderPdf(item, ctx)
    local data = item and item.data
    if type(data) ~= "table" then return nil, "no data" end
    local pos = Util.jsonDecode(data.annotationPosition)
    if type(pos) ~= "table" or type(pos.pageIndex) ~= "number" then
        return nil, "no page position"
    end
    local pageno = pos.pageIndex + 1
    local info = ctx:pageInfo(pageno)
    if not info then return nil, "page geometry unavailable" end
    local rects = page_rects(info, pos.rects)
    if #rects == 0 then return nil, "no rectangles" end

    local needle = Util.normText(data.annotationText or "")
    local boxes = ctx:textBoxes(pageno)
    local first, last
    local how = "geometry"
    if boxes then
        local covered, span
        first, last, covered, span = cover_words(boxes, rects)
        local agrees = false
        if first then
            agrees = span_matches(boxes, first, last, data.annotationText)
        end
        if not agrees and needle ~= "" then
            -- Geometry and text disagree (or nothing was hit): trust the text.
            -- With a reliable transform, the rectangle tells repeated
            -- passages apart; without one, Zotero's character offset does.
            local head_hint = { x = rects[1].x + rects[1].w / 2, y = rects[1].y + rects[1].h / 2 }
            local lr = rects[#rects]
            local tail_hint = { x = lr.x + lr.w / 2, y = lr.y + lr.h / 2 }
            if not info.exact then
                local offset = tonumber(tostring(data.annotationSortIndex or ""):match("^%d+|(%d+)|"))
                if offset then
                    head_hint = { offset = offset }
                    tail_hint = { offset = offset + #needle }
                end
            end
            local tf, tl = find_by_text(boxes, needle, head_hint)
            if not tf and #needle > 40 then
                -- very long passages: anchor head and tail separately
                local hf = find_by_text(boxes, needle:sub(1, 24), head_hint)
                local _, tl2 = find_by_text(boxes, needle:sub(-24), tail_hint)
                if hf and tl2 and (tl2[1] > hf[1] or (tl2[1] == hf[1] and tl2[2] >= hf[2])) then
                    tf, tl = hf, tl2
                end
            end
            if tf then
                first, last = tf, tl
                how = "text"
            elseif first then
                how = "geometry-unverified"
                logger.info("Zotero: annotation", tostring(item.key), "page", pageno,
                    "placed by geometry only; text did not match",
                    covered and string.format("(%d/%d words)", covered, span or 0) or "")
            end
        end
    end

    local pos0, pos1, pboxes
    if first then
        local w0, w1 = boxes[first[1]][first[2]], boxes[last[1]][last[2]]
        local x0, y0 = word_center(w0)
        local x1, y1 = word_center(w1)
        pos0 = { x = x0, y = y0, page = pageno, rotation = 0 }
        pos1 = { x = x1, y = y1, page = pageno, rotation = 0 }
        pboxes = ctx:lineBoxes(pageno, pos0, pos1)
    else
        -- No text layer to anchor on: points inside the first and last rectangle.
        how = "rects"
        local a, b = rects[1], rects[#rects]
        pos0 = { x = a.x + math.min(a.w / 2, 3), y = a.y + a.h / 2, page = pageno, rotation = 0 }
        pos1 = { x = b.x + b.w - math.min(b.w / 2, 3), y = b.y + b.h / 2, page = pageno, rotation = 0 }
    end
    if not pboxes then
        pboxes = {}
        for i, r in ipairs(rects) do pboxes[i] = { x = r.x, y = r.y, w = r.w, h = r.h } end
    end

    local ann = {
        page = pageno,
        pos0 = pos0,
        pos1 = pos1,
        pboxes = pboxes,
        text = data.annotationText or "",
        color = Annotations.zoteroColorToKOReader(data.annotationColor),
        drawer = Annotations.zoteroTypeToDrawer(data.annotationType),
        zoteroKey = item.key,
        zoteroVersion = tonumber(item.version) or 0,
    }
    if data.annotationComment and data.annotationComment ~= "" then
        ann.note = data.annotationComment
    end
    Annotations.applyRemoteDates(ann, item)
    return ann, how
end

-- ---------------------------------------------------------------------------
-- KOReader -> Zotero (PDF)
-- ---------------------------------------------------------------------------

--- Remove the overlap between consecutive line rectangles. KOReader's line
-- boxes are full line height and overlap on tightly set text; overlapping
-- rectangles show up as dark bands in Zotero. Lines stack along whichever
-- axis they overlap least on (pages with /Rotate have vertical lines).
local function trim_overlaps(list)
    for i = 1, #list - 1 do
        local a, b = list[i], list[i + 1]
        local ox = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
        local oy = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
        if ox > 0 and oy > 0 then
            if oy / math.min(a.h, b.h) <= ox / math.min(a.w, b.w) then
                -- stacked vertically
                if b.y > a.y then
                    local mid = (a.y + a.h + b.y) / 2
                    a.h = mid - a.y
                    b.h = b.y + b.h - mid
                    b.y = mid
                elseif a.y > b.y then
                    local mid = (b.y + b.h + a.y) / 2
                    b.h = mid - b.y
                    a.h = a.y + a.h - mid
                    a.y = mid
                end
            else
                -- stacked horizontally
                if b.x > a.x then
                    local mid = (a.x + a.w + b.x) / 2
                    a.w = mid - a.x
                    b.w = b.x + b.w - mid
                    b.x = mid
                elseif a.x > b.x then
                    local mid = (b.x + b.w + a.x) / 2
                    b.w = mid - b.x
                    a.w = a.x + a.w - mid
                    a.x = mid
                end
            end
        end
    end
    return list
end

--- Index of the word box a position refers to, exactly as KOReader picks it
-- (the box containing the point, else the one whose centre is nearest).
local function word_indices(boxes, pos)
    local m, n, best = 1, 1, nil
    for i = 1, #boxes do
        local line = boxes[i]
        for j = 1, #line do
            local b = line[j]
            local d
            if b.x0 <= pos.x and b.y0 <= pos.y and b.x1 >= pos.x and b.y1 >= pos.y then
                d = 0
            else
                local cx, cy = word_center(b)
                d = (pos.x - cx) ^ 2 + (pos.y - cy) ^ 2
            end
            if not best or d < best then
                m, n, best = i, j, d
            end
        end
    end
    if not best then return nil end
    return m, n
end

--- Does a local PDF highlight select its own text?
-- @return true / false, or nil when the page has no text to check against
function Annotations.pdfPositionMatchesText(ann, ctx)
    if type(ann.pos0) ~= "table" or type(ann.pos1) ~= "table" then return false end
    local pageno = tonumber(ann.pos0.page) or tonumber(ann.page)
    if not pageno or not tonumber(ann.pos0.x) or not tonumber(ann.pos1.x) then return false end
    local boxes = ctx:textBoxes(pageno)
    if not boxes then return nil end
    local i0, j0 = word_indices(boxes, ann.pos0)
    local i1, j1 = word_indices(boxes, ann.pos1)
    if not i0 or not i1 then return false end
    if i0 > i1 or (i0 == i1 and j0 > j1) then
        i0, j0, i1, j1 = i1, j1, i0, j0
    end
    return span_matches(boxes, { i0, j0 }, { i1, j1 }, ann.text or "")
end

--- One rectangle per text line for the words between two positions, built
-- from the word boxes themselves so it is right for any text direction.
local function selection_boxes(boxes, p0, p1)
    local i0, j0 = word_indices(boxes, p0)
    local i1, j1 = word_indices(boxes, p1)
    if not i0 or not i1 then return nil end
    if i0 > i1 or (i0 == i1 and j0 > j1) then
        i0, j0, i1, j1 = i1, j1, i0, j0
    end
    local out = {}
    for i = i0, i1 do
        local line = boxes[i]
        local from = i == i0 and j0 or 1
        local to = i == i1 and j1 or #line
        local x0, y0, x1, y1
        for j = from, to do
            local b = line[j]
            if b and b.x1 > b.x0 and b.y1 > b.y0 then
                x0 = x0 and math.min(x0, b.x0) or b.x0
                y0 = y0 and math.min(y0, b.y0) or b.y0
                x1 = x1 and math.max(x1, b.x1) or b.x1
                y1 = y1 and math.max(y1, b.y1) or b.y1
            end
        end
        if x0 then
            out[#out + 1] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
        end
    end
    if #out == 0 then return nil end
    return out
end

local function boxes_to_pdf_rects(info, pboxes)
    local list = {}
    for _, b in ipairs(pboxes) do
        if tonumber(b.x) and tonumber(b.y) and tonumber(b.w) and tonumber(b.h) and b.w > 0 and b.h > 0 then
            list[#list + 1] = { x = b.x, y = b.y, w = b.w, h = b.h }
        end
    end
    trim_overlaps(list)
    local rects = {}
    for _, b in ipairs(list) do
        if b.w > 0 and b.h > 0 then
            local x0, y0, x1, y1 = Geom.applyRect(info.inv, b.x, b.y, b.x + b.w, b.y + b.h)
            rects[#rects + 1] = { x0, y0, x1, y1 }
        end
    end
    return rects
end

local function rects_json(rects)
    local parts = {}
    for i, r in ipairs(rects) do
        parts[i] = "[" .. Util.fmtNumber(r[1]) .. "," .. Util.fmtNumber(r[2]) .. ","
            .. Util.fmtNumber(r[3]) .. "," .. Util.fmtNumber(r[4]) .. "]"
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

--- Number of characters that precede the word under `pos` in the page text
-- (Zotero sorts annotations on a page by this offset).
local function char_offset(boxes, pos)
    if not boxes or not pos then return 0 end
    local best_d, best_off
    local off = 0
    for i = 1, #boxes do
        local line = boxes[i]
        for j = 1, #line do
            local w = line[j]
            local inside = pos.x >= w.x0 and pos.x <= w.x1 and pos.y >= w.y0 and pos.y <= w.y1
            local cx, cy = word_center(w)
            local d = inside and 0 or ((cx - pos.x) ^ 2 + (cy - pos.y) ^ 2)
            if not best_d or d < best_d then best_d, best_off = d, off end
            off = off + (w.word and Util.utf8Len(w.word) or 1) + 1
        end
    end
    return best_off or 0
end

--- PDF annotation sort index as Zotero formats it: page|offset|top.
function Annotations.pdfSortIndex(page_index, offset, top)
    local function clamp(n, digits)
        n = math.max(0, math.floor(tonumber(n) or 0))
        local max = 10 ^ digits - 1
        if n > max then n = max end
        return string.format("%0" .. digits .. "d", n)
    end
    return clamp(page_index, 5) .. "|" .. clamp(offset, 6) .. "|" .. clamp(top, 5)
end

--- Build the Zotero position of a KOReader PDF highlight.
-- @param opts { label_for = function(pageno) -> string or nil }
-- @return { position = <json string>, sortIndex, pageLabel } or nil, reason
function Annotations.koreaderToZoteroPdf(ann, ctx, opts)
    opts = opts or {}
    if type(ann.pos0) ~= "table" then return nil, "not a PDF highlight" end
    local first_page = tonumber(ann.pos0.page) or tonumber(ann.page)
    local last_page = tonumber(ann.pos1 and ann.pos1.page) or first_page
    if not first_page then return nil, "no page" end

    local function boxes_for(pageno)
        local p0, p1 = ann.pos0, ann.pos1 or ann.pos0
        local stored
        if ann.ext and type(ann.ext[pageno]) == "table" then
            p0, p1 = ann.ext[pageno].pos0 or p0, ann.ext[pageno].pos1 or p1
            stored = ann.ext[pageno].pboxes
        elseif first_page == last_page then
            stored = ann.pboxes
        end
        -- Preferred: the selected words themselves.
        local words = ctx:textBoxes(pageno)
        if words and tonumber(p0.x) and tonumber(p1.x) then
            local sel = selection_boxes(words, p0, p1)
            if sel then return sel end
        end
        -- Otherwise the boxes KOReader stored (or would draw).
        if type(stored) == "table" and #stored > 0 then return stored end
        return ctx:lineBoxes(pageno, p0, p1)
    end

    local info = ctx:pageInfo(first_page)
    if not info then return nil, "page geometry unavailable" end
    local pboxes = boxes_for(first_page)
    if type(pboxes) ~= "table" or #pboxes == 0 then return nil, "no highlight boxes" end
    local rects = boxes_to_pdf_rects(info, pboxes)
    if #rects == 0 then return nil, "no highlight boxes" end

    local position = '{"pageIndex":' .. (first_page - 1) .. ',"rects":' .. rects_json(rects)
    if last_page > first_page then
        -- Zotero can continue a highlight onto the following page only.
        local info2 = ctx:pageInfo(first_page + 1)
        local pboxes2 = info2 and boxes_for(first_page + 1)
        if info2 and type(pboxes2) == "table" and #pboxes2 > 0 then
            local rects2 = boxes_to_pdf_rects(info2, pboxes2)
            if #rects2 > 0 then
                position = position .. ',"nextPageRects":' .. rects_json(rects2)
            end
        end
    end
    position = position .. "}"

    local offset = char_offset(ctx:textBoxes(first_page), ann.pos0)
    -- as Zotero computes it: page height minus the top edge of the selection
    local top_edge = rects[1][4]
    for i = 2, #rects do
        if rects[i][4] > top_edge then top_edge = rects[i][4] end
    end
    local top = info.pdf_h - top_edge
    -- Page label, as Zotero's reader would choose it: the PDF's own label
    -- when it is not a plain number (roman front matter etc.); otherwise the
    -- numbering implied by the attachment's existing annotations, the PDF's
    -- numeric label, or the physical page number.
    local pdf_label = ctx:pageLabel(first_page)
    local label
    if pdf_label and not pdf_label:match("^%d+$") then
        label = pdf_label
    else
        label = (opts.label_for and opts.label_for(first_page)) or pdf_label
    end
    if not label or label == "" then label = tostring(first_page) end
    if #label > 50 then label = label:sub(1, 50) end

    return {
        position = position,
        sortIndex = Annotations.pdfSortIndex(first_page - 1, offset, top),
        pageLabel = label,
        exact = info.exact,
    }
end

--- Page label offset implied by existing Zotero annotations of an attachment
-- (label = page number + offset), mirroring what Zotero's reader does when
-- it creates a new annotation. Returns a function pageno -> label or nil.
function Annotations.labelGuesser(remote_items)
    local known = {}
    for _, item in pairs(remote_items or {}) do
        local d = item.data
        if d and d.annotationPageLabel and tostring(d.annotationPageLabel):match("^%d+$") then
            local pos = Util.jsonDecode(d.annotationPosition)
            if type(pos) == "table" and type(pos.pageIndex) == "number" then
                known[#known + 1] = { page = pos.pageIndex + 1, label = tonumber(d.annotationPageLabel) }
            end
        end
    end
    if #known == 0 then return nil end
    table.sort(known, function(a, b) return a.page < b.page end)
    return function(pageno)
        local ref
        for _, k in ipairs(known) do
            if k.page <= pageno then ref = k else break end
        end
        ref = ref or known[1]
        local label = pageno + (ref.label - ref.page)
        if label >= 1 then return tostring(label) end
        return nil
    end
end

return Annotations
