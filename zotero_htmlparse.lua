--[[--
An HTML parser that builds the tree a browser builds.

Zotero stores an annotation in a web snapshot as a CSS selector plus character
offsets into the browser's document tree. To read and to write such positions
the plugin needs that tree, exactly: which elements exist, in which order, and
which text nodes with how many characters. A browser does not take HTML at
face value. It closes paragraphs by itself, moves misplaced text out of
tables, re-parents badly nested formatting tags, decides where <head> ends,
and so on - all of it laid down, step by step, in the HTML standard
("Parsing HTML documents": tokenization and tree construction). This module
follows that algorithm.

Scripting is off, as it is in the two places where Zotero's reader parses a
snapshot. Not implemented: framesets (the document is flagged, see `unsafe`),
and attribute adjustments in SVG and MathML, which do not change the tree.

    local doc = Parse.parse(html_text)
    doc.kids            -- document children (comments, the <html> element)
    doc.quirks          -- true for documents without a modern doctype
    doc.unsafe          -- set when something was met that is not modelled
    element: { name, ns (nil | "svg" | "math"), attrs, kids, parent }
    text:    { text, parent }
    comment: { comment = true, parent }
    <template>: its children are in element.content.kids, as in a browser

Only the attributes in KEEP have their values stored (others are present with
the value true): attribute values of saved pages can be megabytes of embedded
images, and nothing here needs them.
]]

local Entities = require("zotero_htmlentities")

local Parse = { fork = "0.6" }

-- ---------------------------------------------------------------------------
-- Tables from the standard
-- ---------------------------------------------------------------------------

local function set(list)
    local out = {}
    for name in list:gmatch("%S+") do out[name] = true end
    return out
end

--- Attributes whose value matters to this module or its users.
local KEEP = set("id type http-equiv color face size encoding class name shadowrootmode")

local SPECIAL = set([[address applet area article aside base basefont bgsound blockquote body br button caption
center col colgroup dd details dir div dl dt embed fieldset figcaption figure footer form frame frameset h1 h2 h3
h4 h5 h6 head header hgroup hr html iframe img input keygen li link listing main marquee menu meta nav noembed
noframes noscript object ol p param plaintext pre script search section select source style summary table tbody
td template textarea tfoot th thead title tr track ul wbr xmp]])
local SPECIAL_MATH = set("mi mo mn ms mtext annotation-xml")
local SPECIAL_SVG = set("foreignObject desc title")

local FORMATTING = set("a b big code em font i nobr s small strike strong tt u")
local IMPLIED_END = set("dd dt li optgroup option p rb rp rt rtc")
local IMPLIED_END_THOROUGH = set("caption colgroup dd dt li optgroup option p rb rp rt rtc tbody td tfoot th thead tr")
local HEADINGS = set("h1 h2 h3 h4 h5 h6")
local TABLE_SECTION = set("tbody tfoot thead")
local TABLEISH = set("table tbody tfoot thead tr")

local SCOPE_DEFAULT = set("applet caption html table td th marquee object template")
local SCOPE_LIST = set("applet caption html table td th marquee object template ol ul")
local SCOPE_BUTTON = set("applet caption html table td th marquee object template button")
local SCOPE_TABLE = set("html table template")

local BLOCK_START = set([[address article aside blockquote center details dialog dir div dl fieldset figcaption
figure footer header hgroup main menu nav ol p search section summary ul]])
local BLOCK_END = set([[address article aside blockquote button center details dialog dir div dl fieldset figcaption
figure footer header hgroup listing main menu nav ol pre search section summary ul]])
local HEAD_IN_BODY = set("base basefont bgsound link meta noframes script style template title")
local VOID_FORMAT = set("area br embed img keygen wbr")
local IGNORED_IN_BODY = set("caption col colgroup frame head tbody td tfoot th thead tr")

--- Start tags that end SVG or MathML content.
local BREAKOUT = set([[b big blockquote body br center code dd div dl dt em embed h1 h2 h3 h4 h5 h6 head hr i img
li listing menu meta nobr ol p pre ruby s small span strong strike sub sup table tt u ul var]])

--- Tag names inside <svg> that are written in mixed case.
local SVG_NAMES = {}
for name in ([[altGlyph altGlyphDef altGlyphItem animateColor animateMotion animateTransform clipPath feBlend
feColorMatrix feComponentTransfer feComposite feConvolveMatrix feDiffuseLighting feDisplacementMap feDistantLight
feDropShadow feFlood feFuncA feFuncB feFuncG feFuncR feGaussianBlur feImage feMerge feMergeNode feMorphology
feOffset fePointLight feSpecularLighting feSpotLight feTile feTurbulence foreignObject glyphRef linearGradient
radialGradient textPath]]):gmatch("%S+") do
    SVG_NAMES[name:lower()] = name
end

local QUIRKY_PREFIXES = {
    "+//silmaril//dtd html pro v0r11 19970101//", "-//as//dtd html 3.0 aswedit + extensions//",
    "-//advasoft ltd//dtd html 3.0 aswedit + extensions//", "-//ietf//dtd html 2.0 level 1//",
    "-//ietf//dtd html 2.0 level 2//", "-//ietf//dtd html 2.0 strict level 1//",
    "-//ietf//dtd html 2.0 strict level 2//", "-//ietf//dtd html 2.0 strict//", "-//ietf//dtd html 2.0//",
    "-//ietf//dtd html 2.1e//", "-//ietf//dtd html 3.0//", "-//ietf//dtd html 3.2 final//",
    "-//ietf//dtd html 3.2//", "-//ietf//dtd html 3//", "-//ietf//dtd html level 0//",
    "-//ietf//dtd html level 1//", "-//ietf//dtd html level 2//", "-//ietf//dtd html level 3//",
    "-//ietf//dtd html strict level 0//", "-//ietf//dtd html strict level 1//",
    "-//ietf//dtd html strict level 2//", "-//ietf//dtd html strict level 3//", "-//ietf//dtd html strict//",
    "-//ietf//dtd html//", "-//metrius//dtd metrius presentational//",
    "-//microsoft//dtd internet explorer 2.0 html strict//", "-//microsoft//dtd internet explorer 2.0 html//",
    "-//microsoft//dtd internet explorer 2.0 tables//", "-//microsoft//dtd internet explorer 3.0 html strict//",
    "-//microsoft//dtd internet explorer 3.0 html//", "-//microsoft//dtd internet explorer 3.0 tables//",
    "-//netscape comm. corp.//dtd html//", "-//netscape comm. corp.//dtd strict html//",
    "-//o'reilly and associates//dtd html 2.0//", "-//o'reilly and associates//dtd html extended 1.0//",
    "-//o'reilly and associates//dtd html extended relaxed 1.0//",
    "-//sq//dtd html 2.0 hotmetal + extensions//",
    "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
    "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
    "-//spyglass//dtd html 2.0 extended//", "-//sun microsystems corp.//dtd hotjava html//",
    "-//sun microsystems corp.//dtd hotjava strict html//", "-//w3c//dtd html 3 1995-03-24//",
    "-//w3c//dtd html 3.2 draft//", "-//w3c//dtd html 3.2 final//", "-//w3c//dtd html 3.2//",
    "-//w3c//dtd html 3.2s draft//", "-//w3c//dtd html 4.0 frameset//", "-//w3c//dtd html 4.0 transitional//",
    "-//w3c//dtd html experimental 19960712//", "-//w3c//dtd html experimental 970421//",
    "-//w3c//dtd w3 html//", "-//w3o//dtd w3 html 3.0//", "-//webtechs//dtd mozilla html 2.0//",
    "-//webtechs//dtd mozilla html//",
}

--- Replacements for numeric references in the range 0x80-0x9F.
local C1 = {
    [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020,
    [0x87] = 0x2021, [0x88] = 0x02C6, [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
    [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C, [0x94] = 0x201D, [0x95] = 0x2022,
    [0x96] = 0x2013, [0x97] = 0x2014, [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
    [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}

local utf8 = Entities.utf8
local REPLACEMENT = "\239\191\189" -- U+FFFD

-- ---------------------------------------------------------------------------
-- Input: bytes -> the text a browser's UTF-8 decoder produces
-- ---------------------------------------------------------------------------

--- Replace every ill-formed UTF-8 sequence by U+FFFD the way the standard
-- decoder does (one replacement per maximal ill-formed part).
local function decode_utf8(s)
    if not s:find("[\128-\255]") then return s end
    local out, n = {}, 0
    local pos, len = 1, #s
    local changed = false
    while pos <= len do
        local start = s:find("[\128-\255]", pos)
        if not start then
            n = n + 1; out[n] = s:sub(pos)
            break
        end
        if start > pos then n = n + 1; out[n] = s:sub(pos, start - 1) end
        local b = s:byte(start)
        local need, lo, hi = 0, 0x80, 0xBF
        if b >= 0xC2 and b <= 0xDF then need = 1
        elseif b == 0xE0 then need, lo = 2, 0xA0
        elseif b == 0xED then need, hi = 2, 0x9F
        elseif b >= 0xE1 and b <= 0xEF then need = 2
        elseif b == 0xF0 then need, lo = 3, 0x90
        elseif b == 0xF4 then need, hi = 3, 0x8F
        elseif b >= 0xF1 and b <= 0xF3 then need = 3
        end
        local ok = need > 0
        local used = 1
        for i = 1, need do
            local c = s:byte(start + i)
            if not c or c < lo or c > hi then ok = false; break end
            used = used + 1
            lo, hi = 0x80, 0xBF
        end
        if ok then
            n = n + 1; out[n] = s:sub(start, start + need)
        else
            n = n + 1; out[n] = REPLACEMENT
            changed = true
        end
        pos = start + used
    end
    if not changed then return s end
    return table.concat(out)
end
Parse.decodeUtf8 = decode_utf8

-- ---------------------------------------------------------------------------
-- Character references
-- ---------------------------------------------------------------------------

local function numeric_reference(cp)
    if cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return REPLACEMENT end
    return utf8(C1[cp] or cp)
end

--- Decode the character references of a piece of text.
-- @param in_attr inside an attribute value, where "&name" followed by "=" or
--                a letter or digit is left alone
local function decode_refs(text, in_attr)
    if not text:find("&", 1, true) then return text end
    local names, legacy = Entities.names, Entities.legacy
    return (text:gsub("&(#?)(%w*)(;?)()", function(hash, run, semi, after)
        if hash == "#" then
            local digits, rest, cp
            local x = run:sub(1, 1)
            if x == "x" or x == "X" then
                digits, rest = run:match("^[xX](%x+)(.*)$")
                if digits then cp = #digits > 8 and 0x110000 or tonumber(digits, 16) end
            else
                digits, rest = run:match("^(%d+)(.*)$")
                if digits then cp = #digits > 9 and 0x110000 or tonumber(digits) end
            end
            if not cp then return nil end
            if rest ~= "" then return numeric_reference(cp) .. rest .. semi end
            return numeric_reference(cp)
        end
        if run == "" then return nil end
        if semi == ";" and names[run] then return names[run] end
        -- the longest name that needs no semicolon
        for k = math.min(#run, 6), 2, -1 do
            local name = run:sub(1, k)
            if legacy[name] then
                if in_attr then
                    if k < #run then return nil end
                    if semi == "" and text:sub(after, after) == "=" then return nil end
                end
                return names[name] .. run:sub(k + 1) .. semi
            end
        end
        return nil
    end))
end
Parse.decodeReferences = decode_refs

-- ---------------------------------------------------------------------------
-- Tree
-- ---------------------------------------------------------------------------

local function new_element(name, ns, attrs)
    local el = { name = name, ns = ns, attrs = attrs or {}, kids = {} }
    if name == "template" and ns == nil then el.content = { kids = {}, fragment = true } end
    return el
end

local function index_of(parent, node)
    local kids = parent.kids
    for i = #kids, 1, -1 do
        if kids[i] == node then return i end
    end
    return nil
end

local function detach(node)
    local parent = node.parent
    if not parent then return end
    local i = index_of(parent, node)
    if i then table.remove(parent.kids, i) end
    node.parent = nil
end

local function insert_node(parent, node, before)
    if node.parent then detach(node) end
    if before then
        local i = index_of(parent, before)
        if i then
            table.insert(parent.kids, i, node)
            node.parent = parent
            return
        end
    end
    parent.kids[#parent.kids + 1] = node
    node.parent = parent
end
Parse.insertNode = insert_node
Parse.detach = detach
Parse.newElement = new_element

local function is_special(el)
    if el.ns == nil then return SPECIAL[el.name] == true end
    if el.ns == "math" then return SPECIAL_MATH[el.name] == true end
    return SPECIAL_SVG[el.name] == true
end

local function is_scope_marker(el, html_set)
    if el.ns == nil then return html_set[el.name] == true end
    if el.ns == "math" then return SPECIAL_MATH[el.name] == true end
    return SPECIAL_SVG[el.name] == true
end

local function is_math_text_point(el)
    if el.ns ~= "math" then return false end
    local n = el.name
    return n == "mi" or n == "mo" or n == "mn" or n == "ms" or n == "mtext"
end

local function is_html_point(el)
    if el.ns == "svg" then
        return el.name == "foreignObject" or el.name == "desc" or el.name == "title"
    end
    if el.ns == "math" and el.name == "annotation-xml" then
        local enc = el.attrs.encoding
        if type(enc) == "string" then
            enc = enc:lower()
            return enc == "text/html" or enc == "application/xhtml+xml"
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Tokenizer
-- ---------------------------------------------------------------------------

local P = {}
P.__index = P

local EOF = { t = "eof" }
local WS_ONLY = "^[ \t\n\f\r]*$"

--- Is s[at...] the tag name `name` (any case), followed by what ends a name?
local function name_at(s, at, name)
    local n = #name
    if s:sub(at, at + n - 1):lower() ~= name then return false end
    local c = s:byte(at + n)
    return c == 32 or c == 9 or c == 10 or c == 12 or c == 47 or c == 62
end

--- A start or end tag. @return token, or nil when the input ends inside it
function P:tag(pos, is_end)
    local s, len = self.src, self.len
    local name_start = pos + (is_end and 2 or 1)
    local p = s:find("[ \t\n\f/>]", name_start)
    if not p then
        self.pos = len + 1
        return nil
    end
    local name = s:sub(name_start, p - 1):lower()
    if name:find("%z") then name = name:gsub("%z", REPLACEMENT) end
    local attrs = {}
    local self_closing = false
    -- (formatting elements are compared by their attributes)
    local keep_all = self.keep_all or FORMATTING[name]
    while true do
        p = s:find("[^ \t\n\f]", p)
        if not p then self.pos = len + 1; return nil end
        local c = s:byte(p)
        if c == 62 then -- '>'
            p = p + 1
            break
        elseif c == 47 then -- '/'
            if s:byte(p + 1) == 62 then
                self_closing = true
                p = p + 2
                break
            end
            p = p + 1
        else
            -- attribute name (a leading "=" belongs to it)
            local ne = s:find("[ \t\n\f/>=]", p + 1)
            if not ne then self.pos = len + 1; return nil end
            local aname = s:sub(p, ne - 1):lower()
            local q = s:find("[^ \t\n\f]", ne)
            if not q then self.pos = len + 1; return nil end
            local v0, v1 -- value: s[v0..v1]
            if s:byte(q) == 61 then -- '='
                q = s:find("[^ \t\n\f]", q + 1)
                if not q then self.pos = len + 1; return nil end
                local qc = s:byte(q)
                if qc == 34 or qc == 39 then
                    local close = s:find(qc == 34 and '"' or "'", q + 1, true)
                    if not close then self.pos = len + 1; return nil end
                    v0, v1 = q + 1, close - 1
                    p = close + 1
                    if self.marks then
                        -- (see Parse.parse: values a simpler parser would end the tag in)
                        local gt = s:find(">", v0, true)
                        if (gt and gt <= v1) or (aname == "srcdoc" and name == "iframe" and not is_end and v1 >= v0) then
                            self.marks[#self.marks + 1] = { v0, v1, aname == "srcdoc" and name == "iframe" and not is_end }
                        end
                    end
                elseif qc == 62 then
                    p = q
                else
                    local ve = s:find("[ \t\n\f>]", q)
                    if not ve then self.pos = len + 1; return nil end
                    v0, v1 = q, ve - 1
                    p = ve
                end
            else
                p = q
            end
            if attrs[aname] == nil then
                if KEEP[aname] or keep_all then
                    attrs[aname] = v0 and decode_refs(s:sub(v0, v1), true) or ""
                else
                    attrs[aname] = true
                end
            end
        end
    end
    self.pos = p
    if is_end then return { t = "end", name = name } end
    return { t = "start", name = name, attrs = attrs, self_closing = self_closing }
end

function P:comment(pos)
    local s, len = self.src, self.len
    local p = pos + 4
    local stop, next_pos
    if s:byte(p) == 62 then
        stop, next_pos = p - 1, p + 1
    elseif s:sub(p, p + 1) == "->" then
        stop, next_pos = p - 1, p + 2
    else
        local a = s:find("-->", p, true)
        local b = s:find("--!>", p, true)
        if a and (not b or a < b) then
            stop, next_pos = a - 1, a + 3
        elseif b then
            stop, next_pos = b - 1, b + 4
        else
            stop, next_pos = len, len + 1
        end
    end
    self.pos = next_pos
    return { t = "comment", data = s:sub(p, stop) }
end

function P:bogus_comment(from)
    local s = self.src
    local gt = s:find(">", from, true)
    self.pos = gt and gt + 1 or self.len + 1
    return { t = "comment", data = s:sub(from, (gt or self.len + 1) - 1) }
end

function P:doctype(pos)
    local s = self.src
    local gt = s:find(">", pos, true)
    local inner = s:sub(pos + 9, (gt or self.len + 1) - 1)
    self.pos = gt and gt + 1 or self.len + 1
    local tok = { t = "doctype", force_quirks = gt == nil }
    local name, rest = inner:match("^[ \t\n\f]*([^ \t\n\f]+)(.*)$")
    if not name then
        tok.force_quirks = true
        return tok
    end
    tok.name = name:lower()
    local keyword, after = rest:match("^[ \t\n\f]*(%a%a%a%a%a%a)(.*)$")
    if keyword then
        keyword = keyword:upper()
        local function quoted(str)
            local q, tail = str:match("^[ \t\n\f]*([\"'])(.*)$")
            if not q then return nil, str end
            local close = tail:find(q, 1, true)
            if not close then
                tok.force_quirks = true
                return tail, ""
            end
            return tail:sub(1, close - 1), tail:sub(close + 1)
        end
        if keyword == "PUBLIC" then
            local pub, tail = quoted(after)
            if pub == nil then
                tok.force_quirks = true
            else
                tok.public = pub
                tok.system = quoted(tail)
            end
        elseif keyword == "SYSTEM" then
            local sys = quoted(after)
            if sys == nil then tok.force_quirks = true else tok.system = sys end
        else
            tok.force_quirks = true
        end
    elseif rest:find("[^ \t\n\f]") then
        tok.force_quirks = true
    end
    return tok
end

--- Where does the content of a <script> element end? (Position of "</script".)
function P:script_end(pos)
    local s = self.src
    local state = 0 -- 0: script data, 1: escaped ("<!--" seen), 2: double escaped ("<script" inside that)
    local p = pos
    while true do
        local lt = s:find("<", p, true)
        local dashes = state ~= 0 and s:find("-->", p, true) or nil
        if dashes and (not lt or dashes < lt) then
            state = 0
            p = dashes + 3
        elseif not lt then
            return nil
        elseif state == 0 and s:sub(lt, lt + 3) == "<!--" then
            local back = s:match("^%-*>", lt + 4)
            if back then
                p = lt + 4 + #back
            else
                state = 1
                p = lt + 4
            end
        elseif s:byte(lt + 1) == 47 and name_at(s, lt + 2, "script") then
            if state == 2 then
                state = 1
                p = lt + 8
            else
                return lt
            end
        elseif state == 1 and name_at(s, lt + 1, "script") then
            state = 2
            p = lt + 7
        else
            p = lt + 1
        end
    end
end

--- The content of an element whose text is not markup (<style>, <title>...).
function P:raw_token()
    local s, pos, len = self.src, self.pos, self.len
    local st = self.tok_state
    local text
    if st == "plaintext" then
        self.pos = len + 1
        text = s:sub(pos)
    else
        local close
        if st == "script" then
            close = self:script_end(pos)
        else
            local p = pos
            while true do
                local lt = s:find("</", p, true)
                if not lt then break end
                if name_at(s, lt + 2, self.raw_name) then
                    close = lt
                    break
                end
                p = lt + 2
            end
        end
        if close then
            text = s:sub(pos, close - 1)
            self.pos = close
        else
            text = s:sub(pos)
            self.pos = len + 1
        end
        self.tok_state = "data"
        if st == "rcdata" then text = decode_refs(text) end
    end
    if text:find("%z") then text = text:gsub("%z", REPLACEMENT) end
    if text == "" then return self:next_token() end
    return { t = "text", data = text }
end

function P:next_token()
    local s, pos, len = self.src, self.pos, self.len
    if pos > len then return EOF end
    if self.tok_state ~= "data" then return self:raw_token() end
    local lt = s:find("<", pos, true)
    if lt ~= pos then
        local stop = (lt or len + 1) - 1
        self.pos = stop + 1
        return { t = "text", data = decode_refs(s:sub(pos, stop)) }
    end
    local c = s:byte(pos + 1)
    if c and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)) then
        local tok = self:tag(pos, false)
        return tok or EOF
    elseif c == 47 then -- "</"
        local c2 = s:byte(pos + 2)
        if c2 and ((c2 >= 65 and c2 <= 90) or (c2 >= 97 and c2 <= 122)) then
            local tok = self:tag(pos, true)
            return tok or EOF
        elseif c2 == 62 then
            self.pos = pos + 3
            return self:next_token()
        elseif c2 == nil then
            self.pos = len + 1
            return { t = "text", data = "</" }
        end
        return self:bogus_comment(pos + 2)
    elseif c == 33 then -- "<!"
        if s:sub(pos + 2, pos + 3) == "--" then
            return self:comment(pos)
        elseif s:sub(pos + 2, pos + 8):upper() == "DOCTYPE" then
            return self:doctype(pos)
        elseif s:sub(pos + 2, pos + 8) == "[CDATA[" then
            local cur = self.stack[#self.stack]
            if cur and cur.ns ~= nil then
                local close = s:find("]]>", pos + 9, true)
                self.pos = close and close + 3 or len + 1
                local text = s:sub(pos + 9, (close or len + 1) - 1)
                if text == "" then return self:next_token() end
                return { t = "text", data = text }
            end
        end
        return self:bogus_comment(pos + 2)
    elseif c == 63 then -- "<?"
        return self:bogus_comment(pos + 1)
    end
    self.pos = pos + 1
    return { t = "text", data = "<" }
end

-- ---------------------------------------------------------------------------
-- Tree construction: helpers
-- ---------------------------------------------------------------------------

local MARKER = { marker = true }

function P:current()
    return self.stack[#self.stack]
end

function P:pop()
    local stack = self.stack
    local el = stack[#stack]
    stack[#stack] = nil
    return el
end

--- Where the next node goes: parent, and the child it goes in front of (or nil).
function P:place(override)
    local stack = self.stack
    local target = override or stack[#stack]
    local parent, before
    if self.foster and target.ns == nil and TABLEISH[target.name] then
        local last_template, last_table
        for i = #stack, 1, -1 do
            local el = stack[i]
            if el.ns == nil then
                if el.name == "template" and not last_template then last_template = i end
                if el.name == "table" and not last_table then last_table = i end
            end
        end
        if last_template and (not last_table or last_template > last_table) then
            parent = stack[last_template]
        elseif not last_table then
            parent = stack[1]
        elseif stack[last_table].parent then
            parent = stack[last_table].parent
            before = stack[last_table]
        else
            parent = stack[last_table - 1]
        end
    else
        parent = target
    end
    if parent.content then parent = parent.content end
    return parent, before
end

function P:insert_element(tok, ns, name)
    local el = new_element(name or tok.name, ns, tok.attrs)
    local parent, before = self:place()
    insert_node(parent, el, before)
    self.stack[#self.stack + 1] = el
    return el
end

function P:insert_text(data)
    if data == "" then return end
    local parent, before = self:place()
    if parent.document then return end
    local kids = parent.kids
    local prev
    if before then
        local i = index_of(parent, before)
        prev = i and kids[i - 1] or kids[#kids]
        if not i then before = nil end
    else
        prev = kids[#kids]
    end
    if prev and prev.text then
        -- pieces are joined when the tree is finished
        local parts = prev.parts
        if not parts then
            parts = { prev.text }
            prev.parts = parts
            self.joins[#self.joins + 1] = prev
        end
        parts[#parts + 1] = data
        prev.text = data -- (placeholder: non-empty; the real text is in parts)
        return
    end
    insert_node(parent, { text = data }, before)
end

function P:insert_comment(tok, parent)
    if not parent then
        local before
        parent, before = self:place()
        insert_node(parent, { comment = true }, before)
        return
    end
    insert_node(parent, { comment = true })
end

--- Is an HTML element with one of these names in scope?
function P:in_scope(names, scope)
    local stack = self.stack
    scope = scope or SCOPE_DEFAULT
    local single = type(names) == "string"
    for i = #stack, 1, -1 do
        local el = stack[i]
        if el.ns == nil and ((single and el.name == names) or (not single and names[el.name])) then return true end
        if is_scope_marker(el, scope) then return false end
    end
    return false
end

function P:in_table_scope(names)
    local stack = self.stack
    local single = type(names) == "string"
    for i = #stack, 1, -1 do
        local el = stack[i]
        if el.ns == nil then
            if (single and el.name == names) or (not single and names[el.name]) then return true end
            if SCOPE_TABLE[el.name] then return false end
        end
    end
    return false
end

function P:in_select_scope(name)
    local stack = self.stack
    for i = #stack, 1, -1 do
        local el = stack[i]
        if el.ns == nil and el.name == name then return true end
        if not (el.ns == nil and (el.name == "optgroup" or el.name == "option")) then return false end
    end
    return false
end

function P:on_stack(name)
    local stack = self.stack
    for i = #stack, 1, -1 do
        if stack[i].ns == nil and stack[i].name == name then return i end
    end
    return nil
end

function P:implied_end_tags(except, thorough)
    local stack = self.stack
    local names = thorough and IMPLIED_END_THOROUGH or IMPLIED_END
    while true do
        local el = stack[#stack]
        if not el or el.ns ~= nil or not names[el.name] or el.name == except then return end
        stack[#stack] = nil
    end
end

--- Pop elements until an HTML element with this name (or one of these names) was popped.
function P:pop_until(names)
    local stack = self.stack
    local single = type(names) == "string"
    while #stack > 0 do
        local el = stack[#stack]
        stack[#stack] = nil
        if el.ns == nil and ((single and el.name == names) or (not single and names[el.name])) then return el end
    end
    return nil
end

function P:close_p()
    self:implied_end_tags("p")
    self:pop_until("p")
end

-- Active formatting elements ---------------------------------------------------

function P:push_formatting(el, tok)
    local list = self.formatting
    -- "Noah's Ark": at most three equal entries after the last marker
    local same = 0
    for i = #list, 1, -1 do
        local e = list[i]
        if e == MARKER then break end
        if e.el.name == el.name and e.el.ns == el.ns then
            local equal = true
            for k, v in pairs(e.tok.attrs) do
                if tok.attrs[k] ~= v then equal = false; break end
            end
            if equal then
                for k in pairs(tok.attrs) do
                    if e.tok.attrs[k] == nil then equal = false; break end
                end
            end
            if equal then
                same = same + 1
                if same == 3 then
                    table.remove(list, i)
                    break
                end
            end
        end
    end
    list[#list + 1] = { el = el, tok = tok }
end

function P:stack_index(el)
    local stack = self.stack
    for i = #stack, 1, -1 do
        if stack[i] == el then return i end
    end
    return nil
end

function P:reconstruct()
    local list = self.formatting
    local n = #list
    if n == 0 then return end
    local entry = list[n]
    if entry == MARKER or self:stack_index(entry.el) then return end
    local i = n
    while i > 1 do
        local prev = list[i - 1]
        if prev == MARKER or self:stack_index(prev.el) then break end
        i = i - 1
    end
    for j = i, n do
        local e = list[j]
        local el = self:insert_element(e.tok)
        list[j] = { el = el, tok = e.tok }
    end
end

function P:clear_formatting_to_marker()
    local list = self.formatting
    while #list > 0 do
        local e = list[#list]
        list[#list] = nil
        if e == MARKER then return end
    end
end

function P:formatting_index(el)
    local list = self.formatting
    for i = #list, 1, -1 do
        if list[i] ~= MARKER and list[i].el == el then return i end
    end
    return nil
end

--- "Any other end tag" in the body.
function P:other_end_tag(name)
    local stack = self.stack
    for i = #stack, 1, -1 do
        local el = stack[i]
        if el.ns == nil and el.name == name then
            self:implied_end_tags(name)
            while #stack >= i do stack[#stack] = nil end
            return
        end
        if is_special(el) then return end
    end
end

--- The adoption agency algorithm: an end tag for a formatting element whose
-- element is not the innermost open one.
function P:adoption(subject)
    local stack, list = self.stack, self.formatting
    local cur = stack[#stack]
    if cur.ns == nil and cur.name == subject and not self:formatting_index(cur) then
        stack[#stack] = nil
        return
    end
    for _ = 1, 8 do
        -- the formatting element
        local fi
        for i = #list, 1, -1 do
            local e = list[i]
            if e == MARKER then break end
            if e.el.ns == nil and e.el.name == subject then fi = i; break end
        end
        if not fi then return self:other_end_tag(subject) end
        local fe = list[fi].el
        local fsi = self:stack_index(fe)
        if not fsi then
            table.remove(list, fi)
            return
        end
        if not self:in_scope(subject) then return end
        -- the furthest block
        local fb_index
        for i = fsi + 1, #stack do
            if is_special(stack[i]) then fb_index = i; break end
        end
        if not fb_index then
            while #stack >= fsi do stack[#stack] = nil end
            table.remove(list, fi)
            return
        end
        local furthest = stack[fb_index]
        local ancestor = stack[fsi - 1]
        local bookmark = fi
        local node_index = fb_index
        local last = furthest
        local inner = 0
        while true do
            inner = inner + 1
            node_index = node_index - 1
            local node = stack[node_index]
            if node == fe then break end
            local ni = self:formatting_index(node)
            if inner > 3 and ni then
                table.remove(list, ni)
                if ni < bookmark then bookmark = bookmark - 1 end
                ni = nil
            end
            if not ni then
                table.remove(stack, node_index)
                -- (node_index now names the element that was below; the next
                -- round steps up from there, to the one that was above)
            else
                local replacement = new_element(node.name, node.ns, list[ni].tok.attrs)
                list[ni] = { el = replacement, tok = list[ni].tok }
                stack[node_index] = replacement
                node = replacement
                if last == furthest then bookmark = ni + 1 end
                insert_node(node, last)
                last = node
            end
        end
        -- last node goes where a child of the common ancestor would go
        local parent, before = self:place(ancestor)
        insert_node(parent, last, before)
        -- a new element takes over the furthest block's children
        local fe_tok = list[self:formatting_index(fe)].tok
        local fresh = new_element(fe.name, fe.ns, fe_tok.attrs)
        local kids = furthest.kids
        furthest.kids = {}
        for _, k in ipairs(kids) do
            k.parent = fresh
            fresh.kids[#fresh.kids + 1] = k
        end
        insert_node(furthest, fresh)
        local old = self:formatting_index(fe)
        table.remove(list, old)
        if old < bookmark then bookmark = bookmark - 1 end
        table.insert(list, math.min(bookmark, #list + 1), { el = fresh, tok = fe_tok })
        table.remove(stack, self:stack_index(fe))
        table.insert(stack, self:stack_index(furthest) + 1, fresh)
    end
end

function P:reset_mode()
    local stack = self.stack
    for i = #stack, 1, -1 do
        local el = stack[i]
        local last = i == 1
        if el.ns == nil then
            local n = el.name
            if n == "select" then
                if not last then
                    for j = i - 1, 1, -1 do
                        local a = stack[j]
                        if a.ns == nil and a.name == "template" then break end
                        if a.ns == nil and a.name == "table" then
                            self.mode = "in_select_in_table"
                            return
                        end
                    end
                end
                self.mode = "in_select"
                return
            elseif (n == "td" or n == "th") and not last then
                self.mode = "in_cell"; return
            elseif n == "tr" then
                self.mode = "in_row"; return
            elseif TABLE_SECTION[n] then
                self.mode = "in_table_body"; return
            elseif n == "caption" then
                self.mode = "in_caption"; return
            elseif n == "colgroup" then
                self.mode = "in_column_group"; return
            elseif n == "table" then
                self.mode = "in_table"; return
            elseif n == "template" then
                self.mode = self.template_modes[#self.template_modes]; return
            elseif n == "head" and not last then
                self.mode = "in_head"; return
            elseif n == "body" then
                self.mode = "in_body"; return
            elseif n == "frameset" then
                self.mode = "in_frameset"; return
            elseif n == "html" then
                self.mode = self.head and "after_head" or "before_head"; return
            end
        end
        if last then
            self.mode = "in_body"
            return
        end
    end
    self.mode = "in_body"
end

--- An element whose content is text for the tokenizer (<title>, <style>, <script>...).
function P:raw_element(tok, kind)
    self:insert_element(tok)
    self.tok_state = kind
    self.raw_name = tok.name
    self.original_mode = self.mode
    self.mode = "text"
end

local function split_ws(data)
    local stop = data:find("[^ \t\n\f\r]")
    if not stop then return data, "" end
    return data:sub(1, stop - 1), data:sub(stop)
end

-- ---------------------------------------------------------------------------
-- Tree construction: the insertion modes
-- ---------------------------------------------------------------------------

local M = {}

function M.initial(self, tok)
    local t = tok.t
    if t == "text" then
        local _, rest = split_ws(tok.data)
        if rest == "" then return end
        tok = { t = "text", data = rest }
    elseif t == "comment" then
        return insert_node(self.doc, { comment = true })
    elseif t == "doctype" then
        local doc = self.doc
        doc.doctype = { name = tok.name, public = tok.public, system = tok.system }
        local pub = tok.public and tok.public:lower() or nil
        local sys = tok.system and tok.system:lower() or nil
        local quirks = tok.force_quirks or tok.name ~= "html"
            or pub == "-//w3o//dtd w3 html strict 3.0//en//" or pub == "-/w3c/dtd html 4.0 transitional/en"
            or pub == "html" or sys == "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd"
        if not quirks and pub then
            for _, prefix in ipairs(QUIRKY_PREFIXES) do
                if pub:sub(1, #prefix) == prefix then quirks = true; break end
            end
            if not quirks and sys == nil and (pub:sub(1, 32) == "-//w3c//dtd html 4.01 frameset//"
                or pub:sub(1, 36) == "-//w3c//dtd html 4.01 transitional//") then
                quirks = true
            end
        end
        doc.quirks = quirks and true or false
        self.mode = "before_html"
        return
    end
    self.doc.quirks = true
    self.mode = "before_html"
    return self:dispatch(tok)
end

function M.before_html(self, tok)
    local t = tok.t
    if t == "doctype" then
        return
    elseif t == "comment" then
        return insert_node(self.doc, { comment = true })
    elseif t == "text" then
        local _, rest = split_ws(tok.data)
        if rest == "" then return end
        tok = { t = "text", data = rest }
    elseif t == "start" and tok.name == "html" then
        local el = new_element("html", nil, tok.attrs)
        insert_node(self.doc, el)
        self.stack[1] = el
        self.mode = "before_head"
        return
    elseif t == "end" and not (tok.name == "head" or tok.name == "body" or tok.name == "html" or tok.name == "br") then
        return
    end
    local el = new_element("html", nil, {})
    insert_node(self.doc, el)
    self.stack[1] = el
    self.mode = "before_head"
    return self:dispatch(tok)
end

function M.before_head(self, tok)
    local t = tok.t
    if t == "text" then
        local _, rest = split_ws(tok.data)
        if rest == "" then return end
        tok = { t = "text", data = rest }
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "doctype" then
        return
    elseif t == "start" and tok.name == "html" then
        return M.in_body(self, tok)
    elseif t == "start" and tok.name == "head" then
        self.head = self:insert_element(tok)
        self.mode = "in_head"
        return
    elseif t == "end" and not (tok.name == "head" or tok.name == "body" or tok.name == "html" or tok.name == "br") then
        return
    end
    self.head = self:insert_element({ name = "head", attrs = {} })
    self.mode = "in_head"
    return self:dispatch(tok)
end

function M.in_head(self, tok)
    local t, name = tok.t, tok.name
    if t == "text" then
        local lead, rest = split_ws(tok.data)
        self:insert_text(lead)
        if rest == "" then return end
        tok = { t = "text", data = rest }
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "doctype" then
        return
    elseif t == "start" then
        if name == "html" then
            return M.in_body(self, tok)
        elseif name == "base" or name == "basefont" or name == "bgsound" or name == "link" or name == "meta" then
            self:insert_element(tok)
            self:pop()
            return
        elseif name == "title" then
            return self:raw_element(tok, "rcdata")
        elseif name == "noscript" then
            self:insert_element(tok)
            self.mode = "in_head_noscript"
            return
        elseif name == "noframes" or name == "style" then
            return self:raw_element(tok, "rawtext")
        elseif name == "script" then
            return self:raw_element(tok, "script")
        elseif name == "template" then
            self:insert_element(tok)
            self.formatting[#self.formatting + 1] = MARKER
            self.frameset_ok = false
            self.mode = "in_template"
            self.template_modes[#self.template_modes + 1] = "in_template"
            return
        elseif name == "head" then
            return
        end
    elseif t == "end" then
        if name == "head" then
            self:pop()
            self.mode = "after_head"
            return
        elseif name == "template" then
            if not self:on_stack("template") then return end
            self:implied_end_tags(nil, true)
            self:pop_until("template")
            self:clear_formatting_to_marker()
            self.template_modes[#self.template_modes] = nil
            self:reset_mode()
            return
        elseif not (name == "body" or name == "html" or name == "br") then
            return
        end
    end
    self:pop()
    self.mode = "after_head"
    return self:dispatch(tok)
end

function M.in_head_noscript(self, tok)
    local t, name = tok.t, tok.name
    if t == "doctype" then
        return
    elseif t == "start" and name == "html" then
        return M.in_body(self, tok)
    elseif t == "end" and name == "noscript" then
        self:pop()
        self.mode = "in_head"
        return
    elseif t == "comment" then
        return M.in_head(self, tok)
    elseif t == "text" then
        local lead, rest = split_ws(tok.data)
        self:insert_text(lead)
        if rest == "" then return end
        tok = { t = "text", data = rest }
    elseif t == "start" and (name == "basefont" or name == "bgsound" or name == "link" or name == "meta"
        or name == "noframes" or name == "style") then
        return M.in_head(self, tok)
    elseif t == "start" and (name == "head" or name == "noscript") then
        return
    elseif t == "end" and name ~= "br" then
        return
    end
    self:pop()
    self.mode = "in_head"
    return self:dispatch(tok)
end

function M.after_head(self, tok)
    local t, name = tok.t, tok.name
    if t == "text" then
        local lead, rest = split_ws(tok.data)
        self:insert_text(lead)
        if rest == "" then return end
        tok = { t = "text", data = rest }
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "doctype" then
        return
    elseif t == "start" then
        if name == "html" then
            return M.in_body(self, tok)
        elseif name == "body" then
            self:insert_element(tok)
            self.frameset_ok = false
            self.mode = "in_body"
            return
        elseif name == "frameset" then
            self:insert_element(tok)
            self.doc.unsafe = "the page is a frameset"
            self.mode = "in_frameset"
            return
        elseif HEAD_IN_BODY[name] then
            local stack = self.stack
            stack[#stack + 1] = self.head
            M.in_head(self, tok)
            local i = self:stack_index(self.head)
            if i then table.remove(stack, i) end
            return
        elseif name == "head" then
            return
        end
    elseif t == "end" then
        if name == "template" then
            return M.in_head(self, tok)
        elseif not (name == "body" or name == "html" or name == "br") then
            return
        end
    end
    self:insert_element({ name = "body", attrs = {} })
    self.mode = "in_body"
    return self:dispatch(tok)
end

local function body_start(self, tok)
    local name = tok.name
    if name == "html" then
        if self:on_stack("template") then return end
        local html = self.stack[1]
        for k, v in pairs(tok.attrs) do
            if html.attrs[k] == nil then html.attrs[k] = v end
        end
    elseif HEAD_IN_BODY[name] then
        return M.in_head(self, tok)
    elseif name == "body" then
        local stack = self.stack
        local second = stack[2]
        if #stack == 1 or not second or second.ns ~= nil or second.name ~= "body" or self:on_stack("template") then
            return
        end
        self.frameset_ok = false
        for k, v in pairs(tok.attrs) do
            if second.attrs[k] == nil then second.attrs[k] = v end
        end
    elseif name == "frameset" then
        if self.frameset_ok and #self.stack > 1 and self.stack[2].name == "body" then
            self.doc.unsafe = "the page is a frameset"
        end
        return
    elseif BLOCK_START[name] then
        if self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        self:insert_element(tok)
    elseif HEADINGS[name] then
        if self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        local cur = self:current()
        if cur.ns == nil and HEADINGS[cur.name] then self:pop() end
        self:insert_element(tok)
    elseif name == "pre" or name == "listing" then
        if self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        self:insert_element(tok)
        self.skip_lf = true
        self.frameset_ok = false
    elseif name == "form" then
        local in_template = self:on_stack("template")
        if self.form and not in_template then return end
        if self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        local el = self:insert_element(tok)
        if not in_template then self.form = el end
    elseif name == "li" then
        self.frameset_ok = false
        local stack = self.stack
        for i = #stack, 1, -1 do
            local el = stack[i]
            if el.ns == nil and el.name == "li" then
                self:implied_end_tags("li")
                self:pop_until("li")
                break
            end
            if is_special(el) and not (el.ns == nil and (el.name == "address" or el.name == "div" or el.name == "p")) then
                break
            end
        end
        if self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        self:insert_element(tok)
    elseif name == "dd" or name == "dt" then
        self.frameset_ok = false
        local stack = self.stack
        for i = #stack, 1, -1 do
            local el = stack[i]
            if el.ns == nil and (el.name == "dd" or el.name == "dt") then
                self:implied_end_tags(el.name)
                self:pop_until(el.name)
                break
            end
            if is_special(el) and not (el.ns == nil and (el.name == "address" or el.name == "div" or el.name == "p")) then
                break
            end
        end
        if self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        self:insert_element(tok)
    elseif name == "plaintext" then
        if self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        self:insert_element(tok)
        self.tok_state = "plaintext"
        -- (a page with <plaintext> does not survive being written out and read again)
        self.doc.unsafe = "the page uses <plaintext>"
    elseif name == "button" then
        if self:in_scope("button") then
            self:implied_end_tags()
            self:pop_until("button")
        end
        self:reconstruct()
        self:insert_element(tok)
        self.frameset_ok = false
    elseif name == "a" then
        local list = self.formatting
        for i = #list, 1, -1 do
            local e = list[i]
            if e == MARKER then break end
            if e.el.ns == nil and e.el.name == "a" then
                local el = e.el
                self:adoption("a")
                local fi = self:formatting_index(el)
                if fi then table.remove(list, fi) end
                local si = self:stack_index(el)
                if si then table.remove(self.stack, si) end
                break
            end
        end
        self:reconstruct()
        local el = self:insert_element(tok)
        self:push_formatting(el, tok)
    elseif name == "nobr" then
        self:reconstruct()
        if self:in_scope("nobr") then
            self:adoption("nobr")
            self:reconstruct()
        end
        local el = self:insert_element(tok)
        self:push_formatting(el, tok)
    elseif FORMATTING[name] then
        self:reconstruct()
        local el = self:insert_element(tok)
        self:push_formatting(el, tok)
    elseif name == "applet" or name == "marquee" or name == "object" then
        self:reconstruct()
        self:insert_element(tok)
        self.formatting[#self.formatting + 1] = MARKER
        self.frameset_ok = false
    elseif name == "table" then
        if not self.doc.quirks and self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        self:insert_element(tok)
        self.frameset_ok = false
        self.mode = "in_table"
    elseif VOID_FORMAT[name] then
        self:reconstruct()
        self:insert_element(tok)
        self:pop()
        self.frameset_ok = false
    elseif name == "input" then
        self:reconstruct()
        self:insert_element(tok)
        self:pop()
        local ty = tok.attrs.type
        if type(ty) ~= "string" or ty:lower() ~= "hidden" then self.frameset_ok = false end
    elseif name == "param" or name == "source" or name == "track" then
        self:insert_element(tok)
        self:pop()
    elseif name == "hr" then
        if self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        self:insert_element(tok)
        self:pop()
        self.frameset_ok = false
    elseif name == "image" then
        tok.name = "img"
        return body_start(self, tok)
    elseif name == "textarea" then
        self:insert_element(tok)
        self.skip_lf = true
        self.tok_state = "rcdata"
        self.raw_name = "textarea"
        self.original_mode = self.mode
        self.frameset_ok = false
        self.mode = "text"
    elseif name == "xmp" then
        if self:in_scope("p", SCOPE_BUTTON) then self:close_p() end
        self:reconstruct()
        self.frameset_ok = false
        self:raw_element(tok, "rawtext")
    elseif name == "iframe" then
        self.frameset_ok = false
        self:raw_element(tok, "rawtext")
    elseif name == "noembed" or (name == "noscript" and self.scripting) then
        self:raw_element(tok, "rawtext")
    elseif name == "select" then
        self:reconstruct()
        self:insert_element(tok)
        self.frameset_ok = false
        local m = self.mode
        if m == "in_table" or m == "in_caption" or m == "in_table_body" or m == "in_row" or m == "in_cell" then
            self.mode = "in_select_in_table"
        else
            self.mode = "in_select"
        end
    elseif name == "optgroup" or name == "option" then
        local cur = self:current()
        if cur.ns == nil and cur.name == "option" then self:pop() end
        self:reconstruct()
        self:insert_element(tok)
    elseif name == "rb" or name == "rtc" then
        if self:in_scope("ruby") then self:implied_end_tags() end
        self:insert_element(tok)
    elseif name == "rp" or name == "rt" then
        if self:in_scope("ruby") then self:implied_end_tags("rtc") end
        self:insert_element(tok)
    elseif name == "math" or name == "svg" then
        self:reconstruct()
        self:insert_element(tok, name)
        if tok.self_closing then self:pop() end
    elseif IGNORED_IN_BODY[name] then
        return
    else
        self:reconstruct()
        self:insert_element(tok)
    end
end

local function body_end(self, tok)
    local name = tok.name
    if name == "template" then
        return M.in_head(self, tok)
    elseif name == "body" then
        if not self:in_scope("body") then return end
        self.mode = "after_body"
    elseif name == "html" then
        if not self:in_scope("body") then return end
        self.mode = "after_body"
        return self:dispatch(tok)
    elseif BLOCK_END[name] then
        if not self:in_scope(name) then return end
        self:implied_end_tags()
        self:pop_until(name)
    elseif name == "form" then
        if not self:on_stack("template") then
            local node = self.form
            self.form = nil
            if not node then return end
            local i = self:stack_index(node)
            if not i then return end
            -- in scope?
            local stack = self.stack
            for j = #stack, i + 1, -1 do
                if is_scope_marker(stack[j], SCOPE_DEFAULT) then return end
            end
            self:implied_end_tags()
            i = self:stack_index(node)
            if i then table.remove(stack, i) end
        else
            if not self:in_scope("form") then return end
            self:implied_end_tags()
            self:pop_until("form")
        end
    elseif name == "p" then
        if not self:in_scope("p", SCOPE_BUTTON) then
            self:insert_element({ name = "p", attrs = {} })
        end
        self:close_p()
    elseif name == "li" then
        if not self:in_scope("li", SCOPE_LIST) then return end
        self:implied_end_tags("li")
        self:pop_until("li")
    elseif name == "dd" or name == "dt" then
        if not self:in_scope(name) then return end
        self:implied_end_tags(name)
        self:pop_until(name)
    elseif HEADINGS[name] then
        if not self:in_scope(HEADINGS) then return end
        self:implied_end_tags()
        self:pop_until(HEADINGS)
    elseif FORMATTING[name] then
        self:adoption(name)
    elseif name == "applet" or name == "marquee" or name == "object" then
        if not self:in_scope(name) then return end
        self:implied_end_tags()
        self:pop_until(name)
        self:clear_formatting_to_marker()
    elseif name == "br" then
        return body_start(self, { t = "start", name = "br", attrs = {} })
    else
        self:other_end_tag(name)
    end
end

function M.in_body(self, tok)
    local t = tok.t
    if t == "text" then
        local data = tok.data
        if data:find("%z") then
            data = data:gsub("%z", "")
            if data == "" then return end
        end
        self:reconstruct()
        self:insert_text(data)
        if self.frameset_ok and not data:find(WS_ONLY) then self.frameset_ok = false end
    elseif t == "start" then
        return body_start(self, tok)
    elseif t == "end" then
        return body_end(self, tok)
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "eof" then
        if #self.template_modes > 0 then return M.in_template(self, tok) end
        self.done = true
    end
end

function M.text(self, tok)
    local t = tok.t
    if t == "text" then
        return self:insert_text(tok.data)
    elseif t == "eof" then
        self:pop()
        self.mode = self.original_mode
        return self:dispatch(tok)
    end
    self:pop()
    self.mode = self.original_mode
end

local function clear_to(self, names)
    local stack = self.stack
    while #stack > 1 do
        local el = stack[#stack]
        if el.ns == nil and (names[el.name] or el.name == "template" or el.name == "html") then return end
        stack[#stack] = nil
    end
end
local CTX_TABLE = set("table")
local CTX_BODY = set("tbody tfoot thead")
local CTX_ROW = set("tr")

local function table_anything_else(self, tok)
    self.foster = true
    M.in_body(self, tok)
    self.foster = false
end

function M.in_table(self, tok)
    local t, name = tok.t, tok.name
    if t == "text" then
        local cur = self:current()
        if cur.ns == nil and (TABLEISH[cur.name] or cur.name == "template") then
            self.pending_text = {}
            self.original_mode = self.mode
            self.mode = "in_table_text"
            return self:dispatch(tok)
        end
        return table_anything_else(self, tok)
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "doctype" then
        return
    elseif t == "start" then
        if name == "caption" then
            clear_to(self, CTX_TABLE)
            self.formatting[#self.formatting + 1] = MARKER
            self:insert_element(tok)
            self.mode = "in_caption"
            return
        elseif name == "colgroup" then
            clear_to(self, CTX_TABLE)
            self:insert_element(tok)
            self.mode = "in_column_group"
            return
        elseif name == "col" then
            clear_to(self, CTX_TABLE)
            self:insert_element({ name = "colgroup", attrs = {} })
            self.mode = "in_column_group"
            return self:dispatch(tok)
        elseif TABLE_SECTION[name] then
            clear_to(self, CTX_TABLE)
            self:insert_element(tok)
            self.mode = "in_table_body"
            return
        elseif name == "td" or name == "th" or name == "tr" then
            clear_to(self, CTX_TABLE)
            self:insert_element({ name = "tbody", attrs = {} })
            self.mode = "in_table_body"
            return self:dispatch(tok)
        elseif name == "table" then
            if not self:in_table_scope("table") then return end
            self:pop_until("table")
            self:reset_mode()
            return self:dispatch(tok)
        elseif name == "style" or name == "script" or name == "template" then
            return M.in_head(self, tok)
        elseif name == "input" then
            local ty = tok.attrs.type
            if type(ty) == "string" and ty:lower() == "hidden" then
                self:insert_element(tok)
                self:pop()
                return
            end
        elseif name == "form" then
            if self:on_stack("template") or self.form then return end
            self.form = self:insert_element(tok)
            self:pop()
            return
        end
    elseif t == "end" then
        if name == "table" then
            if not self:in_table_scope("table") then return end
            self:pop_until("table")
            self:reset_mode()
            return
        elseif name == "body" or name == "caption" or name == "col" or name == "colgroup" or name == "html"
            or name == "tbody" or name == "td" or name == "tfoot" or name == "th" or name == "thead" or name == "tr" then
            return
        elseif name == "template" then
            return M.in_head(self, tok)
        end
    elseif t == "eof" then
        return M.in_body(self, tok)
    end
    return table_anything_else(self, tok)
end

function M.in_table_text(self, tok)
    if tok.t == "text" then
        local data = tok.data
        if data:find("%z") then data = data:gsub("%z", "") end
        self.pending_text[#self.pending_text + 1] = data
        return
    end
    local all = table.concat(self.pending_text)
    self.pending_text = nil
    if all ~= "" then
        if all:find(WS_ONLY) then
            self:insert_text(all)
        else
            table_anything_else(self, { t = "text", data = all })
        end
    end
    self.mode = self.original_mode
    return self:dispatch(tok)
end

local CAPTION_ENDERS = set("caption col colgroup tbody td tfoot th thead tr")

function M.in_caption(self, tok)
    local t, name = tok.t, tok.name
    if (t == "end" and (name == "caption" or name == "table")) or (t == "start" and CAPTION_ENDERS[name]) then
        if not self:in_table_scope("caption") then return end
        self:implied_end_tags()
        self:pop_until("caption")
        self:clear_formatting_to_marker()
        self.mode = "in_table"
        if not (t == "end" and name == "caption") then return self:dispatch(tok) end
        return
    elseif t == "end" and (name == "body" or name == "col" or name == "colgroup" or name == "html" or name == "tbody"
        or name == "td" or name == "tfoot" or name == "th" or name == "thead" or name == "tr") then
        return
    end
    return M.in_body(self, tok)
end

function M.in_column_group(self, tok)
    local t, name = tok.t, tok.name
    if t == "text" then
        local lead, rest = split_ws(tok.data)
        self:insert_text(lead)
        if rest == "" then return end
        tok = { t = "text", data = rest }
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "doctype" then
        return
    elseif t == "start" and name == "html" then
        return M.in_body(self, tok)
    elseif t == "start" and name == "col" then
        self:insert_element(tok)
        self:pop()
        return
    elseif t == "end" and name == "colgroup" then
        local cur = self:current()
        if cur.ns ~= nil or cur.name ~= "colgroup" then return end
        self:pop()
        self.mode = "in_table"
        return
    elseif t == "end" and name == "col" then
        return
    elseif (t == "start" or t == "end") and name == "template" then
        return M.in_head(self, tok)
    elseif t == "eof" then
        return M.in_body(self, tok)
    end
    local cur = self:current()
    if cur.ns ~= nil or cur.name ~= "colgroup" then return end
    self:pop()
    self.mode = "in_table"
    return self:dispatch(tok)
end

local BODY_ENDERS = set("caption col colgroup tbody tfoot thead")

function M.in_table_body(self, tok)
    local t, name = tok.t, tok.name
    if t == "start" and name == "tr" then
        clear_to(self, CTX_BODY)
        self:insert_element(tok)
        self.mode = "in_row"
        return
    elseif t == "start" and (name == "th" or name == "td") then
        clear_to(self, CTX_BODY)
        self:insert_element({ name = "tr", attrs = {} })
        self.mode = "in_row"
        return self:dispatch(tok)
    elseif t == "end" and TABLE_SECTION[name] then
        if not self:in_table_scope(name) then return end
        clear_to(self, CTX_BODY)
        self:pop()
        self.mode = "in_table"
        return
    elseif (t == "start" and BODY_ENDERS[name]) or (t == "end" and name == "table") then
        if not self:in_table_scope(TABLE_SECTION) then return end
        clear_to(self, CTX_BODY)
        self:pop()
        self.mode = "in_table"
        return self:dispatch(tok)
    elseif t == "end" and (name == "body" or name == "caption" or name == "col" or name == "colgroup"
        or name == "html" or name == "td" or name == "th" or name == "tr") then
        return
    end
    return M.in_table(self, tok)
end

local ROW_ENDERS = set("caption col colgroup tbody tfoot thead tr")

function M.in_row(self, tok)
    local t, name = tok.t, tok.name
    if t == "start" and (name == "th" or name == "td") then
        clear_to(self, CTX_ROW)
        self:insert_element(tok)
        self.mode = "in_cell"
        self.formatting[#self.formatting + 1] = MARKER
        return
    elseif t == "end" and name == "tr" then
        if not self:in_table_scope("tr") then return end
        clear_to(self, CTX_ROW)
        self:pop()
        self.mode = "in_table_body"
        return
    elseif (t == "start" and ROW_ENDERS[name]) or (t == "end" and name == "table") then
        if not self:in_table_scope("tr") then return end
        clear_to(self, CTX_ROW)
        self:pop()
        self.mode = "in_table_body"
        return self:dispatch(tok)
    elseif t == "end" and TABLE_SECTION[name] then
        if not self:in_table_scope(name) then return end
        if not self:in_table_scope("tr") then return end
        clear_to(self, CTX_ROW)
        self:pop()
        self.mode = "in_table_body"
        return self:dispatch(tok)
    elseif t == "end" and (name == "body" or name == "caption" or name == "col" or name == "colgroup"
        or name == "html" or name == "td" or name == "th") then
        return
    end
    return M.in_table(self, tok)
end

local CELLS = set("td th")
local CELL_ENDERS = set("caption col colgroup tbody td tfoot th thead tr")

local function close_cell(self)
    self:implied_end_tags()
    self:pop_until(CELLS)
    self:clear_formatting_to_marker()
    self.mode = "in_row"
end

function M.in_cell(self, tok)
    local t, name = tok.t, tok.name
    if t == "end" and (name == "td" or name == "th") then
        if not self:in_table_scope(name) then return end
        self:implied_end_tags()
        self:pop_until(name)
        self:clear_formatting_to_marker()
        self.mode = "in_row"
        return
    elseif t == "start" and CELL_ENDERS[name] then
        if not self:in_table_scope(CELLS) then return end
        close_cell(self)
        return self:dispatch(tok)
    elseif t == "end" and (name == "body" or name == "caption" or name == "col" or name == "colgroup" or name == "html") then
        return
    elseif t == "end" and (name == "table" or TABLE_SECTION[name] or name == "tr") then
        if not self:in_table_scope(name) then return end
        close_cell(self)
        return self:dispatch(tok)
    end
    return M.in_body(self, tok)
end

function M.in_select(self, tok)
    local t, name = tok.t, tok.name
    if t == "text" then
        local data = tok.data
        if data:find("%z") then data = data:gsub("%z", "") end
        return self:insert_text(data)
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "doctype" then
        return
    elseif t == "start" then
        if name == "html" then
            return M.in_body(self, tok)
        elseif name == "option" then
            local cur = self:current()
            if cur.ns == nil and cur.name == "option" then self:pop() end
            self:insert_element(tok)
        elseif name == "optgroup" then
            local cur = self:current()
            if cur.ns == nil and cur.name == "option" then self:pop() end
            cur = self:current()
            if cur.ns == nil and cur.name == "optgroup" then self:pop() end
            self:insert_element(tok)
        elseif name == "hr" then
            local cur = self:current()
            if cur.ns == nil and cur.name == "option" then self:pop() end
            cur = self:current()
            if cur.ns == nil and cur.name == "optgroup" then self:pop() end
            self:insert_element(tok)
            self:pop()
        elseif name == "select" then
            if not self:in_select_scope("select") then return end
            self:pop_until("select")
            self:reset_mode()
        elseif name == "input" or name == "keygen" or name == "textarea" then
            if not self:in_select_scope("select") then return end
            self:pop_until("select")
            self:reset_mode()
            return self:dispatch(tok)
        elseif name == "script" or name == "template" then
            return M.in_head(self, tok)
        end
        return
    elseif t == "end" then
        if name == "optgroup" then
            local stack = self.stack
            local cur, prev = stack[#stack], stack[#stack - 1]
            if cur.ns == nil and cur.name == "option" and prev and prev.ns == nil and prev.name == "optgroup" then
                self:pop()
            end
            cur = self:current()
            if cur.ns == nil and cur.name == "optgroup" then self:pop() end
        elseif name == "option" then
            local cur = self:current()
            if cur.ns == nil and cur.name == "option" then self:pop() end
        elseif name == "select" then
            if not self:in_select_scope("select") then return end
            self:pop_until("select")
            self:reset_mode()
        elseif name == "template" then
            return M.in_head(self, tok)
        end
        return
    elseif t == "eof" then
        return M.in_body(self, tok)
    end
end

local SELECT_TABLE = set("caption table tbody tfoot thead tr td th")

function M.in_select_in_table(self, tok)
    local t, name = tok.t, tok.name
    if t == "start" and SELECT_TABLE[name] then
        self:pop_until("select")
        self:reset_mode()
        return self:dispatch(tok)
    elseif t == "end" and SELECT_TABLE[name] then
        if not self:in_table_scope(name) then return end
        self:pop_until("select")
        self:reset_mode()
        return self:dispatch(tok)
    end
    return M.in_select(self, tok)
end

function M.in_template(self, tok)
    local t, name = tok.t, tok.name
    if t == "text" or t == "comment" or t == "doctype" then
        return M.in_body(self, tok)
    elseif t == "start" then
        local modes = self.template_modes
        if HEAD_IN_BODY[name] then
            return M.in_head(self, tok)
        elseif name == "caption" or name == "colgroup" or TABLE_SECTION[name] then
            modes[#modes] = "in_table"
            self.mode = "in_table"
        elseif name == "col" then
            modes[#modes] = "in_column_group"
            self.mode = "in_column_group"
        elseif name == "tr" then
            modes[#modes] = "in_table_body"
            self.mode = "in_table_body"
        elseif name == "td" or name == "th" then
            modes[#modes] = "in_row"
            self.mode = "in_row"
        else
            modes[#modes] = "in_body"
            self.mode = "in_body"
        end
        return self:dispatch(tok)
    elseif t == "end" then
        if name == "template" then return M.in_head(self, tok) end
        return
    elseif t == "eof" then
        if not self:on_stack("template") then
            self.done = true
            return
        end
        self:pop_until("template")
        self:clear_formatting_to_marker()
        self.template_modes[#self.template_modes] = nil
        self:reset_mode()
        return self:dispatch(tok)
    end
end

function M.after_body(self, tok)
    local t, name = tok.t, tok.name
    if t == "text" then
        local lead, rest = split_ws(tok.data)
        if lead ~= "" then M.in_body(self, { t = "text", data = lead }) end
        if rest == "" then return end
        tok = { t = "text", data = rest }
    elseif t == "comment" then
        return insert_node(self.stack[1], { comment = true })
    elseif t == "doctype" then
        return
    elseif t == "start" and name == "html" then
        return M.in_body(self, tok)
    elseif t == "end" and name == "html" then
        self.mode = "after_after_body"
        return
    elseif t == "eof" then
        self.done = true
        return
    end
    self.mode = "in_body"
    return self:dispatch(tok)
end

function M.in_frameset(self, tok)
    local t, name = tok.t, tok.name
    if t == "text" then
        local lead = split_ws(tok.data)
        return self:insert_text(lead)
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "start" then
        if name == "html" then
            return M.in_body(self, tok)
        elseif name == "frameset" then
            self:insert_element(tok)
        elseif name == "frame" then
            self:insert_element(tok)
            self:pop()
        elseif name == "noframes" then
            return M.in_head(self, tok)
        end
    elseif t == "end" and name == "frameset" then
        if #self.stack > 1 then
            self:pop()
            local cur = self:current()
            if not (cur.ns == nil and cur.name == "frameset") then self.mode = "after_frameset" end
        end
    elseif t == "eof" then
        self.done = true
    end
end

function M.after_frameset(self, tok)
    local t, name = tok.t, tok.name
    if t == "text" then
        local lead = split_ws(tok.data)
        return self:insert_text(lead)
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "start" and name == "html" then
        return M.in_body(self, tok)
    elseif t == "start" and name == "noframes" then
        return M.in_head(self, tok)
    elseif t == "end" and name == "html" then
        self.mode = "after_after_frameset"
    elseif t == "eof" then
        self.done = true
    end
end

function M.after_after_body(self, tok)
    local t = tok.t
    if t == "comment" then
        return insert_node(self.doc, { comment = true })
    elseif t == "doctype" then
        return
    elseif t == "text" then
        local lead, rest = split_ws(tok.data)
        if lead ~= "" then M.in_body(self, { t = "text", data = lead }) end
        if rest == "" then return end
        tok = { t = "text", data = rest }
    elseif t == "start" and tok.name == "html" then
        return M.in_body(self, tok)
    elseif t == "eof" then
        self.done = true
        return
    end
    self.mode = "in_body"
    return self:dispatch(tok)
end

function M.after_after_frameset(self, tok)
    local t = tok.t
    if t == "comment" then
        return insert_node(self.doc, { comment = true })
    elseif t == "text" then
        local lead = split_ws(tok.data)
        if lead ~= "" then M.in_body(self, { t = "text", data = lead }) end
    elseif t == "start" and tok.name == "html" then
        return M.in_body(self, tok)
    elseif t == "start" and tok.name == "noframes" then
        return M.in_head(self, tok)
    elseif t == "eof" then
        self.done = true
    end
end

--- Tokens inside <svg> or <math>.
function P:foreign(tok)
    local t, name = tok.t, tok.name
    local stack = self.stack
    if t == "text" then
        local data = tok.data
        if data:find("%z") then data = data:gsub("%z", REPLACEMENT) end
        self:insert_text(data)
        if self.frameset_ok and not data:find(WS_ONLY) then self.frameset_ok = false end
        return
    elseif t == "comment" then
        return self:insert_comment(tok)
    elseif t == "doctype" then
        return
    elseif t == "start" then
        local breakout = BREAKOUT[name]
        if name == "font" and (tok.attrs.color ~= nil or tok.attrs.face ~= nil or tok.attrs.size ~= nil) then
            breakout = true
        end
        if breakout then
            while #stack > 1 do
                local cur = stack[#stack]
                if cur.ns == nil or is_math_text_point(cur) or is_html_point(cur) then break end
                stack[#stack] = nil
            end
            return M[self.mode](self, tok)
        end
        local cur = stack[#stack]
        local el_name = name
        if cur.ns == "svg" then el_name = SVG_NAMES[name] or name end
        self:insert_element(tok, cur.ns, el_name)
        if tok.self_closing then self:pop() end
        return
    elseif t == "end" then
        if name == "br" or name == "p" then
            while #stack > 1 do
                local cur = stack[#stack]
                if cur.ns == nil or is_math_text_point(cur) or is_html_point(cur) then break end
                stack[#stack] = nil
            end
            return M[self.mode](self, tok)
        end
        local i = #stack
        local node = stack[i]
        while true do
            if i == 1 then return end
            if node.name:lower() == name then
                while #stack >= i do stack[#stack] = nil end
                return
            end
            i = i - 1
            node = stack[i]
            if node.ns == nil then return M[self.mode](self, tok) end
        end
    end
end

function P:dispatch(tok)
    local stack = self.stack
    local cur = stack[#stack]
    local t = tok.t
    if not cur or cur.ns == nil or t == "eof" then return M[self.mode](self, tok) end
    if is_math_text_point(cur) then
        if t == "text" or (t == "start" and tok.name ~= "mglyph" and tok.name ~= "malignmark") then
            return M[self.mode](self, tok)
        end
    elseif cur.ns == "math" and cur.name == "annotation-xml" and t == "start" and tok.name == "svg" then
        return M[self.mode](self, tok)
    end
    if is_html_point(cur) and (t == "start" or t == "text") then return M[self.mode](self, tok) end
    return self:foreign(tok)
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

--- Parse a document.
-- @param src   the document's text (bytes are taken as UTF-8)
-- @param opts  keep_all: store every attribute's value (for tests)
--              marks: a list that receives { first byte, last byte, is the inline
--              document of a frame } for every quoted attribute value with a ">"
--              in it and every inline frame document; the positions are those of
--              document.source_text, the text that was parsed (document.bom,
--              document.replaced: it differs from src by more than line ends)
-- @return document
function Parse.parse(src, opts)
    opts = opts or {}
    local bom = src:sub(1, 3) == "\239\187\191"
    if bom then src = src:sub(4) end
    local decoded = decode_utf8(src)
    local replaced = decoded ~= src
    src = decoded
    if src:find("\r", 1, true) then src = src:gsub("\r\n?", "\n") end
    local doc = { document = true, kids = {}, quirks = false }
    if opts.marks then doc.source_text, doc.bom, doc.replaced = src, bom, replaced end
    local self = setmetatable({
        src = src, pos = 1, len = #src, tok_state = "data",
        doc = doc, stack = {}, formatting = {}, template_modes = {}, joins = {},
        mode = "initial", frameset_ok = true, foster = false,
        scripting = false, keep_all = opts.keep_all, marks = opts.marks,
    }, P)
    while not self.done do
        local tok = self:next_token()
        if self.skip_lf then
            self.skip_lf = false
            if tok.t == "text" and tok.data:sub(1, 1) == "\n" then
                tok = { t = "text", data = tok.data:sub(2) }
                if tok.data == "" then tok = nil end
            end
        end
        if tok then
            self:dispatch(tok)
            if tok.t == "eof" and not self.done then
                -- every mode ends at the end of the input
                self.done = true
            end
        end
    end
    for _, node in ipairs(self.joins) do
        node.text = table.concat(node.parts)
        node.parts = nil
    end
    return doc
end

--- First element child with this name.
function Parse.child(node, name)
    for _, k in ipairs(node.kids) do
        if k.name == name and k.ns == nil then return k end
    end
    return nil
end

-- Serialising: what a browser's outerHTML gives ------------------------------

local VOID = set("area base basefont bgsound br col embed frame hr img input keygen link meta param source track wbr")
local RAW_TEXT = set("style script xmp iframe noembed noframes plaintext")

local function escape_text(s)
    if not s:find("[&<>\194]") then return s end
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\194\160", "&nbsp;"))
end

local function escape_attr(s)
    if not s:find('[&"\194]') then return s end
    return (s:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("\194\160", "&nbsp;"))
end

local function serialize(node, out, raw)
    if node.text then
        out[#out + 1] = raw and node.text or escape_text(node.text)
    elseif node.comment then
        out[#out + 1] = "<!---->"
    elseif node.name then
        out[#out + 1] = "<" .. node.name
        for k, v in pairs(node.attrs) do
            if type(v) == "string" then
                out[#out + 1] = " " .. k .. '="' .. escape_attr(v) .. '"'
            end
        end
        out[#out + 1] = ">"
        if node.ns == nil and VOID[node.name] then return end
        local inner_raw = node.ns == nil and RAW_TEXT[node.name] == true
        for _, k in ipairs((node.content or node).kids) do
            serialize(k, out, inner_raw)
        end
        out[#out + 1] = "</" .. node.name .. ">"
    end
end

--- The outer HTML of an element. Attributes whose values were not stored are
-- left out (they have no influence on how the text is parsed again).
function Parse.outerHTML(el)
    local out = {}
    serialize(el, out, false)
    return table.concat(out)
end

return Parse
