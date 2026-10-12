-- Unit tests for koplugin/ankireview.koplugin/scheduler.lua. Plain luajit, no KOReader needed:
--   luajit tests/test_scheduler.lua <path to ankireview.koplugin>
package.path = (arg[1] or "koplugin/ankireview.koplugin") .. "/?.lua;" .. package.path
local S = require("ankireview_scheduler")

local failures, n = 0, 0
local function test(name, fn)
    n = n + 1
    local ok, err = pcall(fn)
    if ok then print("ok   " .. name) else failures = failures + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local CUTOFF = 1800000000 -- end of Anki day 100
local T0 = CUTOFF - 12 * 3600 -- middle of day 100

local function pack(extra)
    local p = {
        today = 100, day_cutoff = CUTOFF, applied = {},
        decks = { ["1"] = { name = "Default", new_today = 2, rev_today = 3, new_per_day = 5, rev_per_day = 10,
                            learn_steps = { 60, 600 }, relearn_steps = { 600 },
                            bury_new = true, bury_rev = false, bury_interday = false } },
        cards = {
            { cid = 1, nid = 10, did = 1, queue = 0, type = 0, new_pos = 1, labels = { "<1m", "<6m", "<10m", "4d" } },
            { cid = 2, nid = 10, did = 1, queue = 0, type = 0, new_pos = 2 }, -- sibling of 1
            { cid = 3, nid = 30, did = 1, queue = 0, type = 0, new_pos = 3 },
            { cid = 4, nid = 40, did = 1, queue = 2, type = 2, due_day = 0 },
            { cid = 5, nid = 50, did = 1, queue = 2, type = 2, due_day = -3 },
            { cid = 6, nid = 60, did = 1, queue = 2, type = 2, due_day = 1 },
            { cid = 7, nid = 70, did = 1, queue = 1, type = 1, due_at = T0 + 300, left = 1 },
        },
    }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
end
local function e(id, cid, rating, ts) return { id = id, cid = cid, rating = rating, answered_at_ms = ts * 1000 } end

test("anki day uses rollover", function()
    local p = pack()
    eq(S.ankiDay(p, CUTOFF - 1), 100); eq(S.ankiDay(p, CUTOFF), 101); eq(S.ankiDay(p, CUTOFF - 86400), 100); eq(S.ankiDay(p, CUTOFF - 86400 - 1), 99)
end)

test("queue order: overdue reviews first, limits applied", function()
    local s = S.new(pack(), {})
    local learn, review, new = s:available(T0)
    eq(#learn, 0); eq(#review, 2, "reviews due today")
    eq(review[1].card.cid, 5, "most overdue first")
    eq(#new, 2, "new_today limit")
    eq(s:nextCard(T0).card.cid, 5)
end)

test("learning card shows when due, learn-ahead 20 min", function()
    local s = S.new(pack(), { e("a", 4, 3, T0), e("b", 5, 3, T0), e("c", 1, 3, T0), e("d", 3, 3, T0) })
    -- cid 1 (Good from new -> step 2, 10 min), cid 3 likewise; cid 7 due at T0+300
    local c, nxt = s:nextCard(T0 + 1)
    eq(c.card.cid, 7, "learning card within learn-ahead window")
    s = S.new(pack(), { e("a", 4, 3, T0), e("b", 5, 3, T0), e("c", 1, 3, T0), e("d", 3, 3, T0), e("f", 7, 3, T0) })
    c, nxt = s:nextCard(T0 + 1)
    eq(c.card.cid, 1, "10-min step shown early (learn ahead)")
    c, nxt = s:nextCard(T0 - 30 * 60)
end)

test("sibling burying of new cards", function()
    local s = S.new(pack(), { e("a", 1, 3, T0) })
    local _, _, new = s:available(T0 + 1)
    for _, st in ipairs(new) do if st.card.cid == 2 then error("sibling not buried") end end
    -- next day the sibling is back
    _, _, new = s:available(CUTOFF + 10)
    local found = false
    for _, st in ipairs(new) do if st.card.cid == 2 then found = true end end
    eq(found, true, "sibling back next day")
end)

test("new limit counts local answers per day; next day uses per_day", function()
    local s = S.new(pack(), { e("a", 1, 4, T0), e("b", 3, 4, T0) }) -- two new cards graduated (Easy)
    local _, _, new = s:available(T0 + 1)
    eq(#new, 0, "today's 2 new used up")
    _, _, new = s:available(CUTOFF + 10)
    eq(#new, 1, "only sibling 2 left, now unburied")
end)

test("again on review -> relearning step, good graduates", function()
    local s = S.new(pack(), { e("a", 4, 1, T0) })
    local st = s.cards[4]
    eq(st.kind, "learn"); eq(st.due_at, T0 + 600)
    local labels = s:labels(st)
    eq(labels[1], "10m"); eq(labels[3], "✓")
    s = S.new(pack(), { e("a", 4, 1, T0), e("b", 4, 3, T0 + 700) })
    eq(s.cards[4].done, true)
end)

test("first-answer labels come from the pack", function()
    local s = S.new(pack(), {})
    eq(s:labels(s.cards[1])[4], "4d")
    s = S.new(pack(), { e("a", 1, 1, T0) })
    eq(s:labels(s.cards[1])[1], "1m", "after Again: computed from steps")
end)

test("applied entries are ignored", function()
    local p = pack({ applied = { "a" } })
    local s = S.new(p, { e("a", 4, 3, T0) })
    eq(s.cards[4].done, false)
end)

test("review limit only counts review cards", function()
    local p = pack()
    p.decks["1"].rev_today = 1
    local s = S.new(p, {})
    local _, review = s:available(T0)
    eq(#review, 1)
end)

test("future-day reviews appear on their day", function()
    local s = S.new(pack(), {})
    local _, review = s:available(CUTOFF + 10)
    eq(#review, 3, "cid 6 due tomorrow joins")
end)

print(string.format("%d/%d passed", n - failures, n))
os.exit(failures == 0 and 0 or 1)
