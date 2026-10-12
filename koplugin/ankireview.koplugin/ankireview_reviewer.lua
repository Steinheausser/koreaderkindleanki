--[[--
Full-screen offline reviewer: question → Show answer → Again / Hard / Good / Easy.

The scheduler is built once when the pack is loaded and then updated incrementally per answer; it is only
rebuilt (re-reading ack.json and the review logs) on undo, refresh, the learning-card wake-up timer, or when
a new pack arrives. The answer side is rendered in the background right after the question is shown.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local Scheduler = require("ankireview_scheduler")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local Store = require("ankireview_store")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local socket = require("socket")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext
local Screen = Device.screen

local FULL_REFRESH_EVERY = 10   -- flashing refresh every N answers clears e-ink ghosting
local QUESTION_PART_MAX = 0.35  -- answer view: share of the height for the question part above the rule
local REVEAL_GUARD = 0.4        -- seconds: ignore rating taps right after revealing (double tap on Show answer)

local FONT_DEFAULT, FONT_MIN, FONT_MAX = 22, 14, 44

local EXTRA_CSS = [[
@page { margin: 0; }
body { margin: 0; }
body .card { font-size: 1em; color: black; background-color: white; }
.cloze { font-weight: bold; color: black; }
img { max-width: 100%; }
.mj-display { text-align: center; margin: 0.4em 0; }
hr#answer { margin: 0.6em 0; }
]]

local RATING_NAMES = { _("Again"), _("Hard"), _("Good"), _("Easy") }

local Reviewer = InputContainer:extend{
    store = nil,      -- Store
    did = nil,        -- deck id to review, nil = all decks
    deck_name = nil,
    settings = nil,   -- the plugin's G_reader_settings "ankireview" table (font_size)
    on_close = nil,
    covers_fullscreen = true,
}

--- Card font size from the plugin settings.
function Reviewer.fontSize(settings)
    local fs = tonumber(settings and settings.font_size) or FONT_DEFAULT
    return math.max(FONT_MIN, math.min(FONT_MAX, fs))
end

--- Show the card font size picker; on_change() runs after a new size was saved.
function Reviewer.showFontSizeDialog(settings, on_change)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Card font size"),
        value = Reviewer.fontSize(settings),
        value_min = FONT_MIN,
        value_max = FONT_MAX,
        value_step = 1,
        value_hold_step = 4,
        default_value = FONT_DEFAULT,
        callback = function(spin)
            settings.font_size = spin.value
            G_reader_settings:saveSetting("ankireview", settings)
            if on_change then on_change() end
        end,
    })
end

--- Split Anki answer HTML at its `<hr id=answer>` rule: returns question part, answer part
--- (or nil when there is no rule, or nothing visible before it).
function Reviewer.splitAnswer(html)
    local s, e = html:find("<[hH][rR]%s+[^>]-[iI][dD]%s*=%s*[\"']?[aA][nN][sS][wW][eE][rR]")
    if not s or not html:sub(e + 1, e + 1):find("^[\"'%s/>]") then return nil end
    e = html:find(">", e + 1, true)
    if not e then return nil end
    local q = html:sub(1, s - 1)
    local visible = q:find("<[iI][mM][gG][%s>]") or q:find("<[sS][vV][gG][%s>]")
        or q:gsub("<[^>]*>", ""):gsub("&nbsp;", ""):gsub("%s+", "") ~= ""
    if not visible then return nil end
    return q, html:sub(e + 1)
end

function Reviewer:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.settings = self.settings or G_reader_settings:readSetting("ankireview", {})
    self.answers_shown = 0
    self.tally = { 0, 0, 0, 0, n = 0, ms = 0 }
    self.session_started = false
    self.live = {}     -- ScrollHtmlWidgets currently on screen (freed when replaced)
    self.css_cache = {}
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.Forward = { { Device.input.group.PgFwd } }
        self.key_events.Backward = { { Device.input.group.PgBack } }
    end
    if Device:isTouchDevice() then
        -- Children (scrolling card, buttons, title bar) see gestures first; what they don't use lands here.
        local range = function() return self.content_region end
        self.ges_events.TapReveal = { GestureRange:new{ ges = "tap", range = range } }
        self.ges_events.SwipeReveal = { GestureRange:new{ ges = "swipe", range = range } }
    end
    local dpi = Screen:getDPI()
    -- ~7.5 mm tall buttons
    self.button_height = math.max(Screen:scaleBySize(40), math.floor(dpi * 7.5 / 25.4) - 2 * Size.padding.buttontable)
    self:reload()
end

------------------------------------------------------------------------------------------------------------
-- State

--- Full rebuild from disk. `undone_cid`: card whose answer was just undone (shown again, answer side up).
function Reviewer:reload(undone_cid)
    UIManager:unschedule(self._wake)
    self:dropPrefetch()
    local pack, err, detail = self.store:loadPack()
    if not pack then
        self.pack, self.sched, self.current = nil, nil, nil
        self.message = { title = _("No cards to review"), text = Store.errorText(err, detail, self.store.folder) }
        return self:render("partial")
    end
    self.message = nil
    if pack ~= self.pack then
        self.pack = pack
        self.css_cache = {}
    end
    if not self.session_started then
        -- only now that we have a pack: creates <folder>/reviews
        self.store:cleanup(pack, self.store:loadAck())
        self.store:startSession()
        self.session_started = true
    end
    self.ack = self.store:loadAck()
    self.sched = Scheduler.new(pack, self.store:pendingEntries(pack, self.ack))
    self:showNext(undone_cid)
end

--- Pick the card to show (no disk access) and render it.
function Reviewer:showNext(undone_cid)
    UIManager:unschedule(self._wake)
    self:dropPrefetch()
    local now = socket.gettime()
    local st, q = self.sched:queue(now, self.did)
    if undone_cid then
        local u = self.sched.cards[undone_cid]
        if u and not u.done and (not self.did or u.card.did == self.did) then st = u end
    end
    if self.nothing_due_at_start == nil then self.nothing_due_at_start = (st == nil) end
    self.counts = q
    self.current = st
    self.revealed = st ~= nil and undone_cid ~= nil and st.card.cid == undone_cid
    self.revealed_at = nil
    self.labels = st and self.sched:labels(st)
    local mode = "partial"
    if st then
        self.shown_at = now
        if self.answers_shown > 0 and self.answers_shown % FULL_REFRESH_EVERY == 0 and not self.revealed then
            mode = "full"
        end
    elseif q.next_learn then
        local wait = math.max(1, math.floor(q.next_learn - now))
        self._wake = self._wake or function() self:reload() end
        UIManager:scheduleIn(wait + 1, self._wake)
    end
    self:render(mode)
end

function Reviewer:reveal()
    if not self.current or self.revealed then return end
    self.revealed = true
    self.revealed_at = socket.gettime()
    -- only the card and the buttons change
    self:render("ui", true)
end

function Reviewer:answer(rating)
    local st = self.current
    if not st or not self.revealed then return end
    local now = socket.gettime()
    if self.revealed_at and now - self.revealed_at < REVEAL_GUARD then return end
    local entry, err = self.store:append{
        cid = st.card.cid,
        rating = rating,
        answered_at_ms = math.floor(now * 1000),
        taken_ms = math.floor((now - (self.shown_at or now)) * 1000),
        pack_id = self.pack.pack_id,
    }
    if not entry then
        logger.err("ankireview: cannot save answer:", err)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = T(_("Could not save your answer: %1"), tostring(err)) })
        return
    end
    self.tally[rating] = self.tally[rating] + 1
    self.tally.n = self.tally.n + 1
    self.tally.ms = self.tally.ms + entry.taken_ms
    self.answers_shown = self.answers_shown + 1
    self.sched:answer(st, rating, entry.answered_at_ms / 1000, entry)
    -- a new pack arrived meanwhile: start over from it
    local pack = self.store:loadPack()
    if pack and pack ~= self.pack then return self:reload() end
    self:showNext()
end

function Reviewer:onUndo()
    if not self.ack or not self.store:canUndo(self.ack) then return true end
    local entry = self.store:undo()
    if not entry then return true end
    local r = entry.rating
    if self.tally[r] and self.tally[r] > 0 then
        self.tally[r] = self.tally[r] - 1
        self.tally.n = self.tally.n - 1
        self.tally.ms = math.max(0, self.tally.ms - (entry.taken_ms or 0))
    end
    self:reload(entry.cid)
    UIManager:show(Notification:new{
        text = T(_("Undid last answer (%1)"), RATING_NAMES[r] or tostring(r)),
    })
    return true
end

------------------------------------------------------------------------------------------------------------
-- Rendering

function Reviewer:cssFor(mid)
    local css = self.css_cache[mid]
    if not css then
        css = ((self.pack and self.pack.css and self.pack.css[mid]) or "") .. EXTRA_CSS
        self.css_cache[mid] = css
    end
    return css
end

function Reviewer:htmlWidget(html, card, width, height)
    return ScrollHtmlWidget:new{
        html_body = '<div class="card">' .. (html or "") .. "</div>",
        css = self:cssFor(card.mid),
        html_resource_directory = self.store.media_dir,
        default_font_size = Screen:scaleBySize(Reviewer.fontSize(self.settings)),
        width = width,
        height = height,
        dialog = self,
    }
end

local function freeScroll(w)
    if w and w.htmlbox_widget then w.htmlbox_widget:free() end
end

--- Question side: widget, list of its ScrollHtmlWidgets.
function Reviewer:questionContent(st, width, height)
    local q = self.store:cardHtml(st.card, self.pack)
    local w = self:htmlWidget(q, st.card, width, height)
    return w, { w }
end

--- Answer side. Like Anki, when the answer repeats the question above an `<hr id=answer>`, the question part
--- gets its own scrolling area at the top (at most QUESTION_PART_MAX of the height) and the answer the rest.
function Reviewer:answerContent(st, width, height)
    local _q, a = self.store:cardHtml(st.card, self.pack)
    local qpart, apart = Reviewer.splitAnswer(a)
    if not qpart then
        local w = self:htmlWidget(a, st.card, width, height)
        return w, { w }
    end
    local gap = Size.padding.default
    local line_h = Size.line.thick
    local max_qh = math.floor(height * QUESTION_PART_MAX)
    local qw = self:htmlWidget(qpart, st.card, width, max_qh)
    if qw.htmlbox_widget.page_count == 1 then
        -- short question: only take the room it needs
        local used = qw:getSinglePageHeight()
        local min_qh = Screen:scaleBySize(30)
        if used and used + gap < max_qh then
            freeScroll(qw)
            qw = self:htmlWidget(qpart, st.card, width, math.max(min_qh, used + gap))
        end
    end
    -- page-turn keys drive the answer part, not the question part
    qw.key_events = {}
    local qh = qw:getSize().h
    local aw = self:htmlWidget(apart, st.card, width, height - qh - line_h - 2 * gap)
    local group = VerticalGroup:new{
        align = "left",
        qw,
        VerticalSpan:new{ width = gap },
        LineWidget:new{ dimen = Geom:new{ w = width, h = line_h }, background = Blitbuffer.COLOR_DARK_GRAY },
        VerticalSpan:new{ width = gap },
        aw,
    }
    return group, { qw, aw }
end

function Reviewer:doneContent(width, height)
    local lines = {}
    local title
    if self.message then
        title = self.message.title
        table.insert(lines, self.message.text)
    else
        title = _("Finished for now")
        local t = self.tally
        if t.n > 0 then
            local mins = t.ms / 60000
            local time_str = mins >= 1 and T(_("%1 min"), math.floor(mins + 0.5))
                or T(_("%1 s"), math.floor(t.ms / 1000 + 0.5))
            table.insert(lines, T(_("Reviewed %1 · %2"), t.n, time_str))
            table.insert(lines, T(_("Again %1 · Hard %2 · Good %3 · Easy %4"), t[1], t[2], t[3], t[4]))
            table.insert(lines, "")
        end
        if self.nothing_due_at_start and t.n == 0 then
            table.insert(lines, _("No cards were due in this pack. Sync with your PC to get new cards."))
        else
            table.insert(lines, _("No more cards due right now."))
        end
        local next_learn = self.counts and self.counts.next_learn
        if next_learn then
            local wait = math.max(1, math.floor(next_learn - socket.gettime()))
            table.insert(lines, T(_("Next learning card in %1."), Scheduler.formatDelay(wait)))
        end
        table.insert(lines, "")
        table.insert(lines, T(_("Cards from %1."), os.date("%Y-%m-%d %H:%M", math.floor(self.pack.generated_at / 1000))))
        local waiting = #self.sched.pending
        if waiting > 0 then
            table.insert(lines, T(N_("1 answer waiting to reach Anki (it syncs when the PC runs Anki).",
                "%1 answers waiting to reach Anki (they sync when the PC runs Anki).", waiting), waiting))
        end
    end
    local inner_w = width - 2 * Size.padding.large
    local group = VerticalGroup:new{
        align = "center",
        TextBoxWidget:new{
            text = title,
            face = Font:getFace("tfont"),
            bold = true,
            width = inner_w,
            alignment = "center",
        },
        VerticalSpan:new{ width = Size.padding.large * 2 },
        TextBoxWidget:new{
            text = table.concat(lines, "\n"),
            face = Font:getFace("infofont"),
            width = inner_w,
            alignment = "center",
        },
    }
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, group }
end

function Reviewer:subtitle()
    local c = self.counts
    if not c then return nil end
    return T(_("New %1 · Learn %2 · Review %3"), c.new, c.learn, c.review)
end

function Reviewer:staleText()
    if not self.pack then return nil end
    local age = Store.packAge(self.pack, socket.gettime())
    if age < 1 then return nil end
    return T(N_("Cards are 1 day old — sync soon", "Cards are %1 days old — sync soon", age), age)
end

function Reviewer:buildButtons(width)
    local function btn(text, callback, enabled, font_size)
        return {
            text = text, callback = callback, enabled = enabled,
            height = self.button_height, font_size = font_size or 22,
        }
    end
    local row
    if self.current and self.revealed then
        row = {}
        for r = 1, 4 do
            local label = self.labels and self.labels[r]
            local text = RATING_NAMES[r]
            -- "✓" / "—" are placeholders for "leaves today's queue": show just the name then
            if label and label ~= "" and label ~= "✓" and label ~= "—" then text = text .. " · " .. label end
            table.insert(row, btn(text, function() self:answer(r) end, nil, 20)) -- "Again · <10m" fits a quarter
        end
    elseif self.current then
        row = { btn(_("Show answer"), function() self:reveal() end) }
    elseif self.pack then
        row = {
            btn(_("Undo"), function() self:onUndo() end, self.ack ~= nil and self.store:canUndo(self.ack)),
            btn(_("Refresh"), function() self:reload() end),
        }
    else
        row = { btn(_("Refresh"), function() self:reload() end) }
    end
    return ButtonTable:new{ width = width, buttons = { row }, zero_sep = true, show_parent = self }
end

function Reviewer:openMenu()
    local dialog
    local last = self.ack and self.store:lastUndoable(self.ack)
    local undo_text = last and T(_("Undo last answer (%1)"), RATING_NAMES[last.rating] or "?") or _("Undo last answer")
    dialog = ButtonDialog:new{
        buttons = {
            {{
                text = undo_text,
                enabled = last ~= nil,
                callback = function()
                    UIManager:close(dialog)
                    self:onUndo()
                end,
            }},
            {{
                text = T(_("Card font size: %1"), Reviewer.fontSize(self.settings)),
                callback = function()
                    UIManager:close(dialog)
                    Reviewer.showFontSizeDialog(self.settings, function()
                        self:dropPrefetch()
                        self:render("partial")
                    end)
                end,
            }},
            {{
                text = _("Refresh"),
                callback = function()
                    UIManager:close(dialog)
                    self:reload()
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

--- (Re)build the screen. `refresh`: e-ink refresh mode; `partial_region`: only refresh below the title bar.
function Reviewer:render(refresh, partial_region)
    local w, h = self.dimen.w, self.dimen.h
    self.titlebar = TitleBar:new{
        width = w,
        fullscreen = true,
        align = "left",
        with_bottom_line = true,
        title = self.deck_name or _("All decks"),
        title_shrink_font_to_fit = true,
        subtitle = self.sched and self:subtitle() or nil,
        subtitle_face = Font:getFace("x_smallinfofont"),
        info_text = self:staleText(),
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:openMenu() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local buttons = self:buildButtons(w - 2 * Size.padding.default)
    local pad = Size.padding.large
    local tb_h = self.titlebar:getHeight()
    local content_w = w - 2 * pad
    local content_h = h - tb_h - buttons:getSize().h - 2 * pad
    local old_live = self.live
    local content, live
    if self.current and self.revealed then
        local p = self.prefetch
        if p and p.st == self.current and p.w == content_w and p.h == content_h
                and p.font == Reviewer.fontSize(self.settings) then
            content, live = p.widget, p.live
            self.prefetch = nil
        else
            self:dropPrefetch()
            content, live = self:answerContent(self.current, content_w, content_h)
        end
    elseif self.current then
        content, live = self:questionContent(self.current, content_w, content_h)
    else
        content, live = self:doneContent(content_w, content_h), {}
    end
    for _, old in ipairs(old_live) do
        local kept = false
        for _, new in ipairs(live) do if new == old then kept = true end end
        if not kept then freeScroll(old) end
    end
    self.live = live
    self.content_w, self.content_h = content_w, content_h
    self.content_region = Geom:new{ x = 0, y = tb_h, w = w, h = content_h + 2 * pad }
    self[1] = FrameContainer:new{
        width = w, height = h,
        padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            self.titlebar,
            FrameContainer:new{ padding = pad, bordersize = 0, margin = 0, content },
            CenterContainer:new{ dimen = Geom:new{ w = w, h = buttons:getSize().h }, buttons },
        },
    }
    local region = partial_region and Geom:new{ x = 0, y = tb_h, w = w, h = h - tb_h } or self.dimen
    UIManager:setDirty(self, function() return refresh or "partial", region end)
    if self.current and not self.revealed then self:schedulePrefetch() end
end

------------------------------------------------------------------------------------------------------------
-- Answer-side prefetch: laid out and drawn right after the question is on screen, so revealing is instant.

function Reviewer:schedulePrefetch()
    self:dropPrefetch()
    local st = self.current
    self._prefetch_task = function()
        self._prefetch_task, self._prefetch_wrapper = nil, nil
        if self.closed or self.current ~= st or self.revealed then return end
        local ok, widget, live = pcall(self.answerContent, self, st, self.content_w, self.content_h)
        if not ok then
            logger.warn("ankireview: prefetch failed:", widget)
            return
        end
        for _, sw in ipairs(live) do sw.htmlbox_widget:_render() end -- draw page 1 now too
        self.prefetch = { st = st, w = self.content_w, h = self.content_h, font = Reviewer.fontSize(self.settings),
                          widget = widget, live = live }
    end
    self._prefetch_wrapper = UIManager:tickAfterNext(self._prefetch_task)
end

function Reviewer:dropPrefetch()
    if self._prefetch_wrapper then UIManager:unschedule(self._prefetch_wrapper) end
    if self._prefetch_task then UIManager:unschedule(self._prefetch_task) end
    self._prefetch_task, self._prefetch_wrapper = nil, nil
    if self.prefetch then
        for _, sw in ipairs(self.prefetch.live) do freeScroll(sw) end
        self.prefetch = nil
    end
end

------------------------------------------------------------------------------------------------------------
-- Input

function Reviewer:onTapReveal()
    if self.current and not self.revealed then
        self:reveal()
        return true
    end
end

function Reviewer:onSwipeReveal(_arg, ges)
    if ges and (ges.direction == "west" or ges.direction == "east") then
        return self:onTapReveal()
    end
end

function Reviewer:onForward()
    if not self.current then return true end
    if self.revealed then self:answer(Scheduler.GOOD) else self:reveal() end
    return true
end

function Reviewer:onBackward()
    -- (a long answer scrolls back first: the card widget gets the key before us)
    return self:onUndo()
end

function Reviewer:onClose()
    UIManager:close(self, "full")
    if self.on_close then self.on_close() end
    return true
end

function Reviewer:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self._wake)
    self:dropPrefetch()
    for _, sw in ipairs(self.live) do freeScroll(sw) end
    self.live = {}
end

return Reviewer
