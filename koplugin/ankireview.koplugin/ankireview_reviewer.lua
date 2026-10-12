--[[--
Full-screen offline reviewer: question → Show answer → Again / Hard / Good / Easy.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Scheduler = require("ankireview_scheduler")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local socket = require("socket")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen

local FULL_REFRESH_EVERY = 6

local EXTRA_CSS = [[
@page { margin: 0; }
body { margin: 0; }
body .card { font-size: 1em; color: black; background-color: white; }
.cloze { font-weight: bold; color: black; }
img { max-width: 100%; }
.mj-display { text-align: center; margin: 0.4em 0; }
hr#answer { margin: 0.6em 0; }
]]

local Reviewer = InputContainer:extend{
    store = nil,      -- Store
    did = nil,        -- deck id to review, nil = all decks
    deck_name = nil,
    on_close = nil,
}

function Reviewer:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.answers_shown = 0
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.Forward = { { Device.input.group.PgFwd } }
        self.key_events.Backward = { { Device.input.group.PgBack } }
    end
    self.store:startSession()
    self:reload()
end

function Reviewer:reload()
    local pack, err = self.store:loadPack()
    if not pack then
        self.pack, self.sched, self.current = nil, nil, nil
        self.message = T(_("Cannot read the card pack: %1"), tostring(err))
        return self:render()
    end
    self.pack = pack
    self.ack = self.store:loadAck()
    self.sched = Scheduler.new(pack, self.store:pendingEntries(pack, self.ack))
    local now = socket.gettime()
    local st, next_learn = self.sched:nextCard(now, self.did)
    self.current, self.revealed, self.message = st, false, nil
    if st then
        self.shown_at = now
    else
        self:showDone(now, next_learn)
    end
    self:render()
end

function Reviewer:showDone(now, next_learn)
    local lines = { _("No more cards due right now.") }
    if next_learn then
        local wait = math.max(1, math.floor(next_learn - now))
        table.insert(lines, T(_("Next learning card in %1."), Scheduler.formatDelay(wait)))
        UIManager:unschedule(self._wake)
        self._wake = function() self:reload() end
        UIManager:scheduleIn(wait + 1, self._wake)
    end
    table.insert(lines, "")
    table.insert(lines, T(_("Card pack from %1."), os.date("%Y-%m-%d %H:%M", math.floor(self.pack.generated_at / 1000))))
    local waiting = #self.sched.pending
    if waiting > 0 then
        table.insert(lines, T(_("%1 answers waiting to reach Anki (they sync when the PC runs Anki)."), waiting))
    end
    self.message = table.concat(lines, "\n")
end

function Reviewer:subtitle()
    local learn, review, new = self.sched:available(socket.gettime(), self.did)
    return T(_("New %1 · Learn %2 · Review %3"), #new, #learn, #review)
end

function Reviewer:buildButtons(width)
    local rows = {}
    local undo = {
        text = _("Undo"),
        enabled = self.store:canUndo(self.ack or { applied = {}, skipped = {} }),
        callback = function() self:onUndo() end,
    }
    if self.current and self.revealed then
        local labels = self.sched:labels(self.current)
        local names = { _("Again"), _("Hard"), _("Good"), _("Easy") }
        local row = {}
        for r = 1, 4 do
            table.insert(row, {
                text = names[r] .. " · " .. tostring(labels[r] or ""),
                callback = function() self:answer(r) end,
            })
        end
        table.insert(rows, row)
        table.insert(rows, { undo, { text = _("Close"), callback = function() self:onClose() end } })
    elseif self.current then
        table.insert(rows, { undo, { text = _("Show answer"), callback = function() self:reveal() end } })
    else
        table.insert(rows, {
            undo,
            { text = _("Refresh"), callback = function() self:reload() end },
            { text = _("Close"), callback = function() self:onClose() end },
        })
    end
    return ButtonTable:new{ width = width, buttons = rows, zero_sep = true, show_parent = self }
end

function Reviewer:render()
    local w, h = self.dimen.w, self.dimen.h
    local title = self.deck_name or _("All decks")
    self.titlebar = TitleBar:new{
        width = w,
        fullscreen = true,
        align = "left",
        with_bottom_line = true,
        title = title,
        subtitle = self.sched and self:subtitle() or nil,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local buttons = self:buildButtons(w - 2 * Size.padding.default)
    local pad = Size.padding.large
    local content_h = h - self.titlebar:getHeight() - buttons:getSize().h - 2 * pad
    local content
    if self.current then
        local c = self.current.card
        local html = self.revealed and c.a or c.q
        content = ScrollHtmlWidget:new{
            html_body = '<div class="card">' .. (html or "") .. "</div>",
            css = (self.pack.css[c.mid] or "") .. EXTRA_CSS,
            html_resource_directory = self.store.media_dir,
            default_font_size = Screen:scaleBySize(22),
            width = w - 2 * pad,
            height = content_h,
            dialog = self,
        }
    else
        content = TextBoxWidget:new{
            text = self.message or "",
            face = Font:getFace("infofont"),
            width = w - 2 * pad,
            height = content_h,
            alignment = "center",
        }
    end
    self.content = content
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
    -- e-ink: a flashing refresh every few cards clears ghosting; otherwise a fast partial one
    local mode = (self.answers_shown > 0 and self.answers_shown % FULL_REFRESH_EVERY == 0 and not self.revealed)
        and "full" or "ui"
    UIManager:setDirty(self, function() return mode, self.dimen end)
end

function Reviewer:reveal()
    if not self.current or self.revealed then return end
    self.revealed = true
    self:render()
end

function Reviewer:answer(rating)
    local st = self.current
    if not st or not self.revealed then return end
    local now = socket.gettime()
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
    self.answers_shown = self.answers_shown + 1
    self:reload()
end

function Reviewer:onUndo()
    if self.store:canUndo(self.ack or { applied = {}, skipped = {} }) then
        self.store:undo()
        self:reload()
        -- show the undone card's answer side again, like Anki
        if self.current then self.revealed = true; self:render() end
    end
    return true
end

function Reviewer:onForward()
    if not self.current then return true end
    if self.revealed then self:answer(Scheduler.GOOD) else self:reveal() end
    return true
end

function Reviewer:onBackward()
    if self.current and self.revealed then self:answer(Scheduler.AGAIN) end
    return true
end

function Reviewer:onClose()
    UIManager:unschedule(self._wake)
    UIManager:close(self, "full")
    if self.on_close then self.on_close() end
    return true
end

function Reviewer:onCloseWidget()
    UIManager:unschedule(self._wake)
end

return Reviewer
