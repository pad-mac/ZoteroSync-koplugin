--[[--
Web snapshots: Zotero annotation positions <-> KOReader xpointers.

Zotero's reader addresses a passage of a snapshot by a CSS selector for an
element and character offsets into that element's text nodes
({"type":"CssSelector","value":"#content > p:nth-child(3)","refinedBy":
{"type":"TextPositionSelector","start":12,"end":40}}), or by offsets from the
start of <body> alone. Both refer to the document tree the reader's browser
engine builds - after the reader has changed the page: it parses the file,
removes <base>, <noscript> and content-security-policy elements, writes the
result out, parses that again, and appends an element of its own to <body>.
`Html.readerDocument` goes through the same steps with this plugin's parser.

KOReader addresses the same text by xpointers into its engine's tree, which
is built by a different, simpler HTML parser. As for EPUB, both trees are
reduced to their text and matched on it (see zotero_epub.lua).
]]

local Epub = require("zotero_epub")
local Parse = require("zotero_htmlparse")
local Util = require("zotero_util")
local logger = require("logger")

local Html = { fork = "0.6" }

local X = Epub._x
local strip_ws, finish_stream, stream_pos = X.strip_ws, X.finish_stream, X.stream_pos
local locate, map_range, call = X.locate, X.map_range, X.call

-- ---------------------------------------------------------------------------
-- The document as Zotero's reader has it
-- ---------------------------------------------------------------------------

--- Remove, everywhere in the tree, the elements the reader removes
-- (template contents are not part of the tree and stay as they are).
local function strip_for_reader(node)
    local kids = node.kids
    local i = 1
    while i <= #kids do
        local k = kids[i]
        local drop = false
        if k.name then
            if k.name == "base" or k.name == "noscript" then
                drop = true
            elseif k.name == "meta" then
                local he = k.attrs["http-equiv"]
                drop = type(he) == "string" and he:lower() == "content-security-policy"
            end
        end
        if drop then
            table.remove(kids, i)
            k.parent = nil
        else
            if k.name then strip_for_reader(k) end
            i = i + 1
        end
    end
end

--- @param src the snapshot file's content
-- @return document (see zotero_htmlparse), its <body>   or nil, reason
function Html.readerDocument(src)
    local first = Parse.parse(src)
    if first.unsafe then return nil, first.unsafe end
    local html = Parse.child(first, "html")
    if not html then return nil, "the page has no content" end
    strip_for_reader(html)
    -- The reader writes the changed document out and loads that. Mostly this
    -- gives the same tree again, but not always: a page without a modern
    -- doctype may have a table inside a paragraph, which the second reading
    -- (always in standards mode) does not allow, and a line break at the
    -- start of a <pre> is dropped each time.
    local doc = Parse.parse("<!DOCTYPE html>" .. Parse.outerHTML(html))
    if doc.unsafe then return nil, doc.unsafe end
    html = Parse.child(doc, "html")
    local body = html and Parse.child(html, "body")
    if not body then return nil, "the page has no body" end
    -- the element the reader draws its annotations in
    local overlay = Parse.newElement("div", nil, { id = "annotation-overlay" })
    overlay.overlay = true
    Parse.insertNode(body, overlay)
    return doc, body
end

-- ---------------------------------------------------------------------------
-- A copy of the page that KOReader's engine reads as a browser does
-- ---------------------------------------------------------------------------
--
-- KOReader's engine ends a tag at the first ">", also inside a quoted
-- attribute value. Saved pages are full of such values - the inline document
-- of every frame (srcdoc="<html>..."), pictures written as markup
-- (src="data:image/svg+xml,<svg ...>") - and what follows the ">" is then
-- shown as text, or swallows the rest of the page: after a frame, KOReader
-- often displays nothing more.
--
-- Written with "&gt;" such a value means the same to every HTML parser and
-- is read correctly by KOReader's. The inline documents of frames are emptied
-- (KOReader does not display frames; their text is megabytes of attribute).
-- Nothing else changes: the tree Zotero's reader builds from the copy is the
-- one it builds from the original, which is checked before the copy is used.

local function same_tree(a, b)
    if a.name ~= b.name or a.ns ~= b.ns or a.text ~= b.text or (a.comment ~= nil) ~= (b.comment ~= nil) then return false end
    if a.attrs or b.attrs then
        if not a.attrs or not b.attrs then return false end
        for k, v in pairs(a.attrs) do
            local w = b.attrs[k]
            if w == nil then return false end
            -- (the inline document of a frame is the one value that changes)
            if v ~= w and not (k == "srcdoc" and a.name == "iframe") then return false end
        end
        for k in pairs(b.attrs) do
            if a.attrs[k] == nil then return false end
        end
    end
    local ka, kb = a.kids, b.kids
    if (ka ~= nil) ~= (kb ~= nil) then return false end
    if ka then
        if #ka ~= #kb then return false end
        for i = 1, #ka do
            if not same_tree(ka[i], kb[i]) then return false end
        end
    end
    if (a.content ~= nil) ~= (b.content ~= nil) then return false end
    if a.content and not same_tree(a.content, b.content) then return false end
    return true
end

--- @param src the snapshot file's content
-- @return the content for KOReader's engine, number of values rewritten;
--         nil when the file is to be used as it is (reason as second value
--         when that is not simply "nothing to change")
function Html.engineCopy(src)
    if type(src) ~= "string" or src == "" then return nil end
    -- (most pages need the full reading only once: afterwards no quoted
    -- value holds a ">" any more)
    if not src:find('=%s*"[^"]*>') and not src:find("=%s*'[^']*>") and not src:find("[sS][rR][cC][dD][oO][cC]") then return nil end
    local marks = {}
    local ok, doc = pcall(Parse.parse, src, { marks = marks })
    if not ok then return nil, "the page could not be parsed" end
    if #marks == 0 then return nil end
    -- (a page that is not UTF-8 is shown by KOReader in its own encoding:
    -- its bytes are not to be touched)
    if doc.replaced then return nil, "the page is not UTF-8" end
    if doc.unsafe then return nil, doc.unsafe end
    local text = doc.source_text
    local out, n, pos, changed = {}, 0, 1, 0
    for _, m in ipairs(marks) do
        local v0, v1, frame = m[1], m[2], m[3]
        if v0 >= pos then
            n = n + 1; out[n] = text:sub(pos, v0 - 1)
            if not frame then
                n = n + 1; out[n] = (text:sub(v0, v1):gsub(">", "&gt;"))
            end
            pos = v1 + 1
            changed = changed + 1
        end
    end
    if changed == 0 then return nil end
    n = n + 1; out[n] = text:sub(pos)
    local copy = (doc.bom and "\239\187\191" or "") .. table.concat(out)
    local ok2, again = pcall(Parse.parse, copy, { keep_all = false })
    if not ok2 or not same_tree(doc, again) then
        return nil, "the rewritten page did not read as the original"
    end
    return copy, changed
end

-- ---------------------------------------------------------------------------
-- The model: text nodes and elements of <body>, in document order
-- ---------------------------------------------------------------------------

--- Byte length of the JavaScript white space character at s[i], or 0.
local function js_ws_at(s, i)
    local b = s:byte(i)
    if not b then return 0 end
    if b == 32 or (b >= 9 and b <= 13) then return 1 end
    if b < 0xC2 then return 0 end
    if b == 0xC2 then return s:byte(i + 1) == 0xA0 and 2 or 0 end
    local b2, b3 = s:byte(i + 1), s:byte(i + 2)
    if b == 0xE1 then return (b2 == 0x9A and b3 == 0x80) and 3 or 0 end
    if b == 0xE2 then
        if b2 == 0x80 and b3 and ((b3 >= 0x80 and b3 <= 0x8A) or b3 == 0xA8 or b3 == 0xA9 or b3 == 0xAF) then return 3 end
        if b2 == 0x81 and b3 == 0x9F then return 3 end
        return 0
    end
    if b == 0xE3 then return (b2 == 0x80 and b3 == 0x80) and 3 or 0 end
    if b == 0xEF then return (b2 == 0xBB and b3 == 0xBF) and 3 or 0 end
    return 0
end

--- JavaScript's String.prototype.trim.
local function js_trim(s)
    local i, n = 1, #s
    while i <= n do
        local l = js_ws_at(s, i)
        if l == 0 then break end
        i = i + l
    end
    local j = n
    while j >= i do
        local k = j
        while k > i and s:byte(k) >= 0x80 and s:byte(k) < 0xC0 do k = k - 1 end
        local l = js_ws_at(s, k)
        if l == 0 or k + l - 1 ~= j then break end
        j = k - 1
    end
    return s:sub(i, j)
end
Html._jsTrim = js_trim

local function js_blank(s)
    return js_trim(s) == ""
end

--- Elements whose text nodes are not page text in a browser (they count in
-- positions, but nothing in them can be highlighted there).
local NO_TEXT = {}
for name in ("script style iframe noembed noframes textarea title select datalist canvas audio video"):gmatch("%S+") do
    NO_TEXT[name] = true
end

--- Elements a declarative shadow root can be attached to.
local SHADOW_HOSTS = {}
for name in ("article aside blockquote body div footer h1 h2 h3 h4 h5 h6 header main nav p section span"):gmatch("%S+") do
    SHADOW_HOSTS[name] = true
end

--- Build the model of a snapshot as Zotero's reader sees it.
-- model.texts[i] = { text, node, counted, u16_before, u16_len, trim_before, stream_start, stream_len }
-- Elements get: t0, t1 (their text entries), echildren / echildren_all,
-- eindex / eindex_all, order.
function Html.sourceModel(src)
    local doc, body = Html.readerDocument(src)
    if not doc then return nil, body end
    local model = { texts = {}, elements = {}, body = body, doc = doc, has_shadow = false }
    local u16, trimmed = 0, 0
    local texts, elements = model.texts, model.elements

    local function walk(el, hidden)
        el.t0 = #texts + 1
        local all, light = {}, {}
        local host_free = el.ns == nil and (SHADOW_HOSTS[el.name] or el.name:find("-", 1, true) ~= nil)
        for _, k in ipairs(el.kids) do
            if k.text then
                if k.text ~= "" then
                    local len = Util.utf16Len(k.text)
                    texts[#texts + 1] = {
                        text = k.text, node = k, counted = not hidden,
                        u16_before = u16, u16_len = len, trim_before = trimmed,
                    }
                    k.ti = #texts
                    u16 = u16 + len
                    trimmed = trimmed + Util.utf16Len(js_trim(k.text))
                end
            elseif k.name then
                -- <template shadowrootmode>: newer browser engines turn the
                -- first one in an element into that element's shadow tree
                -- (and it is then not a child); older ones leave it there.
                local mode = k.ns == nil and k.name == "template" and k.attrs.shadowrootmode
                if host_free and type(mode) == "string" and (mode:lower() == "open" or mode:lower() == "closed") then
                    k.shadow_template = true
                    host_free = false
                    model.has_shadow = true
                else
                    light[#light + 1] = k
                    k.eindex = #light
                end
                all[#all + 1] = k
                k.eindex_all = #all
                elements[#elements + 1] = k
                k.order = #elements
                walk(k, hidden or (k.ns == nil and NO_TEXT[k.name] == true))
            end
        end
        el.echildren, el.echildren_all = light, all
        el.t1 = #texts
    end
    walk(body, false)
    model.u16_total = u16
    return finish_stream(model)
end

-- ---------------------------------------------------------------------------
-- CSS selectors (the subset Zotero's reader writes, and a little more)
-- ---------------------------------------------------------------------------

--- An identifier with CSS escapes, from position i. @return string, next position
local function read_ident(sel, i)
    local out = {}
    local n = #sel
    while i <= n do
        local c = sel:sub(i, i)
        if c == "\\" then
            local hex = sel:match("^%x%x?%x?%x?%x?%x?", i + 1)
            if hex then
                i = i + 1 + #hex
                if sel:sub(i, i):match("[ \t\n\f\r]") then i = i + 1 end
                local cp = tonumber(hex, 16)
                if cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then cp = 0xFFFD end
                out[#out + 1] = require("zotero_htmlentities").utf8(cp)
            else
                out[#out + 1] = sel:sub(i + 1, i + 1)
                i = i + 2
            end
        elseif c:match("[%w_%-]") or c:byte() >= 0x80 then
            out[#out + 1] = c
            i = i + 1
        else
            break
        end
    end
    return table.concat(out), i
end

--- @return list of compounds { comb, tag, id, classes, pseudos } or nil (not understood)
local function parse_selector(sel)
    local parts = {}
    local i, n = 1, #sel
    local comb
    while true do
        local ws = sel:match("^[ \t\n\f\r]*", i)
        i = i + #ws
        if i > n then break end
        local c = sel:sub(i, i)
        if c == ">" or c == "+" or c == "~" then
            if #parts == 0 or comb then return nil end
            comb = c
            i = i + 1
        else
            local part = { comb = #parts > 0 and (comb or " ") or nil, classes = {}, pseudos = {} }
            comb = nil
            local start = i
            if c == "*" then
                i = i + 1
            else
                local tag
                tag, i = read_ident(sel, i)
                if tag ~= "" then part.tag = tag end
            end
            while i <= n do
                c = sel:sub(i, i)
                if c == "#" then
                    part.id, i = read_ident(sel, i + 1)
                elseif c == "." then
                    local class
                    class, i = read_ident(sel, i + 1)
                    part.classes[#part.classes + 1] = class
                elseif c == ":" then
                    local name
                    name, i = read_ident(sel, i + 1)
                    local arg
                    if sel:sub(i, i) == "(" then
                        local close = sel:find(")", i, true)
                        if not close then return nil end
                        arg = sel:sub(i + 1, close - 1)
                        i = close + 1
                    end
                    part.pseudos[#part.pseudos + 1] = { name = name:lower(), arg = arg }
                else
                    break
                end
            end
            if i == start then return nil end -- something this parser does not know
            parts[#parts + 1] = part
        end
    end
    if comb or #parts == 0 then return nil end
    return parts
end
Html._parseSelector = parse_selector

local function siblings(el, all)
    local parent = el.parent
    if not parent then return nil end
    local list = all and parent.echildren_all or parent.echildren
    if not list then
        -- above <body>: no prepared list
        list = {}
        for _, k in ipairs(parent.kids) do
            if k.name then list[#list + 1] = k end
        end
    end
    return list
end

local function position_of(el, list, all)
    local i = all and el.eindex_all or el.eindex
    if i and list[i] == el then return i end
    for j, k in ipairs(list) do
        if k == el then return j end
    end
    return nil
end

local function same_type(a, b)
    return a.name == b.name and a.ns == b.ns
end

local function matches(el, part, all)
    if part.tag then
        if el.ns == nil then
            if el.name ~= part.tag:lower() then return false end
        elseif el.name ~= part.tag then
            return false
        end
    end
    if part.id and el.attrs.id ~= part.id then return false end
    if #part.classes > 0 then
        local have = el.attrs.class
        if type(have) ~= "string" then return false end
        for _, class in ipairs(part.classes) do
            local found = false
            for word in have:gmatch("[^ \t\n\f\r]+") do
                if word == class then found = true; break end
            end
            if not found then return false end
        end
    end
    if #part.pseudos > 0 then
        local list = siblings(el, all)
        if not list then return false end
        local index = position_of(el, list, all)
        if not index then return false end
        for _, ps in ipairs(part.pseudos) do
            local name = ps.name
            if name == "first-child" then
                if index ~= 1 then return false end
            elseif name == "last-child" then
                if index ~= #list then return false end
            elseif name == "only-child" then
                if #list ~= 1 then return false end
            elseif name == "nth-child" then
                if index ~= tonumber(ps.arg) then return false end
            elseif name == "first-of-type" or name == "last-of-type" or name == "only-of-type" then
                local before, after = false, false
                for j, k in ipairs(list) do
                    if k ~= el and same_type(k, el) then
                        if j < index then before = true else after = true end
                    end
                end
                if name == "first-of-type" and before then return false end
                if name == "last-of-type" and after then return false end
                if name == "only-of-type" and (before or after) then return false end
            else
                return false -- a pseudo-class this matcher does not know
            end
        end
    end
    return true
end

local function match_chain(el, parts, k, all)
    if not matches(el, parts[k], all) then return false end
    if k == 1 then return true end
    local comb = parts[k].comb
    if comb == ">" then
        local p = el.parent
        return p ~= nil and p.name ~= nil and match_chain(p, parts, k - 1, all)
    elseif comb == " " then
        local p = el.parent
        while p and p.name do
            if match_chain(p, parts, k - 1, all) then return true end
            p = p.parent
        end
        return false
    else
        local list = siblings(el, all)
        local index = list and position_of(el, list, all)
        if not index then return false end
        if comb == "+" then
            return index > 1 and match_chain(list[index - 1], parts, k - 1, all)
        end
        for j = index - 1, 1, -1 do
            if match_chain(list[j], parts, k - 1, all) then return true end
        end
        return false
    end
end

--- body.querySelectorAll, up to `limit` matches.
-- @param all count <template shadowrootmode> elements as children (older engines)
local function query(model, selector, all, limit)
    local parts = type(selector) == "table" and selector or parse_selector(selector)
    if not parts then return nil end
    local out = {}
    local last = #parts
    for _, el in ipairs(model.elements) do
        if (all or not el.shadow_template) and match_chain(el, parts, last, all) then
            out[#out + 1] = el
            if limit and #out >= limit then break end
        end
    end
    return out
end
Html._query = query

--- CSS.escape
local function css_escape(value)
    local out = {}
    local first = value:byte(1)
    local i, n = 1, #value
    while i <= n do
        local b = value:byte(i)
        if b == 0 then
            out[#out + 1] = "\239\191\189"
        elseif b <= 0x1F or b == 0x7F then
            out[#out + 1] = string.format("\\%x ", b)
        elseif b >= 0x30 and b <= 0x39 and (i == 1 or (i == 2 and first == 0x2D)) then
            out[#out + 1] = string.format("\\%x ", b)
        elseif i == 1 and b == 0x2D and n == 1 then
            out[#out + 1] = "\\-"
        elseif b >= 0x80 or b == 0x2D or b == 0x5F or (b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5A)
            or (b >= 0x61 and b <= 0x7A) then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = "\\" .. string.char(b)
        end
        i = i + 1
    end
    return table.concat(out)
end
Html._cssEscape = css_escape

--- In a browser, form.id is not the id attribute when the form has a control
-- that is itself called "id". Zotero's reader then writes a selector that
-- leads nowhere. Such a form's id is not used here.
local function id_is_clobbered(el)
    if el.ns ~= nil or el.name ~= "form" then return false end
    local found = false
    local function walk(node)
        for _, k in ipairs(node.kids) do
            if k.name and not found then
                if k.attrs.name == "id" or k.attrs.id == "id" then
                    local n = k.name
                    if n == "input" or n == "button" or n == "select" or n == "textarea" or n == "fieldset"
                        or n == "object" or n == "output" or n == "img" then
                        found = true
                        return
                    end
                end
                walk(k)
            end
        end
    end
    walk(el)
    return found
end

local function usable_id(el)
    local id = el.attrs.id
    if type(id) ~= "string" or id == "" then return nil end
    if id_is_clobbered(el) then return nil end
    return id
end

--- Zotero's getUniqueSelectorContaining (src/dom/common/lib/unique-selector.ts).
local function unique_selector(model, element, all)
    local root = model.body
    local function test(selector)
        local found = query(model, selector, all, 2)
        return found ~= nil and #found == 1 and found[1] == element
    end
    local cur = element
    local selector = ""
    while cur and cur ~= root do
        local joiner = selector ~= "" and " > " or ""
        local id = usable_id(cur)
        if id then return "#" .. css_escape(id) .. joiner .. selector end
        local tag = cur.name:lower()
        local list = siblings(cur, all)
        local index = list and position_of(cur, list, all)
        if not index then return nil end
        local prev = list[index - 1]
        local prev_id = prev and usable_id(prev)
        if prev_id then
            local candidate = "#" .. css_escape(prev_id) .. " + " .. tag .. joiner .. selector
            if test(candidate) then return candidate end
        end
        local before, after = false, false
        for j, k in ipairs(list) do
            if k ~= cur and same_type(k, cur) then
                if j < index then before = true else after = true end
            end
        end
        local pseudo
        if (not before and not after) or #list == 1 then
            pseudo = ""
        elseif index == 1 then
            pseudo = ":first-child"
        elseif not before then
            pseudo = ":first-of-type"
        elseif index == #list then
            pseudo = ":last-child"
        elseif not after then
            pseudo = ":last-of-type"
        else
            pseudo = ":nth-child(" .. index .. ")"
        end
        selector = tag .. pseudo .. joiner .. selector
        if test(selector) then return selector end
        cur = cur.parent
        if cur and not cur.name then cur = nil end
    end
    return nil
end
Html._uniqueSelector = unique_selector

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------

--- The text node an offset into an element's text falls in: the last one
-- that can hold it, as the reader's own code picks.
-- @return entry index, UTF-16 offset in it   or nil
local function entry_at_offset(model, root, offset)
    local t0, t1 = root.t0, root.t1
    if not t0 or t1 < t0 or type(offset) ~= "number" or offset < 0 then return nil end
    local texts = model.texts
    local target = texts[t0].u16_before + offset
    local lo, hi, found = t0, t1, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if texts[mid].u16_before <= target then
            found = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    if not found then return nil end
    local t = texts[found]
    local inside = target - t.u16_before
    if inside > t.u16_len then return nil end
    return found, inside
end

--- Resolve a Zotero position.
-- @return entry0, offset0, entry1, offset1 (UTF-16 offsets)   or nil, reason
local function resolve_position(model, pos, all)
    if type(pos) ~= "table" then return nil, "the annotation has no position" end
    local root, refine
    if pos.type == "CssSelector" and type(pos.value) == "string" then
        local found = query(model, pos.value, all, 1)
        if not found then return nil, "the position's selector was not understood" end
        root = found[1]
        if not root then return nil, "the position's element was not found in the page" end
        refine = pos.refinedBy
        if refine ~= nil and (type(refine) ~= "table" or refine.type ~= "TextPositionSelector") then
            return nil, "the position has an unknown form"
        end
    elseif pos.type == "TextPositionSelector" then
        root, refine = model.body, pos
    else
        return nil, "the position has an unknown form"
    end
    if not root.t0 or root.t1 < root.t0 then return nil, "the position's element has no text" end
    if refine then
        local e0, o0 = entry_at_offset(model, root, tonumber(refine.start))
        local e1, o1 = entry_at_offset(model, root, tonumber(refine["end"]))
        if not e0 or not e1 then return nil, "the position lies outside its element's text" end
        return e0, o0, e1, o1
    end
    return root.t0, 0, root.t1, model.texts[root.t1].u16_len
end

--- Where is the point p (stream bytes before it) of model A in model B?
-- Believed only if the text around it occurs exactly once on the other side
-- (see locate_point in zotero_epub.lua; here the end of the text is a
-- possible answer too).
local function unique_point(model_a, model_b, p)
    local sa, sb = model_a.stream, model_b.stream
    local len = #sa
    if p < 0 or p > len then return nil end
    local function try(pre, post)
        pre = math.min(pre, p)
        post = math.min(post, len - p)
        if pre + post < 8 then return 0 end
        local needle = sa:sub(p + 1 - pre, p + post)
        local first = sb:find(needle, 1, true)
        if not first then return 0 end
        if sb:find(needle, first + 1, true) then return 2 end
        return 1, first - 1 + pre
    end
    for _, n in ipairs({ 24, 48, 96, 240, 600 }) do
        local count, pos = try(n, n)
        if count == 1 then return pos end
        if count == 0 then break end
    end
    for _, side in ipairs({ "after", "before" }) do
        for _, n in ipairs({ 32, 64, 128, 300, 700 }) do
            local count, pos
            if side == "after" then count, pos = try(0, n) else count, pos = try(n, 0) end
            if count == 1 then return pos end
            if count == 0 then break end
        end
    end
    local count, pos = try(12, 12)
    if count == 1 then return pos end
    return nil
end

--- The same passage, give or take what the two engines disagree on inside it.
local function same_text(a, b)
    if a == b then return true end
    local na, nb = Util.normText(a), Util.normText(b)
    if na == nb then return true end
    local short, long = na, nb
    if #short > #long then short, long = long, short end
    if #short == 0 then return false end
    local k = math.min(8, #short)
    if short:sub(1, k) ~= long:sub(1, k) or short:sub(-k) ~= long:sub(-k) then return false end
    return #short * 5 >= #long * 3 and X.is_subsequence(short, long)
end

--- The range [a0, a1) of model A's text in model B's: the whole passage if
-- it occurs once there, else its two ends, each found by text that occurs
-- once. Never "the nearest of several". @return b0, b1 or nil
local function map_strict(model_a, model_b, a0, a1)
    local sa, sb = model_a.stream, model_b.stream
    if sa == sb then return a0, a1 end
    local needle = sa:sub(a0 + 1, a1)
    if #needle >= 24 then
        local first = sb:find(needle, 1, true)
        if first and not sb:find(needle, first + 1, true) then return first - 1, first - 1 + #needle end
    end
    local b0 = unique_point(model_a, model_b, a0)
    local b1 = unique_point(model_a, model_b, a1)
    if not b0 or not b1 or b1 <= b0 then return nil end
    if not same_text(needle, sb:sub(b0 + 1, b1)) then return nil end
    return b0, b1
end

--- Stream range of a resolved position, or nil.
local function stream_range(model, e0, o0, e1, o1)
    local texts = model.texts
    local a0 = stream_pos(model, e0, Util.utf16ByteIndex(texts[e0].text, o0))
    local a1 = stream_pos(model, e1, Util.utf16ByteIndex(texts[e1].text, o1))
    if not a0 or not a1 or a1 <= a0 then return nil end
    return a0, a1
end

--- The element that contains both text nodes.
local function common_element(a, b)
    local seen = {}
    local n = a.parent
    while n do
        seen[n] = true
        n = n.parent
    end
    n = b.parent
    while n do
        if seen[n] then return n end
        n = n.parent
    end
    return nil
end

--- Is the text of entries [e_from, e_to] outside the given offsets blank?
-- (All of it before `o_from` in the first / after `o_to` in the last.)
local function blank_outside(model, t0, t1, e0, o0, e1, o1)
    local texts = model.texts
    for i = t0, e0 do
        local text = texts[i].text
        if i == e0 then text = text:sub(1, Util.utf16ByteIndex(text, o0) - 1) end
        if not js_blank(text) then return false end
    end
    for i = e1, t1 do
        local text = texts[i].text
        if i == e1 then text = text:sub(Util.utf16ByteIndex(text, o1)) end
        if not js_blank(text) then return false end
    end
    return true
end

--- Zotero's position for a range of the model (SnapshotView.toSelector and
-- _getSortIndex).
-- @return position table, sortIndex   or nil, reason
local function build_position(model, e0, o0, e1, o1, all)
    local texts = model.texts
    local target = common_element(texts[e0].node, texts[e1].node)
    if not target or not target.t0 then return nil, "the passage is not inside the page's body" end
    local position
    local selector = unique_selector(model, target, all)
    if selector then
        position = { type = "CssSelector", value = selector }
        if not blank_outside(model, target.t0, target.t1, e0, o0, e1, o1) then
            local base = texts[target.t0].u16_before
            position.refinedBy = {
                type = "TextPositionSelector",
                start = texts[e0].u16_before - base + o0,
                ["end"] = texts[e1].u16_before - base + o1,
            }
        end
    else
        position = {
            type = "TextPositionSelector",
            start = texts[e0].u16_before + o0,
            ["end"] = texts[e1].u16_before + o1,
        }
    end
    local count = tostring(texts[e0].trim_before + o0)
    if #count < 7 then count = string.rep("0", 7 - #count) .. count end
    if #count > 7 then count = count:sub(1, 7) end
    return position, count
end

--- A position as Zotero writes it (the order of the keys included).
local function position_json(position)
    local function text_position(tp)
        return string.format('{"type":"TextPositionSelector","start":%d,"end":%d}', tp.start, tp["end"])
    end
    if position.type == "TextPositionSelector" then return text_position(position) end
    local out = '{"type":"CssSelector","value":' .. Util.jsonString(position.value)
    if position.refinedBy then out = out .. ',"refinedBy":' .. text_position(position.refinedBy) end
    return out .. "}"
end

Html._x_is_subsequence = X.is_subsequence
Html._resolvePosition = resolve_position
Html._buildPosition = build_position
Html._positionJson = position_json
Html._streamRange = stream_range

-- ---------------------------------------------------------------------------
-- A session bound to one open snapshot
-- ---------------------------------------------------------------------------

local Session = {}
Session.__index = Session

-- KOReader's engine shows what a page keeps for readers without JavaScript;
-- Zotero's reader removes it. And only <body> is the page's text.
local ENGINE_HIDDEN = { noscript = true, head = true }

--- @param document an open, loaded CreDocument of an HTML file
function Html.newSession(document)
    return setmetatable({ doc = document }, Session)
end

function Session:close()
    self.frag = nil
end

--- Both models of the page, or nil, reason.
function Session:models()
    if self.frag ~= nil then
        if self.frag == false then return nil, self.failed end
        return self.frag
    end
    local function fail(reason)
        self.frag = false
        self.failed = reason
        return nil, reason
    end
    local doc = self.doc
    -- The engine's tree has no single root that can be asked for: a page with
    -- stray </html> or <body> tags becomes several <html> elements there.
    local pieces = {}
    for n = 1, 64 do
        local xp = n == 1 and "/html" or ("/html[" .. n .. "]")
        if n > 1 and not call(doc, "isXPointerInDocument", xp) then break end
        local piece = call(doc, "getHTMLFromXPointer", xp, 0x0002)
        if type(piece) ~= "string" or piece == "" then break end
        pieces[#pieces + 1] = piece
    end
    if #pieces == 0 then return fail("the page could not be read from the reading engine") end
    local html = "<root>" .. table.concat(pieces) .. "</root>"
    -- The engine writes attribute values as they are, quotes and markup
    -- included, so where a tag ends is a matter of judgement; and old
    -- documents name its internal boxes in xpointers. Whichever reading
    -- addresses the live document correctly is taken.
    local engine
    for _, try in ipairs({ { false, "strict" }, { true, "strict" }, { false, true }, { false, false }, { true, true }, { true, false } }) do
        local candidate = Epub.engineModel(html, "", try[1], "root", ENGINE_HIDDEN, try[2])
        if candidate and (try[1] == false or candidate.has_boxing) and self:probe(candidate) then
            engine = candidate
            break
        end
    end
    if not engine then return fail("the page's structure was not understood") end
    local path = doc.file
    local f = type(path) == "string" and io.open(path, "rb") or nil
    if not f then return fail("the page's file could not be read") end
    local src = f:read("*a")
    f:close()
    if type(src) ~= "string" or src == "" then return fail("the page's file is empty") end
    local ok, source, serr = pcall(Html.sourceModel, src)
    if not ok then
        logger.warn("Zotero: snapshot could not be parsed:", tostring(source))
        return fail("the page's file could not be parsed")
    end
    if not source then return fail(serr) end
    if #source.stream == 0 or #engine.stream == 0 then return fail("the page has no text") end
    self.frag = { engine = engine, source = source, identical = engine.stream == source.stream }
    return self.frag
end

--- Does the engine model address the live document correctly?
function Session:probe(engine)
    local n = #engine.map
    if n == 0 then return true end
    local picks = {}
    for i = 0, 11 do picks[#picks + 1] = engine.map[1 + math.floor((n - 1) * i / 11)] end
    for _, idx in ipairs(picks) do
        local t = engine.texts[idx]
        local xp = X.engine_path(engine, t.node)
        if not xp then return false end
        local got = call(self.doc, "getTextFromXPointer", xp)
        if type(got) ~= "string" or strip_ws(got) ~= strip_ws(t.text) then return false end
    end
    return true
end

function Session:normalize(xp)
    if type(xp) ~= "string" then return nil end
    local res = call(self.doc, "getNormalizedXPointer", xp)
    if type(res) == "string" and res ~= "" then return res end
    if res == false then return nil end
    return xp
end

--- KOReader xpointers -> Zotero position.
-- @return { position = <json>, sortIndex =, pageLabel = "", exact = } or nil, reason
function Session:toZotero(pos0, pos1)
    local xp0, xp1 = self:normalize(pos0), self:normalize(pos1)
    if not xp0 or not xp1 then return nil, "the highlight's position no longer exists in the page" end
    local frag, ferr = self:models()
    if not frag then return nil, ferr end
    local engine, source = frag.engine, frag.source
    local e0, eb0 = X.engine_point(engine, xp0, false)
    local e1, eb1 = X.engine_point(engine, xp1, true)
    if not e0 or not e1 then return nil, "the highlight's position was not found in the page" end
    for _, check in ipairs({ { xp0, e0 }, { xp1, e1 } }) do
        local path = X.split_xpointer(check[1])
        if path:match("/text%(%)[%[%]%d]*$") then
            if not X.same_node_text(call(self.doc, "getTextFromXPointer", path), engine.texts[check[2]].text) then
                return nil, "the open page has different text at the highlight's position"
            end
        end
    end
    if e1 < e0 or (e1 == e0 and eb1 < eb0) then
        e0, eb0, e1, eb1 = e1, eb1, e0, eb0
    end
    if not engine.texts[e0].counted or not engine.texts[e1].counted then
        -- (KOReader shows what a page offers readers without JavaScript; Zotero removes it)
        return nil, "the highlight begins or ends in text that Zotero's copy of the page does not have (<noscript>)"
    end
    -- The passage in Zotero's tree. A text that repeats in the page must not
    -- lead to its other occurrence: nothing here is guessed.
    local b0, b1 = stream_pos(engine, e0, eb0), stream_pos(engine, e1, eb1)
    if not b0 or not b1 or b1 <= b0 then return nil, "the selection is empty" end
    local a0, a1 = map_strict(engine, source, b0, b1)
    if a0 then
        -- and from there it must lead back to the selection
        local r0, r1 = map_strict(source, engine, a0, a1)
        if r0 ~= b0 or r1 ~= b1 then a0 = nil end
    end
    if not a0 then return nil, "the passage could not be matched with certainty between KOReader's and Zotero's copy of the page" end
    local s0, sb0 = X.point_at(source, a0 + 1)
    local s1, sb1 = X.point_at(source, a1)
    if not s0 or not s1 then return nil, "the position lies outside the text" end
    local texts = source.texts
    sb1 = sb1 + Util.utf8SeqLen(texts[s1].text:byte(sb1))
    local o0 = Util.utf16Len(texts[s0].text:sub(1, sb0 - 1))
    local o1 = Util.utf16Len(texts[s1].text:sub(1, sb1 - 1))
    -- Where a newer engine would have made a shadow tree of a <template>, an
    -- older one has an element: only offsets from the start of the page
    -- mean the same in both.
    local position, sort_index
    if source.has_shadow then
        position = {
            type = "TextPositionSelector",
            start = texts[s0].u16_before + o0,
            ["end"] = texts[s1].u16_before + o1,
        }
        local _
        _, sort_index = build_position(source, s0, o0, s1, o1, false)
    else
        position, sort_index = build_position(source, s0, o0, s1, o1, false)
    end
    if not position then return nil, sort_index end
    -- self-check: the position must lead back to exactly this range
    local function leads_back(p)
        local r0, ro0, r1, ro1 = resolve_position(source, p, false)
        if not r0 then return false end
        local a0, a1 = stream_range(source, r0, ro0, r1, ro1)
        local w0, w1 = stream_range(source, s0, o0, s1, o1)
        return a0 ~= nil and a0 == w0 and a1 == w1
    end
    if not leads_back(position) then
        -- (an id used twice in the page, for instance)
        position = {
            type = "TextPositionSelector",
            start = texts[s0].u16_before + o0,
            ["end"] = texts[s1].u16_before + o1,
        }
        if not leads_back(position) then return nil, "the computed position failed its self-check" end
    end
    return {
        position = position_json(position),
        sortIndex = sort_index,
        pageLabel = "",
        exact = frag.identical,
    }
end

--- Zotero position -> KOReader xpointers.
-- @return pos0, pos1, how ("position" | "text")   or nil, reason
function Session:fromZotero(position, text, sort_index)
    local pos = position
    if type(pos) == "string" then pos = Util.jsonDecode(pos) end
    local frag, ferr = self:models()
    if not frag then return nil, ferr end
    local engine, source = frag.engine, frag.source
    local needle = strip_ws(text or "")
    local b0, b1, how

    -- 1. the position itself (read both ways where the page has a <template shadowrootmode>)
    local a0, a1, agrees = nil, nil, false
    for _, all in ipairs(source.has_shadow and { false, true } or { false }) do
        local e0, o0, e1, o1 = resolve_position(source, pos, all)
        local c0, c1
        if e0 then c0, c1 = stream_range(source, e0, o0, e1, o1) end
        if c0 then
            -- (A short text must be the text itself: a page may use an id
            -- twice, and Zotero's selector then leads to the wrong one of the
            -- two elements - "60" is not found in "0".)
            local function fits_text(slice)
                if slice == needle then return true end
                local ns, nn = Util.normText(slice), Util.normText(needle)
                if ns == nn then return true end
                local short, long = ns, nn
                if #short > #long then short, long = long, short end
                if #short < 12 or #long - #short > math.max(8, math.floor(#long / 4)) then return false end
                return long:find(short, 1, true) ~= nil or X.is_subsequence(short, long)
            end
            local fits
            if needle == "" then
                fits = true
            else
                -- an annotation made in Zotero carries the text of Zotero's
                -- tree, one made here the text KOReader shows
                fits = fits_text(source.stream:sub(c0 + 1, c1))
                if not fits then
                    local m0, m1 = map_strict(source, engine, c0, c1)
                    fits = m0 ~= nil and fits_text(engine.stream:sub(m0 + 1, m1))
                    if m0 and not fits then
                        -- what KOReader displays of the passage (it leaves out
                        -- what the page hides, and that is the text it stored)
                        local x0, x1 = X.engine_range_xpointers(self.doc, engine, m0, m1)
                        local shown = x0 and call(self.doc, "getTextFromXPointers", x0, x1)
                        if type(shown) == "string" then
                            shown = strip_ws(shown)
                            fits = shown ~= "" and (shown == needle or Util.normText(shown) == Util.normText(needle))
                        end
                    end
                end
            end
            if fits or not a0 then a0, a1, agrees = c0, c1, fits end
            if fits then break end
        end
    end
    if a0 and agrees then
        b0, b1 = map_strict(source, engine, a0, a1)
        if b0 then how = "position" end
    end

    -- 2. the annotation's text, nearest to where Zotero says it is
    if not b0 and needle ~= "" then
        -- (the sort index was counted from the passage itself; a position
        -- whose text did not fit may point somewhere else)
        local hint
        local count = tonumber(sort_index)
        if count then
            local texts = source.texts
            local lo, hi, found = 1, #texts, nil
            while lo <= hi do
                local mid = math.floor((lo + hi) / 2)
                if texts[mid].trim_before <= count then
                    found = mid
                    lo = mid + 1
                else
                    hi = mid - 1
                end
            end
            if found then
                local t = texts[found]
                local inside = math.max(0, math.min(t.u16_len, count - t.trim_before))
                hint = stream_pos(source, found, Util.utf16ByteIndex(t.text, inside))
            end
        end
        hint = hint or a0
        -- (the hint is a place in Zotero's text: carried over to KOReader's)
        if hint then hint = unique_point(source, engine, math.min(hint, #source.stream)) or hint end
        b0, b1 = X.text_range(frag, needle, hint)
        if b0 then how = "text" end
    end

    -- (A position whose text is found nowhere in the page is not used: unlike
    -- in an EPUB, it may simply lead to another element.)
    if not b0 then return nil, "the annotated passage was not found in the page" end

    local xp0, xp1 = X.engine_range_xpointers(self.doc, engine, b0, b1)
    if not xp0 then return nil, xp1 end
    return xp0, xp1, how
end

--- Text form of the body tree, for comparison with a browser (tests).
function Html.dump(body)
    local lines = {}
    local function esc(s)
        return (s:gsub("[^%w ]", function(c) return string.format("%%%02X", c:byte()) end))
    end
    local function text_of(node, out)
        for _, k in ipairs(node.kids) do
            if k.text then out[#out + 1] = k.text elseif k.name then text_of(k, out) end
        end
        return out
    end
    local function walk(node, depth)
        local pad = string.rep(" ", depth)
        for _, k in ipairs(node.kids) do
            if k.text then
                if k.text ~= "" then lines[#lines + 1] = pad .. "T " .. Util.utf16Len(k.text) .. " " .. esc(k.text) end
            elseif k.name and not (k.name == "template" and k.ns == nil and type(k.attrs.shadowrootmode) == "string"
                and k.parent.kids and (function()
                    -- (as a newer engine has it: the first such template of an element is its shadow tree)
                    for _, sib in ipairs(k.parent.kids) do
                        if sib.name == "template" and type(sib.attrs.shadowrootmode) == "string" then return sib == k end
                    end
                end)()) then
                local id = k.attrs.id
                lines[#lines + 1] = pad .. "E " .. (k.ns and (k.ns .. ":") or "") .. k.name
                    .. ((type(id) == "string" and id ~= "") and (" #" .. esc(id)) or "")
                if k.ns == nil and k.name == "select" then
                    local t = table.concat(text_of(k, {}))
                    if t ~= "" then lines[#lines + 1] = pad .. " T " .. Util.utf16Len(t) .. " " .. esc(t) end
                else
                    walk(k, depth + 1)
                end
            end
        end
    end
    walk(body, 0)
    return table.concat(lines, "\n") .. "\n"
end

return Html
