local ADDON, ns = ...

--========================================================================
-- Config
--========================================================================
local CHAT_TAG      = "GFMqp1:"   -- marks our hidden chat-channel protocol messages
                                  -- (broadcast queries; addon messages over custom
                                  --  channels are dropped in Classic Era, so we ride the
                                  --  chat layer like GreenWall does and filter it from view)
                                  -- (the whisper send queue + channel join live in Transport.lua)
local QUERY_SETTLE  = 5             -- seconds we collect responses for a search
local SELLER_CAP    = 150           -- max distinct sellers a scan collects (protects the scanner)
local SCAN_JITTER   = 2.0           -- seconds sellers spread scan replies over (unfiltered scan)
local FILTER_MIN    = 3             -- min chars before a seller-name scan goes over the network
ns.SELLER_CAP = SELLER_CAP
ns.FILTER_MIN = FILTER_MIN
ns.QUERY_SETTLE = QUERY_SETTLE
ns.SCAN_JITTER = SCAN_JITTER

--========================================================================
-- State
--========================================================================
local playerName = UnitName("player")
ns.playerName = playerName
ns.CHAT_TAG = CHAT_TAG    -- the channel broadcast tag, used by the feature send sites

ns.config       = nil   -- parsed confederation config from guild info
ns.channelName  = nil   -- private channel derived from the config secret
ns.channelIndex = nil

-- Buyer search-by-item state, grouped under one owned table.
ns.search = {
    results = {},   -- [sellerName#suffix] = { seller, suffix, qty, price, loc } for the active search
    itemID  = nil,  -- the item currently being searched
    -- set while a search runs: active (in flight), start (GetTime when it began)
}

-- Browse-by-seller state, grouped under one owned table. The index only carries a summary
-- per seller; a seller's full catalog is fetched lazily (a directed whisper) when opened.
ns.sellers = {
    results = {},   -- [sellerName] = { count, loc }  index summaries from a scan
    catalog = nil,  -- { seller, loc, items = {...}, loading }  the open seller's catalog
    -- set while a scan runs: scanStart, openStart, filter, scanning, count, capped, pendingOpen
}

-- Browse-by-category state. A category query (class + subclass) collects matching offers
-- from many sellers at once; results span many items, keyed by seller + item + variant.
ns.browseResults = {}   -- [seller#id#suffix] = { seller, id, suffix, qty, price, self }
ns.browseClass   = nil  -- active query's classID / subClassID (for the UI status + own-offer match)
ns.browseSub     = nil

-- Version detection: ride our version along on the broadcasts (appended, so old clients
-- ignore it), track the highest seen, and flag when we're behind.
ns.version = ((C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata)(ADDON, "Version") or "?"
ns.latestVersion = ns.version

function ns.Feedback(msg, isError)
    if msg and msg ~= "" then
        print("|cff00ff96GFM|r: " .. msg)
        if ns.dev and ns.Log then ns.Log("feedback: " .. msg) end   -- mirror into the Debug sidebar in dev mode
    end
end

-- Dev one-off output goes to the Debug sidebar only (copy-pasteable), not chat.
local function devEcho(msg)
    if ns.Log then ns.Log(msg) end
end

-- Listings paused (e.g. while raiding/PvP): items are kept, but we stop answering
-- other players' searches and seller-browse scans. Per-character, like the offers.
local function isPaused() return GuildFoundMarketCharDB and GuildFoundMarketCharDB.paused end
ns.IsPaused = isPaused

local function liveLoc()
    local s = GetSubZoneText()
    if not s or s == "" then s = GetZoneText() or "" end
    return s:gsub("~", " ")
end
ns.LiveLoc = liveLoc

-- Apply the aux-seed setting onto the field the ItemDB seeding actually reads. Idempotent.
ns.On("setting:auxSeed", function(on) GuildFoundMarketDB.disableAux = not on end)

--========================================================================
-- Bootstrap
--========================================================================
local function requestGuildData()
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
    elseif GuildRoster then GuildRoster() end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("CHAT_MSG_SYSTEM")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        GuildFoundMarketDB = GuildFoundMarketDB or {}
        GuildFoundMarketDB.names = GuildFoundMarketDB.names or {}
        GuildFoundMarketDB.quals = GuildFoundMarketDB.quals or {}
        GuildFoundMarketCharDB = GuildFoundMarketCharDB or {}
        GuildFoundMarketCharDB.offers = GuildFoundMarketCharDB.offers or {}
        -- migrate legacy offers keyed by a bare numeric itemID to the "itemID:suffix" form
        do
            local off, legacy = GuildFoundMarketCharDB.offers, {}
            for k, o in pairs(off) do if type(k) == "number" then legacy[k] = o end end
            for k, o in pairs(legacy) do
                off[k] = nil
                o.id = o.id or k; o.suffix = o.suffix or 0
                off[ns.vkey(o.id, o.suffix)] = o
            end
        end

        ns.StartTransport()   -- register the addon prefix and start the whisper send queue
        -- hide our hidden-channel protocol chatter from every chat frame
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(_, _, msg)
            if msg and msg:sub(1, #CHAT_TAG) == CHAT_TAG then return true end
        end)
        ns.InstallShareLinks()   -- guild-chat shop-link rewrite + click handling
        if ns.CreateMinimapButton then ns.CreateMinimapButton() end
        -- push saved settings onto the bus so each feature reactor syncs to it. After the
        -- minimap exists and before aux seeding, since both react to a setting.
        if ns.ApplySettings then ns.ApplySettings() end

        ns.ItemDB.Load()
        ns.ItemDB.LearnFromBags()
        ns.ItemDB.SeedFromAux()

        requestGuildData()
        ns.RefreshConfig()
        for _, d in ipairs({ 2, 5, 10, 20 }) do
            C_Timer.After(d, function() requestGuildData(); ns.RefreshConfig() end)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.RefreshConfig()
        ns.RejoinChannel()

    elseif event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        ns.RefreshConfig()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, _, sender = ...
        if prefix == ns.PREFIX then ns.DispatchMessage(text, sender) end

    elseif event == "CHAT_MSG_CHANNEL" then
        local text, sender = ...
        if text and text:sub(1, #CHAT_TAG) == CHAT_TAG then
            if ns.dev then devEcho("|cff00ff96GFM|r received channel: " .. text:sub(#CHAT_TAG + 1) .. " (from " .. tostring(sender) .. ")") end
            ns.DispatchMessage(text:sub(#CHAT_TAG + 1), sender)
        end

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if msg and ERR_CHAT_THROTTLED and msg == ERR_CHAT_THROTTLED then
            ns.Log("THROTTLE: server says chat is being sent too quickly (channel broadcast may have dropped)")
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        ns.ItemDB.LearnFromBags()

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local itemID, success = ...
        ns.ItemDB.OnItemInfoReceived(itemID, success)
        if ns.RefreshBuySoon then ns.RefreshBuySoon() end
        if ns.RefreshMineSoon then ns.RefreshMineSoon() end
        if ns.RefreshSellerCatalogSoon then ns.RefreshSellerCatalogSoon() end
    end
end)

-- Slash command
SLASH_GFMARKET1 = "/gfm"
SLASH_GFMARKET2 = "/market"
SlashCmdList.GFMARKET = function(msg)
    msg = (msg or ""):lower():gsub("%s+", "")
    if msg == "dev" then
        ns.dev = not ns.dev
        print("|cff00ff96GFM|r: dev mode " .. (ns.dev and "ON" or "off"))
        if ns.UpdateDebugTitle then ns.UpdateDebugTitle() end
    elseif msg == "altsearch" then
        devEcho("|cff00ff96GFM altsearch|r")
        devEcho("  setting altClickSearch = " .. tostring(ns.GetSetting("altClickSearch")))
        local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
        local bagAddons = { "Bagnon", "Baganator", "ArkInventory", "AdiBags", "Combuctor", "BetterBags", "Baggins", "ElvUI" }
        local found = {}
        if loaded then for _, a in ipairs(bagAddons) do if loaded(a) then found[#found + 1] = a end end end
        devEcho("  bag addons detected: " .. (#found > 0 and table.concat(found, ", ") or "none (default Blizzard bags)"))
        devEcho("  HandleModifiedItemClick present: " .. tostring(type(HandleModifiedItemClick) == "function"))
        devEcho("  Alt + left-click an item now; watch for an \"ALT-SEARCH: item click id\" line below.")
        if ns.ToggleDebug and not (_G.GuildFoundMarketDebug and _G.GuildFoundMarketDebug:IsShown()) then ns.ToggleDebug() end
    elseif msg == "debug" then
        ns.RefreshConfig()
        local t = GetGuildInfoText() or ""
        local cur, max = ns.ItemDB.HarvestProgress()
        devEcho("|cff00ff96GFM debug|r")
        devEcho("  guild: " .. tostring(GetGuildInfo("player")))
        devEcho("  guildInfoText length: " .. #t)
        devEcho("  channelName: " .. tostring(ns.channelName) .. " | joined: " .. tostring(ns.channelIndex ~= nil))
        devEcho(("  item DB size: %d | harvest %d/%d (%s) | auxSeeded=%s | disableAux=%s"):format(
            ns.ItemDB.Count(), cur, max, ns.ItemDB.IsHarvesting() and "running" or "idle",
            tostring(GuildFoundMarketDB.auxSeeded), tostring(GuildFoundMarketDB.disableAux)))
        local n = 0; for _ in pairs(GuildFoundMarketCharDB.offers) do n = n + 1 end
        devEcho("  my offers: " .. n)
        if ns.ToggleDebug and not (_G.GuildFoundMarketDebug and _G.GuildFoundMarketDebug:IsShown()) then ns.ToggleDebug() end
    elseif msg == "harvest" then
        ns.ItemDB.StartHarvest()
        local cur, max = ns.ItemDB.HarvestProgress()
        ns.Feedback(("Harvest running: at item %d/%d, DB %d. Watch with /gfm debug."):format(cur, max, ns.ItemDB.Count()), false)
    elseif msg == "harveststop" then
        ns.ItemDB.StopHarvest(); ns.Feedback("Harvest stopped.", false)
    elseif msg == "minimap" then
        local on = ns.ToggleSetting("minimapButton")
        ns.Feedback("Minimap button " .. (on and "shown."
            or "hidden: type /gfm minimap to show it again, or open with /market."), false)
    elseif ns.dev and msg == "noaux" then
        local on = ns.ToggleSetting("auxSeed")
        ns.Feedback("aux seed " .. (on and "enabled" or "DISABLED")
            .. "; run /gfm dbreset to clear the current DB and test a clean build.", false)
    elseif ns.dev and msg == "dbreset" then
        ns.ItemDB.Reset()
        if ns.RefreshBuy then ns.RefreshBuy() end
        ns.Feedback("Item DB wiped (clean-install state). /gfm harvest to rebuild from scratch.", false)
    elseif ns.dev and msg == "selftest" then
        ns.selfTest = not ns.selfTest
        ns.Feedback("Self-test " .. (ns.selfTest and "ON: search an item you've listed in My Items to see your own offer." or "off") .. ".", false)
    elseif ns.dev and msg == "fakesellers" then
        wipe(ns.sellers.results)
        ns.sellers.results["Aldorin"]  = { count = 3,  loc = "Bank, Orgrimmar" }
        ns.sellers.results["Bigbags"]  = { count = 42, loc = "Auction House, Orgrimmar" }
        ns.sellers.results["Cheapcat"] = { count = 1,  loc = "The Crossroads" }
        local many = {}; for i = 1, 42 do many[i] = 700 + i end
        ns._fakeCat = { Aldorin = { 2589, 2592, 4338 }, Cheapcat = { 6948 }, Bigbags = many }
        ns.sellers.scanning = false
        if ns.RefreshSellers then ns.RefreshSellers() end
        ns.Feedback("Injected 3 fake sellers (one with 42 items); open the Sellers tab.", false)
    elseif ns.dev and msg == "faketest" then
        if not ns.search.itemID then
            ns.Feedback("Open Buy, search an item first, then /gfm faketest.", true)
        else
            ns.search.results["Testseller1#0"]  = { seller = "Testseller1",  suffix = 0, qty = 5,  price = 150000, loc = "Bank, Orgrimmar" }
            ns.search.results["Cheapcharlie#0"] = { seller = "Cheapcharlie", suffix = 0, qty = 20, price = 95000,  loc = "Auction House, Orgrimmar" }
            ns.search.results["Bidderbob#0"]    = { seller = "Bidderbob",    suffix = 0, qty = 1,  price = 0,      loc = "The Crossroads" }
            if ns.RefreshBuy then ns.RefreshBuy() end
            ns.Feedback("Injected 3 fake offers into the current search.", false)
        end
    else
        ns.ToggleUI()
    end
end
