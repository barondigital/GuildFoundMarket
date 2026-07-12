local ADDON, ns = ...

--========================================================================
-- Search (buyer side)
--========================================================================
local activeQid  = nil
local querySeq   = 0

function ns.Search(itemID)
    if not ns.channelName then ns.Feedback("Not in a confederation, can't search.", true); return end
    if not itemID then return end
    querySeq = querySeq + 1
    activeQid = ns.playerName .. "#" .. querySeq
    if ns.NetStats then ns.NetStats.ScanStarted(activeQid) end
    wipe(ns.search.results)
    ns.search.itemID = itemID
    ns.search.active = true
    -- Broadcast the query right here, inside the search keypress/click. SendChatMessage
    -- to a channel is only allowed from a hardware event (never a timer), and addon
    -- messages over custom channels are disabled in Classic Era, so this is the only path.
    ns.search.start = GetTime()
    local idx = ns.EnsureChannel()
    if idx then
        SendChatMessage(ns.CHAT_TAG .. ("Q~%s~%d~%s"):format(activeQid, itemID, ns.version), "CHANNEL", nil, idx)
        ns.Log(("SEARCH \"%s\" (id %d) sent"):format(GetItemInfo(itemID) or ("item:" .. itemID), itemID))
    else
        ns.Feedback("Marketplace channel not ready yet; try the search again in a second.", true)
        ns.Log(("SEARCH (id %d) FAILED: channel not ready"):format(itemID))
    end
    -- Always show our own offers for this base item among the results (every variant we
    -- list), so we can see where our price sits and adjust to compete. Local-only injection
    -- (we never whisper ourselves), shown even while paused since it's our own view.
    local mineCount = 0
    for _, it in ipairs(ns.OfferList()) do
        if it.id == itemID then
            mineCount = mineCount + 1
            ns.search.results[ns.playerName .. "#" .. it.suffix] =
                { seller = ns.playerName, suffix = it.suffix, qty = it.qty, price = it.price, loc = ns.LiveLoc(), self = true }
        end
    end
    if mineCount == 0 and ns.selfTest then
        ns.Feedback(("self-test: you have no offer for itemID %d (%s)."):format(itemID, GetItemInfo(itemID) or "?"), true)
    end
    if ns.RefreshBuy then ns.RefreshBuy() end
    local thisQid = activeQid
    C_Timer.After(ns.QUERY_SETTLE, function()
        if activeQid == thisQid then
            ns.search.active = false
            local n = 0; for _ in pairs(ns.search.results) do n = n + 1 end
            ns.Log(("SEARCH done: %d offer(s) in %.1fs"):format(n, GetTime() - (ns.search.start or GetTime())))
            if ns.RefreshBuy then ns.RefreshBuy() end
            if ns.PriceDB then   -- snapshot the prices we just saw for this item (#13)
                local list = {}
                for _, o in pairs(ns.search.results) do
                    list[#list + 1] = { id = ns.search.itemID, suffix = o.suffix, price = o.price }
                end
                ns.PriceDB.Record(list)
            end
        end
    end)
end

-- Q~qid~itemID~ver: someone searched an item. Answer every variant we list for it.
ns.OnMessage("Q", function(a, b, c, _, _, _, sender)
    ns.NotePeerVersion(c, sender)
    local itemID = tonumber(b)
    ns.ItemDB.Learn(itemID)                                       -- learn the searched item (vocabulary)
    if Ambiguate(sender, "short") == ns.playerName then return end   -- my own query: own offers are injected locally
    if ns.IsPaused() then return end                                 -- paused: stay invisible
    -- an offer is the seller's claim: answer every variant we list for this base item,
    -- exactly as posted, no inventory check (settled buyer<->seller in whispers)
    local answered = 0
    for _, it in ipairs(ns.OfferList()) do
        if it.id == itemID then
            -- guild + valid flag appended last (7th/8th field) so older clients read suffix at
            -- field 6 unchanged and drop the tail
            ns.EnqueueWhisper(("R~%s~%d~%d~%d~%s~%d~%s~%s"):format(a, it.id, it.qty, it.price, ns.LiveLoc(), it.suffix, ns.MyGuild() or "", ns.MyValidFlag()), sender)
            answered = answered + 1
        end
    end
    if answered > 0 then
        ns.Log(("answered %s's search for %s (%d variant(s))"):format(Ambiguate(sender, "short"), GetItemInfo(itemID) or ("item:" .. itemID), answered))
    end
end)

-- R~qid~itemID~qty~price~loc~suffixID~guild~valid: an offer in reply to our search (suffix LAST
-- so 0.6.0 clients read qty/price/loc correctly; guild then valid appended for the same reason).
ns.OnMessage("R", function(a, b, c, d, e, f, sender, g, h)
    if a ~= activeQid or tonumber(b) ~= ns.search.itemID then return end
    local suffix = tonumber(f) or 0
    local s = Ambiguate(sender, "short")
    ns.NoteGuild(sender, g)
    ns.NoteValid(sender, h)
    ns.search.results[s .. "#" .. suffix] = { seller = s, suffix = suffix, qty = tonumber(c) or 0, price = tonumber(d) or 0, loc = e or "" }
    ns.ItemDB.Learn(tonumber(b))
    ns.Log(("  offer from %s: %sx @ %sc (%+.1fs)"):format(s, tostring(c), tostring(d), GetTime() - (ns.search.start or GetTime())))
    if ns.RefreshBuySoon then ns.RefreshBuySoon() end
end)
