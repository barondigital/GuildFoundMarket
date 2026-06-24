local ADDON, ns = ...

--========================================================================
-- Config
--========================================================================
local PREFIX        = "GFMarket"  -- addon-message prefix for whispered replies (<=16 chars)
local CHAT_TAG      = "GFMqp1:"   -- marks our hidden chat-channel protocol messages
                                  -- (broadcast queries; addon messages over custom
                                  --  channels are dropped in Classic Era, so we ride the
                                  --  chat layer like GreenWall does and filter it from view)
local SEND_TICK     = 0.30            -- min seconds between outgoing messages (throttle)
local SCAN_INTERVAL = 10             -- how often offers are reconciled with inventory
local QUERY_SETTLE  = 5             -- seconds we collect responses for a search

--========================================================================
-- State
--========================================================================
local playerName = UnitName("player")

ns.config       = nil   -- parsed confederation config from guild info
ns.channelName  = nil   -- private channel derived from the config secret
ns.channelIndex = nil
ns.results      = {}    -- [sellerName] = { qty, price, loc }  for the active search
ns.searchItemID = nil
local activeQid  = nil
local querySeq   = 0

-- Browse-by-seller state. The index only carries a summary per seller; a seller's
-- full catalog is fetched lazily (a directed whisper) when you open them.
ns.sellerResults = {}   -- [sellerName] = { count, loc }            index summaries from a scan
ns.sellerCatalog = nil  -- { seller, loc, items = {[id]=…}, loading } the open seller's catalog
local activeSid  = nil  -- id of the active "who's selling" scan (drops stale replies)
local activeLid  = nil  -- id of the active per-seller catalog fetch
local sellerSeq  = 0

function ns.Feedback(msg, isError)
    if msg and msg ~= "" then print("|cff00ff96GFM|r: " .. msg) end
end

local function offers() return GuildFoundMarketCharDB.offers end

-- Listings paused (e.g. while raiding/PvP): items are kept, but we stop answering
-- other players' searches and seller-browse scans. Per-character, like the offers.
local function isPaused() return GuildFoundMarketCharDB and GuildFoundMarketCharDB.paused end
ns.IsPaused = isPaused

local function liveLoc()
    local s = GetSubZoneText()
    if not s or s == "" then s = GetZoneText() or "" end
    return s:gsub("~", " ")
end

--========================================================================
-- Guild-info confederation config (GFMc/GFMp + GreenWall GWc/GWp). GFM wins.
--========================================================================
local function simpleHash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 0x7FFFFFFF end
    return h
end

local function parseGuildConfig()
    local text = GetGuildInfoText()
    if not text or text == "" then return nil end
    local vars, cfg, picked = {}, { guilds = {} }, {}
    local function applyVars(s) return (s:gsub("%$(.)", function(n) return vars[n] or ("$" .. n) end)) end
    for line in text:gmatch("[^\r\n]+") do
        local src, op, args
        op, args = line:match("^GFM(%a):(.*)$"); if op then src = "GFM" end
        if not op then op, args = line:match("^GW(%a):(.*)$");  if op then src = "GW" end end
        if not op then op, args = line:match("^GW:(%a):(.*)$"); if op then src = "GW" end end
        if op then
            if op == "s" then
                local value, name = strsplit(":", args)
                if name and name ~= "" then vars[name] = value end
            elseif op == "c" then
                local chan, pass = strsplit(":", args)
                picked[src] = { channel = applyVars(chan or ""), password = pass or "" }
            elseif op == "p" then
                local gname, tag = strsplit(":", args)
                gname = applyVars(gname or "")
                if gname ~= "" then cfg.guilds[gname:lower()] = (tag and tag ~= "" and tag) or gname end
            end
        end
    end
    local chosen = picked.GFM or picked.GW
    if not chosen or not chosen.channel or chosen.channel == "" then return nil end
    cfg.channel, cfg.password = chosen.channel, chosen.password
    return cfg
end

local function refreshConfig()
    local cfg = parseGuildConfig()
    ns.config = cfg
    local newName = cfg and ("GFM" .. string.format("%x", simpleHash(cfg.channel .. ":" .. (cfg.password or "")))) or nil
    if newName ~= ns.channelName then
        if ns.channelName then LeaveChannelByName(ns.channelName) end
        ns.channelName  = newName
        ns.channelIndex = nil
        if newName then ns.Feedback("Connected to your confederation marketplace.", false) end
        if ns.RefreshBuy then ns.RefreshBuy() end
    end
end
ns.RefreshConfig = refreshConfig

--========================================================================
-- Outgoing message queue (throttle). Items: {msg, to=whisperTarget or nil=channel}
--========================================================================
local sendQ = {}
local function enqueueWhisper(msg, to)  sendQ[#sendQ + 1] = { msg = msg, to = to } end

local function ensureChannel()
    local name = ns.channelName
    if not name then ns.channelIndex = nil; return nil end
    local idx = GetChannelName(name)
    if not idx or idx == 0 then
        JoinTemporaryChannel(name)
        idx = GetChannelName(name)
    end
    ns.channelIndex = (idx and idx > 0) and idx or nil
    return ns.channelIndex
end

--========================================================================
-- My Items (offers). Per-character; the source we auto-respond from.
--========================================================================
function ns.AddOffer(itemID, qty, price)
    if not ns.channelName then ns.Feedback("No confederation config in your guild info — can't offer.", true); return end
    if not itemID then ns.Feedback("Pick an item first.", true); return end
    price = math.max(0, price or 0)   -- 0 = no fixed price; the seller takes bids
    qty = math.max(1, qty or 1)
    local has = GetItemCount(itemID, true)
    if has < qty then ns.Feedback(("You only have %d (tried to offer %d)."):format(has, qty), true); return end
    offers()[itemID] = { qty = qty, price = price }
    ns.ItemDB.Learn(itemID)
    if ns.RefreshMine then ns.RefreshMine() end
    ns.Feedback(("Offering %s x%d%s."):format(GetItemInfo(itemID) or ("item:" .. itemID), qty, price == 0 and " (bids)" or ""), false)
    return true
end

function ns.RemoveOffer(itemID)
    offers()[itemID] = nil
    if ns.RefreshMine then ns.RefreshMine() end
end

local function reconcileOffers()
    local changed = false
    for itemID, o in pairs(offers()) do
        local has = GetItemCount(itemID, true)
        if has <= 0 then offers()[itemID] = nil; changed = true
        elseif has < o.qty then o.qty = has; changed = true end
    end
    if changed and ns.RefreshMine then ns.RefreshMine() end
end

-- Reconcile my offers against current inventory and return only the in-stock ones
-- as an array of { id, qty, price }. Used to answer seller-browse requests.
local function inStockOffers()
    local list = {}
    for itemID, o in pairs(offers()) do
        local has = GetItemCount(itemID, true)
        if has <= 0 then offers()[itemID] = nil
        else list[#list + 1] = { id = itemID, qty = math.min(o.qty, has), price = o.price } end
    end
    return list
end

--========================================================================
-- Search (buyer side)
--========================================================================
function ns.Search(itemID)
    if not ns.channelName then ns.Feedback("Not in a confederation — can't search.", true); return end
    if not itemID then return end
    querySeq = querySeq + 1
    activeQid = playerName .. "#" .. querySeq
    wipe(ns.results)
    ns.searchItemID = itemID
    ns.searching = true
    -- Broadcast the query right here, inside the search keypress/click. SendChatMessage
    -- to a channel is only allowed from a hardware event (never a timer), and addon
    -- messages over custom channels are disabled in Classic Era, so this is the only path.
    local idx = ensureChannel()
    if idx then
        SendChatMessage(CHAT_TAG .. ("Q~%s~%d"):format(activeQid, itemID), "CHANNEL", nil, idx)
        if ns.dev then print("|cff00ff96GFM|r → channel: Q~" .. activeQid .. "~" .. itemID) end
    else
        ns.Feedback("Marketplace channel not ready yet — try the search again in a second.", true)
    end
    if ns.selfTest and not isPaused() then
        -- deliver our own offer directly (don't rely on the channel echo)
        local o = offers()[itemID]
        if o then
            local has = GetItemCount(itemID, true)
            if has > 0 then ns.results[playerName] = { qty = math.min(o.qty, has), price = o.price, loc = liveLoc() } end
        else
            ns.Feedback(("self-test: you have no offer for itemID %d (%s)."):format(itemID, GetItemInfo(itemID) or "?"), true)
        end
    end
    if ns.RefreshBuy then ns.RefreshBuy() end
    local thisQid = activeQid
    C_Timer.After(QUERY_SETTLE, function()
        if activeQid == thisQid then
            ns.searching = false
            if ns.RefreshBuy then ns.RefreshBuy() end
        end
    end)
end

--========================================================================
-- Browse by seller. ScanSellers broadcasts "who's selling?"; online sellers
-- whisper back a one-line summary (count + location). Opening a seller fetches
-- their full catalog with a directed whisper (chunked, so big lists are fine).
--========================================================================
function ns.ScanSellers()
    if not ns.channelName then ns.Feedback("Not in a confederation — can't browse sellers.", true); return end
    sellerSeq = sellerSeq + 1
    activeSid = playerName .. "#S" .. sellerSeq
    wipe(ns.sellerResults)
    ns.scanningSellers = true
    local idx = ensureChannel()
    if idx then
        SendChatMessage(CHAT_TAG .. ("S~%s"):format(activeSid), "CHANNEL", nil, idx)
        if ns.dev then print("|cff00ff96GFM|r → channel: S~" .. activeSid) end
    else
        ns.Feedback("Marketplace channel not ready yet — try again in a second.", true)
    end
    if ns.selfTest and not isPaused() then
        local list = inStockOffers()
        if #list > 0 then ns.sellerResults[playerName] = { count = #list, loc = liveLoc() } end
    end
    if ns.RefreshSellers then ns.RefreshSellers() end
    local thisSid = activeSid
    C_Timer.After(QUERY_SETTLE, function()
        if activeSid == thisSid then
            ns.scanningSellers = false
            if ns.RefreshSellers then ns.RefreshSellers() end
        end
    end)
end

-- Open one seller: request their full catalog (lazy). Replies arrive as K~ chunks.
function ns.OpenSeller(seller, loc)
    if not seller then return end
    loc = loc or (ns.sellerResults[seller] and ns.sellerResults[seller].loc) or ""
    sellerSeq = sellerSeq + 1
    activeLid = playerName .. "#L" .. sellerSeq
    ns.sellerCatalog = { seller = seller, loc = loc, items = {}, loading = true }
    if ns._fakeCat and ns._fakeCat[seller] then          -- dev: /gfm fakesellers
        for _, id in ipairs(ns._fakeCat[seller]) do
            ns.sellerCatalog.items[id] = { id = id, qty = (id % 5) + 1, price = (id % 90 + 1) * 1000 }
        end
        ns.sellerCatalog.loading = false
    elseif ns.selfTest and seller == playerName and not isPaused() then  -- can't whisper yourself
        for _, it in ipairs(inStockOffers()) do ns.sellerCatalog.items[it.id] = it end
        ns.sellerCatalog.loading = false
    else
        enqueueWhisper(("L~%s"):format(activeLid), seller)
        local thisLid = activeLid
        C_Timer.After(QUERY_SETTLE, function()
            if activeLid == thisLid and ns.sellerCatalog and ns.sellerCatalog.loading then
                ns.sellerCatalog.loading = false   -- no reply (seller went offline / paused)
                if ns.RefreshSellerCatalog then ns.RefreshSellerCatalog() end
            end
        end)
    end
    if ns.RefreshSellerCatalog then ns.RefreshSellerCatalog() end
end

--========================================================================
-- Incoming messages
--========================================================================
local function handleMsg(text, sender)
    local cmd, a, b, c, d, e = strsplit("~", text)
    if cmd == "Q" then
        ns.ItemDB.Learn(tonumber(b))   -- learn the searched item (vocabulary)
        local isSelf = Ambiguate(sender, "short") == playerName
        if isSelf and not ns.selfTest then return end   -- normally ignore my own query
        local itemID = tonumber(b)
        local o = itemID and offers()[itemID]
        if o then
            local has = GetItemCount(itemID, true)
            if has <= 0 then
                offers()[itemID] = nil
            elseif isSelf then
                -- self-test only: deliver our own offer locally (can't whisper yourself)
                if a == activeQid and itemID == ns.searchItemID and not isPaused() then
                    ns.results[playerName] = { qty = math.min(o.qty, has), price = o.price, loc = liveLoc() }
                    if ns.RefreshBuy then ns.RefreshBuy() end
                end
            elseif not isPaused() then
                enqueueWhisper(("R~%s~%d~%d~%d~%s"):format(a, itemID, math.min(o.qty, has), o.price, liveLoc()), sender)
            end
        end
    elseif cmd == "R" then
        if a == activeQid and tonumber(b) == ns.searchItemID then
            ns.results[Ambiguate(sender, "short")] = { qty = tonumber(c), price = tonumber(d), loc = e or "" }
            ns.ItemDB.Learn(tonumber(b))
            if ns.RefreshBuy then ns.RefreshBuy() end
        end
    elseif cmd == "S" then
        -- a seller-browse scan: answer with my summary (count + location) if I have stock
        if Ambiguate(sender, "short") == playerName then return end   -- ignore my own broadcast
        if isPaused() then return end                                 -- paused: stay invisible
        local list = inStockOffers()
        if #list > 0 then enqueueWhisper(("C~%s~%d~%s"):format(a, #list, liveLoc()), sender) end
    elseif cmd == "C" then
        if a == activeSid then
            ns.sellerResults[Ambiguate(sender, "short")] = { count = tonumber(b) or 0, loc = c or "" }
            if ns.RefreshSellers then ns.RefreshSellers() end
        end
    elseif cmd == "L" then
        -- a directed request for my full catalog; reply in <=180-char chunks
        if isPaused() then return end                                 -- paused: don't answer
        local lid, list, buf = a, inStockOffers(), ""
        local function flush(more) enqueueWhisper(("K~%s~%d~%s"):format(lid, more, buf), sender); buf = "" end
        for i = 1, #list do
            local it = list[i]
            local p = ("%d:%d:%d"):format(it.id, it.qty, it.price)
            if #buf + #p + 1 > 180 then flush(1) end
            buf = (buf == "") and p or (buf .. ";" .. p)
        end
        flush(0)   -- final chunk (empty if I have nothing listed)
    elseif cmd == "K" then
        if a == activeLid and ns.sellerCatalog then
            for chunk in (c or ""):gmatch("[^;]+") do
                local id, qty, price = strsplit(":", chunk)
                id = tonumber(id)
                if id then
                    ns.sellerCatalog.items[id] = { id = id, qty = tonumber(qty) or 0, price = tonumber(price) or 0 }
                    ns.ItemDB.Learn(id)
                end
            end
            if tonumber(b) == 0 then ns.sellerCatalog.loading = false end
            if ns.RefreshSellerCatalog then ns.RefreshSellerCatalog() end
        end
    end
end

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

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        GuildFoundMarketDB = GuildFoundMarketDB or {}
        GuildFoundMarketDB.names = GuildFoundMarketDB.names or {}
        GuildFoundMarketDB.quals = GuildFoundMarketDB.quals or {}
        GuildFoundMarketCharDB = GuildFoundMarketCharDB or {}
        GuildFoundMarketCharDB.offers = GuildFoundMarketCharDB.offers or {}

        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        -- hide our hidden-channel protocol chatter from every chat frame
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(_, _, msg)
            if msg and msg:sub(1, #CHAT_TAG) == CHAT_TAG then return true end
        end)
        if ns.CreateMinimapButton then ns.CreateMinimapButton() end

        ns.ItemDB.Load()
        ns.ItemDB.LearnFromBags()
        ns.ItemDB.SeedFromAux()

        requestGuildData()
        refreshConfig()
        for _, d in ipairs({ 2, 5, 10, 20 }) do
            C_Timer.After(d, function() requestGuildData(); refreshConfig() end)
        end

        C_Timer.NewTicker(SEND_TICK, function()
            ensureChannel()   -- keep the marketplace channel joined (to send/receive queries)
            -- only whispered replies go through the queue; addon whispers are allowed from
            -- any context, unlike the channel broadcast which must ride a hardware event
            local item = sendQ[1]
            if item and item.to then
                C_ChatInfo.SendAddonMessage(PREFIX, item.msg, "WHISPER", item.to)
                table.remove(sendQ, 1)
            end
        end)
        C_Timer.NewTicker(SCAN_INTERVAL, reconcileOffers)

    elseif event == "PLAYER_ENTERING_WORLD" then
        refreshConfig()
        ensureChannel()

    elseif event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        refreshConfig()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, _, sender = ...
        if prefix == PREFIX then handleMsg(text, sender) end

    elseif event == "CHAT_MSG_CHANNEL" then
        local text, sender = ...
        if text and text:sub(1, #CHAT_TAG) == CHAT_TAG then
            if ns.dev then print("|cff00ff96GFM|r ← channel: " .. text:sub(#CHAT_TAG + 1) .. " (from " .. tostring(sender) .. ")") end
            handleMsg(text:sub(#CHAT_TAG + 1), sender)
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        reconcileOffers()
        ns.ItemDB.LearnFromBags()

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local itemID, success = ...
        ns.ItemDB.OnItemInfoReceived(itemID, success)
        if ns.RefreshBuy then ns.RefreshBuy() end
        if ns.RefreshMine then ns.RefreshMine() end
        if ns.RefreshSellerCatalog then ns.RefreshSellerCatalog() end
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
    elseif msg == "debug" then
        refreshConfig()
        local t = GetGuildInfoText() or ""
        local cur, max = ns.ItemDB.HarvestProgress()
        print("|cff00ff96GFM debug|r")
        print("  guild: " .. tostring(GetGuildInfo("player")))
        print("  guildInfoText length: " .. #t)
        print("  channelName: " .. tostring(ns.channelName) .. " | joined: " .. tostring(ns.channelIndex ~= nil))
        print(("  item DB size: %d | harvest %d/%d (%s) | auxSeeded=%s | disableAux=%s"):format(
            ns.ItemDB.Count(), cur, max, ns.ItemDB.IsHarvesting() and "running" or "idle",
            tostring(GuildFoundMarketDB.auxSeeded), tostring(GuildFoundMarketDB.disableAux)))
        local n = 0; for _ in pairs(offers()) do n = n + 1 end
        print("  my offers: " .. n)
    elseif msg == "harvest" then
        ns.ItemDB.StartHarvest()
        local cur, max = ns.ItemDB.HarvestProgress()
        ns.Feedback(("Harvest running — at item %d/%d, DB %d. Watch with /gfm debug."):format(cur, max, ns.ItemDB.Count()), false)
    elseif msg == "harveststop" then
        ns.ItemDB.StopHarvest(); ns.Feedback("Harvest stopped.", false)
    elseif msg == "minimap" then
        local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
        if DBIcon and GuildFoundMarketDB.minimap then
            GuildFoundMarketDB.minimap.hide = not GuildFoundMarketDB.minimap.hide
            if GuildFoundMarketDB.minimap.hide then DBIcon:Hide("GuildFoundMarket") else DBIcon:Show("GuildFoundMarket") end
            ns.Feedback("Minimap button " .. (GuildFoundMarketDB.minimap.hide
                and "hidden — type /gfm minimap to show it again, or open with /market." or "shown."), false)
        else
            ns.Feedback("Minimap button not available.", true)
        end
    elseif ns.dev and msg == "noaux" then
        GuildFoundMarketDB.disableAux = not GuildFoundMarketDB.disableAux
        ns.Feedback("aux seed " .. (GuildFoundMarketDB.disableAux and "DISABLED" or "enabled")
            .. " — run /gfm dbreset to clear the current DB and test a clean build.", false)
    elseif ns.dev and msg == "dbreset" then
        ns.ItemDB.Reset()
        if ns.RefreshBuy then ns.RefreshBuy() end
        ns.Feedback("Item DB wiped (clean-install state). /gfm harvest to rebuild from scratch.", false)
    elseif ns.dev and msg == "selftest" then
        ns.selfTest = not ns.selfTest
        ns.Feedback("Self-test " .. (ns.selfTest and "ON — search an item you've listed in My Items to see your own offer." or "off") .. ".", false)
    elseif ns.dev and msg == "fakesellers" then
        wipe(ns.sellerResults)
        ns.sellerResults["Aldorin"]  = { count = 3,  loc = "Bank, Orgrimmar" }
        ns.sellerResults["Bigbags"]  = { count = 42, loc = "Auction House, Orgrimmar" }
        ns.sellerResults["Cheapcat"] = { count = 1,  loc = "The Crossroads" }
        local many = {}; for i = 1, 42 do many[i] = 700 + i end
        ns._fakeCat = { Aldorin = { 2589, 2592, 4338 }, Cheapcat = { 6948 }, Bigbags = many }
        ns.scanningSellers = false
        if ns.RefreshSellers then ns.RefreshSellers() end
        ns.Feedback("Injected 3 fake sellers (one with 42 items) — open the Sellers tab.", false)
    elseif ns.dev and msg == "faketest" then
        if not ns.searchItemID then
            ns.Feedback("Open Buy, search an item first, then /gfm faketest.", true)
        else
            ns.results["Testseller1"]  = { qty = 5,  price = 150000, loc = "Bank, Orgrimmar" }
            ns.results["Cheapcharlie"] = { qty = 20, price = 95000,  loc = "Auction House, Orgrimmar" }
            ns.results["Bidderbob"]    = { qty = 1,  price = 0,      loc = "The Crossroads" }
            if ns.RefreshBuy then ns.RefreshBuy() end
            ns.Feedback("Injected 3 fake offers into the current search.", false)
        end
    else
        ns.ToggleUI()
    end
end
