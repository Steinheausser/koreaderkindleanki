-- Store tests with KOReader's libraries (rapidjson, lfs): pack formats 1 and 2, packs arriving in pieces,
-- pack cache, counts memo, session log / undo / cleanup. Works in a scratch folder it creates and deletes.
--   cd /mnt/us/koreader && ./luajit <this> <plugin dir> <scratch dir>
require("setupkoenv")
package.path = arg[1] .. "/?.lua;" .. package.path
local rapidjson = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Store = require("ankireview_store")
local root = assert(arg[2], "usage: test_store.lua <plugin dir> <scratch dir>")

local failures, n = 0, 0
local function test(name, fn)
    n = n + 1
    local ok, err = pcall(fn)
    if ok then print("ok   " .. name) else failures = failures + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function write(path, data)
    local f = assert(io.open(path, "wb")); f:write(data); f:close()
end
-- lfs mtimes have 1 s resolution: give each rewrite a distinct mtime
local bump = os.time() - 1000
local function touch(path)
    bump = bump + 1
    lfs.touch(path, bump, bump)
end

local CUTOFF = os.time() + 3600
local function makePack(id, fmt, html)
    local cards = {
        { cid = 1, nid = 1, did = 1, mid = "m", queue = 0, type = 0, new_pos = 1, q = html .. " Q1", a = html .. " Q1<hr id=answer>A1" },
        { cid = 2, nid = 2, did = 1, mid = "m", queue = 2, type = 2, due_day = 0, q = "Q2 ünïcødé", a = "Q2 ünïcødé<hr id=answer>A2" },
    }
    local pack = {
        format = fmt, pack_id = id, generated_at = os.time() * 1000, today = 10, day_cutoff = CUTOFF,
        applied = rapidjson.array({}), css = { m = ".card{}" },
        decks = { ["1"] = { name = "D", new_today = 5, rev_today = 5, new_per_day = 5, rev_per_day = 5,
                            learn_steps = { 60, 600 }, relearn_steps = { 600 } } },
        cards = cards,
    }
    local bin
    if fmt == 2 then
        local parts, off = {}, 0
        for _, c in ipairs(cards) do
            c.qo, c.ql = off, #c.q; table.insert(parts, c.q); off = off + #c.q
            c.ao, c.al = off, #c.a; table.insert(parts, c.a); off = off + #c.a
            c.q, c.a = nil, nil
        end
        pack.cards_file = "cards-" .. id .. ".bin"
        bin = table.concat(parts)
    end
    return pack, bin
end

local folder = root .. "/store-test"
os.execute("rm -rf '" .. folder .. "'")
util.makePath(folder .. "/pack")
local pack_path = folder .. "/pack/pack.json"

test("no pack: 'missing', and no reviews folder is created", function()
    local s = Store.new(folder, "dev")
    local p, err = s:loadPack()
    eq(p, nil); eq(err, "missing")
    eq(lfs.attributes(folder .. "/reviews"), nil)
    local text = Store.errorText(err, nil, folder)
    assert(text:find("No card pack yet", 1, true))
end)

test("format 1 pack: card HTML from the fields", function()
    local pack = makePack("100", 1, "one")
    write(pack_path, rapidjson.encode(pack)); touch(pack_path)
    local s = Store.new(folder, "dev")
    local p = assert(s:loadPack())
    eq(p.format, 1)
    local q, a = s:cardHtml(p.cards[2], p)
    eq(q, "Q2 ünïcødé"); eq(a, "Q2 ünïcødé<hr id=answer>A2")
    eq(Store.new(folder, "other"):loadPack(), p, "parsed pack shared between Store instances (module cache)")
end)

test("format 2 pack.json before its cards file: old pack stays, then the new one is used", function()
    local s = Store.new(folder, "dev")
    local old = assert(s:loadPack())
    local pack, bin = makePack("200", 2, "two")
    write(pack_path, rapidjson.encode(pack)); touch(pack_path)
    eq(s:loadPack(), old, "keeps the loaded pack")
    eq(s.pack_waiting, "syncing")
    write(folder .. "/pack/cards-200.bin", bin:sub(1, 10)) -- partial file: still not ready
    eq(s:loadPack(), old, "partial cards file: still the old pack")
    write(folder .. "/pack/cards-200.bin", bin)
    local p = assert(s:loadPack())
    eq(p.pack_id, "200"); eq(s.pack_waiting, false)
    local q, a = s:cardHtml(p.cards[1], p)
    eq(q, "two Q1"); eq(a, "two Q1<hr id=answer>A1")
    q, a = s:cardHtml(p.cards[2], p)
    eq(q, "Q2 ünïcødé"); eq(a, "Q2 ünïcødé<hr id=answer>A2")
    q = s:cardHtml(p.cards[2]) -- default: last loaded pack
    eq(q, "Q2 ünïcødé")
end)

test("format 2 without any loaded pack: 'syncing'", function()
    local f2 = root .. "/store-test2"
    os.execute("rm -rf '" .. f2 .. "'")
    util.makePath(f2 .. "/pack")
    local pack = makePack("300", 2, "three")
    write(f2 .. "/pack/pack.json", rapidjson.encode(pack))
    local s = Store.new(f2, "dev")
    local p, err = s:loadPack()
    eq(p, nil); eq(err, "syncing")
    assert(Store.errorText(err):find("still syncing", 1, true))
    os.execute("rm -rf '" .. f2 .. "'")
end)

test("unknown format / unreadable JSON: friendly errors; the loaded pack stays in use", function()
    local f3 = root .. "/store-test3"
    os.execute("rm -rf '" .. f3 .. "'")
    util.makePath(f3 .. "/pack")
    write(f3 .. "/pack/pack.json", '{"format": 9, "cards": []}')
    local s = Store.new(f3, "dev")
    local p, err, detail = s:loadPack()
    eq(p, nil); eq(err, "format"); eq(detail, "9")
    assert(Store.errorText(err, detail):find("Update the plugin or the Anki add-on", 1, true))
    write(f3 .. "/pack/pack.json", '{"format": 1, "cards": [')
    touch(f3 .. "/pack/pack.json")
    p, err = s:loadPack()
    eq(p, nil); eq(err, "corrupt")
    os.execute("rm -rf '" .. f3 .. "'")
    -- with a pack in use, a broken new one is ignored until it changes again
    local s2 = Store.new(folder, "dev")
    local cur = assert(s2:loadPack())
    local saved = io.open(pack_path, "rb"):read("*a")
    write(pack_path, '{"format": 9, "cards": []}'); touch(pack_path)
    eq(s2:loadPack(), cur); eq(s2.pack_waiting, "format")
    write(pack_path, saved); touch(pack_path)
    eq(s2:loadPack().pack_id, "200")
end)

test("session log, counts memo, undo, cleanup", function()
    local s = Store.new(folder, "dev")
    local p = assert(s:loadPack())
    local now = os.time()
    local per, total = s:counts(now)
    eq(total.new, 1); eq(total.review, 1)
    local _, total_again = s:counts(now)
    eq(total_again, total, "memoized")
    s:startSession()
    eq(lfs.attributes(folder .. "/reviews", "mode"), "directory")
    local e = assert(s:append{ cid = 2, rating = 3, answered_at_ms = now * 1000, taken_ms = 1000, pack_id = p.pack_id })
    local _, total2 = s:counts(now)
    eq(total2.review, 0, "memo invalidated by a new answer")
    eq(#s:pendingEntries(p, s:loadAck()), 1)
    eq(s:lastUndoable(s:loadAck()), e)
    eq(s:undo(), e)
    eq(s:undo(), nil)
    local _, total3 = s:counts(now)
    eq(total3.review, 1, "memo invalidated by undo")
    -- an old session whose answers the pack reflects gets cleaned up; the current one never
    write(folder .. "/reviews/old.jsonl", rapidjson.encode({ id = "old-1", cid = 1, rating = 3, answered_at_ms = 1 }) .. "\n")
    s:append{ cid = 1, rating = 3, answered_at_ms = now * 1000, taken_ms = 1, pack_id = p.pack_id }
    eq(s:cleanup(p, s:loadAck()), 0, "old answer not applied yet: kept")
    p.applied = { "old-1" }
    eq(s:cleanup(p, s:loadAck()), 1)
    eq(lfs.attributes(folder .. "/reviews/old.jsonl"), nil)
    assert(lfs.attributes(folder .. "/reviews/" .. s.session .. ".jsonl"), "current session kept")
end)

os.execute("rm -rf '" .. folder .. "'")
print(string.format("%d/%d passed", n - failures, n))
os.exit(failures == 0 and 0 or 1)
