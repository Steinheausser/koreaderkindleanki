-- Read-only benchmark of the plugin on a real pack (never writes answers).
--   cd /mnt/us/koreader && ./luajit <this> <plugin dir> <exchange folder>
require("setupkoenv")
package.path = arg[1] .. "/?.lua;" .. package.path
local socket = require("socket")
local Store = require("ankireview_store")
local Scheduler = require("ankireview_scheduler")
local store = Store.new(arg[2], "bench")
local t0 = socket.gettime()
local pack = assert(store:loadPack())
local t1 = socket.gettime()
local ack = store:loadAck()
local s = Scheduler.new(pack, store:pendingEntries(pack, ack))
local t2 = socket.gettime()
local per, total = s:counts(os.time())
local st = s:nextCard(os.time())
local t3 = socket.gettime()
-- simulate 50 answers in memory (rebuild each time, like the reviewer does)
local entries, now = {}, os.time()
for i = 1, 50 do
    local c = s:nextCard(now); if not c then break end
    table.insert(entries, { id = "b" .. i, cid = c.card.cid, rating = 3, answered_at_ms = (now + i) * 1000 })
    s = Scheduler.new(pack, entries)
end
local t4 = socket.gettime()
print(string.format("cards %d | load %.0f ms | build %.0f ms | counts+next %.0f ms | 50 answers %.0f ms (%.0f ms each)",
    #pack.cards, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, (t4 - t3) * 1000, (t4 - t3) * 20))
print("due now: new", total.new, "learn", total.learn, "review", total.review)
print("memory KB", math.floor(collectgarbage("count")))
