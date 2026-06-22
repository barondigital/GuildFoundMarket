local ADDON, ns = ...

local ROWS, ROW_H = 10, 24
local playerName = UnitName("player")

local main
local rows = {}
local view = {}            -- current rows being displayed (buy results or my offers)
local currentTab = "BUY"
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
        print("|cff00ff96GFC|r: " .. msg)
    end
end

--========================================================================
-- minimap button
--========================================================================
local minimapBtn
function ns.CreateMinimapButton()
    if minimapBtn then return end
    GuildFoundCraigslistDB.minimapAngle = GuildFoundCraigslistDB.minimapAngle or 220
    local b = CreateFrame("Button", "GuildFoundCraigslistMinimapButton", Minimap)
    b:SetSize(31, 31); b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp"); b:RegisterForDrag("LeftButton")
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20); icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01"); icon:SetPoint("TOPLEFT", 7, -6)
    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53); overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); overlay:SetPoint("TOPLEFT")
    local function updatePos()
        local angle = math.rad(GuildFoundCraigslistDB.minimapAngle or 220)
        b:ClearAllPoints(); b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
    end
    local function onDrag()
        local mx, my = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        local px, py = GetCursorPosition(); px, py = px / scale, py / scale
        GuildFoundCraigslistDB.minimapAngle = math.deg(math.atan2(py - my, px - mx)) % 360
        updatePos()
    end
    b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDrag) end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnClick", function() ns.ToggleUI() end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Guild Found Craigslist")
        GameTooltip:AddLine("Click to open / close", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    minimapBtn = b; updatePos()
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
    r.c1.tip = "Click to whisper " .. d.seller
    r.c1:SetScript("OnClick", function() ChatFrame_SendTell(d.seller) end)
    r.c2:SetText(d.qty)
    r.c3:SetText(d.price > 0 and GetCoinTextureString(d.price) or "|cffffd100Bid|r")
    r.c4:SetText(d.loc or ""); r.c4:Show()
    r.x:Hide()
    r.itemID = nil
end

local function formatMineRow(r, d)
    r.icon:SetTexture(GetItemIcon(d.id)); r.icon:Show()
    r.c1.fs:SetText(itemLink(d.id) or itemName(d.id))
    r.c1:EnableMouse(false)
    r.c1.tip = nil
    r.c1:SetScript("OnClick", nil)
    r.c2:SetText(d.qty)
    r.c3:SetText(d.price > 0 and GetCoinTextureString(d.price) or "|cffffd100Bid|r")
    r.c4:SetText(""); r.c4:Hide()
    r.x:Show()
    r.x:SetScript("OnClick", function() ns.RemoveOffer(d.id) end)
    r.itemID = d.id
end

local function renderRows()
    local offset = FauxScrollFrame_GetOffset(main.scroll)
    FauxScrollFrame_Update(main.scroll, #view, ROWS, ROW_H)
    for i = 1, ROWS do
        local r = rows[i]
        local d = view[offset + i]
        if d then
            if currentTab == "BUY" then formatBuyRow(r, d) else formatMineRow(r, d) end
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
    for id, o in pairs(GuildFoundCraigslistCharDB.offers) do
        view[#view + 1] = { id = id, qty = o.qty, price = o.price }
    end
    table.sort(view, function(a, b) return itemName(a.id) < itemName(b.id) end)
    renderRows()
end

--========================================================================
-- build the window
--========================================================================
local function CreateUI()
    main = CreateFrame("Frame", "GuildFoundCraigslistFrame", UIParent, "BackdropTemplate")
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
    table.insert(UISpecialFrames, "GuildFoundCraigslistFrame")

    local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16); title:SetText("Guild Found |cff00ff96Craigslist|r")
    CreateFrame("Button", nil, main, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -8, -8)

    -- tabs
    local TABS = { { tab = "BUY", label = "Buy", w = 70 }, { tab = "MINE", label = "My Items", w = 90 } }
    local tx = 20
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, main)
        b:SetSize(t.w, 24); b:SetPoint("TOPLEFT", tx, -36); tx = tx + t.w + 8; b.tab = t.tab
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
                    if cq then q = cq; m.q = cq; GuildFoundCraigslistDB.quals[m.id] = cq end
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
    local scroll = CreateFrame("ScrollFrame", "GuildFoundCraigslistScroll", main, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -112); scroll:SetSize(520, ROWS * ROW_H)
    scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, ROW_H, renderRows) end)
    main.scroll = scroll

    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, main); r:SetSize(520, ROW_H)
        if i == 1 then r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        else r:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0) end
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 4, 0)
        r.c1 = CreateFrame("Button", nil, r); r.c1:SetPoint("LEFT", 26, 0); r.c1:SetSize(185, ROW_H); r.c1:RegisterForClicks("LeftButtonUp")
        r.c1.fs = r.c1:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c1.fs:SetAllPoints(); r.c1.fs:SetJustifyH("LEFT")
        local c1hl = r.c1:CreateTexture(nil, "HIGHLIGHT"); c1hl:SetAllPoints(); c1hl:SetColorTexture(1, 1, 1, 0.12)
        r.c1:SetScript("OnEnter", function(self) if self.tip then GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT"); GameTooltip:SetText(self.tip, 1, 1, 1); GameTooltip:Show() end end)
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

    local slot = CreateFrame("Button", "GuildFoundCraigslistSlot", panel, "ItemButtonTemplate")
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

    ns.SelectTab("BUY")
    main:Hide()
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
function ns.SelectTab(tab)
    if not main then return end
    currentTab = tab
    for _, b in ipairs(tabButtons) do
        local on = (b.tab == tab)
        b.sel:SetShown(on)
        b.text:SetTextColor(on and 1 or 1, on and 0.82 or 1, on and 0 or 1)
    end
    local buy = (tab == "BUY")
    main.searchBox:SetShown(buy); main.searchLabel:SetShown(buy)
    main.ac:Hide()
    main.postPanel:SetShown(not buy)
    main.dbPanel:SetShown(buy)
    if buy then ns.UpdateDBPanel() end
    -- headers per tab
    if buy then
        main.h1:SetText("Seller"); main.h2:SetText("Qty"); main.h3:SetText("Price/unit"); main.h4:SetText("Location")
    else
        main.h1:SetText("Item"); main.h2:SetText("Qty"); main.h3:SetText("Price/unit"); main.h4:SetText("")
    end
    FauxScrollFrame_SetOffset(main.scroll, 0); main.scroll:SetVerticalScroll(0)
    main.status:SetText("")
    if buy then ns.RefreshBuy() else ns.RefreshMine() end
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
            ns.Feedback("Not in a Guild Found confederation — open guild (J) once, then /gfc again.", true)
        end
    end
end
