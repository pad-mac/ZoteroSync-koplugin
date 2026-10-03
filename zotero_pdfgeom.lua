--[[--
Page geometry for PDF files, read straight from the file.

Zotero stores annotation rectangles in *PDF user space*: origin wherever the
page's boxes put it, y pointing up, unrotated. KOReader (MuPDF) works in
*page space*: origin at the top-left corner of the visible (cropped) page, y
pointing down, with /Rotate and /UserUnit already applied.

Converting between the two needs each page's MediaBox, CropBox, Rotate and
UserUnit. MuPDF knows them but KOReader's Lua binding does not expose them,
so this module reads them itself: cross-reference table or stream, object
streams, and the page tree with inherited attributes. It also reads
/PageLabels so uploaded annotations can carry the page label Zotero would
use.

Everything here is defensive: any structure it cannot follow makes it return
`nil, reason`, and the caller falls back to the plain "origin at 0,0"
assumption. It never raises.
]]

local Geom = { fork = "0.6" }

-- ---------------------------------------------------------------------------
-- Matrices. Same convention as MuPDF: [a b c d e f],
--   x' = a*x + c*y + e ;  y' = b*x + d*y + f
-- ---------------------------------------------------------------------------

local function concat(m, n) -- apply m, then n
    return {
        m[1] * n[1] + m[2] * n[3],
        m[1] * n[2] + m[2] * n[4],
        m[3] * n[1] + m[4] * n[3],
        m[3] * n[2] + m[4] * n[4],
        m[5] * n[1] + m[6] * n[3] + n[5],
        m[5] * n[2] + m[6] * n[4] + n[6],
    }
end

local function apply(m, x, y)
    return m[1] * x + m[3] * y + m[5], m[2] * x + m[4] * y + m[6]
end
Geom.apply = apply

local function invert(m)
    local det = m[1] * m[4] - m[2] * m[3]
    if det == 0 then return nil end
    local a, b, c, d = m[4] / det, -m[2] / det, -m[3] / det, m[1] / det
    return { a, b, c, d, -(m[5] * a + m[6] * c), -(m[5] * b + m[6] * d) }
end
Geom.invert = invert

--- Transform a rectangle given as x0,y0,x1,y1; returns the normalised
-- bounding rectangle x0,y0,x1,y1 (x0<=x1, y0<=y1).
local function apply_rect(m, x0, y0, x1, y1)
    local ax, ay = apply(m, x0, y0)
    local bx, by = apply(m, x1, y0)
    local cx, cy = apply(m, x1, y1)
    local dx, dy = apply(m, x0, y1)
    return math.min(ax, bx, cx, dx), math.min(ay, by, cy, dy),
        math.max(ax, bx, cx, dx), math.max(ay, by, cy, dy)
end
Geom.applyRect = apply_rect

local function norm_rect(r)
    return { math.min(r[1], r[3]), math.min(r[2], r[4]), math.max(r[1], r[3]), math.max(r[2], r[4]) }
end

local function intersect(a, b)
    local r = { math.max(a[1], b[1]), math.max(a[2], b[2]), math.min(a[3], b[3]), math.min(a[4], b[4]) }
    if r[1] >= r[3] or r[2] >= r[4] then return nil end
    return r
end

local function snap_rotation(rotate)
    rotate = math.floor((tonumber(rotate) or 0) + 0.5)
    if rotate < 0 then rotate = 360 - ((-rotate) % 360) end
    if rotate >= 360 then rotate = rotate % 360 end
    rotate = 90 * math.floor((rotate + 45) / 90)
    if rotate >= 360 then rotate = 0 end
    return rotate
end

--- Build the PDF-user-space -> MuPDF-page-space matrix exactly the way MuPDF
-- does (pdf_page_obj_transform_box).
-- @param info { mediabox = {x0,y0,x1,y1}, cropbox = {..} or nil, rotate = n, userunit = n }
-- @return ctm, width, height   (width/height of the page in page space)
function Geom.pageMatrix(info)
    local mediabox = info.mediabox and norm_rect(info.mediabox) or { 0, 0, 612, 792 }
    local box = mediabox
    if info.cropbox then
        box = intersect(norm_rect(info.cropbox), mediabox)
    end
    if not box then box = { 0, 0, 612, 792 } end
    if box[3] - box[1] < 1 or box[4] - box[2] < 1 then box = { 0, 0, 1, 1 } end

    local unit = tonumber(info.userunit) or 1
    if unit <= 0 then unit = 1 end
    local rotate = snap_rotation(info.rotate)

    -- fz_scale(unit, -unit) pre-rotated by -rotate: rotation is applied first.
    local rad = math.rad(-rotate)
    local cs, sn = math.cos(rad), math.sin(rad)
    -- snap to exact values for the four right angles
    if rotate == 0 then cs, sn = 1, 0
    elseif rotate == 90 then cs, sn = 0, -1
    elseif rotate == 180 then cs, sn = -1, 0
    elseif rotate == 270 then cs, sn = 0, 1 end
    local rot = { cs, sn, -sn, cs, 0, 0 }
    local ctm = concat(rot, { unit, 0, 0, -unit, 0, 0 })

    local x0, y0, x1, y1 = apply_rect(ctm, box[1], box[2], box[3], box[4])
    ctm = concat(ctm, { 1, 0, 0, 1, -x0, -y0 })
    return ctm, x1 - x0, y1 - y0
end

--- Matrix for a page whose boxes are unknown: MediaBox [0 0 w h], no
-- rotation. `w`,`h` are MuPDF's page dimensions.
function Geom.defaultMatrix(w, h)
    return { 1, 0, 0, -1, 0, h }, w, h
end

-- ---------------------------------------------------------------------------
-- PDF tokenizer
-- ---------------------------------------------------------------------------

local NULL = setmetatable({}, { __tostring = function() return "null" end })
local EOF = {} -- thrown (via error) when a chunk ends mid-object

local WS = { [0] = true, [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }
local DELIM = {
    [40] = true, [41] = true, [60] = true, [62] = true, [91] = true, [93] = true,
    [123] = true, [125] = true, [47] = true, [37] = true,
}

local function skip_ws(s, i)
    local len = #s
    while i <= len do
        local b = s:byte(i)
        if WS[b] then
            i = i + 1
        elseif b == 37 then -- comment up to end of line
            local e = s:find("[\r\n]", i)
            if not e then return len + 1 end
            i = e + 1
        else
            break
        end
    end
    return i
end

local parse_value

local function parse_name(s, i)
    -- s:byte(i) == '/'
    local j = i + 1
    local len = #s
    while j <= len do
        local b = s:byte(j)
        if WS[b] or DELIM[b] then break end
        j = j + 1
    end
    if j > len then error(EOF) end
    local raw = s:sub(i + 1, j - 1)
    if raw:find("#", 1, true) then
        raw = raw:gsub("#(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end
    return "/" .. raw, j
end

local function parse_literal_string(s, i)
    -- s:byte(i) == '('
    local out, n = {}, 0
    local depth = 1
    local j = i + 1
    local len = #s
    while true do
        if j > len then error(EOF) end
        local b = s:byte(j)
        if b == 92 then -- backslash
            if j + 1 > len then error(EOF) end
            local c = s:byte(j + 1)
            if c == 110 then n = n + 1; out[n] = "\n"; j = j + 2
            elseif c == 114 then n = n + 1; out[n] = "\r"; j = j + 2
            elseif c == 116 then n = n + 1; out[n] = "\t"; j = j + 2
            elseif c == 98 then n = n + 1; out[n] = "\b"; j = j + 2
            elseif c == 102 then n = n + 1; out[n] = "\f"; j = j + 2
            elseif c >= 48 and c <= 55 then
                local oct = s:match("^[0-7][0-7]?[0-7]?", j + 1)
                n = n + 1; out[n] = string.char(tonumber(oct, 8) % 256)
                j = j + 1 + #oct
            elseif c == 13 then -- line continuation
                j = j + 2
                if s:byte(j) == 10 then j = j + 1 end
            elseif c == 10 then
                j = j + 2
            else
                n = n + 1; out[n] = string.char(c); j = j + 2
            end
        elseif b == 40 then
            depth = depth + 1; n = n + 1; out[n] = "("; j = j + 1
        elseif b == 41 then
            depth = depth - 1
            if depth == 0 then
                return { str = table.concat(out) }, j + 1
            end
            n = n + 1; out[n] = ")"; j = j + 1
        else
            n = n + 1; out[n] = string.char(b); j = j + 1
        end
    end
end

local function parse_hex_string(s, i)
    local e = s:find(">", i + 1, true)
    if not e then error(EOF) end
    local hex = s:sub(i + 1, e - 1):gsub("%s+", "")
    if #hex % 2 == 1 then hex = hex .. "0" end
    local str = hex:gsub("(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return { str = str }, e + 1
end

local function parse_dict(s, i)
    -- s:sub(i, i+1) == '<<'
    local dict = {}
    local j = i + 2
    while true do
        j = skip_ws(s, j)
        if j > #s then error(EOF) end
        if s:byte(j) == 62 then
            if j + 1 > #s then error(EOF) end
            if s:byte(j + 1) == 62 then
                return dict, j + 2
            end
            error("malformed dictionary")
        end
        if s:byte(j) ~= 47 then error("dictionary key is not a name") end
        local key
        key, j = parse_name(s, j)
        local val
        val, j = parse_value(s, j)
        dict[key:sub(2)] = val
    end
end

local function parse_array(s, i)
    local arr, n = {}, 0
    local j = i + 1
    while true do
        j = skip_ws(s, j)
        if j > #s then error(EOF) end
        if s:byte(j) == 93 then
            arr.n = n
            return arr, j + 1
        end
        local val
        val, j = parse_value(s, j)
        n = n + 1
        arr[n] = val
    end
end

parse_value = function(s, i)
    i = skip_ws(s, i)
    local len = #s
    if i > len then error(EOF) end
    local b = s:byte(i)
    if b == 60 then -- <
        if i + 1 > len then error(EOF) end
        if s:byte(i + 1) == 60 then
            return parse_dict(s, i)
        end
        return parse_hex_string(s, i)
    elseif b == 47 then
        return parse_name(s, i)
    elseif b == 91 then
        return parse_array(s, i)
    elseif b == 40 then
        return parse_literal_string(s, i)
    elseif (b >= 48 and b <= 57) or b == 43 or b == 45 or b == 46 then
        local num = s:match("^[%+%-]?%d*%.?%d*", i)
        if not num or num == "" or num == "+" or num == "-" or num == "." then
            error("malformed number")
        end
        local j = i + #num
        if j > len then error(EOF) end -- the number may continue in the next chunk
        local value = tonumber(num) or 0
        -- indirect reference:  <int> <int> R
        if num:match("^%d+$") then
            local gen, r_end = s:match("^[%z\t\n\f\r ]+(%d+)[%z\t\n\f\r ]+R()", j)
            if gen then
                local nb = s:byte(r_end)
                if nb == nil then
                    if r_end > len then error(EOF) end
                elseif WS[nb] or DELIM[nb] then
                    return { ref = value, gen = tonumber(gen) }, r_end
                end
            elseif not s:find("[^%z\t\n\f\r %d]", j) then
                -- only whitespace/digits up to the end of the chunk: cannot
                -- tell yet whether this is a reference
                error(EOF)
            end
        end
        return value, j
    else
        local word = s:match("^%a+", i)
        if word == "true" then return true, i + 4 end
        if word == "false" then return false, i + 5 end
        if word == "null" then return NULL, i + 4 end
        if word and i + #word > len then error(EOF) end
        error("unexpected token '" .. tostring(word or string.char(b)) .. "'")
    end
end

-- ---------------------------------------------------------------------------
-- Flate + predictors
-- ---------------------------------------------------------------------------

local zlib_state
local function inflate(data)
    if zlib_state == nil then
        zlib_state = false
        pcall(function()
            local ffi = require("ffi")
            require("ffi/zlib_h")
            zlib_state = { ffi = ffi, lib = ffi.loadlib("z", 1) }
        end)
    end
    if not zlib_state then return nil, "zlib unavailable" end
    local ffi, lib = zlib_state.ffi, zlib_state.lib
    local cap = math.max(4096, #data * 8)
    for _ = 1, 12 do
        local buf = ffi.new("uint8_t[?]", cap)
        local buflen = ffi.new("unsigned long[1]", cap)
        local res = lib.uncompress(buf, buflen, data, #data)
        if res == 0 then
            return ffi.string(buf, buflen[0])
        elseif res == -5 then -- Z_BUF_ERROR: output buffer too small
            cap = cap * 4
            if cap > 256 * 1024 * 1024 then break end
        else
            return nil, "inflate error " .. tostring(res)
        end
    end
    return nil, "inflate: output too large"
end

local function paeth(a, b, c)
    local p = a + b - c
    local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
    if pa <= pb and pa <= pc then return a end
    if pb <= pc then return b end
    return c
end

local function unpredict_png(data, columns, bpp)
    local rowlen = columns
    local out = {}
    local prev = {}
    for k = 1, rowlen do prev[k] = 0 end
    local pos, len = 1, #data
    while pos + rowlen <= len do
        local ft = data:byte(pos)
        local row = { data:byte(pos + 1, pos + rowlen) }
        for k = 1, rowlen do
            local left = k > bpp and row[k - bpp] or 0
            local up = prev[k]
            local upleft = k > bpp and prev[k - bpp] or 0
            local v = row[k]
            if ft == 1 then v = v + left
            elseif ft == 2 then v = v + up
            elseif ft == 3 then v = v + math.floor((left + up) / 2)
            elseif ft == 4 then v = v + paeth(left, up, upleft)
            end
            row[k] = v % 256
        end
        out[#out + 1] = string.char(unpack(row))
        prev = row
        pos = pos + rowlen + 1
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- File access
-- ---------------------------------------------------------------------------

local Pdf = {}
Pdf.__index = Pdf

local MAX_CHUNK = 8 * 1024 * 1024

function Pdf:read(off, len)
    if off < 0 or off >= self.size then return "" end
    self.f:seek("set", off)
    return self.f:read(len) or ""
end

--- Parse one value located at absolute offset `off`, growing the chunk
-- until the value is complete. Returns value, absolute end offset.
function Pdf:parseAt(off, parser, first_chunk)
    local chunk = first_chunk or 2048
    while true do
        local s = self:read(off, chunk)
        local ok, v, pos = pcall(parser or parse_value, s, 1)
        if ok then
            return v, off + pos - 1
        end
        if v ~= EOF then error(v, 0) end
        if off + #s >= self.size or chunk >= MAX_CHUNK then
            error("unexpected end of data", 0)
        end
        chunk = chunk * 4
    end
end

local function is_dict(v)
    return type(v) == "table" and v.ref == nil and v.str == nil and v.n == nil and v ~= NULL
end

--- Decode a stream given its dictionary and raw bytes.
function Pdf:decodeStream(dict, raw)
    local filter = self:resolve(dict.Filter)
    local parms = self:resolve(dict.DecodeParms)
    if type(filter) == "table" and filter.n then
        if filter.n == 0 then
            filter = nil
        elseif filter.n == 1 then
            filter = self:resolve(filter[1])
            if type(parms) == "table" and parms.n then parms = self:resolve(parms[1]) end
        else
            error("unsupported filter chain", 0)
        end
    end
    if filter == nil or filter == NULL then
        return raw
    end
    if filter ~= "/FlateDecode" and filter ~= "/Fl" then
        error("unsupported stream filter " .. tostring(filter), 0)
    end
    local data, err = inflate(raw)
    if not data then error(err, 0) end
    if is_dict(parms) then
        local predictor = tonumber(self:resolve(parms.Predictor)) or 1
        if predictor >= 10 then
            local columns = tonumber(self:resolve(parms.Columns)) or 1
            local colors = tonumber(self:resolve(parms.Colors)) or 1
            local bpc = tonumber(self:resolve(parms.BitsPerComponent)) or 8
            local bpp = math.max(1, math.floor(colors * bpc / 8))
            local rowlen = math.floor((columns * colors * bpc + 7) / 8)
            data = unpredict_png(data, rowlen, bpp)
        elseif predictor ~= 1 then
            error("unsupported predictor " .. tostring(predictor), 0)
        end
    end
    return data
end

--- Read "N G obj <value> [stream ...]" at an absolute offset.
-- Returns value, stream bytes (decoded) or nil.
function Pdf:readIndirectAt(off, want_stream)
    local value, vend = self:parseAt(off, function(s, i)
        i = skip_ws(s, i)
        local e = select(2, s:find("^%d+[%z\t\n\f\r ]+%d+[%z\t\n\f\r ]*obj", i))
        if not e then
            if #s - i < 40 then error(EOF) end
            error("object header not found")
        end
        return parse_value(s, e + 1)
    end)
    if not want_stream or not is_dict(value) then
        return value
    end
    -- stream keyword follows the dictionary
    local tail = self:read(vend, 64)
    local kw_s, kw_e = tail:find("^[%z\t\n\f\r ]*stream")
    if not kw_s then
        return value
    end
    local data_off = vend + kw_e
    local nl = self:read(data_off, 2)
    if nl:sub(1, 2) == "\r\n" then data_off = data_off + 2
    elseif nl:sub(1, 1) == "\n" or nl:sub(1, 1) == "\r" then data_off = data_off + 1 end
    local length = tonumber(self:resolve(value.Length))
    local raw
    if length and length >= 0 and data_off + length <= self.size then
        raw = self:read(data_off, length)
    else
        -- broken /Length: look for the terminator
        local buf = self:read(data_off, math.min(MAX_CHUNK, self.size - data_off))
        local e = buf:find("endstream", 1, true)
        if not e then error("stream terminator not found", 0) end
        raw = buf:sub(1, e - 1):gsub("\r?\n$", "")
    end
    return value, self:decodeStream(value, raw)
end

function Pdf:loadObjStm(num)
    local cached = self.objstm[num]
    if cached then return cached end
    local entry = self:xrefEntry(num)
    if not entry or entry.type ~= 1 then error("object stream " .. num .. " missing", 0) end
    local dict, data = self:readIndirectAt(self.base + entry.off, true)
    if not data then error("object stream " .. num .. " has no data", 0) end
    local n = tonumber(self:resolve(dict.N)) or 0
    local first = tonumber(self:resolve(dict.First)) or 0
    -- the sentinel keeps a trailing bare number from looking truncated
    local stm = { data = data .. "\nendobj\n", first = first, index = {} }
    local pos = 1
    for k = 0, n - 1 do
        local s, e, onum, ooff = data:find("^[%z\t\n\f\r ]*(%d+)[%z\t\n\f\r ]+(%d+)", pos)
        if not s then break end
        stm.index[k] = { num = tonumber(onum), off = tonumber(ooff) }
        pos = e + 1
    end
    -- keep the cache small
    self.objstm_count = (self.objstm_count or 0) + 1
    if self.objstm_count > 16 then
        self.objstm = {}
        self.objstm_count = 1
    end
    self.objstm[num] = stm
    return stm
end

function Pdf:getObject(num)
    local cached = self.cache[num]
    if cached ~= nil then return cached end
    local entry = self:xrefEntry(num)
    if not entry or entry.type == 0 then
        return NULL
    end
    local value
    if entry.type == 1 then
        value = self:readIndirectAt(self.base + entry.off, false)
    else
        local stm = self:loadObjStm(entry.stm)
        local slot = stm.index[entry.idx]
        if not slot then error("object " .. num .. " not in its object stream", 0) end
        local ok, v = pcall(parse_value, stm.data, stm.first + slot.off + 1)
        if not ok then error("object " .. num .. ": " .. tostring(v == EOF and "truncated" or v), 0) end
        value = v
    end
    self.cache_count = (self.cache_count or 0) + 1
    if self.cache_count > 4000 then
        self.cache = {}
        self.cache_count = 1
    end
    self.cache[num] = value
    return value
end

function Pdf:resolve(v, depth)
    depth = depth or 0
    while type(v) == "table" and v.ref ~= nil do
        depth = depth + 1
        if depth > 32 then error("reference chain too deep", 0) end
        v = self:getObject(v.ref)
    end
    if v == NULL then return nil end
    return v
end

-- ---------------------------------------------------------------------------
-- Cross-reference data. Sections are kept in discovery order (newest first)
-- and consulted lazily, so opening a file with a huge table stays cheap.
-- ---------------------------------------------------------------------------

local WSCLASS = "[%z\t\n\f\r ]"

--- Sequentially parse one classic subsection (used when the entries are not
-- the standard 20 bytes wide). Returns a map and the offset after it.
function Pdf:parseSubsectionSlow(pos, start, count)
    local map = {}
    local data = self:read(pos, count * 24 + 64)
    local p = 1
    for k = 0, count - 1 do
        local es, ee, eoff, egen, kind = data:find("^" .. WSCLASS .. "*(%d+)" .. WSCLASS .. "+(%d+)" .. WSCLASS .. "+([nf])", p)
        if not es then error("malformed xref entry", 0) end
        if kind == "n" then
            map[start + k] = { type = 1, off = tonumber(eoff), gen = tonumber(egen) }
        else
            map[start + k] = { type = 0 }
        end
        p = ee + 1
    end
    return map, pos + p - 1
end

function Pdf:parseXrefTable(off)
    -- "xref" already verified by the caller
    local pos = off + 4
    local section = { kind = "table", subs = {} }
    while true do
        local head = self:read(pos, 64)
        local s, e, start, count = head:find("^" .. WSCLASS .. "*(%d+)" .. WSCLASS .. "+(%d+)" .. WSCLASS .. "*")
        if not s then break end
        start, count = tonumber(start), tonumber(count)
        pos = pos + e
        if count > 0 then
            -- Standard entries are exactly 20 bytes. Check the first and the
            -- last one, and what follows, before trusting that.
            local first = self:read(pos, 20)
            local last = self:read(pos + (count - 1) * 20, 20)
            local after = self:read(pos + count * 20, 24)
            local entry_pat = "^%d%d%d%d%d%d%d%d%d%d %d%d%d%d%d [nf]"
            local fixed = first:find(entry_pat) and last:find(entry_pat)
                and (after:find("^" .. WSCLASS .. "*trailer") or after:find("^" .. WSCLASS .. "*%d+" .. WSCLASS .. "+%d+" .. WSCLASS))
            if fixed then
                section.subs[#section.subs + 1] = { start = start, count = count, off = pos }
                pos = pos + count * 20
            else
                local map
                map, pos = self:parseSubsectionSlow(pos, start, count)
                section.subs[#section.subs + 1] = { start = start, count = count, map = map }
            end
        end
    end
    local tail = self:read(pos, 32)
    local ts, te = tail:find("^" .. WSCLASS .. "*trailer")
    if not ts then error("trailer not found", 0) end
    local trailer = self:parseAt(pos + te)
    if not is_dict(trailer) then error("trailer is not a dictionary", 0) end
    self.sections[#self.sections + 1] = section
    return trailer
end

local function be_int(data, pos, width)
    local v = 0
    for k = 0, width - 1 do
        v = v * 256 + (data:byte(pos + k) or 0)
    end
    return v
end

function Pdf:parseXrefStream(off)
    local dict, data = self:readIndirectAt(off, true)
    if not is_dict(dict) or not data then error("cross-reference stream unreadable", 0) end
    local w = self:resolve(dict.W)
    if type(w) ~= "table" or (w.n or 0) < 3 then error("cross-reference stream without /W", 0) end
    local w1, w2, w3 = tonumber(w[1]) or 0, tonumber(w[2]) or 0, tonumber(w[3]) or 0
    local rowlen = w1 + w2 + w3
    if rowlen <= 0 then error("cross-reference stream with empty rows", 0) end
    local size = tonumber(self:resolve(dict.Size)) or 0
    local index = self:resolve(dict.Index)
    local section = { kind = "stream", data = data, w1 = w1, w2 = w2, w3 = w3, rowlen = rowlen, subs = {} }
    local row = 0
    if type(index) == "table" and index.n and index.n >= 2 then
        for k = 1, index.n - 1, 2 do
            local start, count = tonumber(index[k]) or 0, tonumber(index[k + 1]) or 0
            section.subs[#section.subs + 1] = { start = start, count = count, row = row }
            row = row + count
        end
    else
        section.subs[1] = { start = 0, count = size, row = 0 }
    end
    self.sections[#self.sections + 1] = section
    return dict
end

--- Look up the cross-reference entry of an object:
-- { type = 1, off = } | { type = 2, stm =, idx = } | { type = 0 } | nil
function Pdf:xrefEntry(num)
    local cached = self.xref[num]
    if cached ~= nil then return cached or nil end
    local found
    for _, section in ipairs(self.sections) do
        for _, sub in ipairs(section.subs) do
            if num >= sub.start and num < sub.start + sub.count then
                if section.kind == "stream" then
                    local pos = (sub.row + num - sub.start) * section.rowlen + 1
                    if pos + section.rowlen - 1 <= #section.data then
                        local w1, w2, w3 = section.w1, section.w2, section.w3
                        local kind = w1 > 0 and be_int(section.data, pos, w1) or 1
                        local f2 = w2 > 0 and be_int(section.data, pos + w1, w2) or 0
                        local f3 = w3 > 0 and be_int(section.data, pos + w1 + w2, w3) or 0
                        if kind == 1 then found = { type = 1, off = f2, gen = f3 }
                        elseif kind == 2 then found = { type = 2, stm = f2, idx = f3 }
                        else found = { type = 0 } end
                    end
                elseif sub.map then
                    found = sub.map[num]
                else
                    local entry = self:read(sub.off + (num - sub.start) * 20, 20)
                    local eoff, egen, kind = entry:match("^(%d+) (%d+) ([nf])")
                    if kind == "n" then found = { type = 1, off = tonumber(eoff), gen = tonumber(egen) }
                    elseif kind == "f" then found = { type = 0 } end
                end
                break
            end
        end
        if found then break end
    end
    self.xref_count = (self.xref_count or 0) + 1
    if self.xref_count > 20000 then
        self.xref = {}
        self.xref_count = 1
    end
    self.xref[num] = found or false
    return found
end

function Pdf:loadXref(startxref)
    local seen = {}
    local queue = { startxref }
    local guard = 0
    while #queue > 0 do
        guard = guard + 1
        if guard > 64 then error("too many cross-reference sections", 0) end
        local off = table.remove(queue, 1)
        if not seen[off] and off >= 0 and self.base + off < self.size then
            seen[off] = true
            local abs = self.base + off
            local head = self:read(abs, 16)
            local ws = head:match("^" .. WSCLASS .. "*") or ""
            abs = abs + #ws
            local trailer
            if head:sub(#ws + 1, #ws + 4) == "xref" then
                trailer = self:parseXrefTable(abs)
            else
                trailer = self:parseXrefStream(abs)
            end
            if not self.trailer then
                self.trailer = {}
            end
            -- older sections only fill gaps
            for _, k in ipairs({ "Root", "Encrypt", "Info" }) do
                if self.trailer[k] == nil then self.trailer[k] = trailer[k] end
            end
            -- hybrid files: the stream named by XRefStm comes before /Prev
            local xrefstm = tonumber(trailer.XRefStm)
            if xrefstm then table.insert(queue, 1, xrefstm) end
            local prev = tonumber(trailer.Prev)
            if prev then queue[#queue + 1] = prev end
        end
    end
    if not self.trailer or self.trailer.Root == nil then
        error("no document catalog", 0)
    end
end

-- ---------------------------------------------------------------------------
-- Page tree
-- ---------------------------------------------------------------------------

local INHERITABLE = { "MediaBox", "CropBox", "Rotate" }

function Pdf:toRect(v)
    v = self:resolve(v)
    if type(v) ~= "table" or (v.n or 0) < 4 then return nil end
    local r = {}
    for k = 1, 4 do
        local num = tonumber(self:resolve(v[k]))
        if not num then return nil end
        r[k] = num
    end
    return r
end

function Pdf:countPages(node, depth)
    depth = depth or 0
    if depth > 64 then error("page tree too deep", 0) end
    local kids = self:resolve(node.Kids)
    if type(kids) ~= "table" then return 1 end
    local total = 0
    for k = 1, kids.n or #kids do
        local kid = self:resolve(kids[k])
        if is_dict(kid) then
            if kid.Kids ~= nil then
                local c = tonumber(self:resolve(kid.Count))
                total = total + ((c and c >= 0) and c or self:countPages(kid, depth + 1))
            else
                total = total + 1
            end
        end
    end
    return total
end

--- Find the page dictionary for a 1-based page number, collecting inherited
-- attributes on the way down.
function Pdf:findPage(pageno)
    local root = self:resolve(self.trailer.Root)
    if not is_dict(root) then error("catalog unreadable", 0) end
    local node = self:resolve(root.Pages)
    if not is_dict(node) then error("page tree unreadable", 0) end
    local inherited = {}
    local remaining = pageno
    for _ = 1, 64 do
        for _, key in ipairs(INHERITABLE) do
            if node[key] ~= nil then inherited[key] = node[key] end
        end
        local kids = self:resolve(node.Kids)
        if type(kids) ~= "table" then
            -- a leaf reached directly
            if remaining == 1 then return node, inherited end
            error("page " .. pageno .. " not found", 0)
        end
        local descended = false
        for k = 1, kids.n or #kids do
            local kid = self:resolve(kids[k])
            if is_dict(kid) then
                if kid.Kids ~= nil then
                    local c = tonumber(self:resolve(kid.Count))
                    if not c or c < 0 then c = self:countPages(kid) end
                    if remaining <= c then
                        node = kid
                        descended = true
                        break
                    end
                    remaining = remaining - c
                else
                    if remaining == 1 then
                        for _, key in ipairs(INHERITABLE) do
                            if kid[key] ~= nil then inherited[key] = kid[key] end
                        end
                        return kid, inherited
                    end
                    remaining = remaining - 1
                end
            end
        end
        if not descended then
            error("page " .. pageno .. " not found", 0)
        end
    end
    error("page tree too deep", 0)
end

--- Geometry of a page: { mediabox, cropbox, rotate, userunit } or nil, err.
function Pdf:pageInfo(pageno)
    local cached = self.pages[pageno]
    if cached ~= nil then
        if cached == false then return nil, "unavailable" end
        return cached
    end
    local ok, res = pcall(function()
        local page, inherited = self:findPage(pageno)
        local mediabox = self:toRect(inherited.MediaBox)
        if not mediabox then error("page has no MediaBox", 0) end
        return {
            mediabox = mediabox,
            cropbox = self:toRect(inherited.CropBox),
            rotate = tonumber(self:resolve(inherited.Rotate)) or 0,
            userunit = tonumber(self:resolve(page.UserUnit)) or 1,
        }
    end)
    if not ok then
        self.pages[pageno] = false
        return nil, tostring(res)
    end
    self.pages[pageno] = res
    return res
end

-- ---------------------------------------------------------------------------
-- Page labels
-- ---------------------------------------------------------------------------

local function to_roman(n)
    if n <= 0 or n >= 4000 then return tostring(n) end
    local vals = { 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 }
    local syms = { "m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i" }
    local out = {}
    for k, v in ipairs(vals) do
        while n >= v do
            out[#out + 1] = syms[k]
            n = n - v
        end
    end
    return table.concat(out)
end

local function to_letters(n)
    if n <= 0 then return tostring(n) end
    local letter = string.char(97 + (n - 1) % 26)
    return letter:rep(math.floor((n - 1) / 26) + 1)
end

local function pdf_text(v)
    -- PDF text string -> UTF-8 (UTF-16BE with BOM, or Latin-1-ish)
    if type(v) ~= "table" or not v.str then return "" end
    local s = v.str
    local Util = require("zotero_util")
    if s:sub(1, 2) == "\254\255" then
        local out = {}
        local i = 3
        while i + 1 <= #s do
            local cp = s:byte(i) * 256 + s:byte(i + 1)
            i = i + 2
            if cp >= 0xD800 and cp <= 0xDBFF and i + 1 <= #s then
                local lo = s:byte(i) * 256 + s:byte(i + 1)
                if lo >= 0xDC00 and lo <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    i = i + 2
                end
            end
            out[#out + 1] = Util.utf8Char(cp)
        end
        return table.concat(out)
    end
    if s:sub(1, 3) == "\239\187\191" then
        return s:sub(4)
    end
    local out = {}
    for i = 1, #s do
        out[i] = Util.utf8Char(s:byte(i))
    end
    return table.concat(out)
end

function Pdf:collectLabelRanges(node, out, depth)
    depth = depth or 0
    if depth > 16 then return end
    node = self:resolve(node)
    if not is_dict(node) then return end
    local nums = self:resolve(node.Nums)
    if type(nums) == "table" and nums.n then
        for k = 1, nums.n - 1, 2 do
            local start = tonumber(self:resolve(nums[k]))
            local spec = self:resolve(nums[k + 1])
            if start and is_dict(spec) then
                out[#out + 1] = {
                    start = start,
                    style = self:resolve(spec.S),
                    prefix = pdf_text(self:resolve(spec.P)),
                    first = tonumber(self:resolve(spec.St)) or 1,
                }
            end
        end
    end
    local kids = self:resolve(node.Kids)
    if type(kids) == "table" and kids.n then
        for k = 1, kids.n do
            self:collectLabelRanges(kids[k], out, depth + 1)
        end
    end
end

--- The page label the PDF itself defines for a 1-based page number, or nil
-- when the document has no /PageLabels.
function Pdf:pageLabel(pageno)
    if self.labels == nil then
        self.labels = false
        pcall(function()
            -- strings are encrypted in protected files; labels would be junk
            if self.trailer.Encrypt ~= nil then return end
            local root = self:resolve(self.trailer.Root)
            if is_dict(root) and root.PageLabels ~= nil then
                local ranges = {}
                self:collectLabelRanges(root.PageLabels, ranges)
                if #ranges > 0 then
                    table.sort(ranges, function(a, b) return a.start < b.start end)
                    self.labels = ranges
                end
            end
        end)
    end
    if not self.labels then return nil end
    local idx = pageno - 1
    local range
    for _, r in ipairs(self.labels) do
        if r.start <= idx then range = r else break end
    end
    if not range then return nil end
    local n = range.first + (idx - range.start)
    local numeral = ""
    if range.style == "/D" then numeral = tostring(n)
    elseif range.style == "/r" then numeral = to_roman(n)
    elseif range.style == "/R" then numeral = to_roman(n):upper()
    elseif range.style == "/a" then numeral = to_letters(n)
    elseif range.style == "/A" then numeral = to_letters(n):upper()
    end
    local label = (range.prefix or "") .. numeral
    if label == "" then return nil end
    return label
end

function Pdf:close()
    if self.f then
        self.f:close()
        self.f = nil
    end
end

--- Open a PDF for geometry queries. Returns the object, or nil and a reason.
function Geom.open(path)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open file" end
    local self = setmetatable({
        f = f, path = path, xref = {}, sections = {}, cache = {}, objstm = {}, pages = {}, base = 0,
    }, Pdf)
    local ok, err = pcall(function()
        self.size = f:seek("end")
        if not self.size or self.size < 32 then error("file too small", 0) end
        -- Some files carry junk before the header; offsets are then relative
        -- to the header.
        local head = self:read(0, 1024)
        local hs = head:find("%PDF-", 1, true)
        if not hs then error("not a PDF file", 0) end
        self.base = hs - 1
        local tail_len = math.min(self.size, 2048)
        local tail = self:read(self.size - tail_len, tail_len)
        local startxref
        for v in tail:gmatch("startxref[%z\t\n\f\r ]+(%d+)") do
            startxref = tonumber(v)
        end
        if not startxref then error("startxref not found", 0) end
        self:loadXref(startxref)
    end)
    if not ok then
        self:close()
        return nil, tostring(err)
    end
    return self
end

Geom.NULL = NULL

return Geom
