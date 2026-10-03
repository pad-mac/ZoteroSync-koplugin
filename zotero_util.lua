--[[--
Small helpers shared by the Zotero Atelier modules: JSON handling that copes
with `null`, UTF-8/UTF-16 arithmetic, text normalisation for matching,
timestamps, hashing and Zotero key generation.

Nothing in here touches the network or the database.
]]

local JSON = require("json")
local logger = require("logger")

local Util = { fork = "0.6" }

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------

-- KOReader's `json` module decodes JSON `null` to a sentinel *function*
-- (and rapidjson to a userdata). Both are truthy, so `item.data.x or default`
-- silently picks the sentinel. Strip them right after decoding.
local function strip_nulls(v, depth)
    if type(v) ~= "table" then return v end
    depth = depth or 0
    if depth > 64 then return v end
    for k, val in pairs(v) do
        local tv = type(val)
        if tv == "function" or tv == "userdata" then
            v[k] = nil
        elseif tv == "table" then
            strip_nulls(val, depth + 1)
        end
    end
    return v
end
Util.stripNulls = strip_nulls

--- Decode JSON. Returns `value` or `nil, err`. Never throws.
function Util.jsonDecode(s)
    if type(s) ~= "string" or s == "" then
        return nil, "empty JSON"
    end
    local ok, v = pcall(JSON.decode, s)
    if not ok then
        return nil, tostring(v)
    end
    if v == nil then
        return nil, "undecodable JSON"
    end
    local tv = type(v)
    if tv == "function" or tv == "userdata" then
        return nil, "JSON null"
    end
    return strip_nulls(v)
end

--- Encode JSON. Returns `string` or `nil, err`. Never throws.
function Util.jsonEncode(v)
    local ok, s = pcall(JSON.encode, v)
    if not ok then
        return nil, tostring(s)
    end
    return s
end

--- Escape a Lua string as a JSON string literal (with quotes), without the
-- `\/` escaping KOReader's encoder applies. Used for hand-built payloads
-- whose exact form matters (annotation positions).
function Util.jsonString(s)
    s = tostring(s or "")
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. s .. '"'
end

--- Format a coordinate the way Zotero does: at most 3 decimals, no trailing
-- zeros, never NaN/inf.
function Util.fmtNumber(n)
    if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
        return "0"
    end
    local s = string.format("%.3f", n)
    if s:find(".", 1, true) then
        s = s:gsub("0+$", ""):gsub("%.$", "")
    end
    if s == "-0" then s = "0" end
    return s
end

-- ---------------------------------------------------------------------------
-- Hashing
-- ---------------------------------------------------------------------------

local sha2
local function md5(s)
    if sha2 == nil then
        local ok, mod = pcall(require, "ffi/sha2")
        sha2 = ok and mod or false
    end
    if sha2 and sha2.md5 then
        return sha2.md5(s)
    end
    -- Fallback: a simple, stable (non-cryptographic) hash. Only used to
    -- detect "has this text changed", so collisions are merely unlucky.
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 31 + b) % 4294967291
    end
    return string.format("%08x%08x", h1, h2)
end

--- Short stable fingerprint of a string (16 hex chars).
function Util.hash(s)
    return md5(tostring(s or "")):sub(1, 16)
end

-- ---------------------------------------------------------------------------
-- UTF-8 / UTF-16
-- ---------------------------------------------------------------------------

--- Byte length of the UTF-8 sequence starting with byte `b`.
local function seq_len(b)
    if b < 0x80 then return 1 end
    if b >= 0xF0 then return 4 end
    if b >= 0xE0 then return 3 end
    if b >= 0xC0 then return 2 end
    return 1 -- stray continuation byte: treat as one unit
end
Util.utf8SeqLen = seq_len

--- Number of code points.
function Util.utf8Len(s)
    local n, i, len = 0, 1, #s
    while i <= len do
        i = i + seq_len(s:byte(i))
        n = n + 1
    end
    return n
end

--- Number of UTF-16 code units (astral code points count twice).
function Util.utf16Len(s)
    local n, i, len = 0, 1, #s
    while i <= len do
        local l = seq_len(s:byte(i))
        n = n + (l == 4 and 2 or 1)
        i = i + l
    end
    return n
end

--- Byte index (1-based) of the code point at 0-based code point offset `cp`.
-- Returns #s + 1 when `cp` is at or past the end.
function Util.utf8ByteIndex(s, cp)
    local i, len = 1, #s
    while cp > 0 and i <= len do
        i = i + seq_len(s:byte(i))
        cp = cp - 1
    end
    return i
end

--- Byte index (1-based) for a 0-based UTF-16 offset.
function Util.utf16ByteIndex(s, units)
    local i, len = 1, #s
    while units > 0 and i <= len do
        local l = seq_len(s:byte(i))
        units = units - (l == 4 and 2 or 1)
        i = i + l
    end
    return i
end

--- Encode a code point as UTF-8.
function Util.utf8Char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return "\239\191\189" -- U+FFFD
end

-- ---------------------------------------------------------------------------
-- Text normalisation (for matching the same passage across two text
-- extractors that disagree on spacing, hyphenation and ligatures)
-- ---------------------------------------------------------------------------

-- NFKC + case folding through utf8proc. KOReader's own wrapper passes the C
-- result straight to ffi.string(), which dereferences NULL when the input is
-- not valid UTF-8, so call the library directly and check the pointer.
local utf8proc_lib
local function casefold(s)
    if utf8proc_lib == nil then
        utf8proc_lib = false
        local ok = pcall(function()
            local ffi = require("ffi")
            require("ffi/posix_h")
            require("ffi/utf8proc_h")
            utf8proc_lib = { ffi = ffi, lib = ffi.loadlib("utf8proc", "3") }
        end)
        if not ok then utf8proc_lib = false end
    end
    if utf8proc_lib then
        local ok, r = pcall(function()
            local ffi = utf8proc_lib.ffi
            local p = utf8proc_lib.lib.utf8proc_NFKC_Casefold(s)
            if p == nil then return nil end
            local out = ffi.string(p)
            ffi.C.free(p)
            return out
        end)
        if ok and type(r) == "string" then return r end
    end
    return s:lower()
end

-- Multi-byte characters that are separators/punctuation rather than text.
local DROP = {
    ["\194\160"] = true, -- NBSP
    ["\194\173"] = true, -- soft hyphen
    ["\194\171"] = true, ["\194\187"] = true, -- « »
    ["\194\183"] = true, -- middle dot
    ["\239\187\191"] = true, -- BOM
    ["\227\128\128"] = true, -- ideographic space
}

--- Reduce text to a comparable stream: case-folded, compatibility-normalised
-- (ligatures expanded), with all whitespace, ASCII punctuation, dashes and
-- quote marks removed.
function Util.normText(s)
    if not s or s == "" then return "" end
    s = casefold(s)
    local out, n = {}, 0
    local i, len = 1, #s
    while i <= len do
        local b = s:byte(i)
        if b < 0x80 then
            -- keep ASCII letters and digits only
            if (b >= 48 and b <= 57) or (b >= 97 and b <= 122) or (b >= 65 and b <= 90) then
                n = n + 1
                out[n] = string.char(b)
            end
            i = i + 1
        else
            local l = seq_len(b)
            local ch = s:sub(i, i + l - 1)
            local drop = DROP[ch]
            if not drop and l == 3 and b == 0xE2 then
                -- U+2000..U+206F general punctuation (spaces, dashes, quotes)
                local b2 = s:byte(i + 1)
                if b2 == 0x80 or b2 == 0x81 then drop = true end
            end
            if not drop then
                n = n + 1
                out[n] = ch
            end
            i = i + l
        end
    end
    return table.concat(out)
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

--- Do two normalised strings (see normText) describe the same passage? They
-- may differ by a partially selected word at either end (Zotero selects
-- characters, KOReader whole words), but not by more than that. An empty
-- string matches anything: there is nothing to compare against.
function Util.samePassage(a, b)
    if a == "" or b == "" then return true end
    if a == b then return true end
    local short, long = a, b
    if #short > #long then short, long = long, short end
    local slack = math.max(30, math.floor(#long * 0.1))
    if #long - #short > slack then return false end
    if long:find(short, 1, true) then return true end
    local need = math.max(3, math.min(12, math.floor(#short * 0.4)))
    return common_prefix(a, b) >= need and common_suffix(a, b) >= need
end

--- Replace bytes that are not valid UTF-8 by U+FFFD (the Zotero server
-- rejects a whole upload over one bad byte) and drop NUL bytes.
function Util.fixUtf8(s)
    if type(s) ~= "string" then return "" end
    if not s:find("[%z\128-\255]") then return s end
    local out, n = {}, 0
    local i, len = 1, #s
    while i <= len do
        local b = s:byte(i)
        local l = 0
        if b == 0 then
            l = -1
        elseif b < 0x80 then
            l = 1
        elseif b >= 0xC2 and b <= 0xDF then
            l = 2
        elseif b >= 0xE0 and b <= 0xEF then
            l = 3
        elseif b >= 0xF0 and b <= 0xF4 then
            l = 4
        end
        local ok = l > 0 and i + l - 1 <= len
        if ok and l > 1 then
            for j = i + 1, i + l - 1 do
                local c = s:byte(j)
                if c < 0x80 or c > 0xBF then ok = false break end
            end
            if ok then
                local b2 = s:byte(i + 1)
                if (b == 0xE0 and b2 < 0xA0) or (b == 0xED and b2 > 0x9F)
                    or (b == 0xF0 and b2 < 0x90) or (b == 0xF4 and b2 > 0x8F) then
                    ok = false -- overlong form, surrogate, or beyond U+10FFFF
                end
            end
        end
        n = n + 1
        if ok then
            out[n] = s:sub(i, i + l - 1)
            i = i + l
        elseif l == -1 then
            out[n] = ""
            i = i + 1
        else
            out[n] = "\239\191\189"
            i = i + 1
        end
    end
    return table.concat(out)
end

--- True for the ASCII whitespace characters that crengine and browsers
-- collapse (space, tab, LF, CR, FF).
function Util.isAsciiSpace(b)
    return b == 32 or b == 9 or b == 10 or b == 13 or b == 12
end

--- Collapse whitespace runs to single spaces and trim.
function Util.cleanText(s)
    if not s then return "" end
    return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- ---------------------------------------------------------------------------
-- Timestamps. KOReader stores local time "YYYY-MM-DD HH:MM:SS"; Zotero stores
-- UTC "YYYY-MM-DDTHH:MM:SSZ".
-- ---------------------------------------------------------------------------

local function parse_fields(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, se = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
    if not y then return nil end
    return {
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
    }
end

--- Epoch seconds for a KOReader local timestamp, or nil.
function Util.localToEpoch(s)
    local t = parse_fields(s)
    if not t then return nil end
    -- isdst left nil: let the C library decide.
    local ok, e = pcall(os.time, t)
    if ok then return e end
    return nil
end

--- Epoch seconds for a Zotero UTC timestamp, or nil.
function Util.utcToEpoch(s)
    local t = parse_fields(s)
    if not t then return nil end
    -- Days-from-civil (Howard Hinnant), no dependence on the local zone.
    local y, m, d = t.year, t.month, t.day
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + t.hour * 3600 + t.min * 60 + t.sec
end

--- KOReader local timestamp -> Zotero UTC timestamp (nil if unparsable).
function Util.localToUtcIso(s)
    local e = Util.localToEpoch(s)
    if not e then return nil end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", e)
end

--- Zotero UTC timestamp -> KOReader local timestamp (nil if unparsable).
function Util.utcIsoToLocal(s)
    local e = Util.utcToEpoch(s)
    if not e then return nil end
    return os.date("%Y-%m-%d %H:%M:%S", e)
end

function Util.nowLocal()
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- ---------------------------------------------------------------------------
-- Zotero item keys
-- ---------------------------------------------------------------------------

local KEY_CHARS = "23456789ABCDEFGHIJKLMNPQRSTUVWXYZ"
local key_counter = 0
local seeded = false

--- True if `key` is a syntactically valid Zotero object key.
function Util.isValidKey(key)
    return type(key) == "string" and #key == 8 and key:match("^[23456789ABCDEFGHIJKLMNPQRSTUVWXYZ]+$") ~= nil
end

--- A new random 8-character Zotero key. Generating the key on the device (and
-- storing it before the upload) makes creation idempotent: a retry after a
-- lost response cannot create a duplicate.
function Util.newItemKey()
    local bytes
    local f = io.open("/dev/urandom", "rb")
    if f then
        bytes = f:read(8)
        f:close()
    end
    local out = {}
    if bytes and #bytes == 8 then
        for i = 1, 8 do
            -- 256 mod 33 leaves a small bias; irrelevant for collision purposes.
            local idx = bytes:byte(i) % #KEY_CHARS + 1
            out[i] = KEY_CHARS:sub(idx, idx)
        end
    else
        if not seeded then
            seeded = true
            math.randomseed(os.time() + math.floor(os.clock() * 1000000))
        end
        key_counter = key_counter + 1
        for i = 1, 8 do
            local idx = math.random(#KEY_CHARS)
            out[i] = KEY_CHARS:sub(idx, idx)
        end
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Misc
-- ---------------------------------------------------------------------------

function Util.copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = type(v) == "table" and Util.copy(v) or v
    end
    return out
end

--- Run `fn` under pcall and log failures with a tag; returns ok, ...
function Util.try(tag, fn, ...)
    local res = { pcall(fn, ...) }
    if not res[1] then
        logger.warn("Zotero:", tag, "failed:", tostring(res[2]))
    end
    return unpack(res)
end

return Util
