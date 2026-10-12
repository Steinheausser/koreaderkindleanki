-- Headless run of the plugin's UI with KOReader's real widgets, on a fake 1072x1448 300 dpi touch screen
-- (a blitbuffer in memory: nothing is drawn on the real display, no input devices are opened).
-- Drives the reviewer (question, tap to reveal, answer, undo, menu, font size, done screen) and main.lua's menu.
-- Writes screenshots (PNG) of each step into <work dir>.
--   cd /mnt/us/koreader && ./luajit <this> <plugin dir> <work dir> <exchange folder> [<exchange folder> ...]
-- Exchange folders are modified (answers are written): pass throw-away copies.
require("setupkoenv")
local plugin_dir, work = arg[1], arg[2]
local folders, perf_folder = {}, nil
for i = 3, #arg do
    if arg[i]:match("^perf=") then perf_folder = arg[i]:sub(6) else table.insert(folders, arg[i]) end
end
assert(plugin_dir and work and folders[1], "usage: headless_ui.lua <plugin dir> <work dir> <exchange folder>...")
package.path = plugin_dir .. "/?.lua;" .. package.path

G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(work .. "/settings.reader.lua") -- never the real settings

-- Fake device before anything requires "device"
local logger = require("logger")
local BB = require("ffi/blitbuffer")
local FB = require("ffi/framebuffer")
local fake_fb = {}
function fake_fb:init()
    self.bb = BB.new(1072, 1448, BB.TYPE_BB8)
    self.bb:fill(BB.COLOR_WHITE)
    FB.init(self)
end
local Screen = FB:extend(fake_fb)
local Generic = require("device/generic/device")
local function yes() return true end
local function no() return false end
local Dev = Generic:extend{
    model = "headless", display_dpi = 300,
    isTouchDevice = yes, hasKeys = no, hasKeyboard = no, hasEinkScreen = yes, hasColorScreen = no,
    hasFrontlight = no, isKindle = no, canUseCBB = yes,
}
function Dev:init()
    self.screen = Screen:new{ device = self, debug = logger.dbg }
    self.input = require("device/input"):new{ device = self, input = {} }
    Generic.init(self)
end
package.loaded["device"] = Dev
Dev:init()
require("document/canvascontext"):init(Dev)

local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")

-- count MuPDF documents opened / closed by HtmlBoxWidgets
local open_docs = 0
local orig_setContent, orig_free = HtmlBoxWidget.setContent, HtmlBoxWidget.free
HtmlBoxWidget.setContent = function(self, ...)
    if self.document then open_docs = open_docs - 1; self.document:close(); self.document = nil end
    orig_setContent(self, ...)
    open_docs = open_docs + 1
end
HtmlBoxWidget.free = function(self, ...)
    if self.document then open_docs = open_docs - 1 end
    return orig_free(self, ...)
end

local failures, n = 0, 0
local function check(cond, msg)
    n = n + 1
    if cond then print("ok   " .. msg) else failures = failures + 1; print("FAIL " .. msg) end
end
local shot_n = 0
local function shot(name)
    UIManager:forceRePaint()
    shot_n = shot_n + 1
    local path = string.format("%s/%02d-%s.png", work, shot_n, name)
    Dev.screen.bb:writePNG(path)
end
local function runTasks()
    for _ = 1, 6 do
        UIManager:_checkTasks()
        UIManager:_repaint()
    end
end
local function tap(widget, x, y)
    return widget:handleEvent(Event:new("Gesture", { ges = "tap", pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = time.now() }))
end
-- topmost window that isn't a toast notification
local function topWidget()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if not w.toast then return w end
    end
end
local function closeTop() UIManager:close(topWidget()) end
local function onStack(widget)
    for _, win in ipairs(UIManager._window_stack) do if win.widget == widget then return true end end
    return false
end

local Reviewer = require("ankireview_reviewer")
local Store = require("ankireview_store")

-- splitAnswer
do
    local q, a = Reviewer.splitAnswer('la maison\n\n<hr id=answer>\n\nthe house')
    check(q == "la maison\n\n" and a == "\n\nthe house", "splitAnswer: Anki's unquoted <hr id=answer>")
    q, a = Reviewer.splitAnswer('<b>Q</b><HR ID="answer" class="x">A')
    check(q == "<b>Q</b>" and a == "A", "splitAnswer: quoted, upper case, extra attributes")
    check(Reviewer.splitAnswer('<div> </div><hr id=answer>A') == nil, "splitAnswer: nothing visible before the rule")
    check(Reviewer.splitAnswer('<img src="x.png"><hr id=answer>A') ~= nil, "splitAnswer: image counts as visible")
    check(Reviewer.splitAnswer('Q<hr id=answers>A') == nil and Reviewer.splitAnswer('no rule') == nil, "splitAnswer: no rule")
end

local W, H = Dev.screen:getWidth(), Dev.screen:getHeight()
local settings = { font_size = 22, device_id = "headless" }
G_reader_settings:saveSetting("ankireview", settings)

for fi, folder in ipairs(folders) do
    print("=== exchange folder", folder)
    local store = Store.new(folder, "headless")
    local pack = assert(store:loadPack())
    print("pack format", pack.format, "cards", #pack.cards)
    check(require("libs/libkoreader-lfs").attributes(folder .. "/reviews", "mode") == "directory", "reviews dir exists (test copy)")

    local r = Reviewer:new{ store = store, settings = settings }
    UIManager:show(r)
    check(r.current ~= nil and not r.revealed, "question shown")
    shot(fi .. "-question")
    runTasks()
    check(r.prefetch ~= nil and r.prefetch.st == r.current, "answer side prefetched after the question was painted")

    -- buttons: one full-width Show answer, big enough, no Close
    local function buttonTexts()
        local out = {}
        for _, row in ipairs(r[1][1][3][1].buttons_layout) do
            for _, b in ipairs(row) do table.insert(out, b) end
        end
        return out
    end
    local bts = buttonTexts()
    check(#bts == 1 and bts[1].text == "Show answer", "question state: only Show answer")
    local bh = bts[1]:getSize().h
    print(string.format("button height %d px = %.1f mm", bh, bh / 300 * 25.4))
    check(bh >= 7 * 300 / 25.4 - 2, "Show answer button >= ~7 mm tall")

    -- tap on the card reveals (child ScrollHtmlWidget lets single-page taps through)
    local cr = r.content_region
    local pre = r.prefetch.widget
    tap(r, W * 3 / 4, cr.y + cr.h / 2)
    check(r.revealed, "tap on the card reveals the answer")
    check(r.prefetch == nil and r[1][1][2][1] == pre, "reveal reused the prefetched answer widget")
    shot(fi .. "-answer")
    bts = buttonTexts()
    local texts = {}
    for _, b in ipairs(bts) do
        table.insert(texts, b.text)
        check(not b.did_truncation_tweaks, "button '" .. b.text .. "' fits its width without shrinking")
    end
    print("answer buttons:", table.concat(texts, " | "))
    check(#bts == 4, "answer state: 4 rating buttons, no Close")
    local undo_close = false
    for _, t in ipairs(texts) do if t:find("Close") or t:find("Undo") then undo_close = true end end
    check(not undo_close, "no Close/Undo in the rating row")

    -- double tap guard: an immediate second tap on the Good button is ignored
    local answered_cid = r.current.card.cid
    local gx, gy = bts[3].dimen.x + bts[3].dimen.w / 2, bts[3].dimen.y + bts[3].dimen.h / 2
    tap(r, gx, gy)
    check(r.current.card.cid == answered_cid and r.revealed, "tap within 0.4 s of revealing is ignored")
    r.revealed_at = 0
    local rev_before = store.rev
    tap(r, gx, gy)
    runTasks()
    check(store.rev == rev_before + 1, "tapping Good logged one answer")
    check(r.tally[3] == 1 and r.tally.n == 1, "tally counts Good")
    check(#store.session_entries == 1, "session has 1 entry")
    check(not r.revealed, "next card shows its question")

    -- undo via the title bar menu
    r:openMenu()
    local menu = topWidget()
    check(menu ~= r, "menu dialog opened")
    shot(fi .. "-menu")
    closeTop()
    r:onUndo()
    runTasks()
    check(r.current and r.current.card.cid == answered_cid and r.revealed, "undo shows the undone card, answer side")
    check(r.tally.n == 0 and r.tally[3] == 0, "tally decremented on undo")
    check(#store.session_entries == 0, "undo removed the entry")
    shot(fi .. "-undone")

    -- font size change re-renders
    settings.font_size = 30
    r:dropPrefetch(); r:render("partial")
    runTasks()
    shot(fi .. "-font30")
    settings.font_size = 22

    -- answer everything until done (Good / Easy alternately), checking that the wake timer is not stale
    local guard = 0
    while r.current and guard < 200 do
        guard = guard + 1
        if not r.revealed then r:reveal() end
        r.revealed_at = 0
        r:answer(guard % 2 == 0 and 4 or 3)
        runTasks()
    end
    check(r.current == nil, "reached the done screen after " .. guard .. " answers")
    shot(fi .. "-done")
    local done_text = r[1][1][2][1][1][3].text
    print("done screen text:\n" .. done_text)
    check(done_text:find("Reviewed " .. r.tally.n, 1, true) ~= nil and done_text:find("Good " .. r.tally[3], 1, true) ~= nil,
        "done screen has the session summary")

    -- undo from the done screen
    local last_n = r.tally.n
    r:onUndo()
    runTasks()
    check(r.current ~= nil and r.revealed and r.tally.n == last_n - 1, "undo from the done screen")
    r.revealed_at = 0
    r:answer(3)
    runTasks()

    -- refresh
    r:reload()
    runTasks()
    check(r.current == nil, "refresh keeps the done screen")
    r:onClose()
    runTasks()
    check(not onStack(r), "reviewer closed")
    check(open_docs == 0, "all MuPDF documents freed (open: " .. open_docs .. ")")
end

-- Every card's answer side (split view for <hr id=answer>), from the last folder
do
    local folder = folders[#folders]
    local store = Store.new(folder, "headless")
    local r = Reviewer:new{ store = store, settings = settings }
    UIManager:show(r)
    for i, st in ipairs(r.sched.order) do
        r:dropPrefetch()
        r.current, r.labels, r.revealed = st, r.sched:labels(st), true
        r:render("partial")
        shot("card" .. i)
    end
    r:onClose()
    runTasks()
    check(open_docs == 0, "all MuPDF documents freed after rendering every card (open: " .. open_docs .. ")")
end

-- Timing on a big pack (a throw-away copy): open, reveal, answer, as the device CPU sees it
if perf_folder then
    local socket = require("socket")
    local function ms(t) return (socket.gettime() - t) * 1000 end
    local store = Store.new(perf_folder, "headless")
    local t = socket.gettime()
    local r = Reviewer:new{ store = store, settings = settings }
    UIManager:show(r)
    UIManager:forceRePaint()
    print(string.format("perf: open reviewer + first question painted: %.0f ms (includes pack load)", ms(t)))
    local reveal, answer, prefetch, n_split = {}, {}, {}, 0
    for i = 1, 20 do
        t = socket.gettime(); runTasks(); table.insert(prefetch, ms(t))
        t = socket.gettime(); r:reveal(); UIManager:forceRePaint(); table.insert(reveal, ms(t))
        if r.live[2] then n_split = n_split + 1 end
        r.revealed_at = 0
        t = socket.gettime(); r:answer(i % 3 == 0 and 1 or 3); UIManager:forceRePaint(); table.insert(answer, ms(t))
        if not r.current then break end
    end
    local function stats(list)
        table.sort(list)
        local sum = 0
        for _, v in ipairs(list) do sum = sum + v end
        return string.format("avg %.0f ms, median %.0f, max %.0f", sum / #list, list[math.ceil(#list / 2)], list[#list])
    end
    print("perf: prefetch (background, after question painted): " .. stats(prefetch))
    print("perf: reveal -> painted (prefetched): " .. stats(reveal))
    print("perf: answer -> next question painted: " .. stats(answer))
    print("perf: split answer views:", n_split)
    -- every card with an <hr id=answer> rule: build (and draw) the split answer view
    local n_rule, n_built, worst = 0, 0, 0
    for _, st in ipairs(r.sched.order) do
        local _q, a = store:cardHtml(st.card, r.pack)
        if a:find("<hr", 1, true) then
            n_rule = n_rule + 1
            t = socket.gettime()
            local widget, live = r:answerContent(st, r.content_w, r.content_h)
            for _, sw in ipairs(live) do sw.htmlbox_widget:_render() end
            worst = math.max(worst, ms(t))
            if #live == 2 then n_built = n_built + 1 end
            assert(widget:getSize().h <= r.content_h + 1, "answer view taller than the content area")
            for _, sw in ipairs(live) do sw.htmlbox_widget:free() end
        end
    end
    print(string.format("perf: cards with <hr>: %d, shown split: %d, slowest build+draw %.0f ms", n_rule, n_built, worst))
    -- a question longer than the screen (largest font): taps scroll it first, then reveal
    settings.font_size = 44
    local long
    for _, st in ipairs(r.sched.order) do
        local q = store:cardHtml(st.card, r.pack)
        if #q > 1500 then
            r:dropPrefetch()
            r.current, r.labels, r.revealed = st, r.sched:labels(st), false
            r:render("partial")
            UIManager:forceRePaint()
            if r.live[1].htmlbox_widget.page_count > 1 then long = st; break end
        end
    end
    if long then
        local hb = r.live[1].htmlbox_widget
        local pages = hb.page_count
        local cr = r.content_region
        local x, y = W * 3 / 4, cr.y + cr.h / 2
        for i = 2, pages do
            tap(r, x, y); UIManager:forceRePaint()
            check(hb.page_number == i and not r.revealed, "multi-page question: tap " .. (i - 1) .. " scrolls to page " .. i)
        end
        tap(r, W / 4, cr.y + cr.h / 2); UIManager:forceRePaint()
        check(hb.page_number == pages - 1 and not r.revealed, "multi-page question: left tap scrolls back")
        tap(r, x, y); UIManager:forceRePaint()
        tap(r, x, y); UIManager:forceRePaint()
        check(r.revealed, "multi-page question: tap on the last page reveals")
        shot("long-answer")
    else
        print("perf: no question longer than one page found")
    end
    settings.font_size = 22
    check(n_rule > 0 and n_built == n_rule, "every <hr id=answer> card of the big pack gets the split view")
    r:onClose()
    runTasks()
    collectgarbage(); collectgarbage()
    print(string.format("perf: Lua heap after closing %d KB", math.floor(collectgarbage("count"))))
    check(open_docs == 0, "perf: all MuPDF documents freed (open: " .. open_docs .. ")")
end

-- Font size dialog
Reviewer.showFontSizeDialog(settings, function() end)
check(topWidget().title_text == "Card font size" and topWidget().value == 22, "font size dialog opens with the current size")
shot("fontsize-dialog")
closeTop()

-- main.lua: menu with a pack, and without one
local AnkiReview = require("main")
for _, case in ipairs({ { folder = folders[1], name = "with pack" }, { folder = work .. "/empty", name = "no pack" } }) do
    settings.folder = case.folder
    G_reader_settings:saveSetting("ankireview", settings)
    local plugin = AnkiReview:new{
        ui = { menu = { registerToMainMenu = function() end } },
        path = "plugins/ankireview.koplugin",
    }
    local items = {}
    plugin:addToMainMenu(items)
    print("--- main menu, " .. case.name)
    print("review all:", items.ankireview_review_all.text_func())
    print("font size:", items.ankireview_font_size.text_func())
    print("sync item:", items.ankireview_sync.text)
    for _, it in ipairs(plugin:deckItems()) do
        print("deck item:", it.text, it.sub_item_table and ("[" .. #it.sub_item_table .. " finished]") or "")
    end
    print("status:\n" .. plugin:statusText())
    plugin:openReviewer(nil, nil)
    local top = topWidget()
    if case.name == "no pack" then
        check(top.text ~= nil and top.text:find("No card pack yet", 1, true) ~= nil,
            "no pack: Review all shows the explanation instead of a reviewer")
        check(require("libs/libkoreader-lfs").attributes(case.folder .. "/reviews") == nil, "no pack: reviews/ not created")
    else
        check(top.store ~= nil, "with pack: Review all opens the reviewer")
    end
    shot("main-" .. case.name:gsub(" ", "-"))
    closeTop()
    runTasks()
end
local order = require("ui/elements/filemanager_menu_order")
print("tab items:", table.concat(order.ankireview, ", "))

print(string.format("%d/%d passed", n - failures, n))
os.exit(failures == 0 and 0 or 1)
