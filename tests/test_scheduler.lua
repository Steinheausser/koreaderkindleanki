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

-- Random packs: several decks with different limits, siblings, all queue kinds.
local function lcg(seed)
    local x = seed * 7919 + 1
    return function(a, b)
        x = (x * 16807) % 2147483647 -- Park-Miller: exact in doubles (LuaJIT) and integers alike
        return a + math.floor(x / 7) % (b - a + 1)
    end
end

local function randomPack(rnd)
    local p = { today = 100, day_cutoff = CUTOFF, applied = {}, decks = {}, cards = {} }
    for d = 1, 3 do
        p.decks[tostring(d)] = {
            name = "D" .. d, new_today = rnd(0, 4), rev_today = rnd(0, 6), new_per_day = rnd(1, 5), rev_per_day = rnd(2, 8),
            learn_steps = d == 3 and {} or { 60, 600 }, relearn_steps = d == 2 and {} or { 600 },
            bury_new = rnd(0, 1) == 1, bury_rev = rnd(0, 1) == 1, bury_interday = rnd(0, 1) == 1,
        }
    end
    for cid = 1, 40 do
        local q = ({ 0, 0, 1, 2, 2, 3 })[rnd(1, 6)]
        local c = { cid = cid, nid = 1000 + rnd(1, 25), did = rnd(1, 3), queue = q, type = q == 3 and 1 or q }
        if q == 1 then c.due_at = T0 + rnd(-1800, 3600); c.left = rnd(1, 2)
        elseif q == 2 or q == 3 then c.due_day = rnd(-3, 2)
        else c.new_pos = cid end
        table.insert(p.cards, c)
    end
    return p
end

local function sameCounts(a, b, where)
    local pa, ta = a:counts(where)
    local pb, tb = b:counts(where)
    for _, k in ipairs({ "new", "learn", "review" }) do eq(ta[k], tb[k], "total " .. k .. " at " .. where) end
    for did, c in pairs(pa) do
        for _, k in ipairs({ "new", "learn", "review" }) do eq(c[k], (pb[did] or {})[k], "deck " .. did .. " " .. k) end
    end
    for did in pairs(pb) do if not pa[did] then error("deck " .. did .. " missing at " .. where) end end
    for d = 0, 3 do
        local deck = d > 0 and d or nil
        local ca, na = a:nextCard(where, deck)
        local cb, nb = b:nextCard(where, deck)
        eq(ca and ca.card.cid, cb and cb.card.cid, "nextCard deck " .. d .. " at " .. where)
        eq(na, nb, "next_learn deck " .. d)
    end
end

-- Reference: the card order and counts as available() (sorted lists + limits) gives them.
local function refNext(s, now, did)
    local learn, review, new, next_learn = s:available(now, did)
    if learn[1] then return learn[1] end
    if review[1] then return review[1] end
    if new[1] then return new[1] end
    if next_learn and next_learn - now <= 20 * 60 then
        local l = s:available(next_learn, did)
        if l[1] then return l[1] end
    end
    return nil, next_learn
end

test("incremental answers == rebuild from all answers (random)", function()
    for seed = 1, 60 do
        local rnd = lcg(seed)
        local p = randomPack(rnd)
        local inc = S.new(p, {})
        local entries, ts = {}, T0
        for step = 1, 45 do
            ts = ts + rnd(0, 1500) + (rnd(1, 15) == 1 and 86400 or 0)
            local st = inc:nextCard(ts)
            if not st or rnd(1, 4) == 1 then -- sometimes answer some other card still in play
                local open = {}
                for _, x in ipairs(inc.order) do if not x.done then table.insert(open, x) end end
                if #open == 0 then break end
                st = open[rnd(1, #open)]
            end
            local entry = { id = string.format("s%03d", step), cid = st.card.cid, rating = rnd(1, 4),
                            answered_at_ms = ts * 1000 }
            table.insert(entries, entry)
            inc:answer(st, entry.rating, ts, entry)
            local fresh = S.new(p, entries)
            sameCounts(inc, fresh, ts)
            sameCounts(inc, fresh, ts + 900)
            sameCounts(inc, fresh, ts + 86400)
        end
    end
end)

test("single-pass counts/nextCard == sorted available() (random)", function()
    for seed = 100, 160 do
        local rnd = lcg(seed)
        local p = randomPack(rnd)
        local entries, ts = {}, T0
        for step = 1, 30 do
            ts = ts + rnd(0, 2000) + (rnd(1, 12) == 1 and 86400 or 0)
            table.insert(entries, { id = string.format("r%03d", step), cid = rnd(1, 40), rating = rnd(1, 4),
                                    answered_at_ms = ts * 1000 })
        end
        local s = S.new(p, entries)
        for _, when in ipairs({ T0, ts, ts + 600, ts + 86400, ts + 3 * 86400 }) do
            for d = 0, 3 do
                local deck = d > 0 and d or nil
                local a, an = s:nextCard(when, deck)
                local b, bn = refNext(s, when, deck)
                eq(a and a.card.cid, b and b.card.cid, "seed " .. seed .. " deck " .. d)
                eq(an, bn, "next_learn")
                local learn, review, new = s:available(when, deck)
                local _, q = s:queue(when, deck)
                eq(q.learn, #learn); eq(q.review, #review); eq(q.new, #new)
            end
            local per, total = s:counts(when)
            local learn, review, new = s:available(when)
            eq(total.learn, #learn); eq(total.review, #review); eq(total.new, #new)
            local sum = 0
            for _, c in pairs(per) do sum = sum + c.new + c.learn + c.review end
            eq(sum, #learn + #review + #new, "per-deck sums")
        end
    end
end)

test("answer() with a clock that went backwards rebuilds in time order", function()
    local p = pack()
    local s = S.new(p, {})
    local e1 = e("b", 4, 1, T0 + 100)
    s:answer(s.cards[4], 1, T0 + 100, e1)
    local e2 = e("a", 5, 3, T0)
    s:answer(s.cards[5], 3, T0, e2)
    sameCounts(s, S.new(p, { e1, e2 }), T0 + 200)
end)

print(string.format("%d/%d passed", n - failures, n))
os.exit(failures == 0 and 0 or 1)
