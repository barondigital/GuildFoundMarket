local ADDON, ns = ...

--========================================================================
-- Bag scan: price-check every sellable item you carry against the live market.
--
-- "Sellable" = not bound (soulbound or quest-bound) and not a quest-class item,
-- grouped per variant (itemID:suffixID, same key as offers). Bags always count;
-- bank containers are included while the bank window is open.
--
-- The market side deliberately rides the EXISTING protocol, because a per-item
-- search can't loop (channel broadcasts need a hardware event) and would be the
-- noisiest option anyway. Instead: ONE "who's selling" plus ONE "who's buying"
-- broadcast (both sent from the button click itself, so they're legal), then each
-- replying seller's catalog is fetched with the same L~/K~ whispers the Sellers tab
-- uses and each replying buyer's want list with the WL~/WK~ whispers the Buyers tab
-- uses - directed, timer-safe and throttled by the normal send queue. Catalog rows
-- are matched against the bag variants (the sweep is snapshotted into PriceDB, so
-- item tooltips profit too) and want rows the same way, feeding the per-item Buyers
-- column and its side window.
--
-- The Scan tab shows live progress and has a Stop button: stopping clears the fetch
-- queue, ignores whatever is still in flight, and keeps the prices found so far. The
-- scan itself keeps running while the tab (or the whole window) is hidden.
--========================================================================
ns.BagScan = ns.BagScan or {}

local CONCURRENT   = 6     -- catalog fetches in flight at once (keeps our own send queue shallow)
local FETCH_WINDOW = 6     -- seconds we wait for one seller's catalog before skipping them
local QUEST_CLASS  = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12

local BAG_IDS  = { 0, 1, 2, 3, 4 }
local BANK_IDS = { -1, 5, 6, 7, 8, 9, 10, 11 }

local state = nil    -- nil = idle; see Start() for the fields
local lidSeq = 0
local refreshWin, refreshBuyersWin     -- forward decls (window sections below)

local function vlinkStr(id, suffix) return ("item:%d:0:0:0:0:0:%d"):format(id, suffix or 0) end

-- Unbound copies of one variant currently in the BAGS (bank excluded: mail attachments
-- can only come from bags). Used to clamp the buyers window's Send button to reality.
local function unboundInBags(itemID, suffix)
    suffix = suffix or 0
    local n = 0
    for _, bag in ipairs(BAG_IDS) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and not info.isBound and (ns.Stock.LinkSuffix(info.hyperlink) or 0) == suffix then
                n = n + (info.stackCount or 1)
            end
        end
    end
    return n
end

-- Collect the sellable variants you carry: skip bound copies and quest-class items.
-- A variant can have both bound and unbound copies; only the unbound ones count.
local function collectSellables()
    local containers = {}
    for _, b in ipairs(BAG_IDS) do containers[#containers + 1] = b end
    local bankIncluded = ns.Stock and ns.Stock.IsBankOpen()
    if bankIncluded then for _, b in ipairs(BANK_IDS) do containers[#containers + 1] = b end end
    local items = {}
    for _, bag in ipairs(containers) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                local classID = select(6, GetItemInfoInstant(info.itemID))
                if classID ~= QUEST_CLASS then
                    local suffix = ns.Stock.LinkSuffix(info.hyperlink)
                    local key = ns.vkey(info.itemID, suffix)
                    local e = items[key]
                    if not e then e = { id = info.itemID, suffix = suffix, count = 0 }; items[key] = e end
                    e.count = e.count + (info.stackCount or 1)
                end
            end
        end
    end
    return items, bankIncluded
end

local function inflightCount()
    local n = 0
    for _ in pairs(state.inflight) do n = n + 1 end
    return n
end

-- Variants that got at least one market offer so far.
local function foundCount()
    local n = 0
    for _, list in pairs(state.offers) do if #list > 0 then n = n + 1 end end
    return n
end

-- Variants that got at least one interested buyer so far.
local function wantFoundCount()
    local n = 0
    for _, list in pairs(state.wants) do if #list > 0 then n = n + 1 end end
    return n
end

local function finish(stopped)
    if not state or state.phase == "done" then return end
    state.phase = "done"
    state.stopped = stopped or false
    if state.ticker then state.ticker:Cancel(); state.ticker = nil end
    wipe(state.queue); wipe(state.inflight)
    -- one aggregate snapshot across ALL sellers, so PriceDB gets a real low/high/count
    -- per variant (recording per seller would leave count-1 observations)
    if ns.PriceDB and #state.allRows > 0 then ns.PriceDB.Record(state.allRows) end
    ns.Log(("BAGSCAN %s: %d/%d sellers and %d/%d buyers answered, prices for %d and buyers for %d of %d sellable variants"):format(
        stopped and "stopped" or "done", state.sellerDone, state.sellerTotal, state.wantDone, state.wantTotal,
        foundCount(), wantFoundCount(), state.itemTotal))
    refreshWin()
end

-- Ask the next queued fetch jobs (seller catalogs and buyer want lists), up to the
-- concurrency cap. The lid prefix tells the chunk handlers which kind an answer is.
local function pump()
    while #state.queue > 0 and inflightCount() < CONCURRENT do
        local job = table.remove(state.queue, 1)
        lidSeq = lidSeq + 1
        local lid = ns.playerName .. (job.kind == "wants" and "#BW" or "#BS") .. lidSeq
        state.inflight[lid] = { who = job.who, kind = job.kind, deadline = GetTime() + FETCH_WINDOW }
        if ns.NetStats then ns.NetStats.ScanStarted(lid) end
        ns.EnqueueWhisper((job.kind == "wants" and "WL~" or "L~") .. lid, job.who)
    end
    if #state.queue == 0 and inflightCount() == 0 then finish(false) end
end

-- Watchdog: skip players whose answer never (fully) arrived, keep the pipeline full.
local function tick()
    if not state or state.phase ~= "catalogs" then return end
    local now = GetTime()
    for lid, f in pairs(state.inflight) do
        if now > f.deadline then
            state.inflight[lid] = nil
            state.knownLids[lid] = true   -- swallow chunks that still trickle in for it
            if f.kind == "wants" then state.wantDone = state.wantDone + 1
            else state.sellerDone = state.sellerDone + 1 end
            ns.Log(("BAGSCAN: no %s from %s (skipped)"):format(f.kind == "wants" and "want list" or "catalog", f.who))
        end
    end
    pump()
    refreshWin()
end

-- A K~lid~more~rows chunk. Returns true when the lid is ours (a bag-scan fetch), so the
-- Sellers-tab handler leaves it alone. Rows are id:qty:price:suffix, same as the catalog.
function ns.BagScan.HandleCatalogChunk(lid, more, rows)
    if not state then return false end
    local f = state.inflight[lid]
    if not f then return state.knownLids[lid] or false end   -- ours but already timed out: swallow it
    f.deadline = GetTime() + FETCH_WINDOW   -- chunks are arriving; extend the window
    for chunk in (rows or ""):gmatch("[^;]+") do
        local id, qty, price, suffix = strsplit(":", chunk)
        id = tonumber(id)
        if id then
            local sfx = tonumber(suffix) or 0
            state.allRows[#state.allRows + 1] = { id = id, suffix = sfx, price = tonumber(price) or 0 }
            local mine = state.offers[ns.vkey(id, sfx)]
            if mine then mine[#mine + 1] = { seller = f.who, qty = tonumber(qty) or 0, price = tonumber(price) or 0 } end
        end
    end
    if (tonumber(more) or 0) == 0 then
        state.inflight[lid] = nil
        state.knownLids[lid] = true
        state.sellerDone = state.sellerDone + 1
        pump()
    end
    refreshWin()
    return true
end

-- A WK~lid~more~rows chunk (a buyer's want list). Returns true when the lid is ours, so the
-- Buyers-tab handler leaves it alone. Rows are id:qty:price:suffix:cod, same as the want list.
function ns.BagScan.HandleWantChunk(lid, more, rows)
    if not state then return false end
    local f = state.inflight[lid]
    if not f then return state.knownLids[lid] or false end   -- ours but already timed out: swallow it
    f.deadline = GetTime() + FETCH_WINDOW
    for chunk in (rows or ""):gmatch("[^;]+") do
        local id, qty, price, suffix, cod = strsplit(":", chunk)
        id = tonumber(id)
        if id then
            local mine = state.wants[ns.vkey(id, tonumber(suffix) or 0)]
            if mine then mine[#mine + 1] = { buyer = f.who, qty = tonumber(qty) or 0, price = tonumber(price) or 0, cod = (tonumber(cod) or 0) == 1 } end
        end
    end
    if (tonumber(more) or 0) == 0 then
        state.inflight[lid] = nil
        state.knownLids[lid] = true
        state.wantDone = state.wantDone + 1
        pump()
    end
    refreshWin()
    if refreshBuyersWin then refreshBuyersWin() end
    return true
end

-- Phase 2: the seller and buyer scans settled; queue every answering seller for a catalog
-- fetch and every answering buyer for a want-list fetch (catalogs first: prices are the
-- scan's primary output).
local function startCatalogPhase(gen)
    if not state or state.gen ~= gen or state.phase ~= "sellers" then return end
    state.phase = "catalogs"
    for seller in pairs(ns.sellers.results) do
        if seller ~= ns.playerName then state.queue[#state.queue + 1] = { kind = "catalog", who = seller } end
    end
    state.sellerTotal = #state.queue
    for buyer in pairs(ns.buyers.results) do
        if buyer ~= ns.playerName then state.queue[#state.queue + 1] = { kind = "wants", who = buyer } end
    end
    state.wantTotal = #state.queue - state.sellerTotal
    table.sort(state.queue, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end   -- "catalog" sorts before "wants"
        return a.who < b.who
    end)
    ns.Log(("BAGSCAN: %d seller(s) and %d buyer(s) answered; fetching catalogs and want lists (%d at a time)"):format(
        state.sellerTotal, state.wantTotal, CONCURRENT))
    if #state.queue == 0 then finish(false); return end
    state.ticker = C_Timer.NewTicker(0.5, tick)
    pump()
    refreshWin()
end

-- Kick off a scan. MUST be called from a hardware event (the button click): the seller
-- scan underneath broadcasts on the chat channel, which Classic only allows there.
function ns.BagScan.Start()
    if not ns.channelName then ns.Feedback("Not in a confederation, can't price-check the market.", true); return end
    if state and state.phase ~= "done" then return end   -- already running
    local items, bankIncluded = collectSellables()
    local order, total = {}, 0
    for key in pairs(items) do order[#order + 1] = key; total = total + 1 end
    if total == 0 then
        ns.Feedback("No sellable items found: everything in your bags is soulbound or quest-related.", true)
        return
    end
    state = {
        gen = GetTime(), phase = "sellers",
        items = items, order = order, itemTotal = total, bankIncluded = bankIncluded,
        offers = {},                       -- [vkey] = { {seller, qty, price}, ... } market offers per bag variant
        wants = {},                        -- [vkey] = { {buyer, qty, price, cod}, ... } interested buyers per bag variant
        allRows = {},                      -- every catalog row seen (one PriceDB snapshot at the end)
        queue = {}, inflight = {}, knownLids = {},
        sellerTotal = 0, sellerDone = 0,
        wantTotal = 0, wantDone = 0,
        ticker = nil, stopped = false,
    }
    for _, key in ipairs(order) do state.offers[key] = {}; state.wants[key] = {} end
    if ns.BagScan.ClearSelection then ns.BagScan.ClearSelection() end   -- ticks belong to the previous scan's prices
    ns.Log(("BAGSCAN: %d sellable variant(s) in bags%s; scanning for online sellers and buyers"):format(total, bankIncluded and " + bank" or ""))
    ns.ScanSellers("")   -- one broadcast; replies land in ns.sellers.results (the shared index)
    ns.ScanBuyers("")    -- second broadcast, same click/hardware event; replies land in ns.buyers.results
    if ns.selfTest and not ns.IsPaused() then
        -- dev self-test: you can't whisper yourself a WL, so match your own WTB list locally,
        -- the same way Search and the Buyers tab inject the own player under self-test
        for _, it in ipairs(ns.WantList()) do
            local mine = state.wants[ns.vkey(it.id, it.suffix)]
            if mine then mine[#mine + 1] = { buyer = ns.playerName, qty = it.qty, price = it.price, cod = it.cod, self = true } end
        end
    end
    local gen = state.gen
    C_Timer.After((ns.QUERY_SETTLE or 5) + 0.5, function() startCatalogPhase(gen) end)
    refreshWin()
end

function ns.BagScan.Stop()
    if state and state.phase ~= "done" then finish(true) end
end

--========================================================================
-- The Scan tab panel. Lives in the main window's content area; CreateUI builds it and
-- SelectTab shows it, exactly like the Help and Options panels. A Scan bags button
-- starts the sweep (its click is the hardware event the channel broadcast needs), a
-- Stop button halts it, and one row per sellable variant shows your stock, your
-- current listing and the market price range found so far.
--========================================================================
local win
local ROWS_SHOWN, ROW_H = 15, 20
local winRows = {}
local view = {}          -- sorted vkeys for the scroll list
local refreshQueued = false
local selected = {}      -- [vkey] = true: rows ticked for "List selected"; cleared on a new scan

--========================================================================
-- Listing straight from the scan: tick rows, press List selected, and each ticked item is
-- listed (or its existing listing re-priced) at the price the configured mode derives from
-- the market offers the scan found. Only priced offers count; bid-only rows can't be ticked.
--========================================================================
local MODES = {
    { value = "undercut", label = "Undercut", tip = "The lowest market price found, minus 1 copper." },
    { value = "average",  label = "Average",  tip = "A robust market average: prices far off the middle are dropped first, so one extreme listing can't drag the result." },
    { value = "match",    label = "Match",    tip = "Exactly the lowest market price found." },
}

local function modeLabel()
    local v = ns.GetSetting and ns.GetSetting("scanPriceMode") or "undercut"
    for _, m in ipairs(MODES) do if m.value == v then return m.label end end
    return MODES[1].label
end

-- Robust average: anchor on the median and drop prices more than a factor 2 away from it
-- (below half, above double the median), then average what's left. A single too-cheap or
-- too-expensive listing lands outside that band and is ignored, so it can't drag the
-- result. The band always keeps at least the median itself, so there is always a price.
local function robustAverage(sorted)
    local n = #sorted
    local median = (n % 2 == 1) and sorted[(n + 1) / 2] or (sorted[n / 2] + sorted[n / 2 + 1]) / 2
    local sum, kept = 0, 0
    for _, p in ipairs(sorted) do
        if p >= median / 2 and p <= median * 2 then sum = sum + p; kept = kept + 1 end
    end
    return math.max(1, math.floor(sum / kept + 0.5))
end

-- The unit price the configured mode gives for one scanned variant, or nil while the scan
-- hasn't seen a priced offer for it (bids don't carry a price to derive anything from).
local function modePrice(key)
    local list = state and state.offers[key]
    if not list then return nil end
    local prices = {}
    for _, o in ipairs(list) do
        if (o.price or 0) > 0 then prices[#prices + 1] = o.price end
    end
    if #prices == 0 then return nil end
    table.sort(prices)
    local mode = ns.GetSetting and ns.GetSetting("scanPriceMode") or "undercut"
    if mode == "match" then return prices[1] end
    if mode == "average" then return robustAverage(prices) end
    return math.max(1, prices[1] - 1)   -- undercut; floor at 1c, price 0 would mean "bids"
end

local function selectedCount()
    local n = 0
    for _ in pairs(selected) do n = n + 1 end
    return n
end

local function updateListBtn()
    if not win then return end
    local n = selectedCount()
    win.listBtn:SetText(n > 0 and ("List selected (%d)"):format(n) or "List selected")
    win.listBtn:SetEnabled(n > 0)
    -- the select-all box mirrors the rows: checked only when every listable row is ticked
    if win.selAll then
        local elig, sel = 0, 0
        if state then
            for key in pairs(state.offers) do
                if modePrice(key) then
                    elig = elig + 1
                    if selected[key] then sel = sel + 1 end
                end
            end
        end
        win.selAll:SetEnabled(elig > 0)
        win.selAll:SetChecked(elig > 0 and sel == elig)
        win.selAll:SetAlpha(elig > 0 and 1 or 0.35)
    end
end

function ns.BagScan.ClearSelection()
    wipe(selected)
    updateListBtn()
end

-- List every ticked row: a variant already in My Items keeps its qty (and Bag sync state)
-- and only gets the new price; anything else becomes a new listing for the full scanned
-- count. AddOffer re-runs its own stock/soulbound guards, so a stale count just fails soft.
local function listSelected()
    if not state then return end
    local added, updated, failed = 0, 0, 0
    for key in pairs(selected) do
        local it = state.items[key]
        local price = it and modePrice(key)
        if not price then
            failed = failed + 1
        elseif ns.OfferInfo(it.id, it.suffix) ~= nil then
            if ns.EditOffer(key, nil, price) then updated = updated + 1 else failed = failed + 1 end
        else
            if ns.AddOffer(it.id, it.suffix, it.count, price) then added = added + 1 else failed = failed + 1 end
        end
    end
    wipe(selected)
    local parts = {}
    if added > 0 then parts[#parts + 1] = ("%d new listing(s)"):format(added) end
    if updated > 0 then parts[#parts + 1] = ("%d price(s) updated"):format(updated) end
    if failed > 0 then parts[#parts + 1] = ("%d failed"):format(failed) end
    ns.Log(("BAGSCAN list (%s): %d added, %d updated, %d failed"):format(modeLabel(), added, updated, failed))
    ns.Feedback("Scan: " .. (#parts > 0 and table.concat(parts, ", ") or "nothing selected") .. ".", failed > 0)
    updateListBtn()
    refreshWin()
end

local function marketSummary(list)
    local low, high, n, bids = nil, nil, 0, 0
    for _, o in ipairs(list) do
        if (o.price or 0) > 0 then
            n = n + 1
            if not low or o.price < low then low = o.price end
            if not high or o.price > high then high = o.price end
        else
            bids = bids + 1
        end
    end
    return low, high, n, bids
end

local function buildView()
    wipe(view)
    for _, key in ipairs(state.order) do view[#view + 1] = key end
    table.sort(view, function(a, b)
        local fa, fb = #state.offers[a] > 0, #state.offers[b] > 0
        if fa ~= fb then return fa end   -- priced items bubble up as results come in
        local na = GetItemInfo(vlinkStr(state.items[a].id, state.items[a].suffix)) or ""
        local nb = GetItemInfo(vlinkStr(state.items[b].id, state.items[b].suffix)) or ""
        return na < nb
    end)
end

local function statusText()
    if not state then
        return "Find every sellable item you carry (not soulbound, no quest items; your bank too while its window is open) and see what the confederation currently asks for each. Press Scan bags to start.", 0.7, 0.7, 0.7
    end
    if state.phase == "sellers" then
        return "Step 1/2: asking the confederation who is selling and who is buying ...", 1, 0.82, 0
    elseif state.phase == "catalogs" then
        return ("Step 2/2: catalogs %d/%d · want lists %d/%d  ·  prices for %d and buyers for %d of %d items so far"):format(
            state.sellerDone, state.sellerTotal, state.wantDone, state.wantTotal, foundCount(), wantFoundCount(), state.itemTotal), 1, 0.82, 0
    end
    local verb = state.stopped and "Stopped" or "Done"
    return ("%s: %d sellers + %d buyers checked  ·  prices for %d and buyers for %d of your %d sellable items."):format(
        verb, state.sellerDone, state.wantDone, foundCount(), wantFoundCount(), state.itemTotal), 0.4, 1, 0.4
end

local function renderWinRows()
    local offset = FauxScrollFrame_GetOffset(win.scroll)
    FauxScrollFrame_Update(win.scroll, #view, ROWS_SHOWN, ROW_H)
    for i = 1, ROWS_SHOWN do
        local r, key = winRows[i], view[offset + i]
        if not key then r:Hide() else
            local it = state.items[key]
            local link = vlinkStr(it.id, it.suffix)
            local name, fullLink = GetItemInfo(link)
            r.icon:SetTexture(GetItemIcon(it.id))
            r.name.fs:SetText(fullLink or name or ("item:" .. it.id))
            r.name.itemLink = link
            r.name.key = key
            r.have:SetText(it.count)
            local lqty, _, lprice = ns.OfferInfo and ns.OfferInfo(it.id, it.suffix)
            if lqty then
                r.listed:SetText(lprice and lprice > 0 and ns.PriceToStr(lprice) or (lqty > 0 and "bids" or "parked"))
                r.listed:SetTextColor(0.5, 0.9, 0.5)
            else
                r.listed:SetText("-"); r.listed:SetTextColor(0.45, 0.45, 0.45)
            end
            local low, high, n, bids = marketSummary(state.offers[key])
            if n > 0 then
                local range = (low == high) and ns.PriceToStr(low) or (ns.PriceToStr(low) .. " - " .. ns.PriceToStr(high))
                r.market.fs:SetText(("%s  (%d)"):format(range, n + bids))
                r.market.fs:SetTextColor(1, 1, 1)
            elseif bids > 0 then
                r.market.fs:SetText(("bids only  (%d)"):format(bids)); r.market.fs:SetTextColor(0.8, 0.8, 0.8)
            else
                r.market.fs:SetText(state.phase == "done" and "none found" or "...")
                r.market.fs:SetTextColor(0.45, 0.45, 0.45)
            end
            r.market.key = key
            r.sel.key = key
            r.sel:SetEnabled(n > 0)
            r.sel:SetChecked(selected[key] and true or false)
            r.sel:SetAlpha(n > 0 and 1 or 0.35)
            local wl = state.wants and state.wants[key]
            r.buyers.key = key
            r.buyers:SetEnabled(wl ~= nil and #wl > 0)
            r.buyers:SetAlpha((wl ~= nil and #wl > 0) and 1 or 0.35)
            r:Show()
        end
    end
end

refreshWin = function()
    if not win or not win:IsShown() then return end
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.2, function()
        refreshQueued = false
        if not win or not win:IsShown() then return end
        local txt, cr, cg, cb = statusText()
        win.status:SetText(txt); win.status:SetTextColor(cr, cg, cb)
        win.stopBtn:SetShown(state ~= nil and state.phase ~= "done")
        if state then buildView() else wipe(view) end
        updateListBtn()
        renderWinRows()
    end)
end

function ns.BagScan.CreatePanel(main)
    if win then return win end

    win = CreateFrame("Frame", "GuildFoundMarketBagScan", main)
    win:SetPoint("TOPLEFT", 16, -64); win:SetPoint("BOTTOMRIGHT", -16, 14)

    local scanBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    scanBtn:SetSize(100, 24); scanBtn:SetPoint("TOPLEFT", 4, -2); scanBtn:SetText("Scan bags")
    scanBtn:SetScript("OnClick", function() ns.BagScan.Start() end)
    scanBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Scan bags")
        GameTooltip:AddLine("Find every sellable item you carry (not soulbound, not quest items; your bank too while it's open) and check what the confederation currently asks for each.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Takes a moment: it asks every online seller for their price list. You can stop it at any time.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    scanBtn:SetScript("OnLeave", GameTooltip_Hide)

    win.stopBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.stopBtn:SetSize(60, 24); win.stopBtn:SetPoint("LEFT", scanBtn, "RIGHT", 8, 0); win.stopBtn:SetText("Stop")
    win.stopBtn:Hide()
    win.stopBtn:SetScript("OnClick", function() ns.BagScan.Stop() end)
    win.stopBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Stop the scan. Prices found so far are kept.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    win.stopBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- List selected + the price-mode picker, top right. The radios mirror the
    -- scanPriceMode setting, so the Options panel and this row always agree.
    win.listBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.listBtn:SetSize(130, 24); win.listBtn:SetPoint("TOPRIGHT", -4, -2); win.listBtn:SetText("List selected")
    win.listBtn:SetEnabled(false)
    win.listBtn:SetScript("OnClick", listSelected)
    win.listBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("List selected")
        GameTooltip:AddLine(("List every ticked item at the %s price derived from the scan. "
            .. "An item you already list keeps its quantity and Bag sync switch; only its price is updated. "
            .. "New listings go up for the full scanned count."):format(modeLabel():lower()), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    win.listBtn:SetScript("OnLeave", GameTooltip_Hide)

    local modeRadios = {}
    local prev
    for i = #MODES, 1, -1 do
        local m = MODES[i]
        local rl = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if prev then rl:SetPoint("RIGHT", prev, "LEFT", -12, 0)
        else rl:SetPoint("RIGHT", win.listBtn, "LEFT", -10, 0) end
        rl:SetText(m.label)
        local rb = CreateFrame("CheckButton", nil, win, "UIRadioButtonTemplate")
        rb:SetPoint("RIGHT", rl, "LEFT", -3, 0)
        rb.value = m.value
        rb:SetHitRectInsets(0, -(rl:GetStringWidth() + 6), 0, 0)
        rb:SetScript("OnClick", function(self) ns.SetSetting("scanPriceMode", self.value) end)
        rb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(m.label)
            GameTooltip:AddLine(m.tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        rb:SetScript("OnLeave", GameTooltip_Hide)
        modeRadios[#modeRadios + 1] = rb
        prev = rb
    end
    local function syncModeRadios()
        local v = ns.GetSetting and ns.GetSetting("scanPriceMode") or "undercut"
        for _, rb in ipairs(modeRadios) do rb:SetChecked(rb.value == v) end
    end
    syncModeRadios()
    if ns.On then ns.On("setting:scanPriceMode", syncModeRadios) end

    win.status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.status:SetPoint("TOPLEFT", 8, -34); win.status:SetPoint("TOPRIGHT", -8, -34)
    win.status:SetJustifyH("LEFT")

    -- column headers (x = row x + the scroll frame's own offset)
    local hy = -62
    local function head(text, x, w)
        local h = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", x, hy); h:SetWidth(w); h:SetJustifyH("LEFT"); h:SetText(text)
    end
    head("Item", 34, 250); head("You have", 292, 60); head("Your listing", 362, 100); head("Market low - high (sellers)", 472, 160); head("List", 632, 30); head("Buyers", 678, 44)

    -- select/deselect all, next to the List column header: ticks every row that has a
    -- market price to derive a listing price from (grey rows stay untouched)
    win.selAll = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    win.selAll:SetSize(22, 22); win.selAll:SetPoint("TOPLEFT", 652, hy + 6)
    win.selAll:SetEnabled(false); win.selAll:SetAlpha(0.35)
    win.selAll:SetMotionScriptsWhileDisabled(true)
    win.selAll:SetScript("OnClick", function(self)
        if self:GetChecked() and state then
            for key in pairs(state.offers) do
                if modePrice(key) then selected[key] = true end
            end
        else
            wipe(selected)
        end
        updateListBtn()
        renderWinRows()
    end)
    win.selAll:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Select all")
        GameTooltip:AddLine("Tick or untick every item that has a market price to list at. Items without one can't be selected.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    win.selAll:SetScript("OnLeave", GameTooltip_Hide)

    win.scroll = CreateFrame("ScrollFrame", "GuildFoundMarketBagScanScroll", win, "FauxScrollFrameTemplate")
    win.scroll:SetPoint("TOPLEFT", 8, -78); win.scroll:SetSize(690, ROWS_SHOWN * ROW_H)
    win.scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, ROW_H, renderWinRows) end)
    win.scroll:EnableMouseWheel(true)
    win.scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #view - ROWS_SHOWN)
        local off = math.min(maxOff, math.max(0, FauxScrollFrame_GetOffset(self) - delta))
        FauxScrollFrame_SetOffset(self, off); self:SetVerticalScroll(off * ROW_H); renderWinRows()
    end)

    for i = 1, ROWS_SHOWN do
        local r = CreateFrame("Frame", nil, win); r:SetSize(690, ROW_H)
        if i == 1 then r:SetPoint("TOPLEFT", win.scroll, "TOPLEFT", 4, 0)
        else r:SetPoint("TOPLEFT", winRows[i - 1], "BOTTOMLEFT", 0, 0) end
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 0, 0)
        r.name = CreateFrame("Button", nil, r); r.name:SetPoint("LEFT", 22, 0); r.name:SetSize(256, ROW_H)
        r.name.fs = r.name:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.name.fs:SetAllPoints(); r.name.fs:SetJustifyH("LEFT")
        r.name:SetScript("OnEnter", function(self)
            if not self.itemLink then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end)
        r.name:SetScript("OnLeave", GameTooltip_Hide)
        r.have = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.have:SetPoint("LEFT", 284, 0); r.have:SetWidth(60); r.have:SetJustifyH("LEFT")
        r.listed = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.listed:SetPoint("LEFT", 354, 0); r.listed:SetWidth(100); r.listed:SetJustifyH("LEFT")
        r.market = CreateFrame("Button", nil, r); r.market:SetPoint("LEFT", 464, 0); r.market:SetSize(150, ROW_H)
        r.market.fs = r.market:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.market.fs:SetAllPoints(); r.market.fs:SetJustifyH("LEFT")
        r.market:SetScript("OnEnter", function(self)
            local list = self.key and state and state.offers[self.key]
            if not list or #list == 0 then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Market offers", 1, 0.82, 0)
            for j = 1, math.min(#list, 12) do
                local o = list[j]
                GameTooltip:AddDoubleLine(o.seller .. "  x" .. o.qty, (o.price or 0) > 0 and ns.PriceToStr(o.price) or "bids", 1, 1, 1, 1, 1, 1)
            end
            if #list > 12 then GameTooltip:AddLine(("... and %d more"):format(#list - 12), 0.6, 0.6, 0.6) end
            GameTooltip:Show()
        end)
        r.market:SetScript("OnLeave", GameTooltip_Hide)
        -- tick to include this row in "List selected"; disabled until a priced offer exists
        -- (bid-only or unpriced rows give the modes nothing to derive a price from)
        r.sel = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
        r.sel:SetSize(22, 22); r.sel:SetPoint("LEFT", 624, 0)
        r.sel:SetMotionScriptsWhileDisabled(true)
        r.sel:SetScript("OnClick", function(self)
            if self.key then selected[self.key] = self:GetChecked() and true or nil end
            updateListBtn()
        end)
        r.sel:SetScript("OnEnter", function(self)
            if not self.key then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local price = modePrice(self.key)
            if price then
                local it = state and state.items[self.key]
                local existing = it and ns.OfferInfo(it.id, it.suffix)
                GameTooltip:SetText(existing ~= nil and "Update your listing" or "List this item")
                GameTooltip:AddLine(("%s price: %s"):format(modeLabel(), ns.PriceToStr(price)), 1, 1, 1)
                GameTooltip:AddLine("Tick, then press List selected.", 0.7, 0.7, 0.7)
            else
                GameTooltip:SetText("No priced market offer found (yet), so there is nothing to base a price on.", 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        r.sel:SetScript("OnLeave", GameTooltip_Hide)
        -- Buyers column: a coin button (same icon as My Items' "Find buyers") that opens the
        -- side window with everyone the scan found wanting this item; dim while nobody does
        r.buyers = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.buyers:SetSize(20, 20); r.buyers:SetPoint("LEFT", 680, 0)
        r.buyers:SetMotionScriptsWhileDisabled(true)
        local coin = r.buyers:CreateTexture(nil, "ARTWORK"); coin:SetSize(14, 14); coin:SetPoint("CENTER")
        coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
        r.buyers:SetScript("OnClick", function(self)
            if self.key then ns.BagScan.OpenBuyersFor(self.key) end
        end)
        r.buyers:SetScript("OnEnter", function(self)
            if not self.key then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local list = state and state.wants[self.key]
            if list and #list > 0 then
                GameTooltip:SetText(("%d buyer(s) want this item"):format(#list))
                GameTooltip:AddLine("Click for who they are and what they pay.", 1, 1, 1, true)
            else
                GameTooltip:SetText(state and state.phase ~= "done" and "No buyers found yet ..." or "No buyers found for this item.", 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        r.buyers:SetScript("OnLeave", GameTooltip_Hide)
        local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06)
        r:Hide(); winRows[i] = r
    end

    win:SetScript("OnShow", function() refreshWin() end)
    -- leaving the Scan tab (or closing the main window) takes the buyers side window with it
    win:SetScript("OnHide", function() ns.BagScan.CloseBuyers() end)
    win:Hide()
    return win
end

--========================================================================
-- Buyers side window: who wants one item, and at what price. Two ways in: a scanned row's
-- Buyers coin button (scan mode: reads the sweep's want matches), or My Items' Find buyers
-- coin (query mode: fires the same "who wants this item" broadcast the Buyers tab uses and
-- shows replies as they arrive). It docks where the Debug sidebar does and pushes any open
-- sidebar (Debug / Network) one spot further right, so the order reads main | buyers | sidebar.
--========================================================================
local buyersWin
local buyersKey = nil            -- scan mode: vkey into state.wants
local buyersItem = nil           -- query mode: { id, suffix }, rows read from ns.buyers.find
local buyersTicker = nil         -- query mode: short refresh poll while replies trickle in
local BROWS, BROW_H = 17, 20
local buyersRows = {}

-- Re-anchor the Debug/Network sidebars: beside the buyers window while it is shown, else
-- back beside the main window. Their toggles call this too, so a sidebar opened later
-- still lands right of an already-open buyers window.
function ns.LayoutSidePanels()
    local main = _G.GuildFoundMarketFrame
    if not main then return end
    local anchor = (buyersWin and buyersWin:IsShown()) and buyersWin or main
    for _, name in ipairs({ "GuildFoundMarketDebug", "GuildFoundMarketNetStats" }) do
        local p = _G[name]
        if p then
            p:ClearAllPoints()
            p:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
            p:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 6, 0)
        end
    end
end

-- What a buyer pays, same colours as the Buyers tab: bid-only wants say "Offers",
-- a priced want is their maximum, orange COD = they accept Cash On Delivery.
local function wantPriceText(o)
    if (o.price or 0) <= 0 then return "|cffffd100Offers|r" end
    return ns.PriceToStr(o.price) .. (o.cod and " |cffff8800COD|r" or " |cff888888max|r")
end

-- The item the window is about: the scanned variant (scan mode) or the queried one.
local function buyersItemInfo()
    if buyersKey then return state and state.items[buyersKey] end
    return buyersItem
end

-- The window's rows, best-paying buyer first (bid-only wants sink to the bottom). Every row
-- carries its own suffix: a query answers with every variant of the item a buyer wants.
local function buyersList()
    local list = {}
    if buyersKey then
        local src = state and state.wants[buyersKey]
        local it = state and state.items[buyersKey]
        if src then for _, o in ipairs(src) do
            list[#list + 1] = { buyer = o.buyer, qty = o.qty, price = o.price, cod = o.cod, self = o.self, suffix = it and it.suffix or 0 }
        end end
    elseif buyersItem and ns.buyers.find.itemID == buyersItem.id then
        for _, o in pairs(ns.buyers.find.results) do
            list[#list + 1] = { buyer = o.buyer, qty = o.qty, price = o.price, cod = o.cod, self = o.self, suffix = o.suffix or 0 }
        end
    end
    table.sort(list, function(a, b)
        if (a.price > 0) ~= (b.price > 0) then return a.price > 0 end
        if a.price ~= b.price then return a.price > b.price end
        return a.buyer < b.buyer
    end)
    return list
end

local function renderBuyersRows()
    local list = buyersList()
    local offset = FauxScrollFrame_GetOffset(buyersWin.scroll)
    FauxScrollFrame_Update(buyersWin.scroll, #list, BROWS, BROW_H)
    for i = 1, BROWS do
        local r, o = buyersRows[i], list[offset + i]
        if not o then r:Hide() else
            r.name.fs:SetText(o.self and (o.buyer .. " (you)") or o.buyer)
            r.name.fs:SetTextColor(o.self and 1 or 0.4, o.self and 0.82 or 1, o.self and 0 or 0.4)
            r.name.buyer, r.name.isSelf = o.buyer, o.self
            r.qty:SetText(o.qty or 0)
            r.price:SetText(wantPriceText(o))
            r.send.want = o
            local sendable = (o.price or 0) > 0   -- your own (self-test) row can mail too: full flow rehearsal
            r.send:SetEnabled(sendable)
            r.send:SetAlpha(sendable and 1 or 0.4)
            r:Show()
        end
    end
end

refreshBuyersWin = function()
    if not (buyersWin and buyersWin:IsShown()) then return end
    local it = buyersItemInfo()
    if not it then buyersWin:Hide(); return end
    buyersWin.icon:SetTexture(GetItemIcon(it.id))
    buyersWin.title:SetText(GetItemInfo(vlinkStr(it.id, it.suffix)) or ("item:" .. it.id))
    buyersWin.titleBtn.itemLink = vlinkStr(it.id, it.suffix)
    local busy = (buyersKey and state and state.phase ~= "done")
        or (buyersItem ~= nil and ns.buyers.find.active) or false
    local n = #buyersList()
    if n > 0 then
        buyersWin.status:SetText(("%d buyer(s) want this item%s"):format(n, busy and " · still asking ..." or ""))
        buyersWin.status:SetTextColor(0.4, 1, 0.4)
    else
        buyersWin.status:SetText(busy and "Asking the confederation ..." or "No buyers found for this item.")
        buyersWin.status:SetTextColor(0.7, 0.7, 0.7)
    end
    renderBuyersRows()
end

local function createBuyersWin()
    if buyersWin then return buyersWin end
    local main = _G.GuildFoundMarketFrame
    buyersWin = CreateFrame("Frame", "GuildFoundMarketScanBuyers", main, "BackdropTemplate")
    buyersWin:SetWidth(380)
    buyersWin:SetPoint("TOPLEFT", main, "TOPRIGHT", 6, 0)
    buyersWin:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", 6, 0)
    buyersWin:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    buyersWin:EnableMouse(true)

    local header = buyersWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOP", 0, -16); header:SetText("GFM |cff00ff96Buyers|r")

    local close = CreateFrame("Button", nil, buyersWin, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() buyersWin:Hide() end)

    -- the scanned item this window is about; hovering shows the exact (variant) tooltip
    buyersWin.icon = buyersWin:CreateTexture(nil, "ARTWORK")
    buyersWin.icon:SetSize(16, 16); buyersWin.icon:SetPoint("TOPLEFT", 16, -38)
    buyersWin.title = buyersWin:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    buyersWin.title:SetPoint("LEFT", buyersWin.icon, "RIGHT", 6, 0)
    buyersWin.title:SetWidth(310); buyersWin.title:SetJustifyH("LEFT"); buyersWin.title:SetWordWrap(false)
    buyersWin.titleBtn = CreateFrame("Button", nil, buyersWin)
    buyersWin.titleBtn:SetPoint("TOPLEFT", 16, -36); buyersWin.titleBtn:SetSize(332, 20)
    buyersWin.titleBtn:SetScript("OnEnter", function(self)
        if not self.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.itemLink); GameTooltip:Show()
    end)
    buyersWin.titleBtn:SetScript("OnLeave", GameTooltip_Hide)

    buyersWin.status = buyersWin:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    buyersWin.status:SetPoint("TOPLEFT", 16, -60); buyersWin.status:SetPoint("TOPRIGHT", -16, -60)
    buyersWin.status:SetJustifyH("LEFT")

    local function head(text, x, w)
        local h = buyersWin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", x, -78); h:SetWidth(w); h:SetJustifyH("LEFT"); h:SetText(text)
    end
    head("Buyer", 18, 120); head("Wants", 152, 36); head("Pays up to", 190, 100); head("Send", 300, 40)

    buyersWin.scroll = CreateFrame("ScrollFrame", "GuildFoundMarketScanBuyersScroll", buyersWin, "FauxScrollFrameTemplate")
    buyersWin.scroll:SetPoint("TOPLEFT", 14, -94); buyersWin.scroll:SetSize(328, BROWS * BROW_H)
    buyersWin.scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, BROW_H, renderBuyersRows) end)
    buyersWin.scroll:EnableMouseWheel(true)
    buyersWin.scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #buyersList() - BROWS)
        local off = math.min(maxOff, math.max(0, FauxScrollFrame_GetOffset(self) - delta))
        FauxScrollFrame_SetOffset(self, off); self:SetVerticalScroll(off * BROW_H); renderBuyersRows()
    end)

    for i = 1, BROWS do
        local r = CreateFrame("Frame", nil, buyersWin); r:SetSize(328, BROW_H)
        if i == 1 then r:SetPoint("TOPLEFT", buyersWin.scroll, "TOPLEFT", 2, 0)
        else r:SetPoint("TOPLEFT", buyersRows[i - 1], "BOTTOMLEFT", 0, 0) end
        r.name = CreateFrame("Button", nil, r); r.name:SetPoint("LEFT", 0, 0); r.name:SetSize(130, BROW_H)
        r.name:RegisterForClicks("RightButtonUp")
        r.name.fs = r.name:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.name.fs:SetAllPoints(); r.name.fs:SetJustifyH("LEFT")
        r.name.fs:SetTextColor(0.4, 1, 0.4)          -- green: they answered the scan, so online
        r.name:SetScript("OnClick", function(self, button)
            if button == "RightButton" and self.buyer then
                ChatFrame_OpenChat("/w " .. self.buyer .. " ")
            end
        end)
        r.name:SetScript("OnEnter", function(self)
            if not self.buyer then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(ns.PlayerTitle and ns.PlayerTitle(self.buyer) or self.buyer, 1, 1, 1)
            if self.isSelf then GameTooltip:AddLine("Your own want (self-test)", 0.6, 0.6, 0.6) end
            GameTooltip:AddLine("Right-click to whisper", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        r.name:SetScript("OnLeave", GameTooltip_Hide)
        r.qty = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.qty:SetPoint("LEFT", 136, 0); r.qty:SetWidth(30); r.qty:SetJustifyH("LEFT")
        r.price = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.price:SetPoint("LEFT", 174, 0); r.price:SetWidth(104); r.price:SetJustifyH("LEFT")
        -- Send: pre-fill a COD mail to this buyer via the same send-assist the COD tab uses
        -- (mailbox must be open; it says so itself). Qty = what they want, clamped to the
        -- unbound copies your bags hold right now; COD money = their price for that amount.
        r.send = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.send:SetSize(40, 20); r.send:SetPoint("LEFT", 282, 0); r.send:SetText("Send")
        r.send:SetMotionScriptsWhileDisabled(true)
        r.send:SetScript("OnClick", function(self)
            local o = self.want
            local it = o and buyersItemInfo()
            if not it then return end
            local suffix = o.suffix or it.suffix or 0   -- the buyer's variant wins (query replies carry it)
            local have = unboundInBags(it.id, suffix)
            if have < 1 then ns.Feedback("Your bags hold no unbound copies of this item anymore.", true); return end
            ns.CODSendAssist({ buyer = o.buyer, itemID = it.id, suffix = suffix, qty = math.min(o.qty or 1, have), unit = o.price })
        end)
        r.send:SetScript("OnEnter", function(self)
            local o = self.want
            if not o then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if (o.price or 0) <= 0 then
                GameTooltip:SetText("They take offers only (no price), so there is no COD amount to collect. Whisper them instead.", 1, 1, 1, true)
            else
                GameTooltip:SetText("Prepare a COD mail to " .. o.buyer)
                GameTooltip:AddLine(("Fills the open mailbox's Send Mail: the %d they want (or as many as your bags hold), COD at their price. You still press the real Send button."):format(o.qty or 1), 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        r.send:SetScript("OnLeave", GameTooltip_Hide)
        local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06)
        r:Hide(); buyersRows[i] = r
    end

    buyersWin:SetScript("OnShow", function() ns.LayoutSidePanels() end)
    buyersWin:SetScript("OnHide", function()
        if buyersTicker then buyersTicker:Cancel(); buyersTicker = nil end
        ns.LayoutSidePanels()
    end)
    buyersWin:Hide()
    return buyersWin
end

-- Open (or retarget) the buyers window for one scanned variant. Row buttons only enable
-- when the scan found buyers, so an empty window never opens by itself.
function ns.BagScan.OpenBuyersFor(key)
    if not (state and state.wants and state.wants[key]) then return end
    createBuyersWin()
    buyersKey, buyersItem = key, nil
    buyersWin:Show()
    refreshBuyersWin()
end

-- Find buyers for one item from anywhere (My Items' Find buyers coin): fire the same
-- "who wants this item" broadcast the Buyers tab uses and show the replies here as they
-- arrive. MUST be called from a hardware event (the button click) for the broadcast.
function ns.BagScan.FindBuyers(itemID, suffix)
    if not itemID then return end
    if not ns.channelName then ns.Feedback("Not in a confederation, can't find buyers.", true); return end
    createBuyersWin()
    buyersKey, buyersItem = nil, { id = itemID, suffix = suffix or 0 }
    ns.FindBuyersForItem(itemID)
    buyersWin:Show()
    refreshBuyersWin()
    -- WR replies land in ns.buyers.find without telling this window, so poll briefly;
    -- the ticker stops itself once the query settles or the window moves on
    if buyersTicker then buyersTicker:Cancel() end
    local t
    t = C_Timer.NewTicker(0.3, function()
        refreshBuyersWin()
        if not ns.buyers.find.active or not (buyersWin:IsShown() and buyersItem) then
            t:Cancel()
            if buyersTicker == t then buyersTicker = nil end
        end
    end)
    buyersTicker = t
end

-- Leaving the Scan tab only closes the window when it shows scan data; a query opened
-- from My Items has its own home view (see CloseFindBuyers).
function ns.BagScan.CloseBuyers()
    if buyersWin and buyersKey then buyersWin:Hide() end
end

-- The query window's home is My Items' WTS view: navigating away from it (another
-- sub-tab or another main tab) closes the window, mirroring the Scan tab behaviour.
function ns.BagScan.CloseFindBuyers()
    if buyersWin and buyersItem then buyersWin:Hide() end
end
