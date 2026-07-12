local ADDON, ns = ...

--========================================================================
-- Browse by category. Like Search, but the query carries an item class + subclass
-- instead of one itemID, and every seller answers with ALL their matching in-stock
-- offers (chunked like the catalog). Always class + subclass, never a whole class, to
-- bound the reply volume. Item quality/level are derived by the buyer from the itemID,
-- so nothing extra rides the wire. Returns the matching offers across all sellers.
--========================================================================
local activeQCid = nil
local browseSeq  = 0
local BROWSE_MATCH_CAP = 60   -- max matches one seller answers per category query (bounds the reply)

-- class/subclass of an item (locale-independent); nil if the item isn't cached yet
local function itemCategory(itemID)
    local cid, sub = select(12, GetItemInfo(itemID))
    return cid, sub
end

-- An item's equip slot (INVTYPE_*), with Robe folded into Chest so chest pieces group.
-- Shared by the seller-side QC filter and the buyer-side display filter.
function ns.EquipSlot(itemID)
    local loc = select(4, GetItemInfoInstant(itemID))
    if loc == "INVTYPE_ROBE" then loc = "INVTYPE_CHEST" end
    return loc
end

function ns.BrowseCategory(classID, subClassID, slot)
    if not ns.channelName then ns.Feedback("Not in a confederation, can't browse.", true); return end
    if not classID or not subClassID then return end
    browseSeq = browseSeq + 1
    activeQCid = ns.playerName .. "#QC" .. browseSeq
    if ns.NetStats then ns.NetStats.ScanStarted(activeQCid) end
    wipe(ns.browseResults)
    ns.browseClass, ns.browseSub, ns.browseSlot = classID, subClassID, slot
    ns.browsing = true
    ns.browseStart = GetTime()
    local idx = ns.EnsureChannel()
    if idx then
        -- slot appended last so older clients ignore it (and reply with the whole subclass)
        SendChatMessage(ns.CHAT_TAG .. ("QC~%s~%d~%d~%s~%s"):format(activeQCid, classID, subClassID, ns.version, slot or ""), "CHANNEL", nil, idx)
        ns.Log(("BROWSE category %d/%d%s sent"):format(classID, subClassID, slot and ("/" .. slot) or ""))
    else
        ns.Feedback("Marketplace channel not ready yet; try the browse again in a second.", true)
        ns.Log("BROWSE FAILED: channel not ready")
    end
    -- inject my own matching offers locally (we never whisper ourselves), even while paused
    for _, it in ipairs(ns.OfferList()) do
        local cid, sub = itemCategory(it.id)
        if cid == classID and sub == subClassID and (not slot or ns.EquipSlot(it.id) == slot) then
            ns.browseResults[ns.playerName .. "#" .. it.id .. "#" .. it.suffix] =
                { seller = ns.playerName, id = it.id, suffix = it.suffix, qty = it.qty, price = it.price, loc = ns.LiveLoc(), self = true }
        end
    end
    if ns.RefreshBrowse then ns.RefreshBrowse() end
    local thisId = activeQCid
    C_Timer.After(ns.QUERY_SETTLE, function()
        if activeQCid == thisId then
            ns.browsing = false
            local n = 0; for _ in pairs(ns.browseResults) do n = n + 1 end
            ns.Log(("BROWSE done: %d offer(s) in %.1fs"):format(n, GetTime() - (ns.browseStart or GetTime())))
            if ns.RefreshBrowse then ns.RefreshBrowse() end
            if ns.PriceDB then   -- snapshot the prices from this browse (#13)
                local list = {}
                for _, o in pairs(ns.browseResults) do
                    list[#list + 1] = { id = o.id, suffix = o.suffix, price = o.price }
                end
                ns.PriceDB.Record(list)
            end
        end
    end)
end

-- QC~qid~class~sub~ver~slot: a category browse. Answer with every in-stock offer matching the
-- class + subclass (and the equip slot if the buyer asked for one), chunked like the catalog
-- and capped + jittered like the seller scan. slot is optional (older buyers omit it).
ns.OnMessage("QC", function(a, b, c, d, e, _, sender)
    if Ambiguate(sender, "short") == ns.playerName then return end   -- own query: injected locally
    if ns.IsPaused() then return end
    ns.NotePeerVersion(d, sender)
    local classID, subID = tonumber(b), tonumber(c)
    if not classID or not subID then return end
    local slot = (e and e ~= "") and e or nil
    local matches = {}
    for _, it in ipairs(ns.OfferList()) do
        local cid, sub = itemCategory(it.id)
        if cid == classID and sub == subID and (not slot or ns.EquipSlot(it.id) == slot) then
            matches[#matches + 1] = it
            if #matches >= BROWSE_MATCH_CAP then break end
        end
    end
    if #matches == 0 then return end
    local qid = a
    C_Timer.After(math.random() * ns.SCAN_JITTER, function()
        local buf = ""
        -- guild + location + valid flag appended last (per-seller, repeated on each chunk) so
        -- older clients read qid/more/rows unchanged. The row budget drops to 150 to leave
        -- headroom for the trailing fields + header, keeping the whole line under the ~255-byte
        -- chat limit (the flag adds at most 2 bytes).
        local guild, loc, valid = ns.MyGuild() or "", ns.LiveLoc(), ns.MyValidFlag()
        local function flush(more) ns.EnqueueWhisper(("QR~%s~%d~%s~%s~%s~%s"):format(qid, more, buf, guild, loc, valid), sender); buf = "" end
        for i = 1, #matches do
            local it = matches[i]
            local p = ("%d:%d:%d:%d"):format(it.id, it.qty, it.price, it.suffix)   -- id:qty:price:suffix (suffix last)
            if #buf + #p + 1 > 150 then flush(1) end
            buf = (buf == "") and p or (buf .. ";" .. p)
        end
        flush(0)
    end)
    ns.Log(("answered %s's category browse (%d match(es))"):format(Ambiguate(sender, "short"), #matches))
end)

-- QR~qid~more~rows~guild~loc~valid: a category browse reply chunk (rows are id:qty:price:suffix;...).
ns.OnMessage("QR", function(a, _, c, d, e, f, sender)
    if a ~= activeQCid then return end
    local s = Ambiguate(sender, "short")
    ns.NoteGuild(sender, d)
    ns.NoteValid(sender, f)
    local loc = e or ""
    for chunk in (c or ""):gmatch("[^;]+") do
        local id, qty, price, suffix = strsplit(":", chunk)
        id = tonumber(id)
        if id then
            local sfx = tonumber(suffix) or 0
            ns.browseResults[s .. "#" .. id .. "#" .. sfx] =
                { seller = s, id = id, suffix = sfx, qty = tonumber(qty) or 0, price = tonumber(price) or 0, loc = loc }
            ns.ItemDB.Learn(id)
        end
    end
    if ns.RefreshBrowseSoon then ns.RefreshBrowseSoon() end
end)
