--[[--
Reading position sync.

Zotero keeps, per attachment, where it was last read: a synced setting
"lastPageIndex_u_<key>" whose value is the page index (PDF, counted from 0)
or a CFI to the first visible text (EPUB). Its own apps apply that value when
they open the document and write it when the page changes. There are no
timestamps: whoever wrote last is where the document opens.

Here:

  * a position that arrived from Zotero and was not seen before is applied
    when the document is opened (or at once, if it is open during the sync):
    the reader jumps there and the previous place goes onto its "back" stack;
  * the reader's own position is sent with a sync, if it changed since the
    last one and Zotero's did not;
  * the first time a document meets a Zotero position, the reader keeps its
    own place if it has one (it is not at the beginning).

What is remembered per document (in its settings, "zotero_position"):

    seen     version of the Zotero setting last applied or written
    sent     the reader's position when the two last agreed
    cfi      (EPUB) Zotero form of the position `cfi_xp`, worked out while
    cfi_xp   the book was open, so that it can be sent when it is closed
]]

local DocSettings = require("docsettings")
local Epub = require("zotero_epub")
local Event = require("ui/event")
local ZoteroAPI = require("zoteroapi")
local logger = require("logger")

local Position = { fork = "0.6" }

local STATE_KEY = "zotero_position"

function Position.enabled()
    local settings = ZoteroAPI.getSettings()
    return settings ~= nil and settings:readSetting("sync_reading_position") ~= false
end

--- Reading positions are synced for PDF and EPUB. (For a web snapshot Zotero
-- keeps how far the page was scrolled, which has no counterpart here.)
local function supported(ui)
    local file = ui and ui.document and ui.document.file
    if type(file) ~= "string" then return false end
    local lower = file:lower()
    return lower:match("%.pdf$") ~= nil or lower:match("%.epub$") ~= nil
end

local function is_pdf(path)
    return type(path) == "string" and path:lower():match("%.pdf$") ~= nil
end

local function is_epub(path)
    return type(path) == "string" and path:lower():match("%.epub$") ~= nil
end

local function copy_state(st)
    local out = {}
    if type(st) == "table" then
        for k, v in pairs(st) do out[k] = v end
    end
    return out
end

local function same_state(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

-- ---------------------------------------------------------------------------
-- The open document
-- ---------------------------------------------------------------------------

--- The reader's position: a page number (PDF) or an xpointer (EPUB).
local function current(ui)
    if ui.paging then
        local ok, page = pcall(function() return ui.paging:getTopPage() end)
        page = ok and tonumber(page) or tonumber(ui.paging.current_page)
        return page
    elseif ui.rolling then
        -- what the reader itself saves as the place the book was closed at
        local xp = ui.rolling.xpointer
        if type(xp) == "string" and xp ~= "" then return xp end
        local ok, res = pcall(function() return ui.document:getXPointer() end)
        if ok and type(res) == "string" and res ~= "" then return res end
    end
    return nil
end

local function page_of(ui, pos)
    if ui.paging then return tonumber(pos) end
    local ok, page = pcall(ui.document.getPageFromXPointer, ui.document, pos)
    return ok and tonumber(page) or nil
end

--- The same place for the purpose of "did the reader move"? In a book that
-- is laid out anew for every screen and font, a page is as exact as it gets.
local function same_place(ui, a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    if ui.rolling and type(a) == "string" and type(b) == "string" then
        local pa, pb = page_of(ui, a), page_of(ui, b)
        return pa ~= nil and pa == pb
    end
    return false
end

--- Is the reader at the very beginning (no place of its own yet)?
local function at_start(ui, pos)
    local page = page_of(ui, pos)
    return page == nil or page <= 1
end

--- Zotero value -> a position of the open document. @return position or nil
local function to_local(ui, value, session)
    if ui.paging then
        if type(value) ~= "number" or value ~= math.floor(value) or value < 0 then return nil end
        local pages = tonumber(ui.document:getPageCount()) or 0
        local page = value + 1
        if page > pages then return nil end
        return page
    elseif ui.rolling then
        if type(value) ~= "string" then return nil end
        if value == "_start" then
            local ok, xp = pcall(ui.document.getPageXPointer, ui.document, 1)
            return ok and xp or nil
        end
        local ok, xp, how = pcall(session.pointFromCfi, session, value)
        if not ok then
            logger.warn("Zotero: reading position not understood:", tostring(xp))
            return nil
        end
        return xp, how
    end
    return nil
end

--- A position of the open document -> Zotero value. @return value or nil
local function to_remote(ui, pos, session)
    if ui.paging then
        local page = tonumber(pos)
        return page and page >= 1 and (page - 1) or nil
    elseif ui.rolling then
        local ok, cfi, err = pcall(session.cfiFromXPointer, session, pos)
        if not ok then
            logger.warn("Zotero: reading position not convertible:", tostring(cfi))
            return nil
        end
        if not cfi then logger.dbg("Zotero: reading position not convertible:", tostring(err)) end
        return cfi
    end
    return nil
end

local function go_to(ui, pos)
    if ui.link and ui.link.addCurrentLocationToStack then
        ui.link:addCurrentLocationToStack() -- "back" returns to where the reader was
    end
    if ui.paging then
        ui:handleEvent(Event:new("GotoPage", pos))
    else
        ui:handleEvent(Event:new("GotoXPointer", pos, pos))
    end
end

local function new_session(ui)
    if ui.rolling then return Epub.newSession(ui.document) end
    return nil
end

--- Apply a position that came from Zotero to the open document.
-- No network.
-- @param stay  take note of Zotero's position without going there (the
--              reader is being sent somewhere else on purpose)
-- @return page number jumped to, or nil
function Position.apply(ui, key, stay)
    if not Position.enabled() or not ui or not ui.document or not key or not supported(ui) then return nil end
    local value, version = ZoteroAPI.getRemotePosition(key)
    if value == nil then return nil end
    local ds = ui.doc_settings
    local before = copy_state(ds:readSetting(STATE_KEY))
    local st = copy_state(before)
    if st.seen == version then return nil end -- nothing new from Zotero

    local here = current(ui)
    local jumped
    if stay then
        st.seen = version
    elseif st.seen == nil and st.sent == nil and not at_start(ui, here) then
        -- first contact, and the reader has a place of its own: it stays
        st.seen = version
        st.sent = here
    else
        local session = new_session(ui)
        local target, how = to_local(ui, value, session)
        if session then session:close() end
        if target and how == "chapter" and Epub.fragmentNumber(target) == Epub.fragmentNumber(here) then
            -- only the chapter could be found, and the reader is in it already
            target = nil
        end
        st.seen = version
        if target and page_of(ui, target) and page_of(ui, target) ~= page_of(ui, here) then
            go_to(ui, target)
            jumped = page_of(ui, target)
            st.sent = current(ui) or target
        else
            st.sent = here -- already there, or a position this copy cannot show
        end
    end
    if not same_state(st, before) then ds:saveSetting(STATE_KEY, st) end
    return jumped
end

--- Send the open document's position to Zotero, if it changed here and not
-- there. @return "sent" | "unchanged" | "newer" | "skipped" | "failed"
function Position.pushOpen(ui, key)
    if not Position.enabled() or not ui or not ui.document or not key or not supported(ui) then return "skipped" end
    local ds = ui.doc_settings
    local before = copy_state(ds:readSetting(STATE_KEY))
    local st = copy_state(before)
    local value, version = ZoteroAPI.getRemotePosition(key)
    if value ~= nil and st.seen ~= version then return "newer" end -- applied when opened
    local here = current(ui)
    if here == nil then return "skipped" end
    if same_place(ui, st.sent, here) then return "unchanged" end
    if value == nil and at_start(ui, here) then return "skipped" end -- never read here
    local session = new_session(ui)
    local out = to_remote(ui, here, session)
    if session then session:close() end
    if out == nil then return "skipped" end
    local result = "unchanged"
    if out ~= value then
        local new_version, err = ZoteroAPI.putRemotePosition(key, out, version or 0)
        if not new_version then
            logger.info("Zotero: reading position not sent:", tostring(err))
            return err == 412 and "newer" or "failed"
        end
        st.seen = new_version
        result = "sent"
    end
    st.sent = here
    if ui.rolling then st.cfi, st.cfi_xp = out, here end
    if not same_state(st, before) then ds:saveSetting(STATE_KEY, st) end
    return result
end

--- While an EPUB is still open: work out the Zotero form of the position it
-- is closed at, so that a later sync can send it without opening the book.
function Position.cacheOnClose(ui, key)
    if not Position.enabled() or not ui or not ui.rolling or not ui.document or not key or not supported(ui) then return false end
    local here = current(ui)
    if not here then return false end
    local ds = ui.doc_settings
    local st = copy_state(ds:readSetting(STATE_KEY))
    if st.cfi_xp == here or st.sent == here then return false end
    if at_start(ui, here) and ZoteroAPI.getRemotePosition(key) == nil then return false end -- never read
    if same_place(ui, st.sent, here) then
        -- still on the page the two sides agreed on: nothing to send later
        st.sent = here
        ds:saveSetting(STATE_KEY, st)
        return true
    end
    local session = new_session(ui)
    local out = to_remote(ui, here, session)
    session:close()
    if not out then return false end
    st.cfi, st.cfi_xp = out, here
    ds:saveSetting(STATE_KEY, st)
    return true
end

-- ---------------------------------------------------------------------------
-- A closed document: its sidecar file
-- ---------------------------------------------------------------------------

--- Send a closed document's position. Positions from Zotero are not written
-- into a closed document: they are applied when it is opened, where the
-- reader can keep the previous place.
-- @return "sent" | "unchanged" | "newer" | "skipped" | "failed"
function Position.pushClosed(key, path)
    if not Position.enabled() or not key or not path then return "skipped" end
    if not DocSettings:hasSidecarFile(path) then return "skipped" end -- never opened here
    local ds = DocSettings:open(path)
    local before = copy_state(ds:readSetting(STATE_KEY))
    local st = copy_state(before)
    local value, version = ZoteroAPI.getRemotePosition(key)
    local here, out
    if is_pdf(path) then
        here = tonumber(ds:readSetting("last_page"))
        if here and here >= 1 then out = here - 1 end
    elseif is_epub(path) then
        here = ds:readSetting("last_xpointer")
        if type(here) ~= "string" then here = nil end
        -- the Zotero form of an EPUB position can only be worked out while
        -- the book is open; it is left in the settings when the book is closed
        if here and st.cfi_xp == here and type(st.cfi) == "string" then out = st.cfi end
    end
    if value ~= nil and st.seen ~= version then
        if out ~= nil and out == value then
            -- the same place on both sides (for instance our own upload, whose
            -- answer was lost): nothing to do, now or when the document opens
            st.seen, st.sent = version, here
            ds:saveSetting(STATE_KEY, st)
            ds:flush()
            return "unchanged"
        end
        return "newer" -- applied when the document is opened
    end
    if here == nil then return "skipped" end
    if st.sent == here then return "unchanged" end
    if out == nil then return "skipped" end
    if value == nil and is_pdf(path) and here <= 1 then return "skipped" end -- never read here
    local result = "unchanged"
    if out ~= value then
        local new_version, err = ZoteroAPI.putRemotePosition(key, out, version or 0)
        if not new_version then
            logger.info("Zotero: reading position not sent:", tostring(err))
            return err == 412 and "newer" or "failed"
        end
        st.seen = new_version
        result = "sent"
    end
    st.sent = here
    if not same_state(st, before) then
        ds:saveSetting(STATE_KEY, st)
        ds:flush()
    end
    return result
end

--- One document's part of a sync the user started.
-- @param ui       the ReaderUI, if this is the open document
-- @param can_push false: nothing is sent (offline, read-only key)
-- @return what happened to the reader's position ("sent", ...; nil if nothing
--         was tried), and the page the open document went to, if it did
function Position.sync(ui, key, path, is_open, can_push)
    local result, went
    if is_open then
        went = Position.apply(ui, key)
        if can_push then result = Position.pushOpen(ui, key) end
    elseif can_push then
        result = Position.pushClosed(key, path)
    end
    return result, went
end

return Position
