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
local QUERY_SETTLE  = 5             -- seconds we collect responses for a search
local SELLER_CAP    = 150           -- max distinct sellers a scan collects (protects the scanner)
local SCAN_JITTER   = 2.0           -- seconds sellers spread scan replies over (unfiltered scan)
local FILTER_MIN    = 3             -- min chars before a seller-name scan goes over the network
ns.SELLER_CAP = SELLER_CAP
ns.FILTER_MIN = FILTER_MIN

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

-- Browse-by-category state. A category query (class + subclass) collects matching offers
-- from many sellers at once; results span many items, keyed by seller + item + variant.
ns.browseResults = {}   -- [seller#id#suffix] = { seller, id, suffix, qty, price, self }
ns.browseClass   = nil  -- active query's classID / subClassID (for the UI status + own-offer match)
ns.browseSub     = nil
local activeQCid = nil
local browseSeq  = 0

-- Version detection: ride our version along on the broadcasts (appended, so old clients
-- ignore it), track the highest seen, and flag when we're behind.
ns.version = ((C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata)(ADDON, "Version") or "?"
ns.latestVersion = ns.version
local function verNums(v) local t = {} for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end return t end
local function verNewer(a, b)   -- is version a strictly newer than b?
    local na, nb = verNums(a), verNums(b)
    for i = 1, math.max(#na, #nb) do
        local x, y = na[i] or 0, nb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end
local function notePeerVersion(v)
    if not v or v == "" or not verNewer(v, ns.latestVersion) then return end
    ns.latestVersion = v
    if verNewer(v, ns.version) then
        ns.updateAvailable = v
        if not ns._updateNotified then
            ns._updateNotified = true
            ns.Feedback(("A newer version (%s) of Guild Found Market is out (you have %s). Please update."):format(v, ns.version), true)
        end
        if ns.UpdateVersionDisplay then ns.UpdateVersionDisplay() end
    end
end

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
-- Guild-info marketplace config: a single channel line — GFMc (preferred) or
-- GreenWall's GWc as fallback. The marketplace is gated purely by who can read
-- that secret, so peer-guild lines (GFMp/GWp) are not needed and are ignored.
--========================================================================
local function simpleHash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 0x7FFFFFFF end
    return h
end

local function parseGuildConfig()
    local text = GetGuildInfoText()
    if not text or text == "" then return nil end
    local vars, picked = {}, {}
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
            end
            -- "p" (peer-guild) lines belong to GreenWall's chat bridge; GFM gates on the
            -- channel secret alone, so they are intentionally not parsed.
        end
    end
    local chosen = picked.GFM or picked.GW
    if not chosen or not chosen.channel or chosen.channel == "" then return nil end
    return { channel = chosen.channel, password = chosen.password, source = picked.GFM and "GFM" or "GW" }
end

local function refreshConfig()
    local cfg = parseGuildConfig()
    ns.config = cfg
    local newName = cfg and ("GFM" .. string.format("%x", simpleHash(cfg.channel .. ":" .. (cfg.password or "")))) or nil
    if newName ~= ns.channelName then
        if ns.channelName then LeaveChannelByName(ns.channelName) end
        ns.channelName  = newName
        ns.channelIndex = nil
        if newName then
            ns.Feedback(("Connected to your marketplace channel (using %s config)."):format(
                cfg.source == "GFM" and "GuildFoundMarket" or "GreenWall"), false)
            if ns.Log then ns.Log(("CONFIG connected: %s channel (%s)"):format(cfg.source == "GFM" and "GuildFoundMarket" or "GreenWall", newName)) end
        elseif ns.Log then
            ns.Log("CONFIG disconnected — no marketplace config in guild info")
        end
        if ns.RefreshBuy then ns.RefreshBuy() end
    end
end
ns.RefreshConfig = refreshConfig

--========================================================================
-- Outgoing message queue (throttle). Items: {msg, to=whisperTarget or nil=channel}
--========================================================================
local sendQ = {}
local sendBacklogWarned = false
local SEND_QUEUE_MAX = 50   -- under sustained server throttling, drop the oldest (already-stale)
                            -- reply instead of growing unbounded: a >5s-old search answer is useless
local function enqueueWhisper(msg, to)
    if #sendQ >= SEND_QUEUE_MAX then table.remove(sendQ, 1) end
    sendQ[#sendQ + 1] = { msg = msg, to = to }
end

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
-- My Items (offers). Per-character; the source we auto-respond from. Keyed by variant
-- "itemID:suffixID", so random-enchant variants of one base item ("... of the Bear" vs
-- "... of the Eagle") list separately. suffixID 0 = a plain item, keyed "itemID:0".
--========================================================================
local function vkey(id, suffix) return id .. ":" .. (suffix or 0) end
ns.vkey = vkey

-- Scan the player's bags for an item's bound state. Returns (sawCopy, sawTradeable):
-- sawTradeable is true if at least one UNbound copy exists. We block a listing only
-- when we saw copies and every one was bound (soulbound or quest-bound = untradeable);
-- if we saw none (e.g. it's only in the bank), we fail open and allow it.
local function bagBoundState(itemID)
    local sawCopy, sawTradeable = false, false
    for bag = 0, 4 do
        for s = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, s)
            if info and info.itemID == itemID then
                sawCopy = true
                if not info.isBound then sawTradeable = true end
            end
        end
    end
    return sawCopy, sawTradeable
end

function ns.AddOffer(itemID, suffix, qty, price)
    if not ns.channelName then ns.Feedback("No confederation config in your guild info — can't offer.", true); return end
    if not itemID then ns.Feedback("Pick an item first.", true); return end
    suffix = suffix or 0
    price = math.max(0, price or 0)   -- 0 = no fixed price; the seller takes bids
    qty = math.max(1, qty or 1)
    local has = GetItemCount(itemID, true)
    if has < qty then ns.Feedback(("You only have %d (tried to offer %d)."):format(has, qty), true); return end
    local sawCopy, sawTradeable = bagBoundState(itemID)
    if sawCopy and not sawTradeable then
        ns.Feedback("That item is soulbound, so it can't be traded or listed.", true); return
    end
    offers()[vkey(itemID, suffix)] = { id = itemID, suffix = suffix, qty = qty, price = price }
    ns.ItemDB.Learn(itemID)
    if ns.RefreshMine then ns.RefreshMine() end
    ns.Feedback(("Offering %s x%d%s."):format(GetItemInfo(itemID) or ("item:" .. itemID), qty, price == 0 and " (bids)" or ""), false)
    ns.Log(("OFFER added: %s x%d @ %s"):format(GetItemInfo(itemID) or ("item:" .. itemID), qty, price == 0 and "bid" or (price .. "c")))
    return true
end

function ns.RemoveOffer(key)
    local o = offers()[key]
    offers()[key] = nil
    local id = (o and o.id) or tonumber(key)
    ns.Log("OFFER removed: " .. (id and (GetItemInfo(id) or ("item:" .. id)) or tostring(key)))
    if ns.RefreshMine then ns.RefreshMine() end
end

-- An offer is the seller's claim, not a mirror of their inventory. We deliberately
-- never verify it against bags/bank: sellers may keep stock on a bank alt, items go
-- in and out during play, and every trade is arranged face to face in whispers anyway.
-- So we never auto-edit or auto-remove offers; the seller owns their listings (and the
-- pause toggle hides them all at once). Returns an array of { id, suffix, qty, price }.
-- Tolerates legacy offers keyed by a bare numeric itemID (no stored id/suffix).
local function offerList()
    local list = {}
    for key, o in pairs(offers()) do
        list[#list + 1] = { id = o.id or tonumber(key), suffix = o.suffix or 0, qty = o.qty, price = o.price }
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
    ns.searchStart = GetTime()
    local idx = ensureChannel()
    if idx then
        SendChatMessage(CHAT_TAG .. ("Q~%s~%d~%s"):format(activeQid, itemID, ns.version), "CHANNEL", nil, idx)
        ns.Log(("SEARCH \"%s\" (id %d) sent"):format(GetItemInfo(itemID) or ("item:" .. itemID), itemID))
    else
        ns.Feedback("Marketplace channel not ready yet — try the search again in a second.", true)
        ns.Log(("SEARCH (id %d) FAILED — channel not ready"):format(itemID))
    end
    -- Always show our own offers for this base item among the results (every variant we
    -- list), so we can see where our price sits and adjust to compete. Local-only injection
    -- (we never whisper ourselves), shown even while paused since it's our own view.
    local mineCount = 0
    for _, it in ipairs(offerList()) do
        if it.id == itemID then
            mineCount = mineCount + 1
            ns.results[playerName .. "#" .. it.suffix] =
                { seller = playerName, suffix = it.suffix, qty = it.qty, price = it.price, loc = liveLoc(), self = true }
        end
    end
    if mineCount == 0 and ns.selfTest then
        ns.Feedback(("self-test: you have no offer for itemID %d (%s)."):format(itemID, GetItemInfo(itemID) or "?"), true)
    end
    if ns.RefreshBuy then ns.RefreshBuy() end
    local thisQid = activeQid
    C_Timer.After(QUERY_SETTLE, function()
        if activeQid == thisQid then
            ns.searching = false
            local n = 0; for _ in pairs(ns.results) do n = n + 1 end
            ns.Log(("SEARCH done: %d offer(s) in %.1fs"):format(n, GetTime() - (ns.searchStart or GetTime())))
            if ns.RefreshBuy then ns.RefreshBuy() end
        end
    end)
end

--========================================================================
-- Browse by seller. ScanSellers broadcasts "who's selling?"; online sellers
-- whisper back a one-line summary (count + location). Opening a seller fetches
-- their full catalog with a directed whisper (chunked, so big lists are fine).
--========================================================================
-- filter: optional lowercase name substring. Empty = "who's online" (capped sample);
-- non-empty = only sellers whose name contains it answer, so it scales to big groups.
function ns.ScanSellers(filter)
    if not ns.channelName then ns.Feedback("Not in a confederation — can't browse sellers.", true); return end
    filter = filter or ""
    ns.scanFilter = filter
    ns.pendingOpenSeller = nil   -- a fresh scan cancels any pending shop-link auto-open
    sellerSeq = sellerSeq + 1
    activeSid = playerName .. "#S" .. sellerSeq
    wipe(ns.sellerResults)
    ns.sellerCount = 0
    ns.sellerCapped = false
    ns.scanningSellers = true
    ns.scanStart = GetTime()
    local idx = ensureChannel()
    if idx then
        SendChatMessage(CHAT_TAG .. ("S~%s~%s~%s"):format(activeSid, filter, ns.version), "CHANNEL", nil, idx)
        ns.Log(("SELLERS scan sent%s"):format(filter ~= "" and (" (filter \"" .. filter .. "\")") or ""))
    else
        ns.Feedback("Marketplace channel not ready yet — try again in a second.", true)
        ns.Log("SELLERS scan FAILED — channel not ready")
    end
    if ns.selfTest and not isPaused() and (filter == "" or playerName:lower():find(filter, 1, true)) then
        local list = offerList()
        if #list > 0 then
            -- mimic our own reply arriving over the channel a moment later, so the
            -- same index + pending-open path a real seller would drive is exercised
            local thisSid, count, loc = activeSid, #list, liveLoc()
            C_Timer.After(0.2, function()
                if activeSid ~= thisSid then return end
                if not ns.sellerResults[playerName] then ns.sellerCount = (ns.sellerCount or 0) + 1 end
                ns.sellerResults[playerName] = { count = count, loc = loc }
                if ns.pendingOpenSeller == playerName then
                    ns.pendingOpenSeller = nil
                    ns.OpenSeller(playerName, loc)
                    if ns.SetSellersView then ns.SetSellersView("SHOW") end
                end
                if ns.RefreshSellersSoon then ns.RefreshSellersSoon() end
            end)
        end
    end
    if ns.RefreshSellers then ns.RefreshSellers() end
    local thisSid = activeSid
    C_Timer.After(QUERY_SETTLE, function()
        if activeSid == thisSid then
            ns.scanningSellers = false
            if ns.pendingOpenSeller then   -- a shop-link click that nobody answered
                ns.Feedback(("%s's shop isn't answering. They may be offline or out of stock."):format(ns.pendingOpenSeller), true)
                ns.pendingOpenSeller = nil
            end
            ns.Log(("SELLERS scan done: %d seller(s)%s in %.1fs"):format(
                ns.sellerCount or 0, ns.sellerCapped and " (capped)" or "", GetTime() - (ns.scanStart or GetTime())))
            if ns.RefreshSellers then ns.RefreshSellers() end
        end
    end)
end

-- Open one seller: request their full catalog (lazy). Replies arrive as K~ chunks.
function ns.OpenSeller(seller, loc)
    if not seller then return end
    loc = loc or (ns.sellerResults[seller] and ns.sellerResults[seller].loc) or ""
    ns.Log("OPEN " .. seller .. " — requesting catalog")
    sellerSeq = sellerSeq + 1
    activeLid = playerName .. "#L" .. sellerSeq
    ns.sellerCatalog = { seller = seller, loc = loc, items = {}, loading = true }
    if ns._fakeCat and ns._fakeCat[seller] then          -- dev: /gfm fakesellers
        for _, id in ipairs(ns._fakeCat[seller]) do
            ns.sellerCatalog.items[vkey(id, 0)] = { id = id, suffix = 0, qty = (id % 5) + 1, price = (id % 90 + 1) * 1000 }
        end
        ns.sellerCatalog.loading = false
    elseif ns.selfTest and seller == playerName and not isPaused() then  -- can't whisper yourself
        for _, it in ipairs(offerList()) do ns.sellerCatalog.items[vkey(it.id, it.suffix)] = it end
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
-- Browse by category. Like Search, but the query carries an item class + subclass
-- instead of one itemID, and every seller answers with ALL their matching in-stock
-- offers (chunked like the catalog). Always class + subclass, never a whole class, to
-- bound the reply volume. Item quality/level are derived by the buyer from the itemID,
-- so nothing extra rides the wire. Returns the matching offers across all sellers.
--========================================================================
local BROWSE_MATCH_CAP = 60   -- max matches one seller answers per category query (bounds the reply)

-- class/subclass of an item (locale-independent); nil if the item isn't cached yet
local function itemCategory(itemID)
    local cid, sub = select(12, GetItemInfo(itemID))
    return cid, sub
end

function ns.BrowseCategory(classID, subClassID)
    if not ns.channelName then ns.Feedback("Not in a confederation — can't browse.", true); return end
    if not classID or not subClassID then return end
    browseSeq = browseSeq + 1
    activeQCid = playerName .. "#QC" .. browseSeq
    wipe(ns.browseResults)
    ns.browseClass, ns.browseSub = classID, subClassID
    ns.browsing = true
    ns.browseStart = GetTime()
    local idx = ensureChannel()
    if idx then
        SendChatMessage(CHAT_TAG .. ("QC~%s~%d~%d~%s"):format(activeQCid, classID, subClassID, ns.version), "CHANNEL", nil, idx)
        ns.Log(("BROWSE category %d/%d sent"):format(classID, subClassID))
    else
        ns.Feedback("Marketplace channel not ready yet — try the browse again in a second.", true)
        ns.Log("BROWSE FAILED — channel not ready")
    end
    -- inject my own matching offers locally (we never whisper ourselves), even while paused
    for _, it in ipairs(offerList()) do
        local cid, sub = itemCategory(it.id)
        if cid == classID and sub == subClassID then
            ns.browseResults[playerName .. "#" .. it.id .. "#" .. it.suffix] =
                { seller = playerName, id = it.id, suffix = it.suffix, qty = it.qty, price = it.price, self = true }
        end
    end
    if ns.RefreshBrowse then ns.RefreshBrowse() end
    local thisId = activeQCid
    C_Timer.After(QUERY_SETTLE, function()
        if activeQCid == thisId then
            ns.browsing = false
            local n = 0; for _ in pairs(ns.browseResults) do n = n + 1 end
            ns.Log(("BROWSE done: %d offer(s) in %.1fs"):format(n, GetTime() - (ns.browseStart or GetTime())))
            if ns.RefreshBrowse then ns.RefreshBrowse() end
        end
    end)
end

--========================================================================
-- Incoming messages
--========================================================================
local function handleMsg(text, sender)
    local cmd, a, b, c, d, e, f = strsplit("~", text)
    if cmd == "Q" then
        notePeerVersion(c)             -- Q~qid~itemID~ver
        ns.ItemDB.Learn(tonumber(b))   -- learn the searched item (vocabulary)
        if Ambiguate(sender, "short") == playerName then return end   -- ignore my own query (own offers are injected locally)
        if isPaused() then return end                                 -- paused: stay invisible
        local itemID = tonumber(b)
        -- an offer is the seller's claim: answer every variant we list for this base item,
        -- exactly as posted, no inventory check (settled buyer<->seller in whispers)
        local answered = 0
        for _, it in ipairs(offerList()) do
            if it.id == itemID then
                enqueueWhisper(("R~%s~%d~%d~%d~%s~%d"):format(a, it.id, it.qty, it.price, liveLoc(), it.suffix), sender)
                answered = answered + 1
            end
        end
        if answered > 0 then
            ns.Log(("answered %s's search for %s (%d variant(s))"):format(Ambiguate(sender, "short"), GetItemInfo(itemID) or ("item:" .. itemID), answered))
        end
    elseif cmd == "R" then
        -- R~qid~itemID~qty~price~loc~suffixID  (suffix LAST so 0.6.0 clients read qty/price/loc correctly)
        if a == activeQid and tonumber(b) == ns.searchItemID then
            local suffix = tonumber(f) or 0
            local s = Ambiguate(sender, "short")
            ns.results[s .. "#" .. suffix] = { seller = s, suffix = suffix, qty = tonumber(c) or 0, price = tonumber(d) or 0, loc = e or "" }
            ns.ItemDB.Learn(tonumber(b))
            ns.Log(("  offer from %s: %sx @ %sc (%+.1fs)"):format(s, tostring(c), tostring(d), GetTime() - (ns.searchStart or GetTime())))
            if ns.RefreshBuySoon then ns.RefreshBuySoon() end
        end
    elseif cmd == "S" then
        -- a seller-browse scan: answer with my summary (count + location) if I have stock
        -- and (when the scan is filtered) my name matches the requested substring.
        if Ambiguate(sender, "short") == playerName then return end   -- ignore my own broadcast
        if isPaused() then return end                                 -- paused: stay invisible
        notePeerVersion(c)             -- S~sid~filter~ver
        local filter = b
        if filter and filter ~= "" and not playerName:lower():find(filter, 1, true) then return end
        local list = offerList()
        if #list > 0 then
            -- spread replies over time so the scanner isn't hit by a burst; filtered
            -- scans match few people, so answer those almost immediately.
            local sid, n, loc = a, #list, liveLoc()
            local jitter = (filter and filter ~= "") and 0.3 or SCAN_JITTER
            C_Timer.After(math.random() * jitter, function()
                enqueueWhisper(("C~%s~%d~%s"):format(sid, n, loc), sender)
            end)
        end
    elseif cmd == "C" then
        if a == activeSid then
            local s = Ambiguate(sender, "short")
            if not ns.sellerResults[s] then
                if (ns.sellerCount or 0) >= SELLER_CAP then ns.sellerCapped = true; return end
                ns.sellerCount = (ns.sellerCount or 0) + 1
            end
            ns.sellerResults[s] = { count = tonumber(b) or 0, loc = c or "" }
            ns.Log(("  seller %s: %s items (%+.1fs)"):format(s, tostring(b), GetTime() - (ns.scanStart or GetTime())))
            if ns.pendingOpenSeller and s == ns.pendingOpenSeller then
                -- this seller answered on the private channel, so it's safe to open them
                ns.pendingOpenSeller = nil
                if ns.OpenSeller then ns.OpenSeller(s, c or "") end
                if ns.SetSellersView then ns.SetSellersView("SHOW") end
            end
            if ns.RefreshSellersSoon then ns.RefreshSellersSoon() end
        end
    elseif cmd == "L" then
        -- a directed request for my full catalog; reply in <=180-char chunks
        if isPaused() then return end                                 -- paused: don't answer
        local lid, list, buf = a, offerList(), ""
        local function flush(more) enqueueWhisper(("K~%s~%d~%s"):format(lid, more, buf), sender); buf = "" end
        for i = 1, #list do
            local it = list[i]
            local p = ("%d:%d:%d:%d"):format(it.id, it.qty, it.price, it.suffix)   -- id:qty:price:suffix (suffix last)
            if #buf + #p + 1 > 180 then flush(1) end
            buf = (buf == "") and p or (buf .. ";" .. p)
        end
        flush(0)   -- final chunk (empty if I have nothing listed)
        ns.Log(("sent my catalog (%d items) to %s"):format(#list, Ambiguate(sender, "short")))
    elseif cmd == "K" then
        if a == activeLid and ns.sellerCatalog then
            for chunk in (c or ""):gmatch("[^;]+") do
                local id, qty, price, suffix = strsplit(":", chunk)
                id = tonumber(id)
                if id then
                    local sfx = tonumber(suffix) or 0
                    ns.sellerCatalog.items[vkey(id, sfx)] = { id = id, suffix = sfx, qty = tonumber(qty) or 0, price = tonumber(price) or 0 }
                    ns.ItemDB.Learn(id)
                end
            end
            if tonumber(b) == 0 then
                ns.sellerCatalog.loading = false
                local n = 0; for _ in pairs(ns.sellerCatalog.items) do n = n + 1 end
                ns.Log(("OPEN %s: %d items in %.1fs"):format(ns.sellerCatalog.seller, n, GetTime() - (ns.openStart or GetTime())))
            end
            if ns.RefreshSellerCatalogSoon then ns.RefreshSellerCatalogSoon() end
        end
    elseif cmd == "QC" then
        -- a category browse: answer with every in-stock offer matching class b + subclass c,
        -- chunked like the catalog and capped + jittered like the seller scan
        if Ambiguate(sender, "short") == playerName then return end   -- own query: injected locally
        if isPaused() then return end
        notePeerVersion(d)             -- QC~qid~class~sub~ver
        local classID, subID = tonumber(b), tonumber(c)
        if not classID or not subID then return end
        local matches = {}
        for _, it in ipairs(offerList()) do
            local cid, sub = itemCategory(it.id)
            if cid == classID and sub == subID then
                matches[#matches + 1] = it
                if #matches >= BROWSE_MATCH_CAP then break end
            end
        end
        if #matches > 0 then
            local qid = a
            C_Timer.After(math.random() * SCAN_JITTER, function()
                local buf = ""
                local function flush(more) enqueueWhisper(("QR~%s~%d~%s"):format(qid, more, buf), sender); buf = "" end
                for i = 1, #matches do
                    local it = matches[i]
                    local p = ("%d:%d:%d:%d"):format(it.id, it.qty, it.price, it.suffix)   -- id:qty:price:suffix (suffix last)
                    if #buf + #p + 1 > 180 then flush(1) end
                    buf = (buf == "") and p or (buf .. ";" .. p)
                end
                flush(0)
            end)
            ns.Log(("answered %s's category browse (%d match(es))"):format(Ambiguate(sender, "short"), #matches))
        end
    elseif cmd == "QR" then
        -- category browse reply chunk: id:suffix:qty:price;... from one seller
        if a == activeQCid then
            local s = Ambiguate(sender, "short")
            for chunk in (c or ""):gmatch("[^;]+") do
                local id, qty, price, suffix = strsplit(":", chunk)
                id = tonumber(id)
                if id then
                    local sfx = tonumber(suffix) or 0
                    ns.browseResults[s .. "#" .. id .. "#" .. sfx] =
                        { seller = s, id = id, suffix = sfx, qty = tonumber(qty) or 0, price = tonumber(price) or 0 }
                    ns.ItemDB.Learn(id)
                end
            end
            if ns.RefreshBrowseSoon then ns.RefreshBrowseSoon() end
        end
    end
end

--========================================================================
-- "Shop is open" announce + clickable shop links.
-- The chat server strips custom hyperlinks, so the announce drops a plain-text
-- marker ({{GFM:Name}}) into guild chat. Every GFM client rewrites that marker
-- into a clickable link locally, so only GFM users ever see a clickable link and
-- the server never carries one. Clicking does NOT open the listing from the link:
-- it runs a name-filtered seller scan over the private channel and opens the shop
-- only once that seller actually answers (proof they're on your marketplace). We
-- never trust listing data carried inside the link.
--========================================================================
-- Compose the guild-chat line and hand it to the edit box WITHOUT sending it.
-- Announcing is the player's decision (and that avoids spam); they can still add
-- text or shift-click items in before pressing Enter.
function ns.AnnounceShop()
    if isPaused() then
        ns.Feedback("Your listings are offline. Go online before announcing your shop.", true); return
    end
    if not ns.channelName then
        ns.Feedback("No marketplace config in your guild info, so a shop link wouldn't resolve for anyone.", true); return
    end
    if not IsInGuild() then
        ns.Feedback("You're not in a guild, so there's no guild chat to announce in.", true); return
    end
    -- trailing space so the cursor sits clear of the marker, ready to shift-click items in
    ChatFrame_OpenChat(("/g Shop is open! {{GFM:%s}} "):format(playerName))
    ns.Log("ANNOUNCE composed for guild chat (not sent, your call)")
end

-- Rewrite our plain-text marker into a clickable link on the receiving client.
-- The capture excludes braces and pipes, so a crafted message can't inject
-- escape codes (and we never reach gsub for those).
local function shareFilter(_, _, msg, ...)
    if msg and msg:find("{{GFM:", 1, true) then
        local changed = false
        local out = msg:gsub("{{GFM:([^{}|]+)}}", function(name)
            changed = true
            return ("|cff00ff96|Hgfmshop:%s|h[GFM: browse shop]|h|r"):format(name)
        end)
        if changed then return false, out, ... end
    end
end

-- The Announce button only posts to guild, but rewrite the marker wherever it can
-- appear (incl. whisper + the outgoing whisper echo) so a hand-shared link also
-- clicks, and so it can be tested with a self-whisper.
local SHARE_EVENTS = {
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
}

-- Open a clicked shop link. We REPLACE SetItemRef (capturing the existing chain) and
-- short-circuit our custom gfmshop: link here, so it reaches neither Blizzard's
-- SetItemRef nor any other addon's SetItemRef hook. This is deliberate over two
-- alternatives that each break:
--   * A plain hooksecurefunc on SetItemRef lets the link reach NovaWorldBuffs/Questie,
--     which securehook SetItemRef and call SetHyperlink(link) unconditionally. Our
--     unknown type raises "Unknown link type", and that error aborts the rest of the
--     secure-hook chain, so our own handler never runs and the link does nothing.
--   * Replacing the chat frame's OnHyperlinkClick script taints the chat frames, which
--     then intermittently blocks our SendChatMessage channel broadcasts
--     (ADDON_ACTION_BLOCKED), breaking search and the Sellers scan.
-- Replacing the global SetItemRef touches no chat-frame widget (so search/scan stay
-- untainted) and our link never reaches the unconditional SetHyperlink (so no error).
-- Real links fall through to the original chain unchanged. We install at PLAYER_LOGIN,
-- after other addons have hooked, so our replacement wraps their chain (not vice versa).
local shareInstalled = false
local function installShareLinks()
    if shareInstalled then return end
    shareInstalled = true
    for _, e in ipairs(SHARE_EVENTS) do ChatFrame_AddMessageEventFilter(e, shareFilter) end
    local origSetItemRef = SetItemRef
    SetItemRef = function(link, ...)
        local name = type(link) == "string" and link:match("^gfmshop:(.+)$")
        if name then
            if ns.OpenShopLink then ns.OpenShopLink(name) end
            return
        end
        return origSetItemRef(link, ...)
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
                off[vkey(o.id, o.suffix)] = o
            end
        end

        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        -- hide our hidden-channel protocol chatter from every chat frame
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(_, _, msg)
            if msg and msg:sub(1, #CHAT_TAG) == CHAT_TAG then return true end
        end)
        installShareLinks()   -- guild-chat shop-link rewrite + click handling
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
                local res = C_ChatInfo.SendAddonMessage(PREFIX, item.msg, "WHISPER", item.to)
                local throttled = Enum and Enum.SendAddonMessageResult
                    and res == Enum.SendAddonMessageResult.AddonMessageThrottle
                if throttled then
                    ns.Log("THROTTLE: addon whisper to " .. item.to .. " throttled by server — will retry")
                else
                    table.remove(sendQ, 1)
                end
            end
            -- surface a growing backlog (latency / throttling symptom), edge-triggered
            if #sendQ >= 20 and not sendBacklogWarned then
                sendBacklogWarned = true
                ns.Log("SEND backlog: " .. #sendQ .. " replies queued (throttle/latency?)")
            elseif #sendQ == 0 and sendBacklogWarned then
                sendBacklogWarned = false
                ns.Log("SEND backlog cleared")
            end
        end)

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
            if ns.dev then devEcho("|cff00ff96GFM|r ← channel: " .. text:sub(#CHAT_TAG + 1) .. " (from " .. tostring(sender) .. ")") end
            handleMsg(text:sub(#CHAT_TAG + 1), sender)
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
    elseif msg == "debug" then
        refreshConfig()
        local t = GetGuildInfoText() or ""
        local cur, max = ns.ItemDB.HarvestProgress()
        devEcho("|cff00ff96GFM debug|r")
        devEcho("  guild: " .. tostring(GetGuildInfo("player")))
        devEcho("  guildInfoText length: " .. #t)
        devEcho("  channelName: " .. tostring(ns.channelName) .. " | joined: " .. tostring(ns.channelIndex ~= nil))
        devEcho(("  item DB size: %d | harvest %d/%d (%s) | auxSeeded=%s | disableAux=%s"):format(
            ns.ItemDB.Count(), cur, max, ns.ItemDB.IsHarvesting() and "running" or "idle",
            tostring(GuildFoundMarketDB.auxSeeded), tostring(GuildFoundMarketDB.disableAux)))
        local n = 0; for _ in pairs(offers()) do n = n + 1 end
        devEcho("  my offers: " .. n)
        if ns.ToggleDebug and not (_G.GuildFoundMarketDebug and _G.GuildFoundMarketDebug:IsShown()) then ns.ToggleDebug() end
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
            ns.results["Testseller1#0"]  = { seller = "Testseller1",  suffix = 0, qty = 5,  price = 150000, loc = "Bank, Orgrimmar" }
            ns.results["Cheapcharlie#0"] = { seller = "Cheapcharlie", suffix = 0, qty = 20, price = 95000,  loc = "Auction House, Orgrimmar" }
            ns.results["Bidderbob#0"]    = { seller = "Bidderbob",    suffix = 0, qty = 1,  price = 0,      loc = "The Crossroads" }
            if ns.RefreshBuy then ns.RefreshBuy() end
            ns.Feedback("Injected 3 fake offers into the current search.", false)
        end
    else
        ns.ToggleUI()
    end
end
