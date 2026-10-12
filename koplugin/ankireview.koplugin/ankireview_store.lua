--[[--
Files in the Syncthing exchange folder, as seen from the Kindle.

  pack/pack.json, pack/media/*   written by Anki Desktop (read-only here)
  pack/cards-<pack_id>.bin       format 2: the cards' HTML, sliced by byte offsets stored in pack.json
  ack.json                       written by Anki Desktop: which of our answers it applied or skipped
  reviews/<session>.jsonl        written here: one JSON answer per line, rewritten atomically per answer
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")
local util = require("util")

local Store = {}
Store.__index = Store

local SUPPORTED_FORMATS = { [1] = true, [2] = true }

-- Parsed packs, kept at module level so they survive the plugin being re-created (file manager <-> reader).
-- [pack_path] = { mtime =, pack = } for the pack in use, plus `waiting` = { mtime =, pack = } for a newer
-- pack.json whose cards file hasn't arrived yet.
local pack_cache = {}

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Write via <path>.tmp + rename: Syncthing ignores *.tmp, so it never syncs a half-written file.
local function atomicWrite(path, data)
    local tmp = path .. ".tmp"
    local ok, err = util.writeToFile(data, tmp, true)
    if not ok then return nil, err end
    return os.rename(tmp, path)
end

function Store.new(folder, device_id)
    local self = setmetatable({ folder = folder, device_id = device_id }, Store)
    self.reviews_dir = folder .. "/reviews"
    self.pack_dir = folder .. "/pack"
    self.media_dir = folder .. "/pack/media"
    self.pack_path = folder .. "/pack/pack.json"
    self.rev = 0 -- bumped whenever this device's review logs change
    return self
end

function Store:packExists()
    return lfs.attributes(self.pack_path, "mode") == "file"
end

-- Path of a format-2 pack's cards file, and whether it is complete; nil when the pack is invalid.
local function cardsFile(pack_dir, pack)
    local name = pack.cards_file
    if type(name) ~= "string" or name == "" or name:find("[/\\]") or name:find("^%.") then return nil end
    local path = pack_dir .. "/" .. name
    local size = lfs.attributes(path, "size")
    if not size then return path, false end
    local need = 0
    for _, c in ipairs(pack.cards) do
        local e = math.max((c.qo or 0) + (c.ql or 0), (c.ao or 0) + (c.al or 0))
        if e > need then need = e end
    end
    return path, size >= need
end

--- Decoded pack.json (cached until the file changes), or nil + error code + detail.
--- Error codes: "missing" (no pack yet), "format" (unsupported format), "syncing" (cards file not here yet),
--- "corrupt" (unreadable JSON, e.g. still being written).
--- If a newer pack.json can't be used yet (cards file still syncing, unreadable, unknown format), the pack
--- already in use stays in use and self.pack_waiting is set to the error code.
function Store:loadPack()
    local path = self.pack_path
    local mtime = lfs.attributes(path, "modification")
    local cache = pack_cache[path]
    self.pack_waiting = false
    if not mtime then
        return nil, "missing"
    end
    if cache and cache.mtime == mtime then return cache.pack end
    cache = cache or {}
    pack_cache[path] = cache
    local candidate
    if cache.waiting and cache.waiting.mtime == mtime then
        candidate = cache.waiting.pack
    else
        -- a pack.json that failed is not decoded again until it changes
        local failed = cache.failed
        if not (failed and failed.mtime == mtime) then
            failed = nil
            local pack, err = rapidjson.load(path)
            if type(pack) ~= "table" or type(pack.cards) ~= "table" then
                logger.warn("ankireview: cannot read pack:", err)
                failed = { mtime = mtime, code = "corrupt", detail = tostring(err) }
            elseif not SUPPORTED_FORMATS[pack.format] then
                failed = { mtime = mtime, code = "format", detail = tostring(pack.format) }
            elseif pack.format == 2 then
                pack._bin_path = cardsFile(self.pack_dir, pack)
                if not pack._bin_path then failed = { mtime = mtime, code = "corrupt", detail = "bad cards_file" } end
            end
            cache.failed = failed
            candidate = not failed and pack or nil
        end
        if failed then
            -- e.g. a half-synced or newer-format pack: keep using the one we have, if any
            if cache.pack then self.pack_waiting = failed.code; return cache.pack end
            return nil, failed.code, failed.detail
        end
    end
    if candidate.format == 2 then
        local _, ready = cardsFile(self.pack_dir, candidate)
        if not ready then
            -- Syncthing delivered pack.json before the cards file: keep the old pack until it arrives
            cache.waiting = { mtime = mtime, pack = candidate }
            if cache.pack then self.pack_waiting = "syncing"; return cache.pack end
            return nil, "syncing"
        end
    end
    pack_cache[path] = { mtime = mtime, pack = candidate }
    return candidate
end

--- Question and answer HTML of a card (of `pack`, default: the pack loaded last).
--- Returns "", "" + error if a format-2 cards file can't be read.
function Store:cardHtml(card, pack)
    pack = pack or (pack_cache[self.pack_path] or {}).pack
    if not pack or pack.format ~= 2 then return card.q or "", card.a or "" end
    local f, err = io.open(pack._bin_path, "rb")
    if not f then
        logger.warn("ankireview: cannot open cards file:", err)
        return "", "", err
    end
    local function slice(off, len)
        if not off or not len or len <= 0 then return "" end
        f:seek("set", off)
        return f:read(len) or ""
    end
    local q, a = slice(card.qo, card.ql), slice(card.ao, card.al)
    f:close()
    return q, a
end

--- Parsed ack.json (cached until the file changes), and its mtime.
function Store:loadAck()
    local path = self.folder .. "/ack.json"
    local mtime = lfs.attributes(path, "modification")
    if self._ack and self._ack_mtime == mtime then return self._ack, mtime end
    local data = mtime and readFile(path)
    local ok, ack = pcall(rapidjson.decode, data or "")
    if not ok or type(ack) ~= "table" then ack = {} end
    local applied, skipped = {}, {}
    for _, id in ipairs(type(ack.applied) == "table" and ack.applied or {}) do applied[id] = true end
    for id, reason in pairs(type(ack.skipped) == "table" and ack.skipped or {}) do skipped[id] = reason end
    self._ack = { applied = applied, skipped = skipped, updated_at = ack.updated_at }
    self._ack_mtime = mtime
    return self._ack, mtime
end

--- All answers recorded on this device: list of entries, and {file = {entries}}.
--- Cached until this store writes or deletes a log (or the reviews folder changes).
function Store:loadEntries()
    local dir_mtime = lfs.attributes(self.reviews_dir, "modification")
    if self._entries and self._entries_rev == self.rev and self._entries_mtime == dir_mtime then
        return self._entries, self._entries_by_file
    end
    local all, by_file = {}, {}
    if lfs.attributes(self.reviews_dir, "mode") == "directory" then
        for name in lfs.dir(self.reviews_dir) do
            if name:match("%.jsonl$") then
                local data = readFile(self.reviews_dir .. "/" .. name) or ""
                local list = {}
                for line in data:gmatch("[^\n]+") do
                    local ok, e = pcall(rapidjson.decode, line)
                    if ok and type(e) == "table" and e.id then
                        table.insert(list, e)
                        table.insert(all, e)
                    end
                end
                by_file[name] = list
            end
        end
    end
    self._entries, self._entries_by_file, self._entries_rev, self._entries_mtime = all, by_file, self.rev, dir_mtime
    return all, by_file
end

--- Entries the scheduler should replay locally: not applied in the pack, not skipped by the PC.
function Store:pendingEntries(pack, ack)
    local applied = {}
    for _, id in ipairs(pack.applied or {}) do applied[id] = true end
    local out = {}
    for _, e in ipairs((self:loadEntries())) do
        if not applied[e.id] and not ack.skipped[e.id] then table.insert(out, e) end
    end
    return out
end

--- Per-deck and total counts of cards available now, memoized on (pack, ack, local answers, minute).
--- Returns per, total, pack — or nil + error code + detail when there is no usable pack.
function Store:counts(now)
    local pack, err, detail = self:loadPack()
    if not pack then return nil, err, detail end
    local ack, ack_mtime = self:loadAck()
    local key = string.format("%s|%s|%d|%d", tostring(pack), tostring(ack_mtime), self.rev, math.floor(now / 60))
    if self._counts_key ~= key then
        local Scheduler = require("ankireview_scheduler")
        local per, total = Scheduler.new(pack, self:pendingEntries(pack, ack)):counts(now)
        self._counts_key, self._counts = key, { per = per, total = total }
    end
    return self._counts.per, self._counts.total, pack
end

function Store:startSession()
    util.makePath(self.reviews_dir)
    self.session = string.format("%s-%s", self.device_id, os.date("!%Y%m%dT%H%M%S"))
    self.session_entries = {}
    self.seq = 0
end

function Store:_writeSession()
    self.rev = self.rev + 1
    local lines = {}
    for _, e in ipairs(self.session_entries) do table.insert(lines, rapidjson.encode(e)) end
    local path = self.reviews_dir .. "/" .. self.session .. ".jsonl"
    if #lines == 0 then
        os.remove(path)
        return true
    end
    return atomicWrite(path, table.concat(lines, "\n") .. "\n")
end

function Store:append(entry)
    self.seq = self.seq + 1
    entry.id = string.format("%s-%d", self.session, self.seq)
    table.insert(self.session_entries, entry)
    local ok, err = self:_writeSession()
    if not ok then
        table.remove(self.session_entries)
        return nil, err
    end
    return entry
end

--- The last answer of this session, if it can still be undone (the PC hasn't applied it yet).
function Store:lastUndoable(ack)
    local last = self.session_entries and self.session_entries[#self.session_entries]
    if last and not ack.applied[last.id] and not ack.skipped[last.id] then return last end
end

function Store:canUndo(ack)
    return self:lastUndoable(ack) ~= nil
end

--- Remove the last answer of this session; returns the removed entry (or nil).
function Store:undo()
    local last = self.session_entries and table.remove(self.session_entries)
    if not last then return nil end
    self:_writeSession()
    return last
end

--- Delete review logs whose answers the pack already reflects (or the PC rejected). Never the current session.
function Store:cleanup(pack, ack)
    local applied = {}
    for _, id in ipairs(pack.applied or {}) do applied[id] = true end
    local _, by_file = self:loadEntries()
    local removed = 0
    for name, list in pairs(by_file) do
        if not (self.session and name == self.session .. ".jsonl") then
            local done = true
            for _, e in ipairs(list) do
                if not applied[e.id] and not ack.skipped[e.id] then done = false; break end
            end
            if done then
                os.remove(self.reviews_dir .. "/" .. name)
                removed = removed + 1
            end
        end
    end
    if removed > 0 then self.rev = self.rev + 1 end
    return removed
end

--- Friendly explanation for a loadPack() error code.
function Store.errorText(code, detail, folder)
    local _ = require("gettext")
    local T = require("ffi/util").template
    if code == "missing" then
        return T(_("No card pack yet in %1.\n\nShare the 'anki-kindle' Syncthing folder with this Kindle and let Anki Desktop (with the Kindle review add-on) run once."), folder)
    elseif code == "syncing" then
        return _("Cards are still syncing from the PC. Try again in a minute.")
    elseif code == "format" then
        return T(_("This card pack uses a format this plugin doesn't know (%1). Update the plugin or the Anki add-on so both are current."), tostring(detail))
    end
    return T(_("The card pack could not be read (%1). It may still be syncing from the PC; try again in a minute."), tostring(detail))
end

--- Anki days since the pack was made (0 = made today).
function Store.packAge(pack, now)
    local Scheduler = require("ankireview_scheduler")
    return math.max(0, Scheduler.ankiDay(pack, now) - pack.today)
end

return Store
