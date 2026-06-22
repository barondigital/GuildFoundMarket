local ADDON, ns = ...

--========================================================================
-- Config
--========================================================================
local PREFIX        = "GFCraigslist"  -- addon-message prefix (<=16 chars)
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

function ns.Feedback(msg, isError)
    if msg and msg ~= "" then print("|cff00ff96GFC|r: " .. msg) end
end

local function offers() return GuildFoundCraigslistCharDB.offers end

local function liveLoc()
    local s = GetSubZoneText()
    if not s or s == "" then s = GetZoneText() or "" end
    return s:gsub("~", " ")
end

--========================================================================
-- Guild-info confederation config (GFCc/GFCp + GreenWall GWc/GWp). GFC wins.
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
        op, args = line:match("^GFC(%a):(.*)$"); if op then src = "GFC" end
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
    local chosen = picked.GFC or picked.GW
    if not chosen or not chosen.channel or chosen.channel == "" then return nil end
    cfg.channel, cfg.password = chosen.channel, chosen.password
    return cfg
end

local function refreshConfig()
    local cfg = parseGuildConfig()
    ns.config = cfg
    local newName = cfg and ("GFC" .. string.format("%x", simpleHash(cfg.channel .. ":" .. (cfg.password or "")))) or nil
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
local function enqueue(msg)            sendQ[#sendQ + 1] = { msg = msg } end
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
    enqueue(("Q~%s~%d"):format(activeQid, itemID))
    if ns.selfTest then
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
-- Incoming messages
--========================================================================
local function onAddonMsg(text, sender)
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
                if a == activeQid and itemID == ns.searchItemID then
                    ns.results[playerName] = { qty = math.min(o.qty, has), price = o.price, loc = liveLoc() }
                    if ns.RefreshBuy then ns.RefreshBuy() end
                end
            else
                enqueueWhisper(("R~%s~%d~%d~%d~%s"):format(a, itemID, math.min(o.qty, has), o.price, liveLoc()), sender)
            end
        end
    elseif cmd == "R" then
        if a == activeQid and tonumber(b) == ns.searchItemID then
            ns.results[Ambiguate(sender, "short")] = { qty = tonumber(c), price = tonumber(d), loc = e or "" }
            ns.ItemDB.Learn(tonumber(b))
            if ns.RefreshBuy then ns.RefreshBuy() end
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
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        GuildFoundCraigslistDB = GuildFoundCraigslistDB or {}
        GuildFoundCraigslistDB.names = GuildFoundCraigslistDB.names or {}
        GuildFoundCraigslistDB.quals = GuildFoundCraigslistDB.quals or {}
        GuildFoundCraigslistCharDB = GuildFoundCraigslistCharDB or {}
        GuildFoundCraigslistCharDB.offers = GuildFoundCraigslistCharDB.offers or {}

        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
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
            ensureChannel()
            local item = sendQ[1]
            if item then
                if item.to then
                    C_ChatInfo.SendAddonMessage(PREFIX, item.msg, "WHISPER", item.to)
                    table.remove(sendQ, 1)
                elseif ns.channelIndex then
                    C_ChatInfo.SendAddonMessage(PREFIX, item.msg, "CHANNEL", ns.channelIndex)
                    table.remove(sendQ, 1)
                end
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
        if prefix == PREFIX then onAddonMsg(text, sender) end

    elseif event == "BAG_UPDATE_DELAYED" then
        reconcileOffers()
        ns.ItemDB.LearnFromBags()

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local itemID, success = ...
        ns.ItemDB.OnItemInfoReceived(itemID, success)
        if ns.RefreshBuy then ns.RefreshBuy() end
        if ns.RefreshMine then ns.RefreshMine() end
    end
end)

-- Slash command
SLASH_GFCRAIGSLIST1 = "/gfc"
SLASH_GFCRAIGSLIST2 = "/craigslist"
SlashCmdList.GFCRAIGSLIST = function(msg)
    msg = (msg or ""):lower():gsub("%s+", "")
    if msg == "dev" then
        ns.dev = not ns.dev
        print("|cff00ff96GFC|r: dev mode " .. (ns.dev and "ON" or "off"))
    elseif msg == "debug" then
        refreshConfig()
        local t = GetGuildInfoText() or ""
        local cur, max = ns.ItemDB.HarvestProgress()
        print("|cff00ff96GFC debug|r")
        print("  guild: " .. tostring(GetGuildInfo("player")))
        print("  guildInfoText length: " .. #t)
        print("  channelName: " .. tostring(ns.channelName) .. " | joined: " .. tostring(ns.channelIndex ~= nil))
        print(("  item DB size: %d | harvest %d/%d (%s) | auxSeeded=%s | disableAux=%s"):format(
            ns.ItemDB.Count(), cur, max, ns.ItemDB.IsHarvesting() and "running" or "idle",
            tostring(GuildFoundCraigslistDB.auxSeeded), tostring(GuildFoundCraigslistDB.disableAux)))
        local n = 0; for _ in pairs(offers()) do n = n + 1 end
        print("  my offers: " .. n)
    elseif msg == "harvest" then
        ns.ItemDB.StartHarvest()
        local cur, max = ns.ItemDB.HarvestProgress()
        ns.Feedback(("Harvest running — at item %d/%d, DB %d. Watch with /gfc debug."):format(cur, max, ns.ItemDB.Count()), false)
    elseif msg == "harveststop" then
        ns.ItemDB.StopHarvest(); ns.Feedback("Harvest stopped.", false)
    elseif ns.dev and msg == "noaux" then
        GuildFoundCraigslistDB.disableAux = not GuildFoundCraigslistDB.disableAux
        ns.Feedback("aux seed " .. (GuildFoundCraigslistDB.disableAux and "DISABLED" or "enabled")
            .. " — run /gfc dbreset to clear the current DB and test a clean build.", false)
    elseif ns.dev and msg == "dbreset" then
        ns.ItemDB.Reset()
        if ns.RefreshBuy then ns.RefreshBuy() end
        ns.Feedback("Item DB wiped (clean-install state). /gfc harvest to rebuild from scratch.", false)
    elseif ns.dev and msg == "selftest" then
        ns.selfTest = not ns.selfTest
        ns.Feedback("Self-test " .. (ns.selfTest and "ON — search an item you've listed in My Items to see your own offer." or "off") .. ".", false)
    elseif ns.dev and msg == "faketest" then
        if not ns.searchItemID then
            ns.Feedback("Open Buy, search an item first, then /gfc faketest.", true)
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
