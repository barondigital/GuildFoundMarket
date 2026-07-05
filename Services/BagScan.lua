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
-- The window shows live progress and has a Stop button: stopping clears the fetch
-- queue, ignores whatever is still in flight, and keeps the prices found so far.
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
    if state and state.phase ~= "done" then ns.BagScan.ShowWindow(); return end   -- already running: just surface it
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
    ns.Log(("BAGSCAN: %d sellable variant(s) in bags%s; scanning for online sellers"):format(total, bankIncluded and " + bank" or ""))
    ns.ScanSellers("")   -- one broadcast; replies land in ns.sellers.results (the shared index)
    local gen = state.gen
    C_Timer.After((ns.QUERY_SETTLE or 5) + 0.5, function() startCatalogPhase(gen) end)
    ns.BagScan.ShowWindow()
end

function ns.BagScan.Stop()
    if state and state.phase ~= "done" then finish(true) end
end

--========================================================================
-- The results window: an overlay over the top of the main frame (the compose panel at
-- the bottom stays reachable, so a row click can prefill it). Live progress line, Stop
-- button while running, and one row per sellable variant with your stock, your current
-- listing and the market price range found so far. Click a row to load it into the
-- offer form with the lowest market price as the suggested price.
--========================================================================
local win
local ROWS_SHOWN, ROW_H = 11, 20
local winRows = {}
local view = {}          -- sorted vkeys for the scroll list
local refreshQueued = false

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
            r:Show()
        end
    end
end

refreshWin = function()
    if not win or not win:IsShown() or not state then return end
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.2, function()
        refreshQueued = false
        if not win or not win:IsShown() or not state then return end
        local txt, cr, cg, cb = statusText()
        win.status:SetText(txt); win.status:SetTextColor(cr, cg, cb)
        win.stopBtn:SetShown(state.phase ~= "done")
        buildView()
        renderWinRows()
    end)
end

local function createWindow()
    if win then return win end
    local main = _G.GuildFoundMarketFrame
    if not main then return nil end

    win = CreateFrame("Frame", "GuildFoundMarketBagScan", main, "BackdropTemplate")
    win:SetSize(640, 336)
    win:SetPoint("TOP", main, "TOP", 0, -24)
    win:SetFrameStrata("DIALOG")
    win:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    win:EnableMouse(true)

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -16); title:SetText("Bag scan |cff00ff96market prices|r")

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() win:Hide() end)   -- closing does NOT stop the scan

    win.status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.status:SetPoint("TOPLEFT", 18, -38); win.status:SetPoint("TOPRIGHT", -90, -38)
    win.status:SetJustifyH("LEFT")

    win.stopBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.stopBtn:SetSize(60, 20); win.stopBtn:SetPoint("TOPRIGHT", -24, -34); win.stopBtn:SetText("Stop")
    win.stopBtn:SetScript("OnClick", function() ns.BagScan.Stop() end)
    win.stopBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Stop the scan. Prices found so far are kept.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    win.stopBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- column headers
    local hy = -60
    local function head(text, x, w)
        local h = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", x, hy); h:SetWidth(w); h:SetJustifyH("LEFT"); h:SetText(text)
    end
    head("Item", 40, 250); head("You have", 300, 60); head("Your listing", 366, 90); head("Market low - high (sellers)", 462, 160)

    win.scroll = CreateFrame("ScrollFrame", "GuildFoundMarketBagScanScroll", win, "FauxScrollFrameTemplate")
    win.scroll:SetPoint("TOPLEFT", 18, -76); win.scroll:SetSize(586, ROWS_SHOWN * ROW_H)
    win.scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, ROW_H, renderWinRows) end)
    win.scroll:EnableMouseWheel(true)
    win.scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #view - ROWS_SHOWN)
        local off = math.min(maxOff, math.max(0, FauxScrollFrame_GetOffset(self) - delta))
        FauxScrollFrame_SetOffset(self, off); self:SetVerticalScroll(off * ROW_H); renderWinRows()
    end)

    for i = 1, ROWS_SHOWN do
        local r = CreateFrame("Frame", nil, win); r:SetSize(586, ROW_H)
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
        r.have = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.have:SetPoint("LEFT", 282, 0); r.have:SetWidth(56); r.have:SetJustifyH("LEFT")
        r.listed = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.listed:SetPoint("LEFT", 348, 0); r.listed:SetWidth(92); r.listed:SetJustifyH("LEFT")
        r.market = CreateFrame("Button", nil, r); r.market:SetPoint("LEFT", 444, 0); r.market:SetSize(140, ROW_H)
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
        local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06)
        r:Hide(); winRows[i] = r
    end

    win:SetScript("OnShow", function() refreshWin() end)
    win:Hide()
    return win
end

function ns.BagScan.ShowWindow()
    createWindow()
    if not win then return end
    win:Show()
    refreshWin()
end
