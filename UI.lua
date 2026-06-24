local ADDON, ns = ...

local ROWS, ROW_H = 10, 24
local playerName = UnitName("player")

local main
local rows = {}
local view = {}            -- current rows being displayed (buy results / my offers / sellers)
local currentTab = "BUY"
local sellersView = "INDEX"  -- within the Sellers tab: "INDEX" (list) or "SHOW" (one seller)
local tabButtons = {}
local draft = { itemID = nil }     -- item being composed in the My Items post panel
local selectedSearchID = nil

--========================================================================
-- helpers
--========================================================================
local function parsePrice(str)
    str = (str or ""):lower():gsub("%s+", "")
    if str == "" then return 0 end
    if str:match("^%d+$") then return tonumber(str) * 10000 end
    local g = tonumber(str:match("(%d+)g")) or 0
    local s = tonumber(str:match("(%d+)s")) or 0
    local c = tonumber(str:match("(%d+)c")) or 0
    return g * 10000 + s * 100 + c
end

local function itemName(id)
    local name = GetItemInfo(id)
    return name or ("item:" .. id)
end

local function itemLink(id)
    return (select(2, GetItemInfo(id)))
end

-- Copper -> short "1g2s45c" string (zero parts dropped), mirroring the price input.
local function coinShort(c)
    c = math.floor((c or 0) + 0.5)
    local g = math.floor(c / 10000); c = c % 10000
    local s = math.floor(c / 100); local cp = c % 100
    local out = ""
    if g > 0 then out = out .. g .. "g" end
    if s > 0 then out = out .. s .. "s" end
    if cp > 0 then out = out .. cp .. "c" end
    return out == "" and "0c" or out
end

-- Open a whisper to `name`, pre-filled with the item link + price and a trailing
-- space so the buyer can append a question: "/w Name [Item]@1g2s45c "
local function whisperItem(name, itemID, price)
    local link = (itemID and itemLink(itemID)) or ("[" .. itemName(itemID) .. "]")
    local body = (price and price > 0) and (link .. "@" .. coinShort(price) .. " ") or (link .. " ")
    ChatFrame_OpenChat("/w " .. name .. " " .. body)
end

-- pick an item into the search box and fire a search (used by autocomplete + shift-click)
local function selectSearchItem(id, name)
    if not main then return end
    selectedSearchID = id
    main.searchBox:SetText(name or itemName(id)); main.searchBox:SetCursorPosition(0); main.searchBox:ClearFocus()
    main.ac:Hide()
    ns.Search(id)
end

--========================================================================
-- feedback / status line
--========================================================================
local fbToken = 0
function ns.Feedback(msg, isError)
    if main and main.status then
        main.status:SetText(msg or "")
        main.status:SetTextColor(isError and 1 or 0.3, isError and 0.3 or 1, 0.3)
        fbToken = fbToken + 1
        local mine = fbToken
        if msg and msg ~= "" then
            C_Timer.After(6, function() if fbToken == mine and main and main.status then main.status:SetText("") end end)
        end
    elseif msg and msg ~= "" then
        print("|cff00ff96GFM|r: " .. msg)
    end
end

--========================================================================
-- minimap button
--========================================================================
local LDB    = LibStub and LibStub("LibDataBroker-1.1", true)
local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
local minimapLDB
function ns.CreateMinimapButton()
    if not (LDB and DBIcon) then return end
    -- per-account state for the icon (LibDBIcon stores .hide and .minimapPos here)
    GuildFoundMarketDB.minimap = GuildFoundMarketDB.minimap or {}
    -- migrate the old custom-button angle to LibDBIcon's minimapPos
    if GuildFoundMarketDB.minimapAngle and GuildFoundMarketDB.minimap.minimapPos == nil then
        GuildFoundMarketDB.minimap.minimapPos = GuildFoundMarketDB.minimapAngle
        GuildFoundMarketDB.minimapAngle = nil
    end

    if not minimapLDB then
        minimapLDB = LDB:NewDataObject("GuildFoundMarket", {
            type = "launcher",
            icon = "Interface\\Icons\\INV_Misc_Coin_01",
            label = "Guild Found Market",
            OnClick = function() ns.ToggleUI() end,
            OnTooltipShow = function(tt)
                tt:AddLine("Guild Found Market")
                tt:AddLine("Click to open / close", 1, 1, 1)
            end,
        })
    end

    if not DBIcon:IsRegistered("GuildFoundMarket") then
        DBIcon:Register("GuildFoundMarket", minimapLDB, GuildFoundMarketDB.minimap)
    end
end

--========================================================================
-- row rendering (shared between Buy results and My Items)
--========================================================================
local function formatBuyRow(r, d)
    -- every result is from an online seller (offline sellers can't respond)
    r.icon:Hide()
    r.c1.fs:SetText(d.seller)
    r.c1.fs:SetTextColor(1, 1, 1)
    r.c1:EnableMouse(true)
    r.c1.tip = "Click for items · right-click to whisper"
    r.c1:SetScript("OnClick", function(_, button)
        if button == "RightButton" then whisperItem(d.seller, ns.searchItemID, d.price)
        else ns.SelectTab("SELLERS", d.seller, d.loc) end
    end)
    r.c2:SetText(d.qty)
    r.c3:SetText(d.price > 0 and GetCoinTextureString(d.price) or "|cffffd100Bid|r")
    r.c4:SetText(d.loc or ""); r.c4:Show()
    r.x:Hide()
    r.itemID = nil; r.c1.itemID = ns.searchItemID   -- every Buy row is the searched item
end

local function formatMineRow(r, d)
    r.icon:SetTexture(GetItemIcon(d.id)); r.icon:Show()
    r.c1.fs:SetText(itemLink(d.id) or itemName(d.id))
    r.c1:EnableMouse(true)           -- enable hover for the item tooltip (no click action)
    r.c1.tip = nil
    r.c1.itemID = d.id
    r.c1:SetScript("OnClick", nil)
    r.c2:SetText(d.qty)
    r.c3:SetText(d.price > 0 and GetCoinTextureString(d.price) or "|cffffd100Bid|r")
    r.c4:SetText(""); r.c4:Hide()
    r.x:Show()
    r.x:SetScript("OnClick", function() ns.RemoveOffer(d.id) end)
    r.itemID = d.id
end

-- Sellers tab: either an index row (a seller) or, in the show view, one of their items.
local function formatSellerRow(r, d)
    if d.kind == "seller" then
        r.icon:Hide()
        r.c1.fs:SetText(d.seller)
        r.c1.fs:SetTextColor(0.4, 1, 0.4)        -- green: online right now
        r.c1:EnableMouse(true)
        r.c1.tip = "Click to see " .. d.seller .. "'s items"
        r.c1:SetScript("OnClick", function(_, button)
            if button ~= "RightButton" then ns.OpenSeller(d.seller); ns.SetSellersView("SHOW") end
        end)
        r.c2:SetText(d.count)
        r.c3:SetText("")
        r.c4:SetText(d.loc or ""); r.c4:Show()
        r.x:Hide(); r.itemID = nil; r.c1.itemID = nil
    else
        r.icon:SetTexture(GetItemIcon(d.id)); r.icon:Show()
        r.c1.fs:SetText(itemLink(d.id) or itemName(d.id))
        r.c1.fs:SetTextColor(1, 1, 1)
        r.c1:EnableMouse(true)
        r.c1.tip = "Ctrl-click to compare · right-click to whisper"
        r.c1:SetScript("OnClick", function(_, button)
            if button == "RightButton" then whisperItem(d.seller, d.id, d.price)
            elseif IsControlKeyDown() then ns.SelectTab("BUY"); selectSearchItem(d.id) end
        end)
        r.c2:SetText(d.qty)
        r.c3:SetText(d.price > 0 and GetCoinTextureString(d.price) or "|cffffd100Bid|r")
        r.c4:SetText(""); r.c4:Hide()
        r.x:Hide(); r.itemID = nil; r.c1.itemID = d.id
    end
end

local function renderRows()
    local offset = FauxScrollFrame_GetOffset(main.scroll)
    FauxScrollFrame_Update(main.scroll, #view, ROWS, ROW_H)
    for i = 1, ROWS do
        local r = rows[i]
        local d = view[offset + i]
        if d then
            if currentTab == "BUY" then formatBuyRow(r, d)
            elseif currentTab == "SELLERS" then formatSellerRow(r, d)
            else formatMineRow(r, d) end
            r:Show()
        else
            r:Hide()
        end
    end
end

--========================================================================
-- refresh: Buy results
--========================================================================
function ns.RefreshBuy()
    if not main or not main:IsShown() or currentTab ~= "BUY" then return end
    wipe(view)
    for seller, o in pairs(ns.results) do
        view[#view + 1] = { seller = seller, qty = o.qty, price = o.price, loc = o.loc }
    end
    table.sort(view, function(a, b)
        -- real prices ascending; "bid" offers (price 0) sink to the bottom
        local pa = a.price > 0 and a.price or math.huge
        local pb = b.price > 0 and b.price or math.huge
        if pa ~= pb then return pa < pb end
        return a.seller < b.seller
    end)
    renderRows()
    if not ns.searchItemID then
        main.status:SetText("");
    elseif ns.searching then
        main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText("Searching " .. itemName(ns.searchItemID) .. " ...")
    elseif #view == 0 then
        main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText("No online sellers for " .. itemName(ns.searchItemID) .. ".")
    else
        main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText(("%d offer(s) — cheapest first."):format(#view))
    end
end

--========================================================================
-- refresh: My Items
--========================================================================
function ns.RefreshMine()
    if not main or not main:IsShown() or currentTab ~= "MINE" then return end
    wipe(view)
    for id, o in pairs(GuildFoundMarketCharDB.offers) do
        view[#view + 1] = { id = id, qty = o.qty, price = o.price }
    end
    table.sort(view, function(a, b) return itemName(a.id) < itemName(b.id) end)
    renderRows()
    if GuildFoundMarketCharDB.paused then
        main.status:SetTextColor(1, 0.6, 0.2)
        main.status:SetText("Listings paused — not answering searches. Click \"Offline\" to go back online.")
    elseif #view == 0 then
        main.status:SetTextColor(0.7, 0.7, 0.7)
        main.status:SetText("No items listed yet — pick one up and click the slot below to offer it.")
    else
        main.status:SetText("")
    end
end

--========================================================================
-- refresh: Sellers index (list of online sellers, client-side name filter)
--========================================================================
function ns.RefreshSellers()
    if not main or not main:IsShown() or currentTab ~= "SELLERS" or sellersView ~= "INDEX" then return end
    wipe(view)
    local filter = (main.sellerFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local names = {}
    for s in pairs(ns.sellerResults) do
        if filter == "" or s:lower():find(filter, 1, true) then names[#names + 1] = s end
    end
    table.sort(names)
    for _, s in ipairs(names) do
        local rec = ns.sellerResults[s]
        view[#view + 1] = { kind = "seller", seller = s, count = rec.count, loc = rec.loc }
    end
    renderRows()
    main.status:SetTextColor(0.7, 0.7, 0.7)
    local sf = ns.scanFilter
    if ns.scanningSellers then
        main.status:SetText((sf and sf ~= "") and ("Searching sellers matching \"" .. sf .. "\" ...")
            or "Scanning your confederation for online sellers ...")
    elseif next(ns.sellerResults) == nil then
        main.status:SetText((sf and sf ~= "") and ("No online seller matches \"" .. sf .. "\".")
            or "No online sellers right now.")
    elseif #names == 0 then
        main.status:SetText("No seller matches \"" .. filter .. "\".")
    elseif ns.sellerCapped then
        main.status:SetText(("Showing %d online sellers (capped) — type %d+ letters of a name and press Enter to find a specific one."):format(#names, ns.FILTER_MIN))
    else
        main.status:SetText(("%d online seller(s) — click one to see their items."):format(#names))
    end
end

--========================================================================
-- refresh: Sellers show view (one seller's catalog, fetched lazily)
--========================================================================
function ns.RefreshSellerCatalog()
    if not main or not main:IsShown() or currentTab ~= "SELLERS" or sellersView ~= "SHOW" then return end
    wipe(view)
    local cat = ns.sellerCatalog
    if cat then
        main.sellerHeader:SetText(cat.seller .. ((cat.loc and cat.loc ~= "") and ("  |cff888888" .. cat.loc .. "|r") or ""))
        local items = {}
        for _, it in pairs(cat.items) do items[#items + 1] = it end
        table.sort(items, function(a, b) return itemName(a.id) < itemName(b.id) end)
        for _, it in ipairs(items) do
            view[#view + 1] = { kind = "item", id = it.id, qty = it.qty, price = it.price, seller = cat.seller }
        end
    end
    renderRows()
    main.status:SetTextColor(0.7, 0.7, 0.7)
    if cat and cat.loading then
        main.status:SetText("Loading " .. cat.seller .. "'s items ...")
    elseif cat and next(cat.items) == nil then
        main.status:SetText(cat.seller .. " has nothing listed right now.")
    elseif cat then
        main.status:SetText(("%d item(s) — click one to whisper %s."):format(#view, cat.seller))
    end
end

-- Switch between the seller index and a single seller's catalog.
function ns.SetSellersView(v)
    if not main then return end
    sellersView = v
    local index = (v == "INDEX")
    main.sellerFilter:SetShown(index); main.sellerFilterLabel:SetShown(index); main.sellerRefreshBtn:SetShown(index)
    main.sellerBackBtn:SetShown(not index); main.sellerHeader:SetShown(not index)
    if index then
        main.h1:SetText("Seller"); main.h2:SetText("Items"); main.h3:SetText(""); main.h4:SetText("Location")
    else
        main.h1:SetText("Item"); main.h2:SetText("Qty"); main.h3:SetText("Price/unit"); main.h4:SetText("")
    end
    FauxScrollFrame_SetOffset(main.scroll, 0); main.scroll:SetVerticalScroll(0)
    if index then ns.RefreshSellers() else ns.RefreshSellerCatalog() end
end

--========================================================================
-- Coalesced refreshes — network replies (R/C/K) and item-info events can arrive
-- in bursts; debounce so we re-sort/re-render at most ~5x/sec, not once per message.
--========================================================================
local pendingRefresh = {}
local refreshScheduled = false
local function scheduleRefresh(which)
    pendingRefresh[which] = true
    if refreshScheduled then return end
    refreshScheduled = true
    C_Timer.After(0.2, function()
        refreshScheduled = false
        local p = pendingRefresh; pendingRefresh = {}
        if p.buy     and ns.RefreshBuy            then ns.RefreshBuy() end
        if p.mine    and ns.RefreshMine           then ns.RefreshMine() end
        if p.sellers and ns.RefreshSellers        then ns.RefreshSellers() end
        if p.catalog and ns.RefreshSellerCatalog  then ns.RefreshSellerCatalog() end
    end)
end
function ns.RefreshBuySoon()           scheduleRefresh("buy") end
function ns.RefreshMineSoon()          scheduleRefresh("mine") end
function ns.RefreshSellersSoon()       scheduleRefresh("sellers") end
function ns.RefreshSellerCatalogSoon() scheduleRefresh("catalog") end

--========================================================================
-- build the window
--========================================================================
local function CreateUI()
    main = CreateFrame("Frame", "GuildFoundMarketFrame", UIParent, "BackdropTemplate")
    main:SetSize(560, 470)
    main:SetPoint("CENTER")
    main:SetMovable(true); main:EnableMouse(true); main:RegisterForDrag("LeftButton")
    main:SetScript("OnDragStart", main.StartMoving); main:SetScript("OnDragStop", main.StopMovingOrSizing)
    main:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    main:SetClampedToScreen(true)
    table.insert(UISpecialFrames, "GuildFoundMarketFrame")

    local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16); title:SetText("Guild Found |cff00ff96Market|r")
    CreateFrame("Button", nil, main, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -8, -8)

    -- tabs
    local TABS = { { tab = "BUY", label = "Buy", w = 70 }, { tab = "SELLERS", label = "Sellers", w = 80 }, { tab = "MINE", label = "My Items", w = 90 }, { tab = "HELP", label = "Help", w = 50, right = true } }
    local tx = 20
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, main)
        b:SetSize(t.w, 24)
        if t.right then b:SetPoint("TOPRIGHT", -14, -36) else b:SetPoint("TOPLEFT", tx, -36); tx = tx + t.w + 8 end
        b.tab = t.tab
        local sel = b:CreateTexture(nil, "BACKGROUND"); sel:SetAllPoints(); sel:SetColorTexture(1, 0.82, 0, 0.18); sel:Hide(); b.sel = sel
        local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.10)
        local txt = b:CreateFontString(nil, "OVERLAY", "GameFontNormal"); txt:SetPoint("CENTER"); txt:SetText(t.label); b.text = txt
        b:SetScript("OnClick", function(self) ns.SelectTab(self.tab) end)
        tabButtons[i] = b
    end

    -- search box (Buy)
    local searchLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", 16, -68); searchLabel:SetText("Search item:")
    main.searchLabel = searchLabel
    local searchBox = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    searchBox:SetPoint("TOPLEFT", 100, -64); searchBox:SetSize(300, 22); searchBox:SetAutoFocus(false)
    main.searchBox = searchBox

    -- autocomplete dropdown
    local ac = CreateFrame("Frame", nil, main, "BackdropTemplate")
    ac:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    ac:SetBackdropColor(0, 0, 0, 0.92); ac:SetBackdropBorderColor(0.4, 0.4, 0.4)
    ac:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -2, -2); ac:SetWidth(304); ac:SetFrameStrata("DIALOG"); ac:Hide()
    ac.rows = {}
    for i = 1, 12 do
        local row = CreateFrame("Button", nil, ac)
        row:SetSize(300, 18); row:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 18)
        local hl = row:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.15)
        row.sel = row:CreateTexture(nil, "BACKGROUND"); row.sel:SetAllPoints(); row.sel:SetColorTexture(1, 0.82, 0, 0.25); row.sel:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(14, 14); row.icon:SetPoint("LEFT", 2, 0)
        row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.fs:SetPoint("LEFT", 20, 0)
        row:Hide(); ac.rows[i] = row
    end
    main.ac = ac

    local selectItem = selectSearchItem

    local function highlightAC()
        for i, row in ipairs(ac.rows) do row.sel:SetShown(ac.sel == i and row:IsShown()) end
    end

    local function updateAutocomplete()
        local matches = ns.ItemDB.Match(searchBox:GetText())
        ac.matches = matches; ac.sel = 0
        if #matches == 0 then ac:Hide(); return end
        for i, row in ipairs(ac.rows) do
            local m = matches[i]
            row.sel:Hide()
            if m then
                row.icon:SetTexture(GetItemIcon(m.id))
                -- resolve real quality for the shown item if it's cached (no server fetch)
                local q = m.q
                if C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(m.id) then
                    local _, _, cq = GetItemInfo(m.id)
                    if cq then q = cq; m.q = cq; GuildFoundMarketDB.quals[m.id] = cq end
                end
                local col = ITEM_QUALITY_COLORS[q] or ITEM_QUALITY_COLORS[1]
                row.fs:SetText(m.name); row.fs:SetTextColor(col.r, col.g, col.b)
                row:SetScript("OnClick", function() selectItem(m.id, m.name) end)
                row:SetScript("OnEnter", function() ac.sel = i; highlightAC() end)
                row:Show()
            else
                row:Hide()
            end
        end
        ac:SetHeight(math.min(#matches, 12) * 18 + 4)
        ac:Show()
    end

    -- broad shift-click support: chat links, bags, character tab, merchant, AtlasLoot…
    -- all funnel through ChatEdit_InsertLink. Capture it when our search box is focused.
    if not ns._linkHooked then
        ns._linkHooked = true
        hooksecurefunc("ChatEdit_InsertLink", function(link)
            if not (main and main:IsShown() and currentTab == "BUY" and main.searchBox and main.searchBox:HasFocus()) then return end
            local id = link and tonumber(tostring(link):match("Hitem:(%d+)"))
            if id then ns.ItemDB.Learn(id); selectSearchItem(id) end
        end)
    end
    searchBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        local linkID = self:GetText():match("|Hitem:(%d+)")   -- shift-clicked item link
        if linkID then
            local id = tonumber(linkID)
            ns.ItemDB.Learn(id); selectItem(id, itemName(id)); return
        end
        selectedSearchID = nil; updateAutocomplete()
    end)
    searchBox:SetScript("OnEscapePressed", function(self) ac:Hide(); self:ClearFocus() end)
    searchBox:SetScript("OnArrowPressed", function(self, key)
        if not ac:IsShown() or not ac.matches then return end
        local n = #ac.matches
        if n == 0 then return end
        if key == "DOWN" then
            ac.sel = (ac.sel >= n) and 1 or ac.sel + 1; highlightAC()
        elseif key == "UP" then
            ac.sel = (ac.sel <= 1) and n or ac.sel - 1; highlightAC()
        end
    end)
    searchBox:SetScript("OnEnterPressed", function(self)
        if ac:IsShown() and ac.sel and ac.sel > 0 and ac.matches and ac.matches[ac.sel] then
            local m = ac.matches[ac.sel]; selectItem(m.id, m.name); return
        end
        local matches = ns.ItemDB.Match(self:GetText())
        if selectedSearchID then ns.Search(selectedSearchID); ac:Hide(); self:ClearFocus()
        elseif matches[1] then selectItem(matches[1].id, matches[1].name) end
    end)
    -- shift-click an item link/bag item into the search box
    searchBox:SetScript("OnReceiveDrag", function(self)
        local t, id = GetCursorInfo()
        if t == "item" and id then ClearCursor(); ns.ItemDB.Learn(id); selectItem(id, itemName(id)) end
    end)

    -- column headers
    local function header(x) local fs = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); fs:SetPoint("TOPLEFT", x, -96); return fs end
    main.h1 = header(28); main.h2 = header(215); main.h3 = header(265); main.h4 = header(380)

    -- scroll + rows
    local scroll = CreateFrame("ScrollFrame", "GuildFoundMarketScroll", main, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -112); scroll:SetSize(520, ROWS * ROW_H)
    scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, ROW_H, renderRows) end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #view - ROWS)
        local off = math.min(maxOff, math.max(0, FauxScrollFrame_GetOffset(self) - delta))
        FauxScrollFrame_SetOffset(self, off); self:SetVerticalScroll(off * ROW_H); renderRows()
    end)
    main.scroll = scroll

    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, main); r:SetSize(520, ROW_H)
        if i == 1 then r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        else r:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0) end
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 4, 0)
        r.c1 = CreateFrame("Button", nil, r); r.c1:SetPoint("LEFT", 26, 0); r.c1:SetSize(185, ROW_H); r.c1:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.c1.fs = r.c1:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c1.fs:SetAllPoints(); r.c1.fs:SetJustifyH("LEFT")
        local c1hl = r.c1:CreateTexture(nil, "HIGHLIGHT"); c1hl:SetAllPoints(); c1hl:SetColorTexture(1, 1, 1, 0.12)
        r.c1:SetScript("OnEnter", function(self)
            if self.itemID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(self.itemID)
                if self.tip then GameTooltip:AddLine(self.tip, 0.6, 0.6, 0.6, true) end
                GameTooltip:Show()
            elseif self.tip then
                GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
                GameTooltip:SetText(self.tip, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        r.c1:SetScript("OnLeave", GameTooltip_Hide)
        r.c2 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c2:SetPoint("LEFT", 215, 0); r.c2:SetWidth(45); r.c2:SetJustifyH("LEFT")
        r.c3 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c3:SetPoint("LEFT", 263, 0); r.c3:SetWidth(112); r.c3:SetJustifyH("LEFT")
        r.c4 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c4:SetPoint("LEFT", 380, 0); r.c4:SetWidth(140); r.c4:SetJustifyH("LEFT")
        r.x = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.x:SetSize(24, 20); r.x:SetPoint("RIGHT", -2, 0); r.x:SetText("X")
        r:Hide(); rows[i] = r
    end

    -- status line
    local status = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    status:SetPoint("BOTTOMLEFT", 18, 96); status:SetPoint("BOTTOMRIGHT", -18, 96); status:SetJustifyH("CENTER"); status:SetText("")
    main.status = status

    --==================== My Items post panel ====================
    local panel = CreateFrame("Frame", nil, main)
    panel:SetPoint("BOTTOMLEFT", 16, 14); panel:SetPoint("BOTTOMRIGHT", -16, 14); panel:SetHeight(74)
    main.postPanel = panel

    local slot = CreateFrame("Button", "GuildFoundMarketSlot", panel, "ItemButtonTemplate")
    slot:SetPoint("LEFT", 4, 0); slot:SetSize(36, 36)
    local function setDraft()
        local t, id = GetCursorInfo()
        if t == "item" and id then
            ClearCursor(); draft.itemID = id; ns.ItemDB.Learn(id)
            SetItemButtonTexture(slot, GetItemIcon(id)); SetItemButtonCount(slot, GetItemCount(id, true))
        end
    end
    slot:SetScript("OnClick", setDraft); slot:SetScript("OnReceiveDrag", setDraft)
    slot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if draft.itemID then GameTooltip:SetItemByID(draft.itemID) else GameTooltip:SetText("Pick up an item and click here") end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", GameTooltip_Hide)
    main.slot = slot

    local function label(text, x, y) local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); fs:SetPoint("BOTTOMLEFT", x, y); fs:SetText(text); return fs end
    label("Qty", 52, 30)
    local qtyBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    qtyBox:SetPoint("BOTTOMLEFT", 56, 10); qtyBox:SetSize(44, 20); qtyBox:SetAutoFocus(false); qtyBox:SetNumeric(true); qtyBox:SetText("1")
    main.qtyBox = qtyBox
    label("Price/unit — e.g. 1g20s34c (leave empty to take bids)", 124, 30)
    local priceBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    priceBox:SetPoint("BOTTOMLEFT", 128, 10); priceBox:SetSize(150, 20); priceBox:SetAutoFocus(false); priceBox:SetMaxLetters(20)
    main.priceBox = priceBox
    local offerBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    offerBtn:SetSize(90, 24); offerBtn:SetPoint("BOTTOMRIGHT", -4, 8); offerBtn:SetText("Offer")
    offerBtn:SetScript("OnClick", function()
        if ns.AddOffer(draft.itemID, tonumber(qtyBox:GetText()) or 1, parsePrice(priceBox:GetText())) then
            draft.itemID = nil; SetItemButtonTexture(slot, nil); SetItemButtonCount(slot, 0)
            qtyBox:SetText("1"); priceBox:SetText("")
        end
    end)

    --==================== item database / harvest panel (Buy tab) ====================
    local dbPanel = CreateFrame("Frame", nil, main)
    dbPanel:SetPoint("BOTTOMLEFT", 16, 14); dbPanel:SetPoint("BOTTOMRIGHT", -16, 14); dbPanel:SetHeight(26)
    main.dbPanel = dbPanel
    local dbInfo = dbPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dbInfo:SetPoint("LEFT", 4, 0); dbInfo:SetText(""); main.dbInfo = dbInfo
    local dbBtn = CreateFrame("Button", nil, dbPanel, "UIPanelButtonTemplate")
    dbBtn:SetSize(160, 22); dbBtn:SetPoint("RIGHT", -4, 0); main.dbBtn = dbBtn
    dbBtn:SetScript("OnClick", function()
        if ns.ItemDB.IsHarvesting() then ns.ItemDB.StopHarvest() else ns.ItemDB.StartHarvest() end
        ns.UpdateDBPanel()
    end)
    dbBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Build full item database")
        GameTooltip:AddLine("A one-time background scan so search autocomplete knows every item in the game.", 1, 1, 1, true)
        GameTooltip:AddLine("Runs while you keep playing and resumes if you stop or log out. Only needed once.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("May cause brief lag or latency while it runs — you can stop it anytime.", 1, 0.5, 0.2, true)
        GameTooltip:Show()
    end)
    dbBtn:SetScript("OnLeave", GameTooltip_Hide)

    C_Timer.NewTicker(1, function()
        if main:IsShown() and currentTab == "BUY" then ns.UpdateDBPanel() end
    end)

    --==================== Sellers tab widgets (index + show) ====================
    local sellerFilterLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sellerFilterLabel:SetPoint("TOPLEFT", 16, -68); sellerFilterLabel:SetText("Find seller:"); sellerFilterLabel:Hide()
    main.sellerFilterLabel = sellerFilterLabel
    local sellerFilter = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    sellerFilter:SetPoint("TOPLEFT", 100, -64); sellerFilter:SetSize(225, 22); sellerFilter:SetAutoFocus(false); sellerFilter:Hide()
    -- typing narrows the already-received list instantly (client-side); pressing Enter
    -- sends a network query so sellers matching the name answer even if they weren't in
    -- the capped first scan. (Channel broadcasts are only allowed from a key/click, not a timer.)
    local function sellerFilterText() return (sellerFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower() end
    sellerFilter:SetScript("OnTextChanged", function(_, user) if user then ns.RefreshSellers() end end)
    sellerFilter:SetScript("OnEnterPressed", function(self)
        local t = sellerFilterText(); self:ClearFocus()
        if t == "" then ns.ScanSellers("")
        elseif #t >= ns.FILTER_MIN then ns.ScanSellers(t)
        else ns.Feedback(("Type at least %d letters of a name to search sellers."):format(ns.FILTER_MIN), true) end
    end)
    sellerFilter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); ns.ScanSellers("") end)
    main.sellerFilter = sellerFilter
    local sellerRefreshBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    sellerRefreshBtn:SetSize(80, 22); sellerRefreshBtn:SetPoint("TOPLEFT", 335, -64); sellerRefreshBtn:SetText("Refresh"); sellerRefreshBtn:Hide()
    sellerRefreshBtn:SetScript("OnClick", function()
        local t = sellerFilterText(); ns.ScanSellers((#t >= ns.FILTER_MIN) and t or "")
    end)
    main.sellerRefreshBtn = sellerRefreshBtn

    local sellerBackBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    sellerBackBtn:SetSize(70, 22); sellerBackBtn:SetPoint("TOPLEFT", 16, -64); sellerBackBtn:SetText("< Back"); sellerBackBtn:Hide()
    sellerBackBtn:SetScript("OnClick", function() ns.SetSellersView("INDEX") end)
    main.sellerBackBtn = sellerBackBtn
    local sellerHeader = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sellerHeader:SetPoint("LEFT", sellerBackBtn, "RIGHT", 12, 0); sellerHeader:SetText(""); sellerHeader:Hide()
    main.sellerHeader = sellerHeader

    --==================== My Items: online/offline toggle ====================
    local pauseLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pauseLabel:SetPoint("TOPLEFT", 16, -70); pauseLabel:SetText("Listings:"); pauseLabel:Hide()
    main.pauseLabel = pauseLabel
    local pauseBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    pauseBtn:SetSize(140, 22); pauseBtn:SetPoint("TOPLEFT", 70, -66); pauseBtn:Hide()
    pauseBtn:SetScript("OnClick", function() ns.ToggleListings() end)
    pauseBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        if GuildFoundMarketCharDB.paused then
            GameTooltip:AddLine("Listings paused")
            GameTooltip:AddLine("You don't answer searches and don't show up to other sellers. Your items are kept.", 1, 1, 1, true)
            GameTooltip:AddLine("Click to go back online.", 0.7, 0.7, 0.7, true)
        else
            GameTooltip:AddLine("Listings online")
            GameTooltip:AddLine("Pause this while raiding or doing PvP — your items stay listed but stop answering, nothing to clear.", 1, 1, 1, true)
            GameTooltip:AddLine("Click to go offline.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end)
    pauseBtn:SetScript("OnLeave", GameTooltip_Hide)
    main.pauseBtn = pauseBtn

    --==================== Help tab ====================
    local helpPanel = CreateFrame("Frame", nil, main)
    helpPanel:SetPoint("TOPLEFT", 24, -66); helpPanel:SetPoint("BOTTOMRIGHT", -24, 16); helpPanel:Hide()
    local helpText = helpPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    helpText:SetPoint("TOPLEFT"); helpText:SetPoint("TOPRIGHT")
    helpText:SetJustifyH("LEFT"); helpText:SetJustifyV("TOP"); helpText:SetSpacing(2)
    helpText:SetText(table.concat({
        "|cffff4040» FIRST TIME — open the Buy tab and click |r|cffffd100Build full DB|r|cffff4040 «|r",
        "|cffffffffRequired before you can search:|r until the database is built, autocomplete can't find items you don't already own. It's a safe one-time background scan that resumes if you stop.",
        " ",
        "|cff00ff96Guild Found Market|r is a private, live marketplace for your guild confederation — only sellers who are |cffffffffonline right now|r answer.",
        " ",
        "|cffffd100Buy|r  — find an item",
        "Type a name (or shift-click an item link) and pick it. Online sellers are listed cheapest first.",
        "• |cffffffffLeft-click|r a seller — open their full list of items.",
        "• |cffffffffRight-click|r a seller — whisper them about this item.",
        " ",
        "|cffffd100Sellers|r  — browse who's online",
        "Click a seller to see everything they sell. On one of their items:",
        "• |cffffffffCtrl-click|r — search that item to find who else is selling it.",
        "• |cffffffffRight-click|r — whisper the seller, pre-filled with the item and price.",
        " ",
        "|cffffd100My Items|r  — what you sell",
        "Add your items; your client answers searches automatically — no pop-ups.",
        "• |cffffffffOnline / Offline|r — pause answering while you raid or PvP. Your items are kept.",
        " ",
        "|cffffd100Opening & minimap|r",
        "Open with |cffffffff/gfm|r or |cffffffff/market|r, or the minimap button. Toggle the minimap icon with |cffffffff/gfm minimap|r.",
    }, "\n"))
    main.helpPanel = helpPanel

    ns.SelectTab("BUY")
    main:Hide()
end

function ns.UpdatePauseButton()
    if not main or not main.pauseBtn then return end
    if GuildFoundMarketCharDB.paused then
        main.pauseBtn:SetText("|cffff5555Offline (paused)|r")
    else
        main.pauseBtn:SetText("|cff40ff40Online|r")
    end
end

function ns.ToggleListings()
    GuildFoundMarketCharDB.paused = not GuildFoundMarketCharDB.paused
    ns.UpdatePauseButton()
    if currentTab == "MINE" then ns.RefreshMine() end
    ns.Feedback(GuildFoundMarketCharDB.paused
        and "Listings paused — you won't answer searches until you go online."
        or "Listings online — you're answering searches again.", false)
end

function ns.UpdateDBPanel()
    if not main or not main.dbInfo then return end
    main.dbInfo:SetText(("Item database: %d items"):format(ns.ItemDB.Count()))
    if ns.ItemDB.IsHarvesting() then
        local cur, max = ns.ItemDB.HarvestProgress()
        main.dbBtn:SetText(("Stop (%d%%)"):format(math.floor(cur / max * 100)))
    else
        main.dbBtn:SetText("Build full DB")
    end
end

--========================================================================
-- tab switching
--========================================================================
function ns.SelectTab(tab, goSeller, goLoc)
    if not main then return end
    currentTab = tab
    for _, b in ipairs(tabButtons) do
        local on = (b.tab == tab)
        b.sel:SetShown(on)
        b.text:SetTextColor(on and 1 or 1, on and 0.82 or 1, on and 0 or 1)
    end
    local buy     = (tab == "BUY")
    local mine    = (tab == "MINE")
    local sellers = (tab == "SELLERS")
    local help    = (tab == "HELP")
    main.searchBox:SetShown(buy); main.searchLabel:SetShown(buy)
    main.ac:Hide()
    main.postPanel:SetShown(mine)
    main.dbPanel:SetShown(buy)
    if not sellers then   -- hide all seller widgets when on another tab
        main.sellerFilter:Hide(); main.sellerFilterLabel:Hide(); main.sellerRefreshBtn:Hide()
        main.sellerBackBtn:Hide(); main.sellerHeader:Hide()
    end
    main.pauseBtn:SetShown(mine); main.pauseLabel:SetShown(mine)
    main.helpPanel:SetShown(help)
    main.scroll:SetShown(not help)
    if mine then ns.UpdatePauseButton() end
    if buy then ns.UpdateDBPanel() end
    FauxScrollFrame_SetOffset(main.scroll, 0); main.scroll:SetVerticalScroll(0)
    main.status:SetText("")
    if buy then
        main.h1:SetText("Seller"); main.h2:SetText("Qty"); main.h3:SetText("Price/unit"); main.h4:SetText("Location")
        ns.RefreshBuy()
    elseif sellers then
        main.sellerFilter:SetText("")    -- fresh entry: clear any leftover name filter
        if goSeller then
            ns.SetSellersView("SHOW")    -- jump straight to one seller (e.g. from a Buy result)
            ns.OpenSeller(goSeller, goLoc)
            ns.ScanSellers("")           -- also populate the index so "< Back" has the full list
        else
            ns.SetSellersView("INDEX")   -- sets its own headers + refresh
            ns.ScanSellers("")           -- auto-scan on entering (driven by the tab click = hardware event)
        end
    elseif help then
        main.h1:SetText(""); main.h2:SetText(""); main.h3:SetText(""); main.h4:SetText("")
        wipe(view); renderRows()
    else
        main.h1:SetText("Item"); main.h2:SetText("Qty"); main.h3:SetText("Price/unit"); main.h4:SetText("")
        ns.RefreshMine()
    end
end

--========================================================================
-- toggle
--========================================================================
function ns.ToggleUI()
    if not main then CreateUI() end
    if main:IsShown() then
        main:Hide()
    else
        main:Show()
        if ns.RefreshConfig then ns.RefreshConfig() end
        ns.SelectTab(currentTab)
        if not ns.channelName then
            ns.Feedback("Not in a Guild Found confederation — open guild (J) once, then /gfm again.", true)
        end
    end
end
