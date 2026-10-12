-- Convert a format-1 exchange folder's pack into a format-2 pack (pack.json + cards-<pack_id>.bin), the way the
-- Anki add-on writes it, so the plugin can be tested without the PC side. Media is not copied.
--   cd /mnt/us/koreader && ./luajit <this> <format-1 pack.json> <output exchange folder>
-- Prints the output pack.json path. The output folder gets pack/pack.json, pack/cards-<pack_id>.bin.
require("setupkoenv")
local rapidjson = require("rapidjson")
local util = require("util")

local src, out = arg[1], arg[2]
assert(src and out, "usage: make_format2.lua <format-1 pack.json> <output folder>")
local pack = assert(rapidjson.load(src))
assert(pack.format == 1, "input must be a format-1 pack")
util.makePath(out .. "/pack/media")
util.makePath(out .. "/reviews")

local name = "cards-" .. tostring(pack.pack_id) .. ".bin"
local parts, offset = {}, 0
for _, c in ipairs(pack.cards) do
    local q, a = c.q or "", c.a or ""
    c.q, c.a = nil, nil
    c.qo, c.ql = offset, #q
    table.insert(parts, q); offset = offset + #q
    c.ao, c.al = offset, #a
    table.insert(parts, a); offset = offset + #a
end
local f = assert(io.open(out .. "/pack/" .. name, "wb"))
f:write(table.concat(parts))
f:close()
pack.format = 2
pack.cards_file = name
local json = assert(rapidjson.encode(pack))
f = assert(io.open(out .. "/pack/pack.json", "wb"))
f:write(json)
f:close()
print(out .. "/pack/pack.json", #pack.cards .. " cards", offset .. " bytes of HTML")
