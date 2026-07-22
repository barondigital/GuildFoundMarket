local ADDON, ns = ...

--========================================================================
-- Want scan: find sellers for everything on your WTB list.
--
-- The buy-side twin of the bag scan, riding the same protocol for the same
-- reasons: ONE "who's selling" broadcast (sent from the button click itself,
-- so it's legal), then each replying seller's catalog is fetched with the
-- same L~/K~ whispers the Sellers tab uses - directed, timer-safe and
-- throttled by the normal send queue. Catalog rows are matched against your
-- want variants (itemID:suffixID, the shared offer key) and shown in the
-- sellers side window as they arrive; the full sweep is snapshotted into
-- PriceDB at the end, so item tooltips profit too.
--
-- The window docks right of the main frame (same spot as the buyers side
-- window; the two never show together since each lives on its own view) and
-- is owned by My Items' WTB view: navigating away closes it, and closing it
-- also stops the scan - the window is the scan's only output.
--========================================================================
ns.WantScan = ns.WantScan or {}

local CONCURRENT   = 6     -- catalog fetches in flight at once (keeps our own send queue shallow)
local FETCH_WINDOW = 6     -- seconds we wait for one seller's catalog before skipping them

local state = nil          -- nil = idle; see Start() for the fields
local lidSeq = 0
local refreshWin           -- forward decl (window section below)

local function vlinkStr(id, suffix) return ("item:%d:0:0:0:0:0:%d"):format(id, suffix or 0) end
local function vname(id, suffix) return GetItemInfo(vlinkStr(id, suffix)) or ("item:" .. id) end

local function inflightCount()
    local n = 0
    for _ in pairs(state.inflight) do n = n + 1 end
    return n
end

-- Wanted variants that got at least one market offer so far.
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
    -- late chunks for fetches still in flight must be swallowed, not fed to the Sellers tab
    for lid in pairs(state.inflight) do state.knownLids[lid] = true end
    wipe(state.queue); wipe(state.inflight)
    -- one aggregate snapshot across ALL sellers, so PriceDB gets a real low/high/count
    if ns.PriceDB and #state.allRows > 0 then ns.PriceDB.Record(state.allRows) end
    ns.Log(("WANTSCAN %s: %d/%d sellers answered, sellers found for %d of %d wanted variants"):format(
        stopped and "stopped" or "done", state.sellerDone, state.sellerTotal, foundCount(), state.itemTotal))
    refreshWin()
end

-- Ask the next queued sellers for their catalog, up to the concurrency cap.
local function pump()
    while #state.queue > 0 and inflightCount() < CONCURRENT do
        local who = table.remove(state.queue, 1)
        lidSeq = lidSeq + 1
        local lid = ns.playerName .. "#QS" .. lidSeq
        state.inflight[lid] = { who = who, deadline = GetTime() + FETCH_WINDOW }
        if ns.NetStats then ns.NetStats.ScanStarted(lid) end
        ns.EnqueueWhisper("L~" .. lid, who)
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
            ns.Log(("WANTSCAN: no catalog from %s (skipped)"):format(f.who))
        end
    end
    pump()
    refreshWin()
end

-- A K~lid~more~rows chunk. Returns true when the lid is ours (a want-scan fetch), so the
-- Sellers-tab handler leaves it alone. Rows are id:qty:price:suffix, same as the catalog.
function ns.WantScan.HandleCatalogChunk(lid, more, rows)
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

-- Phase 2: the seller scan settled; queue every answering seller for a catalog fetch.
local function startCatalogPhase(gen)
    if not state or state.gen ~= gen or state.phase ~= "sellers" then return end
    state.phase = "catalogs"
    for seller in pairs(ns.sellers.results) do
        if seller ~= ns.playerName then state.queue[#state.queue + 1] = seller end
    end
    state.sellerTotal = #state.queue
    table.sort(state.queue)
    ns.Log(("WANTSCAN: %d seller(s) answered; fetching catalogs (%d at a time)"):format(state.sellerTotal, CONCURRENT))
    if #state.queue == 0 then finish(false); return end
    state.ticker = C_Timer.NewTicker(0.5, tick)
    pump()
    refreshWin()
end

local createWin   -- forward decl

-- Kick off a scan over your WTB list. MUST be called from a hardware event (the button
-- click): the seller scan underneath broadcasts on the chat channel.
function ns.WantScan.Start()
    if not ns.channelName then ns.Feedback("Not in a confederation, can't scan for sellers.", true); return end
    if state and state.phase ~= "done" then return end   -- already running
    local items, order, total = {}, {}, 0
    for _, w in ipairs(ns.WantList()) do
        local key = ns.vkey(w.id, w.suffix)
        items[key] = { id = w.id, suffix = w.suffix, qty = w.qty }
        order[#order + 1] = key; total = total + 1
    end
    if total == 0 then
        ns.Feedback("Your WTB list is empty: add an item below first, then scan for its sellers.", true)
        return
    end
    state = {
        gen = GetTime(), phase = "sellers",
        items = items, order = order, itemTotal = total,
        offers = {},                       -- [vkey] = { {seller, qty, price}, ... } market offers per wanted variant
        allRows = {},                      -- every catalog row seen (one PriceDB snapshot at the end)
        queue = {}, inflight = {}, knownLids = {},
        sellerTotal = 0, sellerDone = 0,
        ticker = nil, stopped = false,
    }
    for _, key in ipairs(order) do state.offers[key] = {} end
    ns.Log(("WANTSCAN: %d wanted variant(s); scanning for online sellers"):format(total))
    ns.ScanSellers("")   -- one broadcast; replies land in ns.sellers.results (the shared index)
    if ns.selfTest and not ns.IsPaused() then
        -- dev self-test: you can't whisper yourself an L, so match your own offers locally,
        -- the same way the bag scan injects your own wants under self-test
        for _, it in ipairs(ns.OfferList()) do
            local mine = state.offers[ns.vkey(it.id, it.suffix)]
            if mine then mine[#mine + 1] = { seller = ns.playerName, qty = it.qty, price = it.price, self = true } end
        end
    end
    local gen = state.gen
    C_Timer.After((ns.QUERY_SETTLE or 5) + 0.5, function() startCatalogPhase(gen) end)
    createWin()
    ns.WantScan.win:Show()
    refreshWin()
end

function ns.WantScan.Stop()
    if state and state.phase ~= "done" then finish(true) end
end

--========================================================================
-- Sellers side window: who sells your wanted items, and at what price. Docks right of the
-- main window (the buyers side window's spot; each lives on its own view so they never
-- clash) and pushes an open Debug/Network sidebar one spot further right. The list mixes
-- two row kinds: a wanted-item header, then one row per seller found for it.
--========================================================================
local ROWS_SHOWN, ROW_H = 17, 20
local winRows = {}
local refreshQueued = false

-- Used by ns.LayoutSidePanels (BagScan) to dock the Debug/Network sidebars behind us.
function ns.WantScan.ShownWindow()
    local win = ns.WantScan.win
    return (win and win:IsShown()) and win or nil
end

-- Flat display list: wanted items that found at least one seller (name order), each
-- followed by its sellers, cheapest priced offer first and bid-only ones last.
local function buildView()
    local out = {}
    if not state then return out end
    local keys = {}
    for _, key in ipairs(state.order) do
        if #state.offers[key] > 0 then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b)
        return vname(state.items[a].id, state.items[a].suffix) < vname(state.items[b].id, state.items[b].suffix)
    end)
    for _, key in ipairs(keys) do
        local it = state.items[key]
        out[#out + 1] = { kind = "item", id = it.id, suffix = it.suffix, want = it.qty }
        local rows = {}
        for _, o in ipairs(state.offers[key]) do rows[#rows + 1] = o end
        table.sort(rows, function(a, b)
            local ap, bp = (a.price or 0) > 0, (b.price or 0) > 0
            if ap ~= bp then return ap end                                -- priced offers before bid-only
            if ap and a.price ~= b.price then return a.price < b.price end
            return a.seller < b.seller
        end)
        for _, o in ipairs(rows) do
            out[#out + 1] = { kind = "seller", seller = o.seller, qty = o.qty, price = o.price, self = o.self, id = it.id, suffix = it.suffix }
        end
    end
    return out
end

local function statusText()
    if not state then return "", 0.7, 0.7, 0.7 end
    if state.phase == "sellers" then
        return "Step 1/2: asking the confederation who is selling ...", 1, 0.82, 0
    elseif state.phase == "catalogs" then
        return ("Step 2/2: catalogs %d/%d  ·  sellers for %d of %d wanted items so far"):format(
            state.sellerDone, state.sellerTotal, foundCount(), state.itemTotal), 1, 0.82, 0
    end
    local verb = state.stopped and "Stopped" or "Done"
    return ("%s: %d seller(s) checked  ·  sellers for %d of your %d wanted items."):format(
        verb, state.sellerDone, foundCount(), state.itemTotal), 0.4, 1, 0.4
end

local function renderRows()
    local win = ns.WantScan.win
    local list = win.view
    local offset = FauxScrollFrame_GetOffset(win.scroll)
    FauxScrollFrame_Update(win.scroll, #list, ROWS_SHOWN, ROW_H)
    for i = 1, ROWS_SHOWN do
        local r, d = winRows[i], list[offset + i]
        if not d then r:Hide() else
            local item = (d.kind == "item")
            r.icon:SetShown(item); r.name:SetShown(item); r.want:SetShown(item)
            r.seller:SetShown(not item); r.qty:SetShown(not item); r.price:SetShown(not item)
            if item then
                r.validBG:Hide()
                r.icon:SetTexture(GetItemIcon(d.id))
                r.name.fs:SetText(vname(d.id, d.suffix))
                r.name.itemLink = vlinkStr(d.id, d.suffix)
                r.want:SetText(("|cff888888x%d wanted|r"):format(d.want or 1))
            else
                r.seller.fs:SetText(d.self and (d.seller .. " (you)") or d.seller)
                r.seller.fs:SetTextColor(d.self and 1 or 0.4, d.self and 0.82 or 1, d.self and 0 or 0.4)
                r.seller.seller, r.seller.isSelf = d.seller, d.self
                r.seller.itemID, r.seller.suffix, r.seller.price = d.id, d.suffix, d.price
                r.qty:SetText(d.qty or 0)
                r.price:SetText((d.price or 0) > 0 and ns.PriceToStr(d.price) or "|cffffd100bids|r")
                local cr, cg, cb, ca
                if ns.ValidTint then cr, cg, cb, ca = ns.ValidTint(d.seller) end
                if cr then r.validBG:SetColorTexture(cr, cg, cb, ca); r.validBG:Show() else r.validBG:Hide() end
            end
            r:Show()
        end
    end
end

refreshWin = function()
    local win = ns.WantScan.win
    if not (win and win:IsShown()) then return end
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.2, function()
        refreshQueued = false
        if not (win and win:IsShown()) then return end
        local txt, cr, cg, cb = statusText()
        win.status:SetText(txt); win.status:SetTextColor(cr, cg, cb)
        win.stopBtn:SetShown(state ~= nil and state.phase ~= "done")
        win.view = buildView()
        if #win.view == 0 and state and state.phase == "done" then
            win.status:SetText(state.stopped and "Stopped: no sellers found so far." or "No sellers found for anything on your WTB list.")
            win.status:SetTextColor(0.7, 0.7, 0.7)
        end
        renderRows()
    end)
end

createWin = function()
    if ns.WantScan.win then return ns.WantScan.win end
    local main = _G.GuildFoundMarketFrame
    local win = CreateFrame("Frame", "GuildFoundMarketWantSellers", main, "BackdropTemplate")
    ns.WantScan.win = win
    win.view = {}
    win:SetWidth(380)
    win:SetPoint("TOPLEFT", main, "TOPRIGHT", 6, 0)
    win:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", 6, 0)
    win:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    win:EnableMouse(true)

    local header = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOP", 0, -16); header:SetText("GFM |cff00ff96Sellers|r")

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() win:Hide() end)

    win.status = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    win.status:SetPoint("TOPLEFT", 16, -38); win.status:SetPoint("TOPRIGHT", -76, -38)
    win.status:SetJustifyH("LEFT")

    win.stopBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.stopBtn:SetSize(50, 20); win.stopBtn:SetPoint("TOPRIGHT", -18, -36); win.stopBtn:SetText("Stop")
    win.stopBtn:Hide()
    win.stopBtn:SetScript("OnClick", function() ns.WantScan.Stop() end)
    win.stopBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Stop the scan. Sellers found so far are kept.", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    win.stopBtn:SetScript("OnLeave", GameTooltip_Hide)

    local function head(text, x, w)
        local h = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", x, -62); h:SetWidth(w); h:SetJustifyH("LEFT"); h:SetText(text)
    end
    head("Item / seller", 18, 150); head("Stock", 186, 40); head("Price/unit", 232, 100)

    win.scroll = CreateFrame("ScrollFrame", "GuildFoundMarketWantSellersScroll", win, "FauxScrollFrameTemplate")
    win.scroll:SetPoint("TOPLEFT", 14, -78); win.scroll:SetSize(328, ROWS_SHOWN * ROW_H)
    win.scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, ROW_H, renderRows) end)
    win.scroll:EnableMouseWheel(true)
    win.scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #win.view - ROWS_SHOWN)
        local off = math.min(maxOff, math.max(0, FauxScrollFrame_GetOffset(self) - delta))
        FauxScrollFrame_SetOffset(self, off); self:SetVerticalScroll(off * ROW_H); renderRows()
    end)

    for i = 1, ROWS_SHOWN do
        local r = CreateFrame("Frame", nil, win); r:SetSize(328, ROW_H)
        if i == 1 then r:SetPoint("TOPLEFT", win.scroll, "TOPLEFT", 2, 0)
        else r:SetPoint("TOPLEFT", winRows[i - 1], "BOTTOMLEFT", 0, 0) end
        -- Guild Found status tint on seller rows (same scheme as the main window's rows)
        r.validBG = r:CreateTexture(nil, "BACKGROUND", nil, -2)
        r.validBG:SetAllPoints(); r.validBG:Hide()
        -- item header widgets
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 0, 0)
        r.name = CreateFrame("Button", nil, r); r.name:SetPoint("LEFT", 22, 0); r.name:SetSize(220, ROW_H)
        r.name.fs = r.name:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.name.fs:SetAllPoints(); r.name.fs:SetJustifyH("LEFT"); r.name.fs:SetWordWrap(false)
        r.name:SetScript("OnEnter", function(self)
            if not self.itemLink then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.itemLink); GameTooltip:Show()
        end)
        r.name:SetScript("OnLeave", GameTooltip_Hide)
        r.want = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.want:SetPoint("RIGHT", -4, 0); r.want:SetJustifyH("RIGHT")
        -- seller row widgets (indented under their item)
        r.seller = CreateFrame("Button", nil, r); r.seller:SetPoint("LEFT", 16, 0); r.seller:SetSize(150, ROW_H)
        r.seller:RegisterForClicks("RightButtonUp")
        r.seller.fs = r.seller:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.seller.fs:SetAllPoints(); r.seller.fs:SetJustifyH("LEFT")
        -- right-click: whisper the seller, pre-filled [WTB] + the item (you're the buyer here)
        r.seller:SetScript("OnClick", function(self, button)
            if button ~= "RightButton" or not self.seller then return end
            if self.itemID and ns.WhisperItem then
                ns.WhisperItem(self.seller, self.itemID, self.suffix, self.price, "WTB")
            else
                ChatFrame_OpenChat("/w " .. self.seller .. " ")
            end
        end)
        r.seller:SetScript("OnEnter", function(self)
            if not self.seller then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(ns.PlayerTitle and ns.PlayerTitle(self.seller) or self.seller, 1, 1, 1)
            if ns.ValidLine then
                local txt, cr, cg, cb = ns.ValidLine(self.seller)
                if txt then GameTooltip:AddLine(txt, cr, cg, cb, true) end
            end
            if self.isSelf then GameTooltip:AddLine("Your own listing (self-test)", 0.6, 0.6, 0.6) end
            GameTooltip:AddLine("Right-click to whisper", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        r.seller:SetScript("OnLeave", GameTooltip_Hide)
        r.qty = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.qty:SetPoint("LEFT", 172, 0); r.qty:SetWidth(40); r.qty:SetJustifyH("LEFT")
        r.price = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.price:SetPoint("LEFT", 218, 0); r.price:SetWidth(106); r.price:SetJustifyH("LEFT")
        local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06)
        r:Hide(); winRows[i] = r
    end

    win:SetScript("OnShow", function() ns.LayoutSidePanels() end)
    -- the window is the scan's only output: closing it (directly, by leaving the WTB
    -- view, or with the main window) also stops a scan still running
    win:SetScript("OnHide", function()
        ns.WantScan.Stop()
        ns.LayoutSidePanels()
    end)
    win:Hide()
    return win
end

-- Leaving the WTB view (another sub-tab or another main tab) closes the window,
-- mirroring how the buyers side window follows My Items' WTS view.
function ns.WantScan.CloseWindow()
    if ns.WantScan.win then ns.WantScan.win:Hide() end
end
