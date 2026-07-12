local ADDON, ns = ...

--========================================================================
-- Browse by buyer (the buy-side mirror of SellerBrowse + the Q/R half of Search).
-- Three flows, all gated by the shared `paused` flag so one toggle silences buying too:
--   * WQ/WR  "who wants this item?"   (mirror Q/R)   -> ns.buyers.find
--   * W/WC   buyer scan (who's buying) (mirror S/C)  -> ns.buyers.results
--   * WL/WK  one buyer's full want list (mirror L/K) -> ns.buyers.catalog
-- WR packs suffix+cod into one field ("suffix:cod") because the wire dispatcher only yields
-- six payload fields (a..f) and the other six are already used.
--========================================================================
local activeWQid = nil   -- id of the active "who wants this" item query
local activeWSid = nil   -- id of the active buyer scan
local activeWLid = nil   -- id of the active per-buyer want-list fetch
local seq = 0

-- One want row into the shared everything-wanted store (the Buyers tab's default view).
local function noteWant(buyer, id, suffix, qty, price, cod, self)
    ns.buyers.allWants[buyer .. "#" .. id .. "#" .. (suffix or 0)] =
        { buyer = buyer, id = id, suffix = suffix or 0, qty = qty or 0, price = price or 0, cod = cod and true or false, self = self }
end

--========================================================================
-- WQ/WR: "who wants this item?" (driven from a Selling row or the Buyers autocomplete)
--========================================================================
function ns.FindBuyersForItem(itemID)
    if not ns.channelName then ns.Feedback("Not in a confederation, can't find buyers.", true); return end
    if not itemID then return end
    seq = seq + 1
    activeWQid = ns.playerName .. "#WQ" .. seq
    if ns.NetStats then ns.NetStats.ScanStarted(activeWQid) end
    wipe(ns.buyers.find.results)
    ns.buyers.find.itemID = itemID
    ns.buyers.find.active = true
    ns.buyers.find.start = GetTime()
    local idx = ns.EnsureChannel()
    if idx then
        SendChatMessage(ns.CHAT_TAG .. ("WQ~%s~%d~%s"):format(activeWQid, itemID, ns.version), "CHANNEL", nil, idx)
        ns.Log(("FIND-BUYERS \"%s\" (id %d) sent"):format(GetItemInfo(itemID) or ("item:" .. itemID), itemID))
    else
        ns.Feedback("Marketplace channel not ready yet; try again in a second.", true)
        ns.Log(("FIND-BUYERS (id %d) FAILED: channel not ready"):format(itemID))
    end
    if ns.selfTest and not ns.IsPaused() then   -- show our own want for this item locally
        for _, it in ipairs(ns.WantList()) do
            if it.id == itemID then
                ns.buyers.find.results[ns.playerName .. "#" .. it.suffix] =
                    { buyer = ns.playerName, suffix = it.suffix, qty = it.qty, price = it.price, cod = it.cod, loc = ns.LiveLoc(), self = true }
                noteWant(ns.playerName, it.id, it.suffix, it.qty, it.price, it.cod, true)
            end
        end
    end
    if ns.RefreshFindBuyers then ns.RefreshFindBuyers() end
    local thisQid = activeWQid
    C_Timer.After(ns.QUERY_SETTLE, function()
        if activeWQid == thisQid then
            ns.buyers.find.active = false
            if ns.RefreshFindBuyers then ns.RefreshFindBuyers() end
        end
    end)
end

-- WQ~qid~itemID~ver: someone is looking for buyers of an item. Answer every variant we want.
ns.OnMessage("WQ", function(a, b, c, _, _, _, sender)
    ns.NotePeerVersion(c, sender)
    local itemID = tonumber(b)
    ns.ItemDB.Learn(itemID)
    if Ambiguate(sender, "short") == ns.playerName then return end   -- my own query: self-injected locally
    if ns.IsPaused() then return end                                 -- paused: stay invisible
    local answered = 0
    for _, it in ipairs(ns.WantList()) do
        if it.id == itemID then
            -- WR~qid~id~qty~price~loc~suffix:cod~guild~valid  (suffix+cod packed into field 6;
            -- guild then the valid flag appended last)
            ns.EnqueueWhisper(("WR~%s~%d~%d~%d~%s~%d:%d~%s~%s"):format(a, it.id, it.qty, it.price, ns.LiveLoc(), it.suffix, it.cod and 1 or 0, ns.MyGuild() or "", ns.MyValidFlag()), sender)
            answered = answered + 1
        end
    end
    if answered > 0 then
        ns.Log(("answered %s's buyer search for %s (%d variant(s))"):format(Ambiguate(sender, "short"), GetItemInfo(itemID) or ("item:" .. itemID), answered))
    end
end)

-- WR~qid~id~qty~price~loc~suffix:cod~guild~valid: a want in reply to our buyer search.
ns.OnMessage("WR", function(a, b, c, d, e, f, sender, g, h)
    if a ~= activeWQid or tonumber(b) ~= ns.buyers.find.itemID then return end
    local sfx, cod = strsplit(":", f or "0:0")
    local suffix = tonumber(sfx) or 0
    local s = Ambiguate(sender, "short")
    ns.NoteGuild(sender, g)
    ns.NoteValid(sender, h)
    ns.buyers.find.results[s .. "#" .. suffix] =
        { buyer = s, suffix = suffix, qty = tonumber(c) or 0, price = tonumber(d) or 0, loc = e or "", cod = (tonumber(cod) or 0) == 1 }
    -- an item query doubles as a per-item refresh of the everything-wanted view
    noteWant(s, tonumber(b), suffix, tonumber(c), tonumber(d), (tonumber(cod) or 0) == 1)
    ns.ItemDB.Learn(tonumber(b))
    ns.Log(("  buyer %s wants it: %sx @ %sc (%+.1fs)"):format(s, tostring(c), tostring(d), GetTime() - (ns.buyers.find.start or GetTime())))
    if ns.RefreshFindBuyersSoon then ns.RefreshFindBuyersSoon() end
end)

--========================================================================
-- W/WC: buyer scan (browse all buyers with a want list)
--========================================================================
function ns.ScanBuyers(filter)
    if not ns.channelName then ns.Feedback("Not in a confederation, can't browse buyers.", true); return end
    filter = filter or ""
    ns.buyers.filter = filter
    ns.buyers.pendingOpen = nil
    seq = seq + 1
    activeWSid = ns.playerName .. "#WS" .. seq
    if ns.NetStats then ns.NetStats.ScanStarted(activeWSid) end
    wipe(ns.buyers.results)
    ns.buyers.count = 0
    ns.buyers.capped = false
    ns.buyers.scanning = true
    ns.buyers.scanStart = GetTime()
    local idx = ns.EnsureChannel()
    if idx then
        SendChatMessage(ns.CHAT_TAG .. ("W~%s~%s~%s"):format(activeWSid, filter, ns.version), "CHANNEL", nil, idx)
        ns.Log(("BUYERS scan sent%s"):format(filter ~= "" and (" (filter \"" .. filter .. "\")") or ""))
    else
        ns.Feedback("Marketplace channel not ready yet; try again in a second.", true)
        ns.Log("BUYERS scan FAILED: channel not ready")
    end
    if ns.selfTest and not ns.IsPaused() and (filter == "" or ns.playerName:lower():find(filter, 1, true)) then
        local list = ns.WantList()
        if #list > 0 then
            local thisSid, count, loc = activeWSid, #list, ns.LiveLoc()
            C_Timer.After(0.2, function()
                if activeWSid ~= thisSid then return end
                if not ns.buyers.results[ns.playerName] then ns.buyers.count = (ns.buyers.count or 0) + 1 end
                ns.buyers.results[ns.playerName] = { count = count, loc = loc, hasNote = (ns.GetShopNote and ns.GetShopNote() ~= "") }
                if ns.buyers.pendingOpen == ns.playerName then
                    ns.buyers.pendingOpen = nil
                    ns.OpenBuyer(ns.playerName, loc)
                    if ns.SetBuyersView then ns.SetBuyersView("SHOW") end
                end
                if ns.RefreshBuyersSoon then ns.RefreshBuyersSoon() end
            end)
        end
    end
    if ns.RefreshBuyers then ns.RefreshBuyers() end
    local thisSid = activeWSid
    C_Timer.After(ns.QUERY_SETTLE, function()
        if activeWSid == thisSid then
            ns.buyers.scanning = false
            if ns.buyers.pendingOpen then
                ns.Feedback(("%s isn't answering. They may be offline or have nothing wanted."):format(ns.buyers.pendingOpen), true)
                ns.buyers.pendingOpen = nil
            end
            ns.Log(("BUYERS scan done: %d buyer(s)%s in %.1fs"):format(
                ns.buyers.count or 0, ns.buyers.capped and " (capped)" or "", GetTime() - (ns.buyers.scanStart or GetTime())))
            if ns.RefreshBuyers then ns.RefreshBuyers() end
        end
    end)
end

-- W~sid~filter~ver: a buyer-browse scan. Answer with my summary if I have a want list and
-- (when filtered) my name matches.
ns.OnMessage("W", function(a, b, c, _, _, _, sender)
    if Ambiguate(sender, "short") == ns.playerName then return end
    if ns.IsPaused() then return end
    ns.NotePeerVersion(c, sender)
    local filter = b
    if filter and filter ~= "" and not ns.playerName:lower():find(filter, 1, true) then return end
    local list = ns.WantList()
    if #list == 0 then return end
    local sid, n, loc = a, #list, ns.LiveLoc()
    local jitter = (filter and filter ~= "") and 0.3 or ns.SCAN_JITTER
    C_Timer.After(math.random() * jitter, function()
        -- 4th field: 1-byte "have a note" flag (the note text is fetched on demand, NQ/NR)
        local flag = (ns.GetShopNote and ns.GetShopNote() ~= "") and "1" or ""
        -- guild + valid flag appended last so older clients read sid/count/loc/hasNote unchanged
        ns.EnqueueWhisper(("WC~%s~%d~%s~%s~%s~%s"):format(sid, n, loc, flag, ns.MyGuild() or "", ns.MyValidFlag()), sender)
    end)
end)

-- WC~sid~count~loc~hasNote~guild~valid: a buyer's summary in reply to our scan (hasNote, guild
-- and the valid flag appended in that order).
ns.OnMessage("WC", function(a, b, c, d, e, f, sender)
    if a ~= activeWSid then return end
    local s = Ambiguate(sender, "short")
    ns.NoteGuild(sender, e)
    ns.NoteValid(sender, f)
    if not ns.buyers.results[s] then
        if (ns.buyers.count or 0) >= ns.ScanCap() then ns.buyers.capped = true; return end
        ns.buyers.count = (ns.buyers.count or 0) + 1
    end
    ns.buyers.results[s] = { count = tonumber(b) or 0, loc = c or "", hasNote = (d == "1") }
    ns.Log(("  buyer %s: %s want(s) (%+.1fs)"):format(s, tostring(b), GetTime() - (ns.buyers.scanStart or GetTime())))
    if ns.buyers.pendingOpen and s == ns.buyers.pendingOpen then
        ns.buyers.pendingOpen = nil
        if ns.OpenBuyer then ns.OpenBuyer(s, c or "") end
        if ns.SetBuyersView then ns.SetBuyersView("SHOW") end
    end
    if ns.RefreshBuyersSoon then ns.RefreshBuyersSoon() end
end)

--========================================================================
-- WL/WK: one buyer's full want list (lazy, chunked)
--========================================================================
function ns.OpenBuyer(buyer, loc)
    if not buyer then return end
    loc = loc or (ns.buyers.results[buyer] and ns.buyers.results[buyer].loc) or ""
    ns.Log("OPEN buyer " .. buyer .. ": requesting want list")
    seq = seq + 1
    activeWLid = ns.playerName .. "#WL" .. seq
    if ns.NetStats then ns.NetStats.ScanStarted(activeWLid) end
    -- seed the note from the index cache (clicked there) or selftest; real buyers also bundle a
    -- fresh note with their want-list reply (see the WL handler)
    local seededNote = ns.buyers.results[buyer] and ns.buyers.results[buyer].note
    ns.buyers.catalog = { buyer = buyer, loc = loc, items = {}, loading = true, note = seededNote }
    if ns._fakeWant and ns._fakeWant[buyer] then          -- dev: /gfm fakebuyers
        for _, id in ipairs(ns._fakeWant[buyer]) do
            ns.buyers.catalog.items[ns.vkey(id, 0)] = { id = id, suffix = 0, qty = (id % 4) + 1, price = (id % 50 + 1) * 1000, cod = (id % 2) == 0 }
        end
        ns.buyers.catalog.loading = false
    elseif ns.selfTest and buyer == ns.playerName and not ns.IsPaused() then   -- can't whisper yourself
        for _, it in ipairs(ns.WantList()) do ns.buyers.catalog.items[ns.vkey(it.id, it.suffix)] = it end
        ns.buyers.catalog.note = ns.GetShopNote and ns.GetShopNote() or ""
        ns.buyers.catalog.loading = false
    else
        ns.EnqueueWhisper(("WL~%s"):format(activeWLid), buyer)
        local thisLid = activeWLid
        C_Timer.After(ns.QUERY_SETTLE, function()
            if activeWLid == thisLid and ns.buyers.catalog and ns.buyers.catalog.loading then
                ns.buyers.catalog.loading = false
                if ns.RefreshBuyerCatalog then ns.RefreshBuyerCatalog() end
            end
        end)
    end
    if ns.RefreshBuyerCatalog then ns.RefreshBuyerCatalog() end
end

-- WL~lid: a directed request for my full want list. Reply in <=180-char chunks.
ns.OnMessage("WL", function(a, _, _, _, _, _, sender)
    if ns.IsPaused() then return end
    local lid, list, buf = a, ns.WantList(), ""
    local function flush(more) ns.EnqueueWhisper(("WK~%s~%d~%s"):format(lid, more, buf), sender); buf = "" end
    for i = 1, #list do
        local it = list[i]
        local p = ("%d:%d:%d:%d:%d"):format(it.id, it.qty, it.price, it.suffix, it.cod and 1 or 0)   -- id:qty:price:suffix:cod
        if #buf + #p + 1 > 180 then flush(1) end
        buf = (buf == "") and p or (buf .. ";" .. p)
    end
    flush(0)
    -- bundle the shop note with the want list (same NR message the index bubble uses)
    local note = ns.GetShopNote and ns.GetShopNote() or ""
    if note ~= "" then ns.EnqueueWhisper("NR~" .. note, sender) end
    ns.Log(("sent my want list (%d items) to %s"):format(#list, Ambiguate(sender, "short")))
end)

-- WK~lid~more~rows: a chunk of a buyer's want list (rows are id:qty:price:suffix:cod;...).
-- The bag scan and the all-wants sweep fetch want lists over the same message with their
-- own lids; give them first pick so neither collides with a buyer the Buyers tab has open.
ns.OnMessage("WK", function(a, b, c)
    if ns.BagScan and ns.BagScan.HandleWantChunk and ns.BagScan.HandleWantChunk(a, b, c) then return end
    if ns.HandleAllWantsChunk(a, b, c) then return end
    if a ~= activeWLid or not ns.buyers.catalog then return end
    for chunk in (c or ""):gmatch("[^;]+") do
        local id, qty, price, suffix, cod = strsplit(":", chunk)
        id = tonumber(id)
        if id then
            local sfx = tonumber(suffix) or 0
            ns.buyers.catalog.items[ns.vkey(id, sfx)] = { id = id, suffix = sfx, qty = tonumber(qty) or 0, price = tonumber(price) or 0, cod = (tonumber(cod) or 0) == 1 }
            ns.ItemDB.Learn(id)
        end
    end
    if tonumber(b) == 0 then
        ns.buyers.catalog.loading = false
        local n = 0; for _ in pairs(ns.buyers.catalog.items) do n = n + 1 end
        ns.Log(("OPEN buyer %s: %d want(s)"):format(ns.buyers.catalog.buyer, n))
    end
    if ns.RefreshBuyerCatalogSoon then ns.RefreshBuyerCatalogSoon() end
end)

--========================================================================
-- All-wants sweep: every buyer's full want list in one go, feeding the Buyers tab's
-- default "everything wanted" view. Same shape as the bag scan's buyer side: ONE buyer
-- scan broadcast (needs the hardware event of the tab/Refresh click), then a directed
-- WL~ fetch per answering buyer, concurrency-capped with a timeout watchdog.
--========================================================================
local AW_CONCURRENT, AW_WINDOW = 6, 6
local awQueue, awInflight, awKnown = {}, {}, {}
local awTicker, awGen = nil, 0

local function awInflightCount()
    local n = 0
    for _ in pairs(awInflight) do n = n + 1 end
    return n
end

local function awFinish()
    local scan = ns.buyers.allScan
    if not scan.active then return end
    scan.active = false
    if awTicker then awTicker:Cancel(); awTicker = nil end
    wipe(awQueue); wipe(awInflight)
    local n = 0; for _ in pairs(ns.buyers.allWants) do n = n + 1 end
    ns.Log(("ALL-WANTS done: %d/%d buyers answered, %d want(s)"):format(scan.done, scan.total, n))
    if ns.RefreshFindBuyers then ns.RefreshFindBuyers() end
end

local function awPump()
    while #awQueue > 0 and awInflightCount() < AW_CONCURRENT do
        local buyer = table.remove(awQueue, 1)
        seq = seq + 1
        local lid = ns.playerName .. "#AW" .. seq
        awInflight[lid] = { buyer = buyer, deadline = GetTime() + AW_WINDOW }
        if ns.NetStats then ns.NetStats.ScanStarted(lid) end
        ns.EnqueueWhisper("WL~" .. lid, buyer)
    end
    if #awQueue == 0 and awInflightCount() == 0 then awFinish() end
end

local function awTick()
    if not ns.buyers.allScan.active then return end
    local now = GetTime()
    for lid, f in pairs(awInflight) do
        if now > f.deadline then
            awInflight[lid] = nil
            awKnown[lid] = true   -- swallow chunks that still trickle in for it
            ns.buyers.allScan.done = ns.buyers.allScan.done + 1
            ns.Log("ALL-WANTS: no want list from " .. f.buyer .. " (skipped)")
        end
    end
    awPump()
    if ns.RefreshFindBuyersSoon then ns.RefreshFindBuyersSoon() end
end

-- Phase 2: the buyer scan settled; fetch every answering buyer's want list.
local function awStartFetch(gen)
    if gen ~= awGen or not ns.buyers.allScan.active then return end
    for buyer in pairs(ns.buyers.results) do
        if buyer ~= ns.playerName then awQueue[#awQueue + 1] = buyer end
    end
    table.sort(awQueue)
    ns.buyers.allScan.total = #awQueue
    ns.Log(("ALL-WANTS: %d buyer(s) answered; fetching want lists (%d at a time)"):format(#awQueue, AW_CONCURRENT))
    if #awQueue == 0 then awFinish(); return end
    awTicker = C_Timer.NewTicker(0.5, awTick)
    awPump()
    if ns.RefreshFindBuyers then ns.RefreshFindBuyers() end
end

-- A WK chunk answering this sweep. True when the lid is ours, so the other handlers skip it.
function ns.HandleAllWantsChunk(lid, more, rows)
    local f = awInflight[lid]
    if not f then return awKnown[lid] or false end
    f.deadline = GetTime() + AW_WINDOW
    for chunk in (rows or ""):gmatch("[^;]+") do
        local id, qty, price, suffix, cod = strsplit(":", chunk)
        id = tonumber(id)
        if id then
            noteWant(f.buyer, id, tonumber(suffix), tonumber(qty), tonumber(price), (tonumber(cod) or 0) == 1)
            ns.ItemDB.Learn(id)
        end
    end
    if (tonumber(more) or 0) == 0 then
        awInflight[lid] = nil
        awKnown[lid] = true
        ns.buyers.allScan.done = ns.buyers.allScan.done + 1
        awPump()
    end
    if ns.RefreshFindBuyersSoon then ns.RefreshFindBuyersSoon() end
    return true
end

-- Kick off the sweep. MUST be called from a hardware event (tab click, Refresh button):
-- the buyer scan underneath broadcasts on the chat channel. Keeps whatever it already
-- holds until the fresh replies overwrite it, so the view never blanks out.
function ns.ScanAllWants()
    if not ns.channelName then ns.Feedback("Not in a confederation, can't collect wants.", true); return end
    if ns.buyers.allScan.active then return end   -- already sweeping
    awGen = awGen + 1
    wipe(ns.buyers.allWants); wipe(awKnown)
    ns.buyers.allScan.active, ns.buyers.allScan.total, ns.buyers.allScan.done = true, 0, 0
    if ns.selfTest and not ns.IsPaused() then   -- you can't whisper yourself: inject own wants
        for _, it in ipairs(ns.WantList()) do noteWant(ns.playerName, it.id, it.suffix, it.qty, it.price, it.cod, true) end
    end
    ns.ScanBuyers("")   -- one broadcast; replies land in ns.buyers.results (the shared index)
    local gen = awGen
    C_Timer.After((ns.QUERY_SETTLE or 5) + 0.5, function() awStartFetch(gen) end)
    if ns.RefreshFindBuyers then ns.RefreshFindBuyers() end
end
