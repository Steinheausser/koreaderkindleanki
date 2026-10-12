-- Read-only benchmark of the plugin on a real pack (never writes answers). Works with format 1 and 2 packs.
--   cd /mnt/us/koreader && ./luajit <this> <plugin dir> <exchange folder>
require("setupkoenv")
package.path = arg[1] .. "/?.lua;" .. package.path
local socket = require("socket")
local Store = require("ankireview_store")
local Scheduler = require("ankireview_scheduler")
local function ms(t) return (socket.gettime() - t) * 1000 end

collectgarbage(); collectgarbage()
local mem0 = collectgarbage("count")
local store = Store.new(arg[2], "bench")
local t = socket.gettime()
local pack = assert(store:loadPack())
local load_ms = ms(t)
collectgarbage(); collectgarbage()
local pack_kb = collectgarbage("count") - mem0

t = socket.gettime()
assert(store:loadPack() == pack)
local cached_ms = ms(t)

t = socket.gettime()
local ack = store:loadAck()
local s = Scheduler.new(pack, store:pendingEntries(pack, ack))
local build_ms = ms(t)

local now = os.time()
t = socket.gettime()
local per, total = s:counts(now)
local st = s:queue(now)
local counts_ms = ms(t)

t = socket.gettime()
local _p, total2 = store:counts(now)
local memo_cold_ms = ms(t)
t = socket.gettime()
store:counts(now)
local memo_warm_ms = ms(t)
assert(total2.new == total.new and total2.review == total.review)

-- What the reviewer now does per answer: incremental update + pick the next card (one pass, no sort).
local N = 50
local entries = {}
t = socket.gettime()
for i = 1, N do
    local c = s:queue(now + i)
    if not c then break end
    local e = { id = "b" .. i, cid = c.card.cid, rating = 3, answered_at_ms = (now + i) * 1000 }
    table.insert(entries, e)
    s:answer(c, 3, now + i, e)
end
local inc_ms = ms(t)

-- The old way: rebuild the scheduler from scratch after each answer.
local s2 = Scheduler.new(pack, store:pendingEntries(pack, ack))
local old_entries = {}
t = socket.gettime()
for i = 1, N do
    local c = s2:nextCard(now + i); if not c then break end
    table.insert(old_entries, { id = "b" .. i, cid = c.card.cid, rating = 3, answered_at_ms = (now + i) * 1000 })
    s2 = Scheduler.new(pack, old_entries)
end
local old_ms = ms(t)

-- Card HTML access (format 2 reads slices from the cards file)
t = socket.gettime()
local bytes = 0
for _, c in ipairs(pack.cards) do
    local q, a = store:cardHtml(c, pack)
    bytes = bytes + #q + #a
end
local html_ms = ms(t)

print(string.format("format %d | cards %d | load %.0f ms (cached %.2f ms) | Scheduler.new %.0f ms | counts+queue %.0f ms",
    pack.format, #pack.cards, load_ms, cached_ms, build_ms, counts_ms))
print(string.format("Store:counts memo: first %.0f ms, again %.2f ms", memo_cold_ms, memo_warm_ms))
print(string.format("per answer: incremental %.1f ms (answer+queue) vs rebuild %.1f ms  [%d answers]",
    inc_ms / #entries, old_ms / #old_entries, #entries))
print(string.format("cardHtml: all %d cards %.0f ms (%.2f ms/card), %d bytes", #pack.cards, html_ms, html_ms / #pack.cards, bytes))
print("due now: new", total.new, "learn", total.learn, "review", total.review)
collectgarbage(); collectgarbage()
print(string.format("memory: parsed pack ~%d KB, total Lua heap %d KB", math.floor(pack_kb), math.floor(collectgarbage("count"))))
