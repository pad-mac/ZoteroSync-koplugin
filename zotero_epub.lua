--[[--
EPUB positions: KOReader xpointers <-> Zotero EPUB CFIs.

KOReader (crengine) addresses a highlight with xpointers into *its own* DOM:

    /body/DocFragment[3]/body/div/p[7]/text()[2].45

Zotero addresses it with an EPUB CFI into the *browser* DOM of the spine item:

    epubcfi(/6/8!/4/2/14,/3:52,/3:118)

The two DOMs are built from the same XHTML but are not the same tree:
crengine drops whitespace-only text nodes, collapses whitespace inside text
and inserts internal "boxing" elements, so neither tree paths nor character
offsets can be translated one-to-one as soon as the markup is indented.

What both trees do share is the sequence of non-whitespace characters. This
module builds that sequence for each side, with a map from every character
back to its text node and offset:

  * source side:  the spine item's XHTML, parsed here, with CFI steps counted
                  the way Zotero's reader (its epub.js fork) counts them;
  * engine side:  crengine's own serialisation of the fragment, with xpointer
                  paths computed the way crengine writes them.

A position is converted by locating the highlighted passage in the other
side's sequence. Every result is checked against the live document before it
is returned; anything that cannot be verified is reported as a failure, never
guessed.
]]

local Util = require("zotero_util")
local logger = require("logger")

local Epub = { fork = "0.6" }

-- ---------------------------------------------------------------------------
-- Characters left out of the comparison streams: everything JavaScript's \s
-- matches (that is what Zotero collapses when it stores an annotation's
-- text), plus the soft hyphen, which crengine leaves out of the text it
-- returns for a selection.
-- ---------------------------------------------------------------------------

local function strip_ws(s)
    s = s:gsub("[ \t\n\r\f\v]+", "")
    if s:find("[\194\225\226\227\239]") then
        s = s:gsub("\194[\160\173]", "")                       -- U+00A0, U+00AD
        s = s:gsub("\225\154\128", "")                         -- U+1680
        s = s:gsub("\226\128[\128-\138\168\169\175]", "")      -- U+2000-200A, 2028, 2029, 202F
        s = s:gsub("\226\129\159", "")                         -- U+205F
        s = s:gsub("\227\128\128", "")                         -- U+3000
        s = s:gsub("\239\187\191", "")                         -- U+FEFF
    end
    return s
end
Epub.stripWhitespace = strip_ws

--- Byte length of the left-out character starting at byte i (0 if none).
local function ws_len(s, i)
    local b = s:byte(i)
    if b == 32 or (b >= 9 and b <= 13) then return 1 end
    if b < 0xC2 then return 0 end
    if b == 0xC2 then
        local b2 = s:byte(i + 1)
        return (b2 == 0xA0 or b2 == 0xAD) and 2 or 0
    elseif b == 0xE2 then
        local b2, b3 = s:byte(i + 1), s:byte(i + 2)
        if not b3 then return 0 end
        if b2 == 0x80 and ((b3 >= 0x80 and b3 <= 0x8A) or b3 == 0xA8 or b3 == 0xA9 or b3 == 0xAF) then return 3 end
        if b2 == 0x81 and b3 == 0x9F then return 3 end
        return 0
    elseif b == 0xE1 then
        return (s:byte(i + 1) == 0x9A and s:byte(i + 2) == 0x80) and 3 or 0
    elseif b == 0xE3 then
        return (s:byte(i + 1) == 0x80 and s:byte(i + 2) == 0x80) and 3 or 0
    elseif b == 0xEF then
        return (s:byte(i + 1) == 0xBB and s:byte(i + 2) == 0xBF) and 3 or 0
    end
    return 0
end

--- Number of kept (non-whitespace) bytes in s[1 .. upto-1].
local function kept_before(s, upto)
    local n, i = 0, 1
    local stop = math.min(upto - 1, #s)
    while i <= stop do
        local w = ws_len(s, i)
        if w > 0 then
            i = i + w
        else
            n = n + 1
            i = i + 1
        end
    end
    return n
end

--- Byte index in s of its k-th kept byte (1-based), or nil.
local function kept_byte(s, k)
    local n, i, len = 0, 1, #s
    while i <= len do
        local w = ws_len(s, i)
        if w > 0 then
            i = i + w
        else
            n = n + 1
            if n == k then return i end
            i = i + 1
        end
    end
    return nil
end

--- Start of the UTF-8 character that contains byte index i.
local function char_start(s, i)
    while i > 1 do
        local b = s:byte(i)
        if b >= 0x80 and b < 0xC0 then i = i - 1 else break end
    end
    return i
end

-- ---------------------------------------------------------------------------
-- Entities (the XHTML 1.x set; EPUB content may not use any others)
-- ---------------------------------------------------------------------------

local ENTITY_DATA = "AElig=198,Aacute=193,Acirc=194,Agrave=192,Alpha=913,Aring=197,Atilde=195,Auml=196,Beta=914,Ccedil=199,Chi=935,Dagger=8225,Delta=916,ETH=208,Eacute=201,Ecirc=202,Egrave=200,Epsilon=917,Eta=919,Euml=203,Gamma=915,Iacute=205,Icirc=206,Igrave=204,Iota=921,Iuml=207,Kappa=922,Lambda=923,Mu=924,Ntilde=209,Nu=925,OElig=338,Oacute=211,Ocirc=212,Ograve=210,Omega=937,Omicron=927,Oslash=216,Otilde=213,Ouml=214,Phi=934,Pi=928,Prime=8243,Psi=936,Rho=929,Scaron=352,Sigma=931,THORN=222,Tau=932,Theta=920,Uacute=218,Ucirc=219,Ugrave=217,Upsilon=933,Uuml=220,Xi=926,Yacute=221,Yuml=376,Zeta=918,aacute=225,acirc=226,acute=180,aelig=230,agrave=224,alefsym=8501,alpha=945,and=8743,ang=8736,aring=229,asymp=8776,atilde=227,auml=228,bdquo=8222,beta=946,brvbar=166,bull=8226,cap=8745,ccedil=231,cedil=184,cent=162,chi=967,circ=710,clubs=9827,cong=8773,copy=169,crarr=8629,cup=8746,curren=164,dArr=8659,dagger=8224,darr=8595,deg=176,delta=948,diams=9830,divide=247,eacute=233,ecirc=234,egrave=232,empty=8709,emsp=8195,ensp=8194,epsilon=949,equiv=8801,eta=951,eth=240,euml=235,euro=8364,exist=8707,fnof=402,forall=8704,frac12=189,frac14=188,frac34=190,frasl=8260,gamma=947,ge=8805,hArr=8660,harr=8596,hearts=9829,hellip=8230,iacute=237,icirc=238,iexcl=161,igrave=236,image=8465,infin=8734,int=8747,iota=953,iquest=191,isin=8712,iuml=239,kappa=954,lArr=8656,lambda=955,lang=9001,laquo=171,larr=8592,lceil=8968,ldquo=8220,le=8804,lfloor=8970,lowast=8727,loz=9674,lrm=8206,lsaquo=8249,lsquo=8216,macr=175,mdash=8212,micro=181,middot=183,minus=8722,mu=956,nabla=8711,nbsp=160,ndash=8211,ne=8800,ni=8715,not=172,notin=8713,nsub=8836,ntilde=241,nu=957,oacute=243,ocirc=244,oelig=339,ograve=242,oline=8254,omega=969,omicron=959,oplus=8853,or=8744,ordf=170,ordm=186,oslash=248,otilde=245,otimes=8855,ouml=246,para=182,part=8706,permil=8240,perp=8869,phi=966,pi=960,piv=982,plusmn=177,pound=163,prime=8242,prod=8719,prop=8733,psi=968,rArr=8658,radic=8730,rang=9002,raquo=187,rarr=8594,rceil=8969,rdquo=8221,real=8476,reg=174,rfloor=8971,rho=961,rlm=8207,rsaquo=8250,rsquo=8217,sbquo=8218,scaron=353,sdot=8901,sect=167,shy=173,sigma=963,sigmaf=962,sim=8764,spades=9824,sub=8834,sube=8838,sum=8721,sup=8835,sup1=185,sup2=178,sup3=179,supe=8839,szlig=223,tau=964,there4=8756,theta=952,thetasym=977,thinsp=8201,thorn=254,tilde=732,times=215,trade=8482,uArr=8657,uacute=250,uarr=8593,ucirc=251,ugrave=249,uml=168,upsih=978,upsilon=965,uuml=252,weierp=8472,xi=958,yacute=253,yen=165,yuml=255,zeta=950,zwj=8205,zwnj=8204"

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
for name, cp in ENTITY_DATA:gmatch("(%w+)=(%d+)") do
    ENTITIES[name] = Util.utf8Char(tonumber(cp))
end

--- Replace character and entity references. `custom` holds entities declared
-- in the document's own DOCTYPE. Unknown references are left as written.
local function decode_entities(s, custom)
    if not s:find("&", 1, true) then return s end
    return (s:gsub("&(#?[%w_.:-]+);", function(ref)
        if ref:sub(1, 1) == "#" then
            local cp
            local c2 = ref:sub(2, 2)
            if c2 == "x" or c2 == "X" then
                cp = tonumber(ref:sub(3), 16)
            else
                cp = tonumber(ref:sub(2), 10)
            end
            if cp and cp > 0 and cp < 0x110000 then return Util.utf8Char(cp) end
            return nil
        end
        return (custom and custom[ref]) or ENTITIES[ref]
    end))
end
Epub.decodeEntities = decode_entities

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

local CP1252 = {
    [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020,
    [0x87] = 0x2021, [0x88] = 0x02C6, [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
    [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C, [0x94] = 0x201D, [0x95] = 0x2022,
    [0x96] = 0x2013, [0x97] = 0x2014, [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
    [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}

--- Bring an XML document to UTF-8 without BOM. Returns string or nil, err.
local function to_utf8(src)
    if src:sub(1, 3) == "\239\187\191" then
        return src:sub(4)
    end
    local b1, b2 = src:byte(1), src:byte(2)
    if (b1 == 0xFF and b2 == 0xFE) or (b1 == 0xFE and b2 == 0xFF) then
        local le = b1 == 0xFF
        local out, n = {}, 0
        local i, len = 3, #src
        while i + 1 <= len do
            local lo, hi = src:byte(i), src:byte(i + 1)
            local cp = le and (hi * 256 + lo) or (lo * 256 + hi)
            i = i + 2
            if cp >= 0xD800 and cp <= 0xDBFF and i + 1 <= len then
                local lo2, hi2 = src:byte(i), src:byte(i + 1)
                local cp2 = le and (hi2 * 256 + lo2) or (lo2 * 256 + hi2)
                if cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                    i = i + 2
                end
            end
            n = n + 1
            out[n] = Util.utf8Char(cp)
        end
        return table.concat(out)
    end
    local decl = src:match("^%s*<%?xml[^>]-encoding%s*=%s*[\"']([^\"']+)[\"']")
    if decl then
        local enc = decl:lower()
        if enc == "utf-8" or enc == "utf8" or enc == "us-ascii" or enc == "ascii" then
            return src
        end
        local latin1 = enc == "iso-8859-1" or enc == "latin1"
        if latin1 or enc == "windows-1252" or enc == "cp1252" then
            local out, n = {}, 0
            for i = 1, #src do
                local b = src:byte(i)
                n = n + 1
                if b < 0x80 then
                    out[n] = string.char(b)
                else
                    out[n] = Util.utf8Char((not latin1 and CP1252[b]) or b)
                end
            end
            return table.concat(out)
        end
        return nil, "unsupported text encoding (" .. decl .. ")"
    end
    return src
end

-- ---------------------------------------------------------------------------
-- A small, tolerant XML parser producing a browser-like tree:
--   element : { name =, attrs = {}, kids = {}, parent = }
--   text    : { text =, parent = }            (cdata = true for CDATA sections)
--   other   : { split = true, parent = }      (comment / processing instruction;
--                                              these separate text nodes, as in a DOM)
-- ---------------------------------------------------------------------------

local function parse_attrs(s, custom)
    local attrs = {}
    local pos = 1
    while true do
        local ns, ne, name = s:find("^%s*([^%s=/>]+)", pos)
        if not ns then break end
        pos = ne + 1
        local es, ee = s:find("^%s*=%s*", pos)
        if es then
            pos = ee + 1
            local q = s:sub(pos, pos)
            if q == '"' or q == "'" then
                local close = s:find(q, pos + 1, true)
                if not close then
                    attrs[name] = decode_entities(s:sub(pos + 1), custom)
                    break
                end
                attrs[name] = decode_entities(s:sub(pos + 1, close - 1), custom)
                pos = close + 1
            else
                local vs, ve, val = s:find("^([^%s>]+)", pos)
                if vs then
                    attrs[name] = decode_entities(val, custom)
                    pos = ve + 1
                end
            end
        else
            attrs[name] = ""
        end
    end
    return attrs
end

--- End of the tag that starts at `pos` (index of '<'), honouring quoted
-- attribute values. Returns the index of '>' or nil.
local function tag_end(src, pos)
    local i = pos + 1
    local len = #src
    while i <= len do
        local s, _, ch = src:find("([\"'>])", i)
        if not s then return nil end
        if ch == ">" then return s end
        local close = src:find(ch, s + 1, true)
        if not close then return nil end
        i = close + 1
    end
    return nil
end

function Epub.parseXml(src)
    if type(src) ~= "string" or src == "" then return nil, "empty document" end
    local utf8, err = to_utf8(src)
    if not utf8 then return nil, err end
    src = utf8:gsub("\r\n", "\n"):gsub("\r", "\n")

    local doc = { kids = {} }
    local cur = doc
    local last_text -- the open text node of `cur`, when its previous child was text
    local custom    -- entities declared in the DOCTYPE

    local function add_text(t)
        if t == "" then return end
        if t:find("\r", 1, true) then
            -- A carriage return can only get here through a character
            -- reference (&#13;). Zotero's reader serialises each chapter and
            -- parses it again, which turns it into a plain line feed.
            t = t:gsub("\r\n", "\n"):gsub("\r", "\n")
        end
        if last_text then
            last_text.text = last_text.text .. t
        else
            last_text = { text = t, parent = cur }
            cur.kids[#cur.kids + 1] = last_text
        end
    end

    local pos = 1
    local len = #src
    while pos <= len do
        local lt = src:find("<", pos, true)
        if not lt then
            add_text(decode_entities(src:sub(pos), custom))
            break
        end
        if lt > pos then
            add_text(decode_entities(src:sub(pos, lt - 1), custom))
        end
        local c2 = src:sub(lt + 1, lt + 1)
        if c2 == "!" then
            if src:sub(lt, lt + 3) == "<!--" then
                local e = src:find("-->", lt + 4, true)
                cur.kids[#cur.kids + 1] = { split = true, parent = cur }
                last_text = nil
                pos = e and e + 3 or len + 1
            elseif src:sub(lt, lt + 8) == "<![CDATA[" then
                local e = src:find("]]>", lt + 9, true)
                cur.kids[#cur.kids + 1] = { text = src:sub(lt + 9, e and e - 1 or len), cdata = true, parent = cur }
                last_text = nil
                pos = e and e + 3 or len + 1
            else
                -- DOCTYPE, possibly with an internal subset
                local e = src:find("[%[>]", lt + 2)
                if e and src:sub(e, e) == "[" then
                    local close = src:find("]%s*>", e + 1)
                    if close then
                        local subset = src:sub(e + 1, close - 1)
                        for name, _, value in subset:gmatch("<!ENTITY%s+([%w_.:-]+)%s+([\"'])(.-)%2%s*>") do
                            custom = custom or {}
                            custom[name] = decode_entities(value, custom)
                        end
                        e = src:find(">", close, true)
                    else
                        e = nil
                    end
                end
                pos = e and e + 1 or len + 1
            end
        elseif c2 == "?" then
            local e = src:find("?>", lt + 2, true)
            if cur ~= doc then
                cur.kids[#cur.kids + 1] = { split = true, parent = cur }
                last_text = nil
            end
            pos = e and e + 2 or len + 1
        elseif c2 == "/" then
            local e = src:find(">", lt + 2, true)
            local name = src:sub(lt + 2, (e or len + 1) - 1):match("^%s*([^%s>]+)")
            -- close the nearest open element of that name
            local node = cur
            while node ~= doc and node.name ~= name do node = node.parent end
            if node ~= doc then
                cur = node.parent
                last_text = nil
            end
            pos = e and e + 1 or len + 1
        else
            local e = tag_end(src, lt)
            local inner = e and src:sub(lt + 1, e - 1)
            local selfclose = false
            if inner and inner:sub(-1) == "/" then
                selfclose = true
                inner = inner:sub(1, -2)
            end
            local name, rest
            if inner then name, rest = inner:match("^([^%s/>]+)(.*)$") end
            if not name then
                -- a stray '<': keep it as text
                add_text("<")
                pos = lt + 1
            else
                local node = { name = name, attrs = parse_attrs(rest or "", custom), kids = {}, parent = cur }
                cur.kids[#cur.kids + 1] = node
                last_text = nil
                if not selfclose then cur = node end
                pos = e + 1
            end
        end
    end
    return doc
end

local function local_name(name)
    return (name:match(":([^:]+)$") or name):lower()
end

local function first_element(node, wanted)
    for _, k in ipairs(node.kids) do
        if k.name and (not wanted or local_name(k.name) == wanted) then return k end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Package (container.xml, OPF manifest and spine)
-- ---------------------------------------------------------------------------

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function normalize_path(p)
    p = p:gsub("\\", "/"):gsub("#.*$", "")
    local parts = {}
    for part in p:gmatch("[^/]+") do
        if part == ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end
Epub.normalizePath = normalize_path

--- Read the spine of an EPUB.
-- @param read_file function(path) -> content or nil
-- @return { spine = { path|false, ... }, types = { media-type, ... }, spine_step = n } or nil, err
function Epub.readPackage(read_file)
    local container = read_file("META-INF/container.xml")
    if not container then return nil, "no container.xml" end
    local cdoc = Epub.parseXml(container)
    if not cdoc then return nil, "container.xml unreadable" end
    local opf_path
    local function find_rootfile(node)
        for _, k in ipairs(node.kids) do
            if k.name then
                if not opf_path and local_name(k.name) == "rootfile" and k.attrs["full-path"] then
                    opf_path = k.attrs["full-path"]
                end
                find_rootfile(k)
            end
        end
    end
    find_rootfile(cdoc)
    if not opf_path then return nil, "no rootfile" end
    opf_path = normalize_path(opf_path)
    local opf = read_file(opf_path)
    if not opf then
        opf_path = normalize_path(url_decode(opf_path))
        opf = read_file(opf_path)
    end
    if not opf then return nil, "package document missing" end
    local odoc = Epub.parseXml(opf)
    local package = odoc and first_element(odoc, "package")
    if not package then return nil, "package document unreadable" end
    local base = opf_path:match("^(.*)/[^/]*$") or ""

    local manifest, spine_el, spine_pos = {}, nil, 0
    local el_index = 0
    for _, k in ipairs(package.kids) do
        if k.name then
            el_index = el_index + 1
            local ln = local_name(k.name)
            if ln == "manifest" then
                for _, item in ipairs(k.kids) do
                    if item.name and local_name(item.name) == "item" and item.attrs.id and item.attrs.href then
                        manifest[item.attrs.id] = { href = item.attrs.href, type = item.attrs["media-type"] or "" }
                    end
                end
            elseif ln == "spine" and not spine_el then
                spine_el = k
                spine_pos = el_index
            end
        end
    end
    if not spine_el then return nil, "no spine" end
    local spine, types = {}, {}
    for _, k in ipairs(spine_el.kids) do
        if k.name and local_name(k.name) == "itemref" then
            local item = manifest[k.attrs.idref or ""]
            local path = false
            if item then
                path = normalize_path((base ~= "" and base .. "/" or "") .. url_decode(item.href))
            end
            spine[#spine + 1] = path
            types[#spine] = item and item.type or ""
        end
    end
    return { spine = spine, types = types, spine_step = spine_pos * 2, opf_path = opf_path }
end

-- ---------------------------------------------------------------------------
-- Text streams shared by both models
-- ---------------------------------------------------------------------------

local function finish_stream(model)
    local parts, map = {}, {}
    local pos = 0
    for idx, t in ipairs(model.texts) do
        if t.counted then
            local stripped = strip_ws(t.text)
            t.stream_start = pos
            t.stream_len = #stripped
            if #stripped > 0 then
                parts[#parts + 1] = stripped
                map[#map + 1] = idx
                pos = pos + #stripped
            end
        end
    end
    model.stream = table.concat(parts)
    model.map = map
    return model
end

--- Index of the text entry that holds stream byte p (1-based), or nil.
local function entry_at(model, p)
    local map = model.map
    local lo, hi = 1, #map
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local t = model.texts[map[mid]]
        if p <= t.stream_start then
            hi = mid - 1
        elseif p > t.stream_start + t.stream_len then
            lo = mid + 1
        else
            return map[mid]
        end
    end
    return nil
end

--- Stream position (number of stream bytes before it) of the point at text
-- entry `idx`, byte index `byte_index`.
local function stream_pos(model, idx, byte_index)
    local t = model.texts[idx]
    if not t then return nil end
    if not t.counted then
        -- not part of the stream: use the position of the next counted entry
        for j = idx + 1, #model.texts do
            if model.texts[j].counted then return model.texts[j].stream_start end
        end
        return #model.stream
    end
    return t.stream_start + kept_before(t.text, byte_index)
end

--- Text entry + byte index of the character holding stream byte p.
local function point_at(model, p)
    local idx = entry_at(model, p)
    if not idx then return nil end
    local t = model.texts[idx]
    local bi = kept_byte(t.text, p - t.stream_start)
    if not bi then return nil end
    return idx, char_start(t.text, bi)
end

-- ---------------------------------------------------------------------------
-- Source model: the XHTML as Zotero's reader sees it
-- ---------------------------------------------------------------------------

--- Elements Zotero's reader removes from a section before displaying it.
local function is_removed(node, ln)
    if ln == "title" or ln == "style" then return true end
    if ln == "link" then
        local rel = (node.attrs.rel or ""):lower()
        if rel:find("%f[%w_]stylesheet%f[^%w_]") then return true end
    end
    return false
end

--- <object data=... type="image/..."> is replaced by an <img> (its fallback
-- content disappears).
local function is_image_object(node, ln)
    if ln ~= "object" then return false end
    return node.attrs.data ~= nil and (node.attrs.type or ""):sub(1, 6) == "image/"
end

local NO_TEXT = { script = true, style = true }

--- Build the source-side model of one spine item.
-- model.texts[i] = { text, node, counted, u16_before, stream_start, stream_len }
function Epub.sourceModel(xhtml)
    local doc, err = Epub.parseXml(xhtml)
    if not doc then return nil, err end
    local html = first_element(doc)
    if not html then return nil, "no root element" end
    local model = { texts = {}, images = {}, root = html }
    local u16 = 0

    local function walk(node, in_body, hidden)
        local els, txts = {}, {}
        for _, k in ipairs(node.kids) do
            if k.name then
                local ln = local_name(k.name)
                if is_removed(k, ln) then
                    k.removed = true
                else
                    els[#els + 1] = k
                    k.el_index = #els
                    if ln == "script" and (k.attrs.type or ""):lower() == "text/x-mathjax-config" then
                        model.unsafe = "the chapter is typeset with MathJax"
                    end
                    if in_body and (ln == "img" or is_image_object(k, ln)) then
                        -- what Zotero's reader takes as a reading position when
                        -- a picture is the first thing in view
                        model.images[#model.images + 1] = { node = k, next_ti = #model.texts + 1 }
                        k.image_index = #model.images
                    end
                    if is_image_object(k, ln) then
                        k.el_kids, k.text_kids = {}, {}
                    else
                        walk(k, in_body or ln == "body", hidden or NO_TEXT[ln] == true)
                    end
                end
            elseif k.text then
                if k.cdata then
                    -- Not a text node as far as CFI steps go, and it splits the
                    -- text around it. Too unusual to be worth modelling.
                    if in_body and not hidden then
                        model.unsafe = "the chapter contains a CDATA section"
                    end
                    u16 = u16 + Util.utf16Len(k.text)
                else
                    txts[#txts + 1] = k
                    k.txt_index = #txts
                    model.texts[#model.texts + 1] = {
                        text = k.text, node = k, counted = in_body and not hidden, u16_before = u16,
                    }
                    k.ti = #model.texts
                    u16 = u16 + Util.utf16Len(k.text)
                end
            end
        end
        node.el_kids, node.text_kids = els, txts
    end
    walk(html, false, false)
    return finish_stream(model)
end

--- CFI steps (as numbers) leading to a source text node.
local function source_steps(model, text_node)
    local rev = { (text_node.txt_index - 1) * 2 + 1 }
    local n = text_node.parent
    while n and n ~= model.root do
        rev[#rev + 1] = n.el_index * 2
        n = n.parent
    end
    local steps = {}
    for i = #rev, 1, -1 do steps[#steps + 1] = rev[i] end
    return steps
end

Epub._sourceSteps = source_steps

--- First text entry inside an element, in document order.
local function first_text_in(node)
    if node.text_kids == nil then return nil end
    for _, k in ipairs(node.kids) do
        if k.ti then
            return k.ti
        elseif k.name and not k.removed and k.el_kids then
            local r = first_text_in(k)
            if r then return r end
        end
    end
    return nil
end

--- The next node in document order that is not inside `node` (works on both
-- models: their child lists and parent links have different names).
local function next_outside(node, kids_field, up_field)
    local n = node
    while n do
        local up = n[up_field]
        if not up then return nil end
        local seen = false
        for _, k in ipairs(up[kids_field] or {}) do
            if seen then return k end
            if k == n then seen = true end
        end
        n = up
    end
    return nil
end

--- First text entry at or after a node, in document order.
local function first_text_from(node, kids_field, up_field)
    local function inside(n)
        if n.ti then return n.ti end
        if n.removed then return nil end
        for _, k in ipairs(n[kids_field] or {}) do
            local r = inside(k)
            if r then return r end
        end
        return nil
    end
    local n = node
    while n do
        local r = inside(n)
        if r then return r end
        n = next_outside(n, kids_field, up_field)
    end
    return nil
end

--- Number of stream bytes before an image (the text after it starts there).
local function image_pos(model, img)
    for j = img.next_ti, #model.texts do
        local t = model.texts[j]
        if t.counted then return t.stream_start end
    end
    return #model.stream
end

--- Resolve one parsed CFI component as a point: Zotero's reading position is
-- the start of a text node, or an image given as child `offset` of its parent.
-- @return "text", text entry index, byte index  |  "image", image index  |  nil, reason
local function resolve_point(model, comp)
    local node = model.root
    local steps = comp.steps
    for i, step in ipairs(steps) do
        if step % 2 == 0 then
            local child = node.el_kids and node.el_kids[step / 2]
            if not child then return nil, "path" end
            node = child
        else
            local tnode = node.text_kids and node.text_kids[(step - 1) / 2 + 1]
            if not tnode or i ~= #steps then return nil, "path" end
            local offset = comp.offset or 0
            if offset > Util.utf16Len(tnode.text) then return nil, "offset" end
            return "text", tnode.ti, Util.utf16ByteIndex(tnode.text, offset)
        end
    end
    -- The path ends on an element. With an offset: its child of that number,
    -- counted as the reader's DOM counts them (text, elements, comments).
    local target = node
    if comp.offset then
        local i = -1
        target = nil
        for _, k in ipairs(node.kids or {}) do
            if not k.removed then
                i = i + 1
                if i == comp.offset then target = k; break end
            end
        end
        if not target then
            if comp.offset ~= i + 1 then return nil, "element offset" end
            -- just behind the last child: whatever follows the element
            local nxt = next_outside(node, "kids", "parent")
            local ti = nxt and first_text_from(nxt, "kids", "parent")
            if not ti then return nil, "no text" end
            return "text", ti, 1
        end
    end
    if target.image_index then return "image", target.image_index end
    local ti = first_text_from(target, "kids", "parent")
    if not ti then return nil, "no text" end
    return "text", ti, 1
end

--- Resolve one parsed CFI component in a source model.
-- @return text entry index, byte index (1-based) or nil, reason
local function resolve_component(model, comp)
    local node = model.root
    local steps = comp.steps
    for i, step in ipairs(steps) do
        if step % 2 == 0 then
            local child = node.el_kids and node.el_kids[step / 2]
            if not child then return nil, "path" end
            node = child
        else
            local tnode = node.text_kids and node.text_kids[(step - 1) / 2 + 1]
            if not tnode or i ~= #steps then return nil, "path" end
            local text = tnode.text
            local offset = comp.offset or 0
            if offset > Util.utf16Len(text) then return nil, "offset" end
            return tnode.ti, Util.utf16ByteIndex(text, offset)
        end
    end
    -- The path ends on an element: only its very start is supported.
    if comp.offset and comp.offset > 0 then return nil, "element offset" end
    local ti = first_text_in(node)
    if not ti then return nil, "no text" end
    return ti, 1
end

-- ---------------------------------------------------------------------------
-- Engine model: crengine's DOM, read from its own serialisation
-- ---------------------------------------------------------------------------

local BOXING = {
    autoBoxing = true, tabularBox = true, rubyBox = true, mathBox = true,
    floatBox = true, inlineBox = true,
}

local TEXT_OPEN = "\226\159\170"  -- U+27EA, marks the start of a text node
local TEXT_CLOSE = "\226\159\171" -- U+27EB, marks its end

local function unescape_engine_text(s)
    if not s:find("&", 1, true) then return s end
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

--- Parse the output of getHTMLFromXPointer(fragment, 0x0002): elements, and
-- text nodes delimited by the two marks above.
local function parse_engine_html(html)
    local root = { kids = {} }
    local cur = root
    local pos, len = 1, #html
    while pos <= len do
        local b = html:byte(pos)
        if b == 0xE2 and html:sub(pos, pos + 2) == TEXT_OPEN then
            -- the text node ends at the closing mark that is followed by markup
            local search = pos + 3
            local close
            while true do
                local s = html:find(TEXT_CLOSE, search, true)
                if not s then break end
                local nxt = html:byte(s + 3)
                if nxt == nil or nxt == 60 or html:sub(s + 3, s + 5) == TEXT_OPEN then
                    close = s
                    break
                end
                search = s + 3
            end
            if not close then return nil, "unterminated text node" end
            cur.kids[#cur.kids + 1] = { text = unescape_engine_text(html:sub(pos + 3, close - 1)), parent = cur }
            pos = close + 3
        elseif b == 60 then -- '<'
            if html:byte(pos + 1) == 47 then -- '/'
                local e = html:find(">", pos + 2, true)
                if not e then return nil, "unterminated end tag" end
                if cur.parent then cur = cur.parent end
                pos = e + 1
            else
                -- attribute values are written unescaped, so the tag ends at
                -- the first '>' that is followed by markup, a text mark or the end
                local search = pos + 1
                local e
                while true do
                    local s = html:find(">", search, true)
                    if not s then break end
                    local nxt = html:byte(s + 1)
                    if nxt == nil or nxt == 60 or html:sub(s + 1, s + 3) == TEXT_OPEN then
                        e = s
                        break
                    end
                    search = s + 1
                end
                if not e then return nil, "unterminated tag" end
                local inner = html:sub(pos + 1, e - 1)
                local last = inner:sub(-1)
                local selfclose = last == "/" or last == "?"
                local name = inner:match("^([^%s/>]+)")
                if not name then return nil, "tag without a name" end
                local node = { name = name:match(":([^:]+)$") or name, kids = {}, parent = cur }
                if node.name == "DocFragment" then
                    node.source = inner:match('%sSource="([^"]*)"')
                end
                cur.kids[#cur.kids + 1] = node
                if not selfclose then cur = node end
                pos = e + 1
            end
        else
            pos = pos + 1 -- nothing is written between nodes with these flags
        end
    end
    return root
end

--- Build the engine-side model of one DocFragment.
-- @param html      output of getHTMLFromXPointer(frag_xp, 0x0002)
-- @param frag_xp   xpointer of the DocFragment element
-- @param legacy    true for books kept on a pre-2018 DOM version, whose
--                  xpointers name crengine's internal boxing elements
function Epub.engineModel(html, frag_xp, legacy)
    if type(html) ~= "string" or html == "" then return nil, "empty fragment" end
    local root, err = parse_engine_html(html)
    if not root then return nil, err end
    local frag = root.kids[1]
    if not frag or frag.name ~= "DocFragment" then
        return nil, "not a DocFragment"
    end
    local model = { texts = {}, images = {}, source = frag.source, frag = frag, frag_xp = frag_xp, has_boxing = false }

    local function collect(node, out)
        for _, k in ipairs(node.kids) do
            if k.name and BOXING[k.name] then
                model.has_boxing = true
                if legacy then
                    out[#out + 1] = k
                else
                    collect(k, out) -- transparent: its children take its place
                end
            elseif k.name == "pseudoElem" and not legacy then
                -- generated content, ignored by xpointers
            else
                out[#out + 1] = k
            end
        end
        return out
    end

    local function walk(node, hidden)
        local ukids = collect(node, {})
        node.ukids = ukids
        for _, k in ipairs(ukids) do
            k.up = node
            if k.name then
                if k.name == "img" then
                    model.images[#model.images + 1] = { node = k, next_ti = #model.texts + 1 }
                    k.image_index = #model.images
                end
                walk(k, hidden or NO_TEXT[k.name] == true)
            else
                model.texts[#model.texts + 1] = { text = k.text, node = k, counted = not hidden }
                k.ti = #model.texts
            end
        end
    end
    walk(frag, false)
    return finish_stream(model)
end

--- xpointer path (without offset) of a node of the engine model, written the
-- way crengine writes it.
local function engine_path(model, node)
    local rev = {}
    local n = node
    while n and n ~= model.frag do
        local up = n.up
        if not up then return nil end
        local count, index = 0, 0
        if n.name then
            for _, s in ipairs(up.ukids) do
                if s.name == n.name then
                    count = count + 1
                    if s == n then index = count end
                end
            end
            rev[#rev + 1] = count > 1 and (n.name .. "[" .. index .. "]") or n.name
        else
            for _, s in ipairs(up.ukids) do
                if not s.name then
                    count = count + 1
                    if s == n then index = count end
                end
            end
            rev[#rev + 1] = count > 1 and ("text()[" .. index .. "]") or "text()"
        end
        n = up
    end
    local out = { model.frag_xp }
    for i = #rev, 1, -1 do out[#out + 1] = rev[i] end
    return table.concat(out, "/")
end

local function split_xpointer(xp)
    local path, offset = xp:match("^(.-)%.(%d+)$")
    if not path then return xp, nil end
    return path, tonumber(offset)
end

--- Number of the DocFragment an xpointer lies in, or nil.
local function fragment_number(xp)
    if type(xp) ~= "string" then return nil end
    local n = xp:match("^/body/DocFragment%[(%d+)%]")
    if n then return tonumber(n) end
    if xp == "/body/DocFragment" or xp:match("^/body/DocFragment[/%.]") then return 1 end
    return nil
end
Epub.fragmentNumber = fragment_number

--- Node of the engine model an xpointer addresses, and its offset.
local function engine_resolve(model, xp)
    local path, offset = split_xpointer(xp)
    local rest = path:gsub("^/body/DocFragment%[%d+%]", "", 1)
    if rest == path then rest = path:gsub("^/body/DocFragment", "", 1) end
    local node = model.frag
    for seg in rest:gmatch("/([^/]+)") do
        if not node.ukids then return nil end
        local name, idx = seg:match("^(.-)%[(%d+)%]$")
        if name then idx = tonumber(idx) else name, idx = seg, 1 end
        local want_text = name == "text()"
        local count, found = 0, nil
        for _, s in ipairs(node.ukids) do
            if (want_text and not s.name) or (not want_text and s.name == name) then
                count = count + 1
                if count == idx then
                    found = s
                    break
                end
            end
        end
        if not found then return nil end
        node = found
    end
    return node, offset
end

--- Text entry + byte index for an xpointer. An xpointer to an element snaps
-- to the start of its first text (or, for a range end, the end of its last).
local function engine_point(model, xp, at_end)
    local node, offset = engine_resolve(model, xp)
    if not node then return nil end
    if not node.name then
        local t = model.texts[node.ti]
        return node.ti, Util.utf8ByteIndex(t.text, offset or 0)
    end
    local found
    local function walk(n)
        for _, k in ipairs(n.ukids or {}) do
            if k.ti then
                found = k.ti
                if not at_end then return true end
            elseif k.name and walk(k) then
                return true
            end
        end
        return false
    end
    walk(node)
    if not found then return nil end
    return found, at_end and (#model.texts[found].text + 1) or 1
end

-- ---------------------------------------------------------------------------
-- CFI strings
-- ---------------------------------------------------------------------------

--- Remove [..] assertions; '^' escapes the next character.
local function strip_assertions(s)
    if not s:find("[", 1, true) then return s end
    local out, n = {}, 0
    local i, len = 1, #s
    local depth = 0
    while i <= len do
        local c = s:sub(i, i)
        if c == "^" then
            if depth == 0 then
                n = n + 1
                out[n] = s:sub(i + 1, i + 1)
            end
            i = i + 2
        elseif c == "[" then
            depth = depth + 1
            i = i + 1
        elseif c == "]" and depth > 0 then
            depth = depth - 1
            i = i + 1
        else
            if depth == 0 then
                n = n + 1
                out[n] = c
            end
            i = i + 1
        end
    end
    return table.concat(out)
end

local function parse_component(s)
    local path, offset = s:match("^([^:]*):?(%d*)")
    local steps = {}
    for num in (path or ""):gmatch("/(%d+)") do
        steps[#steps + 1] = tonumber(num)
    end
    return { steps = steps, offset = tonumber(offset) }
end

local function join_components(a, b)
    local steps = {}
    for _, v in ipairs(a.steps) do steps[#steps + 1] = v end
    for _, v in ipairs(b.steps) do steps[#steps + 1] = v end
    return { steps = steps, offset = b.offset }
end

--- Parse an EPUB CFI.
-- @return { spine_index = 0-based, start = {steps, offset}, stop = {steps, offset} | nil } or nil
function Epub.parseCfi(cfi)
    if type(cfi) ~= "string" then return nil end
    local inner = cfi:match("^%s*epubcfi%((.*)%)%s*$") or cfi
    inner = strip_assertions(inner)
    local base, rest = inner:match("^([^!]*)!([^!]*)")
    if not base then return nil end
    local base_steps = parse_component(base).steps
    if #base_steps < 2 then return nil end
    local spine_index = base_steps[2] / 2 - 1
    if spine_index < 0 or spine_index ~= math.floor(spine_index) then return nil end
    local parts = {}
    for part in (rest .. ","):gmatch("([^,]*),") do parts[#parts + 1] = part end
    local result = { spine_index = spine_index }
    local common = parse_component(parts[1] or "")
    if #parts == 3 then
        result.start = join_components(common, parse_component(parts[2]))
        result.stop = join_components(common, parse_component(parts[3]))
    else
        result.start = common
    end
    return result
end

--- Write a range CFI exactly as Zotero's reader does (no assertions; the
-- last step of the start is never part of the common path).
function Epub.buildCfi(spine_step, spine_index, start_steps, start_off, stop_steps, stop_off)
    local common = 0
    local n = #start_steps
    for i = 1, n do
        if start_steps[i] ~= stop_steps[i] or i == n then break end
        common = i
    end
    local function seg(steps, from, to, offset)
        local parts = {}
        for i = from, to do parts[#parts + 1] = tostring(steps[i]) end
        local s = "/" .. table.concat(parts, "/")
        if offset then s = s .. ":" .. offset end
        return s
    end
    return "epubcfi(/" .. spine_step .. "/" .. ((spine_index + 1) * 2) .. "!"
        .. seg(start_steps, 1, common) .. ","
        .. seg(start_steps, common + 1, #start_steps, start_off) .. ","
        .. seg(stop_steps, common + 1, #stop_steps, stop_off) .. ")"
end

--- Section number and character offset of a Zotero EPUB sort index.
function Epub.parseSortIndex(sort_index)
    if type(sort_index) ~= "string" then return nil end
    local section, offset = sort_index:match("^(%d+)|(%d+)$")
    if not section then return nil end
    return tonumber(section), tonumber(offset)
end

-- ---------------------------------------------------------------------------
-- Finding a passage in a stream
-- ---------------------------------------------------------------------------

--- All start positions (0-based "bytes before") of needle in hay; capped.
local function occurrences(hay, needle, cap)
    local out = {}
    local from = 1
    while #out < (cap or 500) do
        local s = hay:find(needle, from, true)
        if not s then break end
        out[#out + 1] = s - 1
        from = s + 1
    end
    return out
end

local function nearest(list, target)
    local best, best_d
    for _, p in ipairs(list) do
        local d = math.abs(p - target)
        if not best_d or d < best_d then best, best_d = p, d end
    end
    return best
end

--- The two ends of a passage, looked for separately.
-- @param head, tail   byte strings expected at the start / at the end
-- @param head_skip    bytes of `head` that precede the passage (context)
-- @param tail_skip    bytes of `tail` that follow the passage (context)
-- @param expected     where the passage should start, roughly (or nil)
-- @param len          how long it should be, roughly
-- @param unique_only  accept the head only if it occurs once
-- @return b0, b1 ("bytes before" the passage / its end) or nil
local function find_ends(hay, head, head_skip, tail, tail_skip, expected, len, unique_only)
    local heads = occurrences(hay, head)
    if #heads == 0 then return nil end
    if #heads > 1 and (unique_only or not expected) then return nil end
    local b0 = nearest(heads, (expected or heads[1]) - head_skip) + head_skip
    local want_stop = b0 + len
    local slack = math.max(256, len)
    local best, best_d
    for _, t in ipairs(occurrences(hay, tail)) do
        local stop = t + #tail - tail_skip
        local d = math.abs(stop - want_stop)
        if stop > b0 and d <= slack and (not best_d or d < best_d) then
            best, best_d = stop, d
        end
    end
    if not best then return nil end
    return b0, best
end

--- Where does the passage [a0, a1) of model A's stream sit in model B's?
-- @return b0, b1 or nil
local function locate(model_a, model_b, a0, a1)
    if a1 <= a0 then return nil end
    local sa, sb = model_a.stream, model_b.stream
    if sa == sb then return a0, a1 end -- the normal case: same text on both sides
    local len = a1 - a0
    -- The streams differ somewhere. Look for the passage together with its
    -- surroundings, so that a repeated word is not taken for another
    -- occurrence; with context on one side only when the other side is where
    -- the two differ.
    for _, ctx in ipairs({ { 48, 48 }, { 16, 16 }, { 24, 0 }, { 0, 24 }, { 0, 0 } }) do
        local pre = math.min(ctx[1], a0)
        local post = math.min(ctx[2], #sa - a1)
        local hits = occurrences(sb, sa:sub(a0 + 1 - pre, a1 + post))
        if #hits == 1 or (#hits > 1 and pre + post >= 16) then
            local b0 = nearest(hits, a0 - pre) + pre
            return b0, b0 + len
        elseif #hits > 1 then
            break -- ambiguous without context
        end
    end
    -- The passage itself contains something only one side has (an image's
    -- fallback text, a formula, a title): match its two ends.
    if len < 16 then return nil end
    local k = math.min(32, math.floor(len / 2))
    for _, ctx in ipairs({ 16, 0 }) do
        local pre = math.min(ctx, a0)
        local post = math.min(ctx, #sa - a1)
        local b0, b1 = find_ends(sb, sa:sub(a0 + 1 - pre, a0 + k), pre, sa:sub(a1 - k + 1, a1 + post), post,
            a0, len, pre + post < 16)
        if b0 then return b0, b1 end
    end
    return nil
end

--- Map a range between models.
-- @return start entry, start byte, stop entry, byte after the last character (or nil, reason)
local function map_range(model_a, model_b, a_idx0, a_byte0, a_idx1, a_byte1)
    local a0 = stream_pos(model_a, a_idx0, a_byte0)
    local a1 = stream_pos(model_a, a_idx1, a_byte1)
    if not a0 or not a1 or a1 <= a0 then return nil, "the selection is empty" end
    local b0, b1 = locate(model_a, model_b, a0, a1)
    if not b0 then return nil, "the passage could not be matched between the two document trees" end
    local s_idx, s_byte = point_at(model_b, b0 + 1)
    local e_idx, e_byte = point_at(model_b, b1)
    if not s_idx or not e_idx then return nil, "the position lies outside the text" end
    local t = model_b.texts[e_idx].text
    return s_idx, s_byte, e_idx, e_byte + Util.utf8SeqLen(t:byte(e_byte))
end

--- Same passage, give or take what two text extractors disagree on.
local function same_passage(a, b)
    if a == b then return true end
    if a == "" or b == "" then return false end
    local short, long = a, b
    if #short > #long then short, long = long, short end
    if #long - #short > math.max(30, math.floor(#long * 0.1)) then return false end
    return long:find(short, 1, true) ~= nil
end

--- Are all bytes of `part` found in `whole`, in order? (Text with pieces
-- left out: what the reader returns for a range that contains hidden text.)
local function is_subsequence(part, whole)
    local j, n = 1, #whole
    for i = 1, #part do
        local b = part:byte(i)
        while j <= n and whole:byte(j) ~= b do j = j + 1 end
        if j > n then return false end
        j = j + 1
    end
    return true
end

local function same_node_text(live, model_text)
    if type(live) ~= "string" then return false end
    return live == model_text or strip_ws(live) == strip_ws(model_text)
end

-- ---------------------------------------------------------------------------
-- A session bound to one open crengine document
-- ---------------------------------------------------------------------------

local Session = {}
Session.__index = Session

--- @param document an open, loaded CreDocument
function Epub.newSession(document)
    return setmetatable({ doc = document, fragments = {}, fragment_count = 0, spine_to_frag = {} }, Session)
end

function Session:close()
    self.fragments = {}
    self.fragment_count = 0
end

local function call(doc, method, ...)
    local fn = doc[method]
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, doc, ...)
    if ok then return a, b end
    return nil
end

function Session:package()
    if self.pkg ~= nil then return self.pkg or nil end
    local doc = self.doc
    local pkg, err = Epub.readPackage(function(path)
        local content = call(doc, "getDocumentFileContent", path)
        if type(content) == "string" and content ~= "" then return content end
        return nil
    end)
    if not pkg then
        logger.warn("Zotero: EPUB package not readable:", tostring(err))
        self.pkg = false
        return nil
    end
    pkg.index_of = {}
    for i, path in ipairs(pkg.spine) do
        if path and pkg.index_of[path] == nil then pkg.index_of[path] = i - 1 end
    end
    self.pkg = pkg
    return pkg
end

--- xpointer of DocFragment n (crengine omits the index when there is one).
function Session:fragmentXPointer(n)
    if self.multi == nil then
        self.multi = call(self.doc, "isXPointerInDocument", "/body/DocFragment[2]") and true or false
    end
    if self.multi then
        return "/body/DocFragment[" .. n .. "]"
    end
    return n == 1 and "/body/DocFragment" or nil
end

--- Does the engine model address the live document correctly? Checked on a
-- few text nodes: their computed xpointers must return their text.
function Session:probe(engine)
    local n = #engine.map
    if n == 0 then return true end
    local picks = { engine.map[1], engine.map[math.ceil(n / 2)], engine.map[n] }
    for _, idx in ipairs(picks) do
        local t = engine.texts[idx]
        local xp = engine_path(engine, t.node)
        if not xp then return false end
        local got = call(self.doc, "getTextFromXPointer", xp)
        if type(got) ~= "string" or strip_ws(got) ~= strip_ws(t.text) then return false end
    end
    return true
end

--- Both models of DocFragment n (1-based), or nil, reason.
-- @param textless_ok also return a chapter without any text (pictures only)
function Session:fragment(n, textless_ok)
    local cached = self.fragments[n]
    if cached ~= nil then
        if cached.failed then
            if textless_ok and cached.textless then return cached.textless end
            return nil, cached.failed
        end
        return cached
    end
    local function fail(reason)
        self.fragments[n] = { failed = reason }
        return nil, reason
    end
    local doc = self.doc
    local frag_xp = self:fragmentXPointer(n)
    if not frag_xp then return fail("the book has no such chapter") end
    local html = call(doc, "getHTMLFromXPointer", frag_xp, 0x0002)
    if type(html) ~= "string" or html == "" then return fail("the chapter could not be read from the reading engine") end
    local engine, eerr = Epub.engineModel(html, frag_xp, false)
    if not engine then return fail("the chapter's structure was not understood (" .. tostring(eerr) .. ")") end
    if not self:probe(engine) then
        local ok = false
        if engine.has_boxing then
            engine = Epub.engineModel(html, frag_xp, true)
            ok = engine ~= nil and self:probe(engine)
        end
        if not ok then return fail("the chapter's structure was not understood") end
    end

    local pkg = self:package()
    if not pkg then return fail("the book's file list could not be read") end
    local spine_index
    if engine.source then
        spine_index = pkg.index_of[normalize_path(engine.source)]
        if spine_index == nil then spine_index = pkg.index_of[normalize_path(url_decode(engine.source))] end
    elseif pkg.spine[n] then
        spine_index = n - 1 -- engine builds without the Source attribute
    end
    local path = spine_index and pkg.spine[spine_index + 1]
    if not path then return fail("the chapter was not found in the book's reading order") end
    if not (pkg.types[spine_index + 1] or ""):find("xml", 1, true) then
        return fail("the chapter is not XHTML")
    end
    local xhtml = call(doc, "getDocumentFileContent", path)
    if type(xhtml) ~= "string" or xhtml == "" then return fail("the chapter's file could not be read") end
    local source, serr = Epub.sourceModel(xhtml)
    if not source then return fail("the chapter's file could not be parsed (" .. tostring(serr) .. ")") end
    if source.unsafe then return fail(source.unsafe) end
    if #source.stream == 0 or #engine.stream == 0 then
        local reason = "the chapter has no text"
        local textless = {
            n = n, xp = frag_xp, engine = engine, source = source, spine_index = spine_index, pkg = pkg,
            identical = false, textless = true,
        }
        self.fragments[n] = { failed = reason, textless = textless }
        if textless_ok then return textless end
        return nil, reason
    end

    -- keep only a few chapters in memory
    self.fragment_count = self.fragment_count + 1
    if self.fragment_count > 4 then
        self.fragments = {}
        self.fragment_count = 1
    end
    local frag = {
        n = n, xp = frag_xp, engine = engine, source = source, spine_index = spine_index, pkg = pkg,
        identical = engine.stream == source.stream,
    }
    self.fragments[n] = frag
    return frag
end

--- Fragment number for a spine index (0-based), or nil.
function Session:fragmentForSpine(spine_index)
    local cached = self.spine_to_frag[spine_index]
    if cached ~= nil then return cached or nil end
    -- Normally fragment n holds spine item n-1. Books kept on an old DOM
    -- version may lack fragments for unsupported items, which shifts later
    -- ones down, so look a little below as well.
    local tried = 0
    for n = spine_index + 1, 1, -1 do
        local frag = self:fragment(n, true)
        if frag and frag.spine_index == spine_index then
            self.spine_to_frag[spine_index] = n
            return n
        end
        if frag and frag.spine_index < spine_index then break end
        tried = tried + 1
        if tried >= 8 then break end
    end
    self.spine_to_frag[spine_index] = false
    return nil
end

function Session:normalize(xp)
    if type(xp) ~= "string" then return nil end
    local res = call(self.doc, "getNormalizedXPointer", xp)
    if type(res) == "string" and res ~= "" then return res end
    if res == false then return nil end -- not in the document
    return xp
end

--- Publisher page label at an xpointer, when the book itself defines page
-- numbers (Zotero shows these for EPUBs that have them). "" otherwise.
function Session:pageLabel(xp)
    local doc = self.doc
    if self.page_map == nil then
        -- only a page map that comes with the book counts, not a generated one
        local provided = call(doc, "isPageMapDocumentProvided")
        if provided == nil then provided = call(doc, "hasPageMap") end
        self.page_map = provided and true or false
        if self.page_map then
            local map = call(doc, "getPageMap")
            self.first_page_xp = type(map) == "table" and map[1] and map[1].xpointer or nil
        end
    end
    if not self.page_map then return "" end
    if self.first_page_xp and call(doc, "compareXPointers", self.first_page_xp, xp) == -1 then
        return "" -- before the first numbered page
    end
    local label = call(doc, "getPageMapXPointerPageLabel", xp)
    if type(label) ~= "string" or #label > 50 then return "" end
    return label
end

--- KOReader xpointers -> Zotero position.
-- @return { position = <json>, sortIndex =, pageLabel =, cfi =, exact = } or nil, reason
function Session:toZotero(pos0, pos1)
    local xp0, xp1 = self:normalize(pos0), self:normalize(pos1)
    if not xp0 or not xp1 then
        return nil, "the highlight's position no longer exists in the book"
    end
    local n = fragment_number(xp0)
    if not n then return nil, "the highlight's position was not understood" end
    if fragment_number(xp1) ~= n then
        return nil, "the highlight spans two chapters, which Zotero cannot store"
    end
    local frag, ferr = self:fragment(n)
    if not frag then return nil, ferr end
    local e0, eb0 = engine_point(frag.engine, xp0, false)
    local e1, eb1 = engine_point(frag.engine, xp1, true)
    if not e0 or not e1 then return nil, "the highlight's position was not found in the chapter" end
    -- The nodes we resolved must be the ones the open book has at these paths.
    for _, check in ipairs({ { xp0, e0 }, { xp1, e1 } }) do
        local path = split_xpointer(check[1])
        if path:match("/text%(%)[%[%]%d]*$") then
            if not same_node_text(call(self.doc, "getTextFromXPointer", path), frag.engine.texts[check[2]].text) then
                return nil, "the open book has different text at the highlight's position"
            end
        end
    end
    if e1 < e0 or (e1 == e0 and eb1 < eb0) then
        e0, eb0, e1, eb1 = e1, eb1, e0, eb0
    end
    local s0, sb0, s1, sb1 = map_range(frag.engine, frag.source, e0, eb0, e1, eb1)
    if not s0 then return nil, sb0 end
    local st0, st1 = frag.source.texts[s0], frag.source.texts[s1]
    local off0 = Util.utf16Len(st0.text:sub(1, sb0 - 1))
    local off1 = Util.utf16Len(st1.text:sub(1, sb1 - 1))
    local cfi = Epub.buildCfi(frag.pkg.spine_step, frag.spine_index,
        source_steps(frag.source, st0.node), off0, source_steps(frag.source, st1.node), off1)
    -- self-check: the CFI must lead back to exactly this range
    local parsed = Epub.parseCfi(cfi)
    local r0, rb0, r1, rb1
    if parsed and parsed.stop then
        r0, rb0 = resolve_component(frag.source, parsed.start)
        r1, rb1 = resolve_component(frag.source, parsed.stop)
    end
    if r0 ~= s0 or r1 ~= s1 or rb0 ~= sb0 or rb1 ~= sb1 or parsed.spine_index ~= frag.spine_index then
        return nil, "the computed position failed its self-check"
    end
    local offset = math.min(st0.u16_before + off0, 99999999)
    return {
        position = '{"type":"FragmentSelector","conformsTo":"http://www.idpf.org/epub/linking/cfi/epub-cfi.html","value":'
            .. Util.jsonString(cfi) .. "}",
        sortIndex = string.format("%05d|%08d", math.min(frag.spine_index, 99999), offset),
        pageLabel = self:pageLabel(xp0),
        cfi = cfi,
        exact = frag.identical,
    }
end

--- Source-stream range [a0, a1) a CFI points to, or nil.
local function cfi_range(frag, cfi)
    local s0, sb0 = resolve_component(frag.source, cfi.start)
    if not s0 then return nil end
    local s1, sb1 = resolve_component(frag.source, cfi.stop)
    if not s1 then return nil end
    local a0 = stream_pos(frag.source, s0, sb0)
    local a1 = stream_pos(frag.source, s1, sb1)
    if not a0 or not a1 or a1 <= a0 then return nil end
    return a0, a1
end

--- Engine-stream range of a passage found by its text.
-- @param hint approximate stream position, or nil
local function text_range(frag, needle, hint)
    local se = frag.engine.stream
    if #needle < 2 then return nil end
    local hits = occurrences(se, needle)
    if #hits == 1 then return hits[1], hits[1] + #needle end
    if #hits > 1 then
        if not hint then return nil end
        local b0 = nearest(hits, hint)
        return b0, b0 + #needle
    end
    -- Not found as a whole (the text was edited in Zotero, or contains
    -- something the reading engine lacks): match its beginning and its end.
    if #needle < 48 then return nil end
    return find_ends(se, needle:sub(1, 24), 0, needle:sub(-24), 0, hint, #needle, false)
end

--- Zotero position -> KOReader xpointers.
-- @param position    annotationPosition (JSON string or decoded table)
-- @param text        annotationText (used to verify, and to search if needed)
-- @param sort_index  annotationSortIndex (a hint for the search)
-- @return pos0, pos1, how   ("cfi" | "text" | "cfi-unverified")   or nil, reason
function Session:fromZotero(position, text, sort_index)
    local pos = position
    if type(pos) == "string" then pos = Util.jsonDecode(pos) end
    local cfi
    if type(pos) == "table" and pos.type == "FragmentSelector" and type(pos.value) == "string" then
        cfi = Epub.parseCfi(pos.value)
    end
    local section, offset = Epub.parseSortIndex(sort_index)
    local spine_index = cfi and cfi.spine_index or section
    if not spine_index then return nil, "the annotation has no usable EPUB position" end
    local n = self:fragmentForSpine(spine_index)
    if not n then return nil, "the annotation's chapter was not found in this copy of the book" end
    local frag, ferr = self:fragment(n)
    if not frag then return nil, ferr end

    local needle = strip_ws(text or "")
    local b0, b1, how

    -- 1. the position itself
    local a0, a1
    if cfi and cfi.stop then a0, a1 = cfi_range(frag, cfi) end
    local agrees = false
    if a0 then
        if needle == "" then
            agrees = true
        else
            local slice = frag.source.stream:sub(a0 + 1, a1)
            agrees = slice == needle
            if not agrees then
                local ns, nn = Util.normText(slice), Util.normText(needle)
                -- Text that came from KOReader lacks what the reader does not
                -- return for a selection (ruby annotations, hidden text): the
                -- passage with pieces left out is still the passage.
                agrees = same_passage(ns, nn) or (#nn * 5 >= #ns * 2 and is_subsequence(nn, ns))
            end
        end
        if agrees then
            b0, b1 = locate(frag.source, frag.engine, a0, a1)
            if b0 then how = "cfi" end
        end
    end

    -- 2. the annotation's text, nearest to where Zotero says it is
    if not b0 and needle ~= "" then
        local hint = a0
        if not hint and offset and section == frag.spine_index then
            for i, t in ipairs(frag.source.texts) do
                local nxt = frag.source.texts[i + 1]
                if not nxt or nxt.u16_before > offset then
                    hint = stream_pos(frag.source, i, Util.utf16ByteIndex(t.text, math.max(0, offset - t.u16_before)))
                    break
                end
            end
        end
        b0, b1 = text_range(frag, needle, hint)
        if b0 then how = "text" end
    end

    -- 3. a position that resolves, with text that is found nowhere in the
    --    chapter: the text was edited in Zotero; the position still stands
    if not b0 and a0 and not agrees then
        b0, b1 = locate(frag.source, frag.engine, a0, a1)
        if b0 then how = "cfi-unverified" end
    end
    if not b0 then
        return nil, "the annotated passage was not found in the chapter"
    end

    local e0, eb0 = point_at(frag.engine, b0 + 1)
    local e1, eb1 = point_at(frag.engine, b1)
    if not e0 or not e1 then return nil, "the position lies outside the text" end
    local t0, t1 = frag.engine.texts[e0], frag.engine.texts[e1]
    eb1 = eb1 + Util.utf8SeqLen(t1.text:byte(eb1))
    local path0, path1 = engine_path(frag.engine, t0.node), engine_path(frag.engine, t1.node)
    if not path0 or not path1 then return nil, "the position could not be expressed for the reading engine" end
    local xp0 = path0 .. "." .. Util.utf8Len(t0.text:sub(1, eb0 - 1))
    local xp1 = path1 .. "." .. Util.utf8Len(t1.text:sub(1, eb1 - 1))

    -- Check against the live document: both ends exist and sit in the text
    -- nodes we think they do, and the text the reader shows between them is
    -- the passage we meant (minus whatever the book's styles hide).
    local doc = self.doc
    if not call(doc, "isXPointerInDocument", xp0) or not call(doc, "isXPointerInDocument", xp1) then
        return nil, "the computed position does not exist in the open book"
    end
    if not same_node_text(call(doc, "getTextFromXPointer", path0), t0.text)
        or not same_node_text(call(doc, "getTextFromXPointer", path1), t1.text) then
        return nil, "the open book has different text at the computed position"
    end
    local got = call(doc, "getTextFromXPointers", xp0, xp1)
    if type(got) ~= "string" then
        return nil, "the computed position could not be checked in the open book"
    end
    local have = Util.normText(got)
    local want = Util.normText(frag.engine.stream:sub(b0 + 1, b1))
    if strip_ws(got) == "" then
        return nil, "the annotated passage is not displayed in the book"
    end
    if have ~= want and not is_subsequence(have, want) then
        return nil, "the open book shows different text at the computed position"
    end
    return xp0, xp1, how
end

-- ---------------------------------------------------------------------------
-- Reading positions
--
-- Zotero stores where an EPUB was last read as a CFI without the
-- epubcfi(...) wrapper: the start of the first text node visible in its
-- reader ("/6/14!/4/2/14/1:0"), or the first visible picture, as the range
-- that selects it ("/6/14!/4/2,/8:1,/8:2"), or "_start". KOReader keeps the
-- xpointer of the top of the page. A point is carried from one tree to the
-- other by the text around it, a picture by its place in that text.
-- ---------------------------------------------------------------------------

--- Where is the point a0 (stream bytes before it) of model A in model B?
-- A highlight carries its text, which proves where it belongs; a reading
-- position carries nothing. So the text around the point is looked for, and
-- only a window that occurs exactly once on the other side is believed:
-- with text on both sides of the point first (grown while it is ambiguous),
-- then on one side only (the other side being where the two differ: a
-- formula, an image's fallback text).
-- @return stream bytes before the point in B, or nil
local function locate_point(model_a, model_b, a0)
    local sa, sb = model_a.stream, model_b.stream
    local len = #sa
    if len == 0 or #sb == 0 or a0 < 0 or a0 > len then return nil end
    if sa == sb then return math.min(a0, len - 1) end -- the normal case: same text on both sides
    local function try(pre, post)
        pre = math.min(pre, a0)
        post = math.min(post, len - a0)
        if pre + post < 8 then return 0 end
        local hits = occurrences(sb, sa:sub(a0 + 1 - pre, a0 + post), 2)
        if #hits == 1 then return 1, math.min(#sb - 1, hits[1] + pre) end
        return #hits
    end
    for _, n in ipairs({ 24, 48, 96, 240, 600 }) do
        local count, pos = try(n, n)
        if count == 1 then return pos end
        if count == 0 then break end -- the two differ inside the window
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

--- The image of model_b that is the image `ia` of model_a: the one at the
-- same place in the text (the n-th of them, where several follow each other).
local function match_image(model_a, model_b, ia)
    local img = model_a.images[ia]
    if not img or #model_b.images == 0 then return nil end
    local a0 = image_pos(model_a, img)
    local len_a, len_b = #model_a.stream, #model_b.stream
    local b0
    if len_a == 0 or len_b == 0 then
        if len_a ~= len_b then return nil end
        b0 = 0 -- a chapter of pictures only
    elseif a0 >= len_a then
        -- behind the last text: the two texts must end alike
        if locate_point(model_a, model_b, len_a - 1) ~= len_b - 1 then return nil end
        b0 = len_b
    else
        b0 = locate_point(model_a, model_b, a0)
        if not b0 then return nil end
    end
    local rank = 0
    for i = ia, 1, -1 do
        if image_pos(model_a, model_a.images[i]) ~= a0 then break end
        rank = rank + 1
    end
    local seen = 0
    for j, other in ipairs(model_b.images) do
        local p = image_pos(model_b, other)
        if p == b0 then
            seen = seen + 1
            if seen == rank then return j end
        elseif p > b0 then
            break
        end
    end
    return nil
end

--- Zotero reading position -> xpointer.
-- @return xpointer, "exact" | "chapter" (only the chapter could be found)  or nil, reason
function Session:pointFromCfi(value)
    if type(value) ~= "string" or value == "" then return nil, "no position" end
    if value == "_start" then return nil, "start" end
    local cfi = Epub.parseCfi(value)
    if not cfi or not cfi.start then return nil, "the position was not understood" end
    local doc = self.doc
    local function chapter_start()
        -- the chapter itself is known, even if nothing more can be said
        local xp = self:fragmentXPointer(cfi.spine_index + 1)
        if xp and call(doc, "isXPointerInDocument", xp) then return xp, "chapter" end
        return nil, "the chapter was not found in this copy of the book"
    end
    local n = self:fragmentForSpine(cfi.spine_index)
    local frag = n and self:fragment(n, true)
    if not frag then return chapter_start() end
    local kind, s, sb = resolve_point(frag.source, cfi.start)
    if not kind then return chapter_start() end
    local a0
    if kind == "image" then
        -- the picture itself, if the reading engine has it at the same place
        local j = match_image(frag.source, frag.engine, s)
        local path = j and engine_path(frag.engine, frag.engine.images[j].node)
        if path then
            for _, xp in ipairs({ path .. ".0", path }) do
                if call(doc, "isXPointerInDocument", xp) then return xp, "exact" end
            end
        end
        a0 = image_pos(frag.source, frag.source.images[s]) -- else the text after it
    else
        a0 = stream_pos(frag.source, s, sb)
    end
    if frag.textless then return chapter_start() end
    local b0 = a0 and locate_point(frag.source, frag.engine, math.min(a0, #frag.source.stream - 1))
    if not b0 then return chapter_start() end
    local e, eb = point_at(frag.engine, b0 + 1)
    if not e then return chapter_start() end
    local t = frag.engine.texts[e]
    local path = engine_path(frag.engine, t.node)
    if not path then return chapter_start() end
    local xp = path .. "." .. Util.utf8Len(t.text:sub(1, eb - 1))
    if not call(doc, "isXPointerInDocument", xp) then return chapter_start() end
    return xp, "exact"
end

--- xpointer -> Zotero reading position, in the two forms Zotero's reader
-- writes itself (without the "epubcfi()" wrapper): a point in a text node, or
-- a picture given as the range that selects it.
-- @return string or nil, reason
function Session:cfiFromXPointer(xp)
    local nxp = self:normalize(xp)
    if not nxp then return nil, "the position does not exist in the book" end
    local n = fragment_number(nxp)
    if not n then return nil, "the position was not understood" end
    local frag, ferr = self:fragment(n, true)
    if not frag then return nil, ferr end
    local base = "/" .. frag.pkg.spine_step .. "/" .. ((frag.spine_index + 1) * 2) .. "!"
    local node = engine_resolve(frag.engine, nxp)

    -- a picture at the top of the page
    if node and node.image_index then
        local j = match_image(frag.engine, frag.source, node.image_index)
        local img = j and frag.source.images[j].node
        local parent = img and img.parent
        if parent and parent ~= frag.source.root and parent.el_index then
            local index = -1
            for _, k in ipairs(parent.kids) do
                if not k.removed then
                    index = index + 1
                    if k == img then break end
                end
            end
            local rev = {}
            local p = parent
            while p and p ~= frag.source.root do
                rev[#rev + 1] = p.el_index * 2
                p = p.parent
            end
            local common = {}
            for i = #rev, 2, -1 do common[#common + 1] = "/" .. rev[i] end
            -- (For a picture directly in <body> Zotero's reader writes a lone
            -- "/" as the common path - "!/,/4:1,/4:2" - and then cannot read
            -- that back itself. Without the slash it can.)
            local cfi = base .. table.concat(common) .. ",/" .. rev[1] .. ":" .. index .. ",/" .. rev[1] .. ":" .. (index + 1)
            -- self-check: it must lead back to this very picture
            local parsed = Epub.parseCfi(cfi)
            local kind, back = nil, nil
            if parsed and parsed.start then kind, back = resolve_point(frag.source, parsed.start) end
            if kind == "image" and back == j and parsed.spine_index == frag.spine_index then return cfi end
        end
    end
    if frag.textless then return nil, "the chapter has no text" end

    local e, eb = engine_point(frag.engine, nxp, false)
    if not e and node then
        -- an element without text of its own (a picture, a rule): the text after it
        e, eb = first_text_from(node, "ukids", "up"), 1
    end
    if not e then return nil, "the position was not found in the chapter" end
    local b0 = stream_pos(frag.engine, e, eb)
    local a0 = b0 and locate_point(frag.engine, frag.source, math.min(b0, #frag.engine.stream - 1))
    if not a0 then return nil, "the position could not be matched between the two document trees" end
    local s, sb = point_at(frag.source, a0 + 1)
    if not s then return nil, "the position lies outside the text" end
    local st = frag.source.texts[s]
    local offset = Util.utf16Len(st.text:sub(1, sb - 1))
    local cfi = base .. "/" .. table.concat(source_steps(frag.source, st.node), "/") .. ":" .. offset
    -- self-check: the CFI must lead back to this very point
    local parsed = Epub.parseCfi(cfi)
    local kind, r, rb
    if parsed and parsed.start then kind, r, rb = resolve_point(frag.source, parsed.start) end
    if kind ~= "text" or r ~= s or rb ~= sb or parsed.spine_index ~= frag.spine_index then
        return nil, "the computed position failed its self-check"
    end
    return cfi
end

return Epub
