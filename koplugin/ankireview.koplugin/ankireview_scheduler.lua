--[[--
Offline review queue for a card pack exported by the Anki "kindle_review" add-on.

Pure Lua (no KOReader dependencies) so it can be unit-tested with plain luajit.

The state is built from (pack, local answers the pack doesn't reflect yet), which makes undo, restarts
and new packs trivial; new answers are then applied incrementally (Scheduler:answer), which gives exactly
the same state as rebuilding. This only decides *what to show when*; the real scheduling happens
later on the PC, when Anki replays the recorded answers.
]]

local Scheduler = {}
Scheduler.__index = Scheduler

local DAY = 86400
local LEARN_AHEAD = 20 * 60 -- like Anki: show learning cards up to 20 min early when nothing else is due

local AGAIN, HARD, GOOD, EASY = 1, 2, 3, 4
Scheduler.AGAIN, Scheduler.HARD, Scheduler.GOOD, Scheduler.EASY = AGAIN, HARD, GOOD, EASY

--- Anki day number of a timestamp (uses the pack's rollover, so it is timezone independent).
function Scheduler.ankiDay(pack, ts)
    return pack.today - math.floor((pack.day_cutoff - 1 - ts) / DAY)
end

local function stepsFor(deck, card)
    if card.type == 3 then return deck.relearn_steps or {} end
    return deck.learn_steps or {}
end

local function formatDelay(secs)
    if secs < 3600 then return string.format("%dm", math.max(1, math.floor(secs / 60 + 0.5))) end
    if secs < DAY then return string.format("%dh", math.floor(secs / 3600 + 0.5)) end
    return string.format("%dd", math.floor(secs / DAY + 0.5))
end
Scheduler.formatDelay = formatDelay

--- @param pack table decoded pack.json
--- @param entries table answers recorded on this device, any order (already-applied ones are ignored)
function Scheduler.new(pack, entries)
    local self = setmetatable({ pack = pack, cards = {}, by_nid = {}, order = {} }, Scheduler)
    local applied = {}
    for _, id in ipairs(pack.applied or {}) do applied[id] = true end
    for i, c in ipairs(pack.cards) do
        local st = {
            card = c, idx = i, deck = pack.decks[tostring(c.did)],
            done = false, first = true,
        }
        if c.queue == 0 then
            st.kind = "new"
        elseif c.queue == 1 then
            st.kind = "learn"; st.due_at = c.due_at
            local steps = stepsFor(st.deck, c)
            st.step = math.max(1, #steps - (c.left or 0) + 1)
        else -- 2 = review, 3 = interday learning
            st.kind = c.queue == 2 and "review" or "dayLearn"
            st.due_day = pack.today + (c.due_day or 0)
        end
        if st.deck then
            self.cards[c.cid] = st
            table.insert(self.order, st)
            self.by_nid[c.nid] = self.by_nid[c.nid] or {}
            table.insert(self.by_nid[c.nid], st)
        end
    end
    -- per Anki day and deck: how many new / review cards were introduced locally (counts against limits)
    self.used = {}
    self.buried = {} -- [day][cid] = true
    self.pending = {}
    for _, e in ipairs(entries) do
        if not applied[e.id] and self.cards[e.cid] then table.insert(self.pending, e) end
    end
    table.sort(self.pending, function(a, b)
        if a.answered_at_ms ~= b.answered_at_ms then return a.answered_at_ms < b.answered_at_ms end
        return a.id < b.id
    end)
    for _, e in ipairs(self.pending) do
        self:_apply(self.cards[e.cid], e.rating, e.answered_at_ms / 1000)
    end
    return self
end

function Scheduler:_used(day, did)
    self.used[day] = self.used[day] or {}
    local u = self.used[day][did]
    if not u then u = { new = 0, rev = 0 }; self.used[day][did] = u end
    return u
end

function Scheduler:_bury(st, day)
    local d = st.deck
    for _, sib in ipairs(self.by_nid[st.card.nid] or {}) do
        if sib ~= st then
            local k = sib.kind
            if (k == "new" and d.bury_new) or (k == "review" and d.bury_rev)
                or (k == "dayLearn" and d.bury_interday) then
                self.buried[day] = self.buried[day] or {}
                self.buried[day][sib.card.cid] = true
            end
        end
    end
end

-- Delay (seconds) the learning step `step` (1-based) waits after an answer, or nil when it graduates.
local function learnDelay(steps, step, rating)
    if not steps[1] then return nil end -- no (re)learning steps: the card leaves the queue
    if rating == AGAIN then return steps[1], 1 end
    if rating == HARD then
        local cur = steps[step] or steps[#steps]
        if step == 1 and steps[2] then return math.floor((steps[1] + steps[2]) / 2), step end
        if step == 1 then return math.floor(cur * 1.5), step end
        return cur, step
    end
    if rating == GOOD then
        if steps[step + 1] then return steps[step + 1], step + 1 end
        return nil
    end
    return nil -- EASY graduates immediately
end

--- Next state for a rating, without changing anything: returns kind ("learn" or "done") and delay.
function Scheduler:preview(st, rating)
    local steps = stepsFor(st.deck, st.card)
    if st.kind == "review" or st.kind == "dayLearn" then
        if rating == AGAIN and st.kind == "review" then
            local rsteps = st.deck.relearn_steps or {}
            if rsteps[1] and rsteps[1] < DAY then return "learn", rsteps[1], 1, rsteps end
        end
        return "done"
    end
    if st.kind == "new" or st.kind == "learn" then
        local s = st.kind == "new" and 1 or st.step
        local delay, nstep = learnDelay(steps, s, rating)
        if delay and delay < DAY then return "learn", delay, nstep, steps end
        return "done"
    end
    return "done"
end

function Scheduler:_apply(st, rating, ts)
    local day = Scheduler.ankiDay(self.pack, ts)
    local did = st.card.did
    if st.first then
        if st.kind == "new" then
            self:_used(day, did).new = self:_used(day, did).new + 1
        elseif st.kind == "review" then
            self:_used(day, did).rev = self:_used(day, did).rev + 1
        end
        self:_bury(st, day)
    end
    local kind, delay, nstep, steps = self:preview(st, rating)
    st.first = false
    if kind == "learn" then
        if st.kind == "review" then st.card = setmetatable({ type = 3 }, { __index = st.card }) end
        st.kind = "learn"; st.step = nstep; st.due_at = ts + delay; st.steps = steps
    else
        st.kind = "done"; st.done = true
    end
end

--- Record a new answer (same effect as rebuilding with `entry` added to the answers).
--- @param st table card state from this scheduler
--- @param entry table the logged answer ({id, cid, rating, answered_at_ms, ...})
function Scheduler:answer(st, rating, ts, entry)
    local last = self.pending[#self.pending]
    if last and (last.answered_at_ms > entry.answered_at_ms
            or (last.answered_at_ms == entry.answered_at_ms and last.id > entry.id)) then
        -- clock went backwards: replaying in time order differs from appending, so rebuild
        local list = { entry }
        for _, e in ipairs(self.pending) do table.insert(list, e) end
        local fresh = Scheduler.new(self.pack, list)
        for k in pairs(self) do self[k] = nil end
        for k, v in pairs(fresh) do self[k] = v end
        return
    end
    table.insert(self.pending, entry)
    self:_apply(st, rating, ts)
end

--- Button labels for the four ratings.
function Scheduler:labels(st)
    if st.first and st.card.labels and #st.card.labels == 4 then return st.card.labels end
    local out = {}
    for r = AGAIN, EASY do
        local kind, delay = self:preview(st, r)
        out[r] = kind == "learn" and formatDelay(delay) or (r == AGAIN and "—" or "✓")
    end
    return out
end

local function inDeck(st, did)
    if not did then return true end
    return st.card.did == did
end

--- Cards available now, optionally limited to one deck id.
--- Returns learn (due), review, new lists and the next learning due time (if any).
function Scheduler:available(now, did)
    local day = Scheduler.ankiDay(self.pack, now)
    local learn, review, new, next_learn = {}, {}, {}, nil
    local rev_left, new_left = {}, {}
    local function left(tbl, deck_id, field_today, field_day, used_field)
        if tbl[deck_id] == nil then
            local d = self.pack.decks[tostring(deck_id)]
            local limit = (day == self.pack.today) and d[field_today] or d[field_day]
            tbl[deck_id] = limit - self:_used(day, deck_id)[used_field]
        end
        return tbl[deck_id]
    end
    local buried = self.buried[day] or {}
    for _, st in ipairs(self.order) do
        if not st.done and inDeck(st, did) and not buried[st.card.cid] then
            if st.kind == "learn" then
                if st.due_at <= now then
                    table.insert(learn, st)
                elseif not next_learn or st.due_at < next_learn then
                    next_learn = st.due_at
                end
            elseif st.kind == "review" or st.kind == "dayLearn" then
                if st.due_day <= day then table.insert(review, st) end
            elseif st.kind == "new" then
                table.insert(new, st)
            end
        end
    end
    table.sort(learn, function(a, b)
        if a.due_at ~= b.due_at then return a.due_at < b.due_at end
        return a.idx < b.idx
    end)
    table.sort(review, function(a, b)
        if a.due_day ~= b.due_day then return a.due_day < b.due_day end
        return a.idx < b.idx
    end)
    table.sort(new, function(a, b) return a.idx < b.idx end)
    -- apply per-deck daily limits (reviews: only real review cards count, like Anki)
    local function cap(list, tbl, ft, fd, uf, counts)
        local out = {}
        for _, st in ipairs(list) do
            if not counts or st.kind == counts then
                local n = left(tbl, st.card.did, ft, fd, uf)
                if n > 0 then tbl[st.card.did] = n - 1; table.insert(out, st) end
            else
                table.insert(out, st)
            end
        end
        return out
    end
    review = cap(review, rev_left, "rev_today", "rev_per_day", "rev", "review")
    new = cap(new, new_left, "new_today", "new_per_day", "new")
    return learn, review, new, next_learn
end

-- One pass over the cards, without sorting: what is available at `now` after daily limits, and the first card
-- of each queue in the order available() would give. Results are identical to available()'s.
function Scheduler:_scan(now, did, want_per)
    local pack = self.pack
    local day = Scheduler.ankiDay(pack, now)
    local is_today = day == pack.today
    local buried = self.buried[day] or {}
    local left = {} -- per deck: { rev =, new = } still allowed today
    local raw = {}  -- per deck: { learn =, rev =, day =, new = } before limits
    local first_learn, first_rev, first_new, next_learn
    local n_learn = 0
    for _, st in ipairs(self.order) do
        if not st.done and inDeck(st, did) and not buried[st.card.cid] then
            local kind = st.kind
            local deck_id = st.card.did
            if kind == "learn" then
                if st.due_at <= now then
                    n_learn = n_learn + 1
                    if not first_learn or st.due_at < first_learn.due_at
                            or (st.due_at == first_learn.due_at and st.idx < first_learn.idx) then
                        first_learn = st
                    end
                    if want_per then
                        local r = raw[deck_id] or { learn = 0, rev = 0, day = 0, new = 0 }
                        raw[deck_id] = r
                        r.learn = r.learn + 1
                    end
                elseif not next_learn or st.due_at < next_learn then
                    next_learn = st.due_at
                end
            elseif kind == "new" or ((kind == "review" or kind == "dayLearn") and st.due_day <= day) then
                local l = left[deck_id]
                if not l then
                    local d = pack.decks[tostring(deck_id)]
                    local u = self:_used(day, deck_id)
                    l = { rev = (is_today and d.rev_today or d.rev_per_day) - u.rev,
                          new = (is_today and d.new_today or d.new_per_day) - u.new }
                    left[deck_id] = l
                end
                local r = raw[deck_id] or { learn = 0, rev = 0, day = 0, new = 0 }
                raw[deck_id] = r
                if kind == "new" then
                    r.new = r.new + 1
                    if l.new > 0 and (not first_new or st.idx < first_new.idx) then first_new = st end
                else
                    if kind == "review" then r.rev = r.rev + 1 else r.day = r.day + 1 end
                    if (kind == "dayLearn" or l.rev > 0) and (not first_rev or st.due_day < first_rev.due_day
                            or (st.due_day == first_rev.due_day and st.idx < first_rev.idx)) then
                        first_rev = st
                    end
                end
            end
        end
    end
    local total = { new = 0, learn = n_learn, review = 0 }
    local per = want_per and {} or nil
    for deck_id, r in pairs(raw) do
        local l = left[deck_id]
        local rev = r.day + (l and math.min(r.rev, math.max(0, l.rev)) or 0)
        local new = l and math.min(r.new, math.max(0, l.new)) or 0
        total.review = total.review + rev
        total.new = total.new + new
        if per and (r.learn + rev + new) > 0 then per[deck_id] = { new = new, learn = r.learn, review = rev } end
    end
    return {
        first_learn = first_learn, first_review = first_rev, first_new = first_new, next_learn = next_learn,
        new = total.new, learn = total.learn, review = total.review, per = per,
    }
end

--- The card to show now (or nil), plus the counts for the deck ({new=, learn=, review=, next_learn=}).
--- When no card is returned, counts.next_learn tells when the next learning card becomes due (if any).
function Scheduler:queue(now, did)
    local q = self:_scan(now, did)
    local st = q.first_learn or q.first_review or q.first_new
    if not st and q.next_learn and q.next_learn - now <= LEARN_AHEAD then
        st = self:_scan(q.next_learn, did).first_learn
    end
    return st, q
end

--- The card to show now (or nil) and, if none, when the next learning card becomes due.
function Scheduler:nextCard(now, did)
    local st, q = self:queue(now, did)
    if st then return st end
    return nil, q.next_learn
end

--- {did = {new=, learn=, review=}} (decks with nothing available are left out) plus totals, for the deck list.
function Scheduler:counts(now)
    local q = self:_scan(now, nil, true)
    return q.per, { new = q.new, learn = q.learn, review = q.review }
end

return Scheduler
