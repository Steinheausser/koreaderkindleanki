--[[--
Files in the Syncthing exchange folder, as seen from the Kindle.

  pack/pack.json, pack/media/*   written by Anki Desktop (read-only here)
  ack.json                       written by Anki Desktop: which of our answers it applied or skipped
  reviews/<session>.jsonl        written here: one JSON answer per line, rewritten atomically per answer
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")
local util = require("util")

local Store = {}
Store.__index = Store

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
    self.media_dir = folder .. "/pack/media"
    self.pack_path = folder .. "/pack/pack.json"
    return self
end

function Store:packExists()
    return lfs.attributes(self.pack_path, "mode") == "file"
end

--- Decoded pack.json (cached until the file changes), or nil + error.
function Store:loadPack()
    local mtime = lfs.attributes(self.pack_path, "modification")
    if not mtime then return nil, "no pack" end
    if self._pack and self._pack_mtime == mtime then return self._pack end
    local pack, err = rapidjson.load(self.pack_path)
    if not pack then
        logger.warn("ankireview: cannot read pack:", err)
        return nil, err
    end
    if pack.format ~= 1 then return nil, "unsupported pack format " .. tostring(pack.format) end
    self._pack, self._pack_mtime = pack, mtime
    return pack
end

function Store:loadAck()
    local data = readFile(self.folder .. "/ack.json")
    local ack = data and rapidjson.decode(data)
    if type(ack) ~= "table" then ack = {} end
    local applied, skipped = {}, {}
    for _, id in ipairs(ack.applied or {}) do applied[id] = true end
    for id, reason in pairs(type(ack.skipped) == "table" and ack.skipped or {}) do skipped[id] = reason end
    return { applied = applied, skipped = skipped, updated_at = ack.updated_at }
end

--- All answers recorded on this device: list of entries, and {file = {entries}}.
function Store:loadEntries()
    local all, by_file = {}, {}
    if lfs.attributes(self.reviews_dir, "mode") ~= "directory" then return all, by_file end
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

function Store:startSession()
    util.makePath(self.reviews_dir)
    self.session = string.format("%s-%s", self.device_id, os.date("!%Y%m%dT%H%M%S"))
    self.session_entries = {}
    self.seq = 0
end

function Store:_writeSession()
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

--- Undo the last answer of this session, unless the PC already applied it.
function Store:canUndo(ack)
    local last = self.session_entries and self.session_entries[#self.session_entries]
    return last ~= nil and not ack.applied[last.id] and not ack.skipped[last.id]
end

function Store:undo()
    local last = table.remove(self.session_entries)
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
    return removed
end

return Store
