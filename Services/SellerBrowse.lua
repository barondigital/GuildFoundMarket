local ADDON, ns = ...

--========================================================================
-- Browse by seller. ScanSellers broadcasts "who's selling?"; online sellers
-- whisper back a one-line summary (count + location). Opening a seller fetches
-- their full catalog with a directed whisper (chunked, so big lists are fine).
--========================================================================
local activeSid  = nil  -- id of the active "who's selling" scan (drops stale replies)
local activeLid  = nil  -- id of the active per-seller catalog fetch
local sellerSeq  = 0

-- filter: optional lowercase name substring. Empty = "who's online" (capped sample);
-- non-empty = only sellers whose name contains it answer, so it scales to big groups.
function ns.ScanSellers(filter)
    if not ns.channelName then ns.Feedback("Not in a confederation, can't browse sellers.", true); return end
    filter = filter or ""
    ns.sellers.filter = filter
    ns.sellers.pendingOpen = nil   -- a fresh scan cancels any pending shop-link auto-open
    sellerSeq = sellerSeq + 1
    activeSid = ns.playerName .. "#S" .. sellerSeq
    wipe(ns.sellers.results)
    ns.sellers.count = 0
    ns.sellers.capped = false
    ns.sellers.scanning = true
    ns.sellers.scanStart = GetTime()
    local idx = ns.EnsureChannel()
    if idx then
        SendChatMessage(ns.CHAT_TAG .. ("S~%s~%s~%s"):format(activeSid, filter, ns.version), "CHANNEL", nil, idx)
        ns.Log(("SELLERS scan sent%s"):format(filter ~= "" and (" (filter \"" .. filter .. "\")") or ""))
    else
        ns.Feedback("Marketplace channel not ready yet; try again in a second.", true)
        ns.Log("SELLERS scan FAILED: channel not ready")
    end
    if ns.selfTest and not ns.IsPaused() and (filter == "" or ns.playerName:lower():find(filter, 1, true)) then
        local list = ns.OfferList()
        if #list > 0 then
            -- mimic our own reply arriving over the channel a moment later, so the
            -- same index + pending-open path a real seller would drive is exercised
            local thisSid, count, loc = activeSid, #list, ns.LiveLoc()
            C_Timer.After(0.2, function()
                if activeSid ~= thisSid then return end
                if not ns.sellers.results[ns.playerName] then ns.sellers.count = (ns.sellers.count or 0) + 1 end
                ns.sellers.results[ns.playerName] = { count = count, loc = loc, hasNote = (ns.GetShopNote and ns.GetShopNote() ~= "") }
                if ns.sellers.pendingOpen == ns.playerName then
                    ns.sellers.pendingOpen = nil
                    ns.OpenSeller(ns.playerName, loc)
                    if ns.SetSellersView then ns.SetSellersView("SHOW") end
                end
                if ns.RefreshSellersSoon then ns.RefreshSellersSoon() end
            end)
        end
    end
    if ns.RefreshSellers then ns.RefreshSellers() end
    local thisSid = activeSid
    C_Timer.After(ns.QUERY_SETTLE, function()
        if activeSid == thisSid then
            ns.sellers.scanning = false
            if ns.sellers.pendingOpen then   -- a shop-link click that nobody answered
                ns.Feedback(("%s's shop isn't answering. They may be offline or out of stock."):format(ns.sellers.pendingOpen), true)
                ns.sellers.pendingOpen = nil
            end
            ns.Log(("SELLERS scan done: %d seller(s)%s in %.1fs"):format(
                ns.sellers.count or 0, ns.sellers.capped and " (capped)" or "", GetTime() - (ns.sellers.scanStart or GetTime())))
            if ns.RefreshSellers then ns.RefreshSellers() end
        end
    end)
end

-- Snapshot the open seller's catalog prices into the local price DB (#13). One seller, so each
-- item lands as a count-1 observation (overwriting unless a richer search snapshot is newer).
local function recordCatalogPrices()
    if not ns.PriceDB or not ns.sellers.catalog then return end
    local list = {}
    for _, it in pairs(ns.sellers.catalog.items) do
        list[#list + 1] = { id = it.id, suffix = it.suffix, price = it.price }
    end
    ns.PriceDB.Record(list)
end

-- Open one seller: request their full catalog (lazy). Replies arrive as K~ chunks.
function ns.OpenSeller(seller, loc)
    if not seller then return end
    loc = loc or (ns.sellers.results[seller] and ns.sellers.results[seller].loc) or ""
    ns.Log("OPEN " .. seller .. ": requesting catalog")
    sellerSeq = sellerSeq + 1
    activeLid = ns.playerName .. "#L" .. sellerSeq
    -- seed the note from the index cache (if you already loaded it there); real sellers also
    -- bundle a fresh note with their catalog reply (see the L handler)
    local seededNote = ns.sellers.results[seller] and ns.sellers.results[seller].note
    ns.sellers.catalog = { seller = seller, loc = loc, items = {}, loading = true, note = seededNote }
    if ns._fakeCat and ns._fakeCat[seller] then          -- dev: /gfm fakesellers
        for _, id in ipairs(ns._fakeCat[seller]) do
            ns.sellers.catalog.items[ns.vkey(id, 0)] = { id = id, suffix = 0, qty = (id % 5) + 1, price = (id % 90 + 1) * 1000 }
        end
        ns.sellers.catalog.loading = false
        recordCatalogPrices()
    elseif ns.selfTest and seller == ns.playerName and not ns.IsPaused() then  -- can't whisper yourself
        for _, it in ipairs(ns.OfferList()) do ns.sellers.catalog.items[ns.vkey(it.id, it.suffix)] = it end
        ns.sellers.catalog.note = ns.GetShopNote and ns.GetShopNote() or ""
        ns.sellers.catalog.loading = false
        recordCatalogPrices()
    else
        ns.EnqueueWhisper(("L~%s"):format(activeLid), seller)
        local thisLid = activeLid
        C_Timer.After(ns.QUERY_SETTLE, function()
            if activeLid == thisLid and ns.sellers.catalog and ns.sellers.catalog.loading then
                ns.sellers.catalog.loading = false   -- no reply (seller went offline / paused)
                if ns.RefreshSellerCatalog then ns.RefreshSellerCatalog() end
            end
        end)
    end
    if ns.RefreshSellerCatalog then ns.RefreshSellerCatalog() end
end

-- S~sid~filter~ver: a seller-browse scan. Answer with my summary (count + location) if I
-- have stock and (when filtered) my name matches the requested substring.
ns.OnMessage("S", function(a, b, c, _, _, _, sender)
    if Ambiguate(sender, "short") == ns.playerName then return end   -- ignore my own broadcast
    if ns.IsPaused() then return end                                 -- paused: stay invisible
    ns.NotePeerVersion(c, sender)
    local filter = b
    if filter and filter ~= "" and not ns.playerName:lower():find(filter, 1, true) then return end
    local list = ns.OfferList()
    if #list == 0 then return end
    -- spread replies over time so the scanner isn't hit by a burst; filtered scans match
    -- few people, so answer those almost immediately.
    local sid, n, loc = a, #list, ns.LiveLoc()
    local jitter = (filter and filter ~= "") and 0.3 or ns.SCAN_JITTER
    C_Timer.After(math.random() * jitter, function()
        -- 4th field is a 1-byte "have a shop note" flag, not the note itself: the index reply
        -- stays tiny (full protocol headroom) and the note text is fetched on demand (NQ/NR)
        -- only when a buyer clicks the bubble. Old clients ignore the extra field.
        local flag = (ns.GetShopNote and ns.GetShopNote() ~= "") and "1" or ""
        -- guild appended last so older clients read sid/count/loc/hasNote unchanged
        ns.EnqueueWhisper(("C~%s~%d~%s~%s~%s"):format(sid, n, loc, flag, ns.MyGuild() or ""), sender)
    end)
end)

-- C~sid~count~loc~hasNote~guild: a seller's summary in reply to our scan (hasNote + guild last).
ns.OnMessage("C", function(a, b, c, d, e, _, sender)
    if a ~= activeSid then return end
    local s = Ambiguate(sender, "short")
    ns.NoteGuild(sender, e)
    if not ns.sellers.results[s] then
        if (ns.sellers.count or 0) >= ns.SELLER_CAP then ns.sellers.capped = true; return end
        ns.sellers.count = (ns.sellers.count or 0) + 1
    end
    -- note stays nil ("not fetched yet"); the bubble offers to load it when hasNote is set
    ns.sellers.results[s] = { count = tonumber(b) or 0, loc = c or "", hasNote = (d == "1") }
    ns.Log(("  seller %s: %s items (%+.1fs)"):format(s, tostring(b), GetTime() - (ns.sellers.scanStart or GetTime())))
    if ns.sellers.pendingOpen and s == ns.sellers.pendingOpen then
        -- this seller answered on the private channel, so it's safe to open them
        ns.sellers.pendingOpen = nil
        if ns.OpenSeller then ns.OpenSeller(s, c or "") end
        if ns.SetSellersView then ns.SetSellersView("SHOW") end
    end
    if ns.RefreshSellersSoon then ns.RefreshSellersSoon() end
end)

-- L~lid: a directed request for my full catalog. Reply in <=180-char chunks.
ns.OnMessage("L", function(a, _, _, _, _, _, sender)
    if ns.IsPaused() then return end                                 -- paused: don't answer
    local lid, list, buf = a, ns.OfferList(), ""
    local function flush(more) ns.EnqueueWhisper(("K~%s~%d~%s"):format(lid, more, buf), sender); buf = "" end
    for i = 1, #list do
        local it = list[i]
        local p = ("%d:%d:%d:%d"):format(it.id, it.qty, it.price, it.suffix)   -- id:qty:price:suffix (suffix last)
        if #buf + #p + 1 > 180 then flush(1) end
        buf = (buf == "") and p or (buf .. ";" .. p)
    end
    flush(0)   -- final chunk (empty if I have nothing listed)
    -- bundle the shop note with the catalog so opening a seller delivers items + note together
    -- (same NR message the index bubble uses); skip it when there's nothing to show
    local note = ns.GetShopNote and ns.GetShopNote() or ""
    if note ~= "" then ns.EnqueueWhisper("NR~" .. note, sender) end
    ns.Log(("sent my catalog (%d items) to %s"):format(#list, Ambiguate(sender, "short")))
end)

-- K~lid~more~rows: a chunk of a seller's catalog (rows are id:qty:price:suffix;...).
ns.OnMessage("K", function(a, b, c)
    if a ~= activeLid or not ns.sellers.catalog then return end
    for chunk in (c or ""):gmatch("[^;]+") do
        local id, qty, price, suffix = strsplit(":", chunk)
        id = tonumber(id)
        if id then
            local sfx = tonumber(suffix) or 0
            ns.sellers.catalog.items[ns.vkey(id, sfx)] = { id = id, suffix = sfx, qty = tonumber(qty) or 0, price = tonumber(price) or 0 }
            ns.ItemDB.Learn(id)
        end
    end
    if tonumber(b) == 0 then
        ns.sellers.catalog.loading = false
        local n = 0; for _ in pairs(ns.sellers.catalog.items) do n = n + 1 end
        ns.Log(("OPEN %s: %d items in %.1fs"):format(ns.sellers.catalog.seller, n, GetTime() - (ns.sellers.openStart or GetTime())))
        recordCatalogPrices()
    end
    if ns.RefreshSellerCatalogSoon then ns.RefreshSellerCatalogSoon() end
end)

--========================================================================
-- Shop note: a per-character note shown on BOTH the Sellers and Buyers sides. Fetched on demand
-- (clicking a player's bubble in either index), so the heavy text never rides a scan. We whisper
-- NQ to the player; they answer NR with the note, matched back by the whisper's sender.
--========================================================================

-- Ask one player for their note (directed whisper). `store` is the index table to cache into
-- (ns.sellers.results or ns.buyers.results); a timeout clears "loading" if they don't answer.
function ns.RequestNote(name, store)
    if not name or not ns.channelName then return end
    local rec = store and store[name]
    if not rec or rec.note ~= nil or rec.noteLoading or rec.noteFailed then return end   -- have it / in flight / gave up
    rec.noteLoading = true
    if ns.selfTest and name == ns.playerName then                      -- can't whisper yourself
        rec.note = ns.GetShopNote and ns.GetShopNote() or ""; rec.noteLoading = nil
        if ns.RefreshSellersSoon then ns.RefreshSellersSoon() end
        if ns.RefreshBuyersSoon then ns.RefreshBuyersSoon() end
        if ns.NoteArrived then ns.NoteArrived(name) end
        return
    end
    ns.EnqueueWhisper("NQ", name)
    ns.Log("NOTE request -> " .. name)
    C_Timer.After(ns.QUERY_SETTLE, function()
        if rec.noteLoading then          -- no answer (offline / paused / no addon)
            rec.noteLoading = nil
            rec.noteFailed = true         -- stop hover/refresh from re-firing the request in a loop
            ns.Feedback(("Couldn't fetch %s's note (offline?)."):format(name), true)
            if ns.NoteArrived then ns.NoteArrived(name) end
        end
    end)
end

-- NQ: someone wants my note. Answer with it (paused clients stay silent).
ns.OnMessage("NQ", function(_, _, _, _, _, _, sender)
    if ns.IsPaused() then return end
    ns.EnqueueWhisper("NR~" .. (ns.GetShopNote and ns.GetShopNote() or ""), sender)
end)

-- NR~note: a player's note. Arrives as the reply to an index NQ click, or bundled with a catalog
-- fetch (L / WL). Updates wherever that player appears: the seller/buyer index records and the
-- open seller/buyer catalog. Matched to the player by the whisper's sender.
ns.OnMessage("NR", function(a, _, _, _, _, _, sender)
    local s = Ambiguate(sender, "short")
    local note = a or ""
    local srec = ns.sellers.results[s]
    local brec = ns.buyers and ns.buyers.results[s]
    local lrec = ns.shopLinkNotes and ns.shopLinkNotes[s]   -- pulled by hovering a shop link
    local scat = ns.sellers.catalog;        local sForCat = scat and scat.seller == s
    local bcat = ns.buyers and ns.buyers.catalog; local bForCat = bcat and bcat.buyer == s
    if not (srec or brec or lrec or sForCat or bForCat) then return end   -- unsolicited / stale
    if srec then srec.note = note; srec.noteLoading = nil; srec.noteFailed = nil end
    if brec then brec.note = note; brec.noteLoading = nil; brec.noteFailed = nil end
    if lrec then lrec.note = note; lrec.noteLoading = nil; lrec.noteFailed = nil end
    if sForCat then scat.note = note; if ns.RefreshSellerCatalogSoon then ns.RefreshSellerCatalogSoon() end end
    if bForCat then bcat.note = note; if ns.RefreshBuyerCatalogSoon then ns.RefreshBuyerCatalogSoon() end end
    ns.Log(("NOTE recv <- %s (%d chars)"):format(s, #note))
    if ns.RefreshSellersSoon then ns.RefreshSellersSoon() end
    if ns.RefreshBuyersSoon then ns.RefreshBuyersSoon() end
    if ns.NoteArrived then ns.NoteArrived(s) end
end)
