--[[--
Anki review: offline spaced-repetition reviews of cards exported by the Anki Desktop "kindle_review" add-on.

@module koplugin.ankireview
]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")
local T = require("ffi/util").template
local _ = require("gettext")

local DEFAULT_FOLDER = "/mnt/us/anki-kindle"

local AnkiReview = WidgetContainer:extend{
    name = "ankireview",
    is_doc_only = false,
}

function AnkiReview:init()
    self.settings = G_reader_settings:readSetting("ankireview", {})
    if not self.settings.device_id then
        self.settings.device_id = string.format("%s-%x", (Device.model or "kindle"):gsub("[^%w]", ""), os.time())
        G_reader_settings:saveSetting("ankireview", self.settings)
    end
    self.ui.menu:registerToMainMenu(self)
end

function AnkiReview:folder()
    return self.settings.folder or DEFAULT_FOLDER
end

function AnkiReview:getStore()
    local Store = require("ankireview_store")
    local folder = self:folder()
    if not self.store or self.store.folder ~= folder then
        self.store = Store.new(folder, self.settings.device_id)
    end
    return self.store
end

function AnkiReview:openReviewer(did, deck_name, touchmenu_instance)
    local Reviewer = require("ankireview_reviewer")
    UIManager:show(Reviewer:new{
        store = self:getStore(),
        did = did,
        deck_name = deck_name,
        on_close = function()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

function AnkiReview:deckItems()
    local store = self:getStore()
    local pack, err = store:loadPack()
    if not pack then
        return {{
            text = _("No card pack yet"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("No readable card pack in %1 (%2).\n\nShare the 'anki-kindle' Syncthing folder with this Kindle and let Anki Desktop (with the Kindle review add-on) run once."),
                        self:folder(), tostring(err)),
                })
            end,
        }}
    end
    local ack = store:loadAck()
    store:cleanup(pack, ack)
    local Scheduler = require("ankireview_scheduler")
    local sched = Scheduler.new(pack, store:pendingEntries(pack, ack))
    local per, total = sched:counts(socket.gettime())
    local function label(name, c)
        return T(_("%1  —  %2 new · %3 learn · %4 review"), name, c.new, c.learn, c.review)
    end
    local items = {{
        text = label(_("All decks"), total),
        callback = function(touchmenu_instance) self:openReviewer(nil, nil, touchmenu_instance) end,
        separator = true,
    }}
    local decks = {}
    for did, d in pairs(pack.decks) do
        local c = per[tonumber(did)]
        if c then table.insert(decks, { did = tonumber(did), name = d.name, c = c }) end
    end
    table.sort(decks, function(a, b) return a.name < b.name end)
    for _, d in ipairs(decks) do
        table.insert(items, {
            text = label(d.name, d.c),
            callback = function(touchmenu_instance) self:openReviewer(d.did, d.name, touchmenu_instance) end,
        })
    end
    if #decks == 0 then
        items[1].separator = nil
    end
    return items
end

function AnkiReview:statusText()
    local store = self:getStore()
    local pack = store:loadPack()
    if not pack then return T(_("Exchange folder: %1\nNo card pack yet."), self:folder()) end
    local ack = store:loadAck()
    local waiting = #store:pendingEntries(pack, ack)
    local skipped = 0
    for _ in pairs(ack.skipped) do skipped = skipped + 1 end
    local lines = {
        T(_("Exchange folder: %1"), self:folder()),
        T(_("Card pack from %1 (%2 cards)."), os.date("%Y-%m-%d %H:%M", math.floor(pack.generated_at / 1000)), #pack.cards),
        T(_("Answers not yet in Anki: %1"), waiting),
    }
    if ack.updated_at then
        table.insert(lines, T(_("Anki last confirmed answers at %1."), os.date("%Y-%m-%d %H:%M", math.floor(ack.updated_at / 1000))))
    end
    if skipped > 0 then
        table.insert(lines, T(_("%1 answers were not applied (card changed elsewhere)."), skipped))
    end
    return table.concat(lines, "\n")
end

-- Talk to the Syncthing instance run by KOReader's Syncthing plugin (REST API on this device).
local SYNC_FOLDER_ID = "anki-kindle"

local function syncthingApi()
    local DataStorage = require("datastorage")
    local f = io.open(DataStorage:getSettingsDir() .. "/syncthing/config.xml", "r")
    if not f then return nil, _("Syncthing is not set up in KOReader.") end
    local xml = f:read("*a")
    f:close()
    local gui = xml:match("<gui.->(.-)</gui>") or ""
    local key = gui:match("<apikey>(.-)</apikey>")
    local port = (gui:match("<address>.-:(%d+)</address>")) or "8384"
    if not key then return nil, _("Could not read Syncthing's API key.") end
    return { base = "http://127.0.0.1:" .. port, key = key }
end

local function syncthingRequest(api, method, path)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local rapidjson = require("rapidjson")
    local socketutil = require("socketutil")
    local body = {}
    socketutil:set_timeout(3, 6)
    local _ok, code = http.request{
        url = api.base .. path,
        method = method,
        headers = { ["X-API-Key"] = api.key },
        sink = ltn12.sink.table(body),
    }
    socketutil:reset_timeout()
    if code ~= 200 then return nil, code end
    local text = table.concat(body)
    if text == "" then return {} end
    local ok, data = pcall(rapidjson.decode, text)
    return ok and data or {}
end

function AnkiReview:syncNow()
    local api, err = syncthingApi()
    if not api then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    -- Start Syncthing through its own plugin if it isn't running (it doesn't autostart by default).
    -- KOReader registers plugins under their folder name (syncthing.koplugin -> self.ui.syncthing).
    local st_plugin = self.ui.syncthing
    if st_plugin and st_plugin.isRunning and st_plugin.start then
        if not st_plugin:isRunning() then
            logger.info("ankireview: starting Syncthing")
            st_plugin:start()
        end
    else
        logger.warn("ankireview: Syncthing plugin not found; cannot start it")
    end
    local attempts = 0
    local function scan()
        attempts = attempts + 1
        local ok, code = syncthingRequest(api, "POST", "/rest/db/scan?folder=" .. SYNC_FOLDER_ID)
        if ok then
            UIManager:show(InfoMessage:new{ text = _("Syncing with your PC…"), timeout = 4 })
            UIManager:scheduleIn(5, function() self:reportSync(api) end)
        elseif code == 404 then
            UIManager:show(InfoMessage:new{ text = T(_("Syncthing has no '%1' folder."), SYNC_FOLDER_ID) })
        elseif attempts < 15 then
            UIManager:scheduleIn(2, scan) -- Syncthing takes a few seconds to bring its API up
        else
            logger.warn("ankireview: Syncthing API not answering after", attempts, "attempts:", code)
            UIManager:show(InfoMessage:new{
                text = _("Syncthing isn't responding. Start it from KOReader's Syncthing menu, then try again."),
            })
        end
    end
    scan()
end

function AnkiReview:reportSync(api)
    local status = syncthingRequest(api, "GET", "/rest/db/status?folder=" .. SYNC_FOLDER_ID) or {}
    local conns = syncthingRequest(api, "GET", "/rest/system/connections") or {}
    local connected = false
    for _id, c in pairs(conns.connections or {}) do
        if c.connected then connected = true end
    end
    local lines = {}
    table.insert(lines, connected and _("PC connected.")
        or _("PC not reachable yet: is it on, on the same network, with Syncthing running? (It can take a minute after starting.)"))
    if (tonumber(status.needFiles) or 0) > 0 then
        table.insert(lines, T(_("Still receiving %1 files from the PC…"), status.needFiles))
    end
    local store = self:getStore()
    local pack = store:loadPack()
    if pack then
        local waiting = #store:pendingEntries(pack, store:loadAck())
        table.insert(lines, waiting > 0
            and T(_("%1 answers waiting for Anki on the PC (open Anki to apply them)."), waiting)
            or _("All your answers are in Anki."))
        table.insert(lines, T(_("Cards from %1."), os.date("%Y-%m-%d %H:%M", math.floor(pack.generated_at / 1000))))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

-- Our own tab in the top menu bar, right after Tools, in both the file browser and the reader.
local TAB_ITEMS = { "ankireview_review_all", "ankireview_decks", "----------------------------",
                    "ankireview_sync", "ankireview_status", "ankireview_folder" }

function AnkiReview:addTab()
    -- addToMainMenu runs before the menu is sorted, so the (shared, cached) order table can be extended here.
    local order = require(self.ui.document and "ui/elements/reader_menu_order" or "ui/elements/filemanager_menu_order")
    local buttons = order["KOMenu:menu_buttons"]
    for _i, id in ipairs(buttons) do
        if id == "ankireview" then return end
    end
    local pos = #buttons + 1
    for i, id in ipairs(buttons) do
        if id == "tools" then pos = i + 1 end
    end
    table.insert(buttons, pos, "ankireview")
    order.ankireview = TAB_ITEMS
end

function AnkiReview:addToMainMenu(menu_items)
    self:addTab()
    menu_items.ankireview = {
        -- Icons are looked up relative to KOReader's icon folders; this resolves to our own plugin folder.
        icon = self.path and self.path:sub(1, 1) ~= "/" and ("../../../" .. self.path .. "/appbar.ankireview")
            or "appbar.tools",
        text = _("Anki review"),
    }
    menu_items.ankireview_review_all = {
        text_func = function()
            local store = self:getStore()
            local pack = store:loadPack()
            if not pack then return _("Review all decks (no cards yet)") end
            local Scheduler = require("ankireview_scheduler")
            local _per, total = Scheduler.new(pack, store:pendingEntries(pack, store:loadAck())):counts(socket.gettime())
            return T(_("Review all decks  —  %1 new · %2 learn · %3 review"), total.new, total.learn, total.review)
        end,
        callback = function(touchmenu_instance) self:openReviewer(nil, nil, touchmenu_instance) end,
    }
    menu_items.ankireview_decks = {
        text = _("Decks"),
        sub_item_table_func = function() return self:deckItems() end,
    }
    menu_items.ankireview_sync = {
        text = _("Sync now"),
        keep_menu_open = true,
        callback = function()
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenOnline(function() self:syncNow() end)
        end,
    }
    menu_items.ankireview_status = {
        text = _("Status"),
        keep_menu_open = true,
        callback = function() UIManager:show(InfoMessage:new{ text = self:statusText() }) end,
    }
    menu_items.ankireview_folder = {
        text_func = function() return T(_("Exchange folder: %1"), self:folder()) end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local PathChooser = require("ui/widget/pathchooser")
            UIManager:show(PathChooser:new{
                select_file = false,
                path = lfs.attributes(self:folder(), "mode") == "directory" and self:folder() or "/mnt/us",
                onConfirm = function(path)
                    self.settings.folder = path
                    G_reader_settings:saveSetting("ankireview", self.settings)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

return AnkiReview
