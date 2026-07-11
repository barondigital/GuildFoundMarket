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

-- The sellers/buyers index cap is player-tunable (Options > Network): a bigger, more
-- complete index versus a lighter, snappier scan. Purely client-side (it only limits what
-- THIS client stores; everyone replies regardless), so each player picks their own.
function ns.ScanCap() return tonumber(ns.GetSetting and ns.GetSetting("scanCap")) or SELLER_CAP end
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

-- Browse-by-buyer state (the buy-side mirror of ns.sellers). `find` holds the "who wants this
-- item?" results, `results` the buyer index, `catalog` one opened buyer's full want list.
-- `allWants` is every want across the confederation (the Buyers tab's default view), filled by
-- the all-wants sweep in BuyerBrowse.lua and upserted by item queries as they answer.
ns.buyers = {
    results = {},   -- [buyerName] = { count, loc }  index summaries from a scan
    catalog = nil,  -- { buyer, loc, items = {...}, loading }  the open buyer's want list
    find    = { itemID = nil, active = false, results = {} },  -- [buyer#suffix] = { buyer, suffix, qty, price, cod, loc, self }
    allWants = {},  -- [buyer#id#suffix] = { buyer, id, suffix, qty, price, cod, self }
    allScan  = { active = false, total = 0, done = 0 },   -- the all-wants sweep's progress
    -- set while a scan runs: scanStart, filter, scanning, count, capped, pendingOpen
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

-- ns.Feedback is defined once, in UI.lua (status line with print fallback). It used to be
-- defined here too, but UI loads last so this copy was always dead.

-- Dev one-off output goes to the Debug sidebar only (copy-pasteable), not chat.
local function devEcho(msg)
    if ns.Log then ns.Log(msg) end
end

--========================================================================
-- Channel monitor (diagnostic). Watches OUR marketplace channel for traffic that isn't our
-- GFM protocol, to catch another addon (or a person) riding the same channel. Toggle with
-- /gfm channelscan; every line goes to the Debug view. Read-only: it never sends anything, and
-- it resets on /reload.
--========================================================================
local chanMon   -- nil = off; else { start, gfm, foreign, senders = {}, prefixes = {} }

-- Is a CHAT_MSG_CHANNEL line on our marketplace channel? Match by base name (robust to the
-- channel's slot number shifting), with the numeric index as a fallback.
local function onOurChannel(chanIdx, chanName, chanBase)
    local mine = ns.channelName and ns.channelName:lower()
    if not mine then return false end
    if chanBase and chanBase:lower() == mine then return true end
    if chanName and chanName:lower() == mine then return true end
    return ns.channelIndex ~= nil and chanIdx == ns.channelIndex
end

-- A short tag for a foreign line (leading non-space run, capped) so repeated traffic from one
-- addon groups under one prefix in the summary.
local function msgPrefix(text)
    return ((text or ""):match("^(%S+)") or "(blank)"):sub(1, 12)
end

local function chanMonObserve(text, sender, isGFM, chanIdx, chanName, chanBase)
    if not chanMon or not onOurChannel(chanIdx, chanName, chanBase) then return end
    if isGFM then chanMon.gfm = chanMon.gfm + 1; return end
    local who = (sender and Ambiguate(sender, "short")) or "?"
    if who == ns.playerName then return end                       -- our own untagged line (shouldn't happen)
    chanMon.foreign = chanMon.foreign + 1
    chanMon.senders[who] = (chanMon.senders[who] or 0) + 1
    local pfx = msgPrefix(text); chanMon.prefixes[pfx] = (chanMon.prefixes[pfx] or 0) + 1
    -- live, truncated so a chatty addon can't flood the Debug view
    devEcho(("|cffff8800channelscan|r FOREIGN #%d from %s: %s"):format(chanMon.foreign, who, (text or ""):sub(1, 60)))
end

-- Print the top few entries of a { key = count } map to the Debug view, busiest first.
local function chanMonTop(label, map)
    local arr = {}
    for k, v in pairs(map) do arr[#arr + 1] = { k = k, v = v } end
    table.sort(arr, function(a, b) return a.v > b.v end)
    if #arr == 0 then devEcho("  " .. label .. ": none"); return end
    for i = 1, math.min(5, #arr) do devEcho(("  %s: %s (%d)"):format(label, arr[i].k, arr[i].v)) end
end

-- Listings paused (e.g. while raiding/PvP): items are kept, but we stop answering
-- other players' searches and seller-browse scans. Per-character, like the offers.
local function isPaused() return GuildFoundMarketCharDB and GuildFoundMarketCharDB.paused end
ns.IsPaused = isPaused

-- Where I am, as "SubZone, Zone" ("The Drag, Orgrimmar"), or just the zone in open
-- terrain. Travels as one wire field; receivers show the zone in list columns and the
-- full string on hover (older clients just display the full string everywhere).
local function liveLoc()
    local zone = (GetZoneText() or ""):gsub("~", " ")
    local sub = (GetSubZoneText() or ""):gsub("~", " ")
    if sub == "" or sub == zone then return zone end
    if zone == "" then return sub end
    return sub .. ", " .. zone
end
ns.LiveLoc = liveLoc

-- The zone half of a wire location ("The Drag, Orgrimmar" -> "Orgrimmar"). A location
-- from an older client has no comma and passes through whole.
function ns.LocZone(loc)
    if not loc then return loc end
    return loc:match(",%s*([^,]+)$") or loc
end

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
frame:RegisterEvent("BANKFRAME_OPENED")          -- bank/mail stock snapshots (ns.Stock)
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
frame:RegisterEvent("PLAYERBANKBAGSLOTS_CHANGED")
frame:RegisterEvent("MAIL_SHOW")
frame:RegisterEvent("MAIL_CLOSED")
frame:RegisterEvent("MAIL_INBOX_UPDATE")
frame:RegisterEvent("UPDATE_PENDING_MAIL")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        GuildFoundMarketDB = GuildFoundMarketDB or {}
        GuildFoundMarketDB.names = GuildFoundMarketDB.names or {}
        GuildFoundMarketDB.quals = GuildFoundMarketDB.quals or {}
        GuildFoundMarketDB.prices = GuildFoundMarketDB.prices or {}   -- local price snapshots (#13)
        GuildFoundMarketCharDB = GuildFoundMarketCharDB or {}
        GuildFoundMarketCharDB.offers = GuildFoundMarketCharDB.offers or {}
        GuildFoundMarketCharDB.wants = GuildFoundMarketCharDB.wants or {}   -- WTB list (buy side)
        GuildFoundMarketCharDB.codOrders = GuildFoundMarketCharDB.codOrders or {}   -- COD to-do list (seller side)
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
        if prefix == ns.PREFIX then
            if ns.NetStats then ns.NetStats.Bump("recvWhisper") end
            ns.DispatchMessage(text, sender)
        end

    elseif event == "CHAT_MSG_CHANNEL" then
        local text, sender, _, chanName, _, _, _, chanIdx, chanBase = ...
        local isGFM = text and text:sub(1, #CHAT_TAG) == CHAT_TAG
        if isGFM then
            if ns.NetStats then ns.NetStats.Bump("recvChannel") end
            if ns.dev then devEcho("|cff00ff96GFM|r received channel: " .. text:sub(#CHAT_TAG + 1) .. " (from " .. tostring(sender) .. ")") end
            ns.DispatchMessage(text:sub(#CHAT_TAG + 1), sender)
        end
        chanMonObserve(text, sender, isGFM, chanIdx, chanName, chanBase)   -- no-op unless /gfm channelscan is on

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if msg and ERR_CHAT_THROTTLED and msg == ERR_CHAT_THROTTLED then
            ns.Log("THROTTLE: server says chat is being sent too quickly (channel broadcast may have dropped)")
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        ns.ItemDB.LearnFromBags()
        if ns.SyncTrackedOffersSoon then ns.SyncTrackedOffersSoon() end   -- keep tracked listings in step with bags
        if ns.Stock and ns.Stock.IsBankOpen() then ns.Stock.RefreshBankSoon() end   -- a bank-bag slot changed while open

    elseif event == "BANKFRAME_OPENED" then
        if ns.Stock then ns.Stock.SetBankOpen(true); ns.Stock.RefreshBankSoon() end

    elseif event == "BANKFRAME_CLOSED" then
        if ns.Stock then ns.Stock.SetBankOpen(false) end   -- last change was captured by a slot event while open

    elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERBANKBAGSLOTS_CHANGED" then
        if ns.Stock then ns.Stock.RefreshBankSoon() end

    elseif event == "MAIL_SHOW" then
        if ns.Stock then ns.Stock.SetMailOpen(true); ns.Stock.RefreshMailSoon() end

    elseif event == "MAIL_CLOSED" then
        if ns.Stock then ns.Stock.SetMailOpen(false) end

    elseif event == "MAIL_INBOX_UPDATE" then
        if ns.Stock then ns.Stock.RefreshMailSoon() end

    elseif event == "UPDATE_PENDING_MAIL" then
        if ns.RefreshMineSoon then ns.RefreshMineSoon() end   -- new-mail flag flipped: refresh the Bag-sync reliability hint

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local itemID, success = ...
        ns.ItemDB.OnItemInfoReceived(itemID, success)
        if ns.SyncTrackedOffersSoon then ns.SyncTrackedOffersSoon() end   -- cache just warmed: re-sync items skipped while cold
        if ns.RefreshBuySoon then ns.RefreshBuySoon() end
        if ns.RefreshMineSoon then ns.RefreshMineSoon() end
        if ns.RefreshSellerCatalogSoon then ns.RefreshSellerCatalogSoon() end
        if ns.RefreshWantSoon then ns.RefreshWantSoon() end
        if ns.RefreshBuyerCatalogSoon then ns.RefreshBuyerCatalogSoon() end
        if ns.RefreshFindBuyersSoon then ns.RefreshFindBuyersSoon() end
    end
end)

-- Slash command
SLASH_GFMARKET1 = "/gfm"
SLASH_GFMARKET2 = "/market"
SlashCmdList.GFMARKET = function(msg)
    -- test helper: force a local trade channel without editing guild info
    -- usage: /gfm tradechannel <name> [password]   (no args clears it)
    local tcArgs = (msg or ""):match("^%s*[Tt][Rr][Aa][Dd][Ee][Cc][Hh][Aa][Nn][Nn][Ee][Ll]%s*(.-)%s*$")
    if tcArgs ~= nil then
        if tcArgs == "" then
            ns._testTradeChannel = nil
            ns.Feedback("Test trade channel cleared.", false)
        else
            local name, pass = tcArgs:match("^(%S+)%s*(%S*)$")
            ns._testTradeChannel = { name = name, password = (pass ~= "" and pass) or nil }
            ns.Feedback(("Test trade channel set to %s%s. Open My Items to test."):format(name, pass ~= "" and " (pw: " .. pass .. ")" or ""), false)
        end
        if ns.RefreshConfig then ns.RefreshConfig() end   -- re-applies the override onto ns.config
        return
    end
    msg = (msg or ""):lower():gsub("%s+", "")
    if msg == "changelog" then
        if ns.ShowChangelog then ns.ShowChangelog() end   -- what's new / update overlay, on demand
    elseif msg == "dev" then
        ns.dev = not ns.dev
        ns.selfTest = ns.dev   -- dev implies self-test; toggle both at once (use "selftest" to peel it back off)
        print("|cff00ff96GFM|r: dev mode " .. (ns.dev and "ON" or "off") .. " (self-test " .. (ns.selfTest and "ON" or "off") .. ")")
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
        devEcho(("  my offers: %d (%d active, rest parked at qty 0)"):format(n, #ns.OfferList()))
        if ns.ToggleDebug and not (_G.GuildFoundMarketDebug and _G.GuildFoundMarketDebug:IsShown()) then ns.ToggleDebug() end
    elseif msg == "channelscan" then
        if chanMon then
            local dur = math.max(1, math.floor(time() - chanMon.start))
            devEcho(("|cff00ff96GFM channelscan|r stopped after %ds — GFM msgs: %d, foreign msgs: %d"):format(dur, chanMon.gfm, chanMon.foreign))
            if chanMon.foreign == 0 then
                devEcho("  No non-GFM traffic seen on the channel.")
            else
                chanMonTop("foreign sender", chanMon.senders)
                chanMonTop("foreign prefix", chanMon.prefixes)
            end
            chanMon = nil
        elseif not ns.channelName then
            ns.Feedback("No marketplace channel configured yet, so there's nothing to scan.", true)
        else
            chanMon = { start = time(), gfm = 0, foreign = 0, senders = {}, prefixes = {} }
            devEcho("|cff00ff96GFM channelscan|r ON — watching \"" .. ns.channelName .. "\" for non-GFM traffic. Run /gfm channelscan again to stop and summarise.")
            if ns.ToggleDebug and not (_G.GuildFoundMarketDebug and _G.GuildFoundMarketDebug:IsShown()) then ns.ToggleDebug() end
        end
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
    elseif ns.dev and msg == "codtimeout" then
        -- fire a COD cancel at a name nobody's playing, so no OA comes back and you can watch the
        -- cancel-specific timeout message land after ns.QUERY_SETTLE seconds. (Hearthstone = 6948.)
        devEcho("codtimeout: sending a cancel to an unanswering seller; watch for the timeout in ~" .. (ns.QUERY_SETTLE or 5) .. "s")
        ns.RequestCOD("Gfmnobodyxyz", 6948, 0, 0, 0)
    elseif ns.dev and msg == "codwhispertest" then
        -- simulate a buyer whispering a COD about your first listing (you can't whisper yourself), so
        -- you can watch the capture + on-screen flash + confirmation whisper solo. The order lands for
        -- "Testbuyer"; the confirmation whisper to that fake name errors in chat but the rest happens.
        local it = ns.OfferList()[1]
        if not it then
            devEcho("codwhispertest: list an item first, then run this again")
        else
            local link = ("|Hitem:%d:0:0:0:0:0:%d:0|h[test]|h"):format(it.id, it.suffix or 0)
            devEcho("codwhispertest: simulating Testbuyer whispering \"" .. link .. " cod 2\"")
            ns.HandleCODWhisper(link .. " cod 2", "Testbuyer", true)
        end
    elseif ns.dev and msg == "changelogtest" then
        -- preview the "newer version" overlay solo: fake being behind a v99.0.0 peer that shared this
        -- build's own notes. Shows now (if GFM is open) and on every open until you /reload.
        ns.updateAvailable = "99.0.0"
        ns.newerChangelog = { version = "99.0.0", text = ns.CHANGELOG or "(no changelog bundled)" }
        if ns.UpdateVersionDisplay then ns.UpdateVersionDisplay() end
        if ns.ShowChangelogOverlay then ns.ShowChangelogOverlay() end
        devEcho("changelogtest: faked a newer version (99.0.0) with this build's notes; the overlay shows on every GFM open until /reload")
    elseif ns.dev and msg == "fakesellers" then
        wipe(ns.sellers.results)
        -- Aldorin: note pre-cached (hover shows it at once). Bigbags: flag only, so the bubble
        -- offers "click to load" (a real fetch that times out, since it's a fake name). Cheapcat:
        -- no note (no bubble) as a control.
        ns.sellers.results["Aldorin"]  = { count = 3,  loc = "Bank, Orgrimmar", hasNote = true, note = "Bulk enchanting mats; whisper for a guild discount. Also buying greens." }
        ns.sellers.results["Bigbags"]  = { count = 42, loc = "Auction House, Orgrimmar", hasNote = true }
        ns.sellers.results["Cheapcat"] = { count = 1,  loc = "The Crossroads" }
        local many = {}; for i = 1, 42 do many[i] = 700 + i end
        ns._fakeCat = { Aldorin = { 2589, 2592, 4338 }, Cheapcat = { 6948 }, Bigbags = many }
        ns.sellers.scanning = false
        if ns.RefreshSellers then ns.RefreshSellers() end
        ns.Feedback("Injected 3 fake sellers (Aldorin has a note, Bigbags 'click to load'); open the Sellers tab.", false)
    elseif ns.dev and msg == "fakebuyers" then
        wipe(ns.buyers.results)
        ns.buyers.results["Wantsalot"] = { count = 3,  loc = "Bank, Orgrimmar", hasNote = true, note = "Paying top gold for Black Lotus and Arcane Crystal. Whisper me!" }
        ns.buyers.results["Maxbidder"] = { count = 12, loc = "Auction House, Orgrimmar", hasNote = true }
        ns.buyers.results["Pennypinch"] = { count = 1, loc = "The Crossroads" }
        local many = {}; for i = 1, 12 do many[i] = 760 + i end
        ns._fakeWant = { Wantsalot = { 2589, 2592, 4338 }, Pennypinch = { 6948 }, Maxbidder = many }
        ns.buyers.scanning = false
        if ns.RefreshBuyers then ns.RefreshBuyers() end
        ns.Feedback("Injected 3 fake buyers; open the Buyers tab.", false)
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
