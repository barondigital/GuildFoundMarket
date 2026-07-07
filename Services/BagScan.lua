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
-- noisiest option anyway. Instead: ONE "who's selling" broadcast (sent from the
-- button click itself, so it's legal), then each replying seller's catalog is
-- fetched with the same L~/K~ whispers the Sellers tab uses - directed, timer-safe
-- and throttled by the normal send queue. Every seller answers once, exactly as if
-- a buyer had opened their shop. Catalog rows are matched against the bag variants
-- and the whole sweep is snapshotted into PriceDB, so item tooltips profit too.
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
local refreshWin     -- forward decl (window section below)

local function vlinkStr(id, suffix) return ("item:%d:0:0:0:0:0:%d"):format(id, suffix or 0) end

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

local function finish(stopped)
    if not state or state.phase == "done" then return end
    state.phase = "done"
    state.stopped = stopped or false
    if state.ticker then state.ticker:Cancel(); state.ticker = nil end
    wipe(state.queue); wipe(state.inflight)
    -- one aggregate snapshot across ALL sellers, so PriceDB gets a real low/high/count
    -- per variant (recording per seller would leave count-1 observations)
    if ns.PriceDB and #state.allRows > 0 then ns.PriceDB.Record(state.allRows) end
    ns.Log(("BAGSCAN %s: %d/%d sellers answered, prices for %d of %d sellable variants"):format(
        stopped and "stopped" or "done", state.sellerDone, state.sellerTotal, foundCount(), state.itemTotal))
    refreshWin()
end

-- Ask the next queued sellers for their catalog, up to the concurrency cap.
local function pump()
    while #state.queue > 0 and inflightCount() < CONCURRENT do
        local seller = table.remove(state.queue, 1)
        lidSeq = lidSeq + 1
        local lid = ns.playerName .. "#BS" .. lidSeq
        state.inflight[lid] = { seller = seller, deadline = GetTime() + FETCH_WINDOW }
        if ns.NetStats then ns.NetStats.ScanStarted(lid) end
        ns.EnqueueWhisper("L~" .. lid, seller)
    end
    if #state.queue == 0 and inflightCount() == 0 then finish(false) end
end

-- Watchdog: skip sellers whose catalog never (fully) arrived, keep the pipeline full.
local function tick()
    if not state or state.phase ~= "catalogs" then return end
    local now = GetTime()
    for lid, f in pairs(state.inflight) do
        if now > f.deadline then
            state.inflight[lid] = nil
            state.knownLids[lid] = true   -- swallow chunks that still trickle in for it
            state.sellerDone = state.sellerDone + 1
            ns.Log("BAGSCAN: no catalog from " .. f.seller .. " (skipped)")
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
            if mine then mine[#mine + 1] = { seller = f.seller, qty = tonumber(qty) or 0, price = tonumber(price) or 0 } end
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

-- Phase 2: the seller scan settled; queue every answering seller for a catalog fetch.
local function startCatalogPhase(gen)
    if not state or state.gen ~= gen or state.phase ~= "sellers" then return end
    state.phase = "catalogs"
    for seller in pairs(ns.sellers.results) do
        if seller ~= ns.playerName then state.queue[#state.queue + 1] = seller end
    end
    table.sort(state.queue)
    state.sellerTotal = #state.queue
    ns.Log(("BAGSCAN: %d seller(s) answered; fetching catalogs (%d at a time)"):format(state.sellerTotal, CONCURRENT))
    if state.sellerTotal == 0 then finish(false); return end
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
        allRows = {},                      -- every catalog row seen (one PriceDB snapshot at the end)
        queue = {}, inflight = {}, knownLids = {},
        sellerTotal = 0, sellerDone = 0,
        ticker = nil, stopped = false,
    }
    for _, key in ipairs(order) do state.offers[key] = {} end
    if ns.BagScan.ClearSelection then ns.BagScan.ClearSelection() end   -- ticks belong to the previous scan's prices
    ns.Log(("BAGSCAN: %d sellable variant(s) in bags%s; scanning for online sellers"):format(total, bankIncluded and " + bank" or ""))
    ns.ScanSellers("")   -- one broadcast; replies land in ns.sellers.results (the shared index)
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
        return "Step 1/2: asking the confederation who is selling ...", 1, 0.82, 0
    elseif state.phase == "catalogs" then
        return ("Step 2/2: fetching price catalogs  %d/%d  ·  prices for %d of %d items so far"):format(
            state.sellerDone, state.sellerTotal, foundCount(), state.itemTotal), 1, 0.82, 0
    end
    local verb = state.stopped and "Stopped" or "Done"
    return ("%s: %d of %d sellers checked  ·  market prices for %d of your %d sellable items."):format(
        verb, state.sellerDone, state.sellerTotal, foundCount(), state.itemTotal), 0.4, 1, 0.4
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
    head("Item", 34, 280); head("You have", 322, 60); head("Your listing", 392, 100); head("Market low - high (sellers)", 502, 160); head("List", 662, 30)

    -- select/deselect all, next to the List column header: ticks every row that has a
    -- market price to derive a listing price from (grey rows stay untouched)
    win.selAll = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    win.selAll:SetSize(22, 22); win.selAll:SetPoint("TOPLEFT", 684, hy + 6)
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
        r.name = CreateFrame("Button", nil, r); r.name:SetPoint("LEFT", 22, 0); r.name:SetSize(286, ROW_H)
        r.name.fs = r.name:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.name.fs:SetAllPoints(); r.name.fs:SetJustifyH("LEFT")
        r.name:SetScript("OnEnter", function(self)
            if not self.itemLink then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end)
        r.name:SetScript("OnLeave", GameTooltip_Hide)
        r.have = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.have:SetPoint("LEFT", 314, 0); r.have:SetWidth(60); r.have:SetJustifyH("LEFT")
        r.listed = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.listed:SetPoint("LEFT", 384, 0); r.listed:SetWidth(100); r.listed:SetJustifyH("LEFT")
        r.market = CreateFrame("Button", nil, r); r.market:SetPoint("LEFT", 494, 0); r.market:SetSize(150, ROW_H)
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
        r.sel:SetSize(22, 22); r.sel:SetPoint("LEFT", 654, 0)
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
        local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06)
        r:Hide(); winRows[i] = r
    end

    win:SetScript("OnShow", function() refreshWin() end)
    win:Hide()
    return win
end
