local ADDON, ns = ...

local ROWS, ROW_H = 10, 24
local playerName = UnitName("player")

local main
local rows = {}
local view = {}            -- current rows being displayed (buy results / my offers / sellers)
local currentTab = "BUY"
local sellersView = "INDEX"  -- within the Sellers tab: "INDEX" (list) or "SHOW" (one seller)
local sellerSort = { col = "count", asc = false }  -- Sellers index sort: col "name"|"count", direction (default: most items first)
local tabButtons = {}
local draft = { itemID = nil }     -- item being composed in the My Items post panel
local selectedSearchID = nil

-- Buy tab has two sub-modes: item Search (existing) and category Browse (#3).
local buyMode = "BROWSE"   -- "SEARCH" | "BROWSE" (Browse is the default view)
local BROWSE_CAP = 150     -- max Browse rows shown; beyond it the user narrows by level range / filter
local browseSort = { col = "lvl", asc = false }   -- Browse results sort: "qual"|"lvl"|"price"; default level desc
local browseSel = { class = nil, sub = nil }      -- selected category (nil = none picked yet)
local browseExpanded = nil                        -- classID currently expanded in the sidebar (accordion)
local browseRows, browseView = {}, {}             -- the 6-column results table
local sideRows, sideView = {}, {}                 -- the category sidebar tree
local setBuyMode                                  -- forward declaration (defined with the other refreshers)

--========================================================================
-- helpers
--========================================================================
-- Parse a typed price to copper. Accepts BOTH notations regardless of the chosen format, so
-- switching format never breaks existing input:
--   coins:   "3g50s5c" (silver/copper clamped to 0-99)
--   decimal: "3" = 3g, "3.5" = 3g50s, "3.05" = 3g5s (two decimals = silver, no copper)
local function parsePrice(str)
    str = (str or ""):lower():gsub("%s+", "")
    if str == "" then return 0 end
    if str:match("^%d*%.?%d*$") and str:match("%d") then          -- a plain or decimal number = gold
        return math.floor((tonumber(str) or 0) * 100 + 0.5) * 100 -- round to silver, drop copper
    end
    local g = tonumber(str:match("(%d+)g")) or 0
    local s = math.min(99, tonumber(str:match("(%d+)s")) or 0)
    local c = math.min(99, tonumber(str:match("(%d+)c")) or 0)
    return g * 10000 + s * 100 + c
end

-- Inverse of parsePrice for the edit prefill, in the player's chosen format. 0 = "" (bids).
-- "currency" shows decimal gold with two decimals (3g50s -> "3.50"); copper is dropped there.
local function priceToStr(c)
    c = c or 0
    if c <= 0 then return "" end
    if ns.GetSetting("priceFormat") == "currency" then
        return string.format("%.2f", math.floor(c / 100) / 100)   -- copper-free, two decimals
    end
    local g, s, cc = math.floor(c / 10000), math.floor((c % 10000) / 100), c % 100
    return (g > 0 and (g .. "g") or "") .. (s > 0 and (s .. "s") or "") .. (cc > 0 and (cc .. "c") or "")
end

local function itemName(id)
    local name = GetItemInfo(id)
    return name or ("item:" .. id)
end

local function itemLink(id)
    return (select(2, GetItemInfo(id)))
end

-- Variant-aware item display (#7). A random-enchant item's suffix ("of the Bear") and
-- stats are fully determined by itemID + suffixID, so we reconstruct a display link from
-- them. suffix 0 = a plain item, so we fall through to the base itemID helpers.
local function variantString(id, suffix)
    if suffix and suffix ~= 0 then return ("item:%d:0:0:0:0:0:%d:0"):format(id, suffix) end
    return "item:" .. id
end
local function vName(id, suffix)
    if not suffix or suffix == 0 then return itemName(id) end
    return (GetItemInfo(variantString(id, suffix))) or itemName(id)
end
local function vLink(id, suffix)
    if not suffix or suffix == 0 then return itemLink(id) end
    return (select(2, GetItemInfo(variantString(id, suffix)))) or variantString(id, suffix)
end
-- The " of the Bear" remainder after the base name, for tagging Buy rows where the item
-- column is implied by the search. Empty when not a (yet-known) suffix variant.
local function suffixTag(id, suffix)
    if not suffix or suffix == 0 then return "" end
    local full, base = vName(id, suffix), itemName(id)
    if full and base and full ~= base and full:sub(1, #base) == base then return full:sub(#base + 1) end
    return ""
end

-- Category tree for the Browse sidebar (#3). Built from GetItemClassInfo /
-- GetItemSubClassInfo, whose IDs match GetItemInfo's classID/subClassID, so a query
-- resolves correctly seller-side. Obsolete and non-tradeable classes are skipped.
local SKIP_CLASS = { [3] = true, [8] = true, [10] = true, [12] = true, [13] = true, [14] = true }
-- top-level order mirrors the Auction House browse list, not the numeric class IDs
local CLASS_ORDER = { 2, 4, 1, 0, 7, 6, 11, 9, 5, 15 }  -- Weapon, Armor, Container, Consumable, Trade Goods, Projectile, Quiver, Recipe, Reagent, Miscellaneous
local browseCats
local function buildCats()
    if browseCats then return browseCats end
    browseCats = {}
    local function addClass(classID)
        if SKIP_CLASS[classID] then return end
        local cname = GetItemClassInfo(classID)
        if not cname or cname:find("OBSOLETE") then return end
        local subs = {}
        for subID = 0, 20 do
            local sname = GetItemSubClassInfo(classID, subID)
            if sname and sname ~= "" and not sname:find("OBSOLETE") then
                subs[#subs + 1] = { id = subID, name = sname }
            end
        end
        -- require real sub-categorisation: a class with one generic subclass (Consumable,
        -- Reagent, Junk) is too broad to browse usefully, so we drop it from the sidebar
        if #subs >= 2 then browseCats[#browseCats + 1] = { id = classID, name = cname, subs = subs } end
    end
    local seen = {}
    for _, classID in ipairs(CLASS_ORDER) do seen[classID] = true; addClass(classID) end
    for classID = 0, 19 do if not seen[classID] then addClass(classID) end end  -- any kept class not listed above, appended
    return browseCats
end

-- An item's quality (number) and required level, derived locally from the variant.
-- We use the required level (5th return), not item level, since that's what a buyer cares
-- about; it drives the Lvl column, the level-range filter and the level sort.
local function itemQualLevel(id, suffix)
    local _, _, quality, _, minLevel = GetItemInfo(variantString(id, suffix))
    return quality or 0, minLevel or 0
end
local function qualityRGB(quality)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
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
local function whisperItem(name, itemID, suffix, price)
    local link = (itemID and vLink(itemID, suffix)) or ("[" .. itemName(itemID) .. "]")
    local body = (price and price > 0) and (link .. "@" .. coinShort(price) .. " ") or (link .. " ")
    ChatFrame_OpenChat("/w " .. name .. " " .. body)
end

-- pick an item into the search box and fire a search (used by autocomplete + shift-click)
local function selectSearchItem(id, name)
    if not main then return end
    if setBuyMode and buyMode ~= "SEARCH" then setBuyMode("SEARCH") end   -- a picked search item always lands in the Search view
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
    if ns.dev and ns.Log and msg and msg ~= "" then ns.Log("feedback: " .. msg) end   -- mirror into the Debug sidebar in dev mode
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
        local function iconTooltip(tt)
            tt:AddLine("Guild Found Market")
            tt:AddLine("Left-click to open / close", 1, 1, 1)
            tt:AddLine("Right-click to toggle online / offline", 1, 1, 1)
        end
        minimapLDB = LDB:NewDataObject("GuildFoundMarket", {
            type = "launcher",
            icon = "Interface\\Icons\\INV_Misc_Coin_01",
            label = "Guild Found Market",
            OnClick = function(_, button)
                if button == "RightButton" then ns.ToggleListings()   -- listings online / offline (the icon dims when offline)
                else ns.ToggleUI() end                                -- open / close the window
            end,
            OnTooltipShow = iconTooltip,
        })
    end

    if not DBIcon:IsRegistered("GuildFoundMarket") then
        DBIcon:Register("GuildFoundMarket", minimapLDB, GuildFoundMarketDB.minimap)
    end
    ns.UpdateMinimapIcon()
end

-- Apply the minimap-button setting: keep LibDBIcon's own .hide field in sync (other code
-- and the lib both read it) and show/hide the live icon. Idempotent.
function ns.SetMinimapShown(on)
    GuildFoundMarketDB.minimap = GuildFoundMarketDB.minimap or {}
    GuildFoundMarketDB.minimap.hide = not on
    if DBIcon and DBIcon:IsRegistered("GuildFoundMarket") then
        if on then DBIcon:Show("GuildFoundMarket") else DBIcon:Hide("GuildFoundMarket") end
    end
end
ns.On("setting:minimapButton", ns.SetMinimapShown)

-- Grey + dim the minimap icon while listings are offline (paused), as a live status cue.
-- Set it straight on the button (most reliable) and also stash iconR/G/B so it survives
-- LibDBIcon refreshes.
function ns.UpdateMinimapIcon()
    if not minimapLDB then return end
    local paused = ns.IsPaused()
    local v = paused and 0.4 or 1
    minimapLDB.iconR, minimapLDB.iconG, minimapLDB.iconB = v, v, v
    local btn = DBIcon and DBIcon.GetMinimapButton and DBIcon:GetMinimapButton("GuildFoundMarket")
    if btn and btn.icon then
        btn.icon:SetVertexColor(v, v, v)
        if btn.icon.SetDesaturated then btn.icon:SetDesaturated(paused) end
    end
end

--========================================================================
-- row rendering (shared between Buy results and My Items)
--========================================================================
-- Price cell text: a coin string, or a gold "Bid" tag when there is no fixed price.
local function priceText(price)
    return (price or 0) > 0 and GetCoinTextureString(price) or "|cffffd100Bid|r"
end

-- Reset a pooled row to a known baseline before a formatter fills in only its differences.
-- Rows are shared across the Buy / My Items / Sellers tabs, so anything a previous row set
-- (scripts, colour, the trailing buttons, the hover link) must be cleared here.
local function resetRow(r)
    r.icon:Hide()
    r.c1:EnableMouse(true)
    r.c1.fs:SetTextColor(1, 1, 1)
    r.c1.tip = nil
    r.c1.itemID = nil; r.c1.itemLink = nil
    r.c1:SetScript("OnClick", nil)
    r.c2:SetText(""); r.c3:SetText("")
    r.c4:SetText(""); r.c4:Hide()
    r.x:Hide(); r.x:SetScript("OnClick", nil)
    r.edit:Hide(); r.edit:SetScript("OnClick", nil)
    r.itemID = nil
end

local function formatBuyRow(r, d)
    resetRow(r)
    -- every result is from an online seller (offline sellers can't respond); the item is
    -- implied by the search, so tag the row with the random-enchant suffix (if any)
    local tag = suffixTag(ns.search.itemID, d.suffix)
    tag = tag ~= "" and (" |cff888888" .. tag .. "|r") or ""
    if d.self then
        -- our own offer, injected locally so we can see our price rank (#6): no point
        -- whispering or browsing ourselves, so left-click jumps to My Items to adjust.
        r.c1.fs:SetText((ns.IsPaused() and (d.seller .. " (you, paused)") or (d.seller .. " (you)")) .. tag)
        r.c1.fs:SetTextColor(1, 0.82, 0)   -- gold: stands out as your own row
        r.c1.tip = "Your offer: click to open My Items and adjust your price"
        r.c1:SetScript("OnClick", function(_, button)
            if button ~= "RightButton" then ns.SelectTab("MINE") end
        end)
    else
        r.c1.fs:SetText(d.seller .. tag)
        r.c1.tip = "Click for items · right-click to whisper"
        r.c1:SetScript("OnClick", function(_, button)
            if button == "RightButton" then whisperItem(d.seller, ns.search.itemID, d.suffix, d.price)
            else ns.SelectTab("SELLERS", d.seller, d.loc) end
        end)
    end
    r.c2:SetText(d.qty or 0)
    r.c3:SetText(priceText(d.price))
    r.c4:SetText(d.loc or ""); r.c4:Show()
    -- hover shows the exact variant (stats), so use the reconstructed link, not the base ID
    r.c1.itemLink = vLink(ns.search.itemID, d.suffix)
end

local function formatMineRow(r, d)
    resetRow(r)
    r.icon:SetTexture(GetItemIcon(d.id)); r.icon:Show()
    r.c1.fs:SetText(vLink(d.id, d.suffix) or vName(d.id, d.suffix))
    r.c1.tip = "Ctrl-click to find who else sells this · shift-click to drop into your open chat message"
    r.c1.itemLink = vLink(d.id, d.suffix)
    r.c1:SetScript("OnClick", function()
        if IsModifiedClick("CHATLINK") then
            local link = vLink(d.id, d.suffix)
            if link then ChatEdit_InsertLink(link) end
        elseif IsControlKeyDown() then ns.SelectTab("BUY"); selectSearchItem(d.id) end
    end)
    r.c2:SetText(d.qty or 0)
    r.c3:SetText(priceText(d.price))
    r.x:Show(); r.x:SetScript("OnClick", function() ns.RemoveOffer(d.key) end)
    r.edit:Show(); r.edit:SetScript("OnClick", function() ns.LoadOfferForEdit(d.key) end)
    r.itemID = d.id
end

-- Sellers tab: either an index row (a seller) or, in the show view, one of their items.
local function formatSellerRow(r, d)
    resetRow(r)
    if d.kind == "seller" then
        r.c1.fs:SetText(d.seller)
        r.c1.fs:SetTextColor(0.4, 1, 0.4)        -- green: online right now
        r.c1.tip = "Click to see " .. d.seller .. "'s items"
        r.c1:SetScript("OnClick", function(_, button)
            if button ~= "RightButton" then ns.OpenSeller(d.seller); ns.SetSellersView("SHOW") end
        end)
        r.c2:SetText(d.count or 0)
        r.c4:SetText(d.loc or ""); r.c4:Show()
    else
        r.icon:SetTexture(GetItemIcon(d.id)); r.icon:Show()
        r.c1.fs:SetText(vLink(d.id, d.suffix) or vName(d.id, d.suffix))
        r.c1.tip = "Ctrl-click to compare · right-click to whisper"
        r.c1:SetScript("OnClick", function(_, button)
            if button == "RightButton" then whisperItem(d.seller, d.id, d.suffix, d.price)
            elseif IsControlKeyDown() then ns.SelectTab("BUY"); selectSearchItem(d.id) end
        end)
        r.c2:SetText(d.qty or 0)
        r.c3:SetText(priceText(d.price))
        r.c1.itemLink = vLink(d.id, d.suffix)
    end
end

-- Browse results row: Item (quality-coloured) | Qual swatch | Lvl | Qty | Price | Seller.
local function formatBrowseRow(r, d)
    local q, lvl = itemQualLevel(d.id, d.suffix)
    r.icon:SetTexture(GetItemIcon(d.id))
    r.c1.fs:SetText(vName(d.id, d.suffix))
    r.c1.fs:SetTextColor(qualityRGB(q))
    r.c1.itemLink = vLink(d.id, d.suffix)
    r.c1.tip = "Ctrl-click to find who else sells this · right-click to whisper"
    r.c1:SetScript("OnClick", function(_, button)
        if button == "RightButton" then whisperItem(d.seller, d.id, d.suffix, d.price)
        elseif IsControlKeyDown() then setBuyMode("SEARCH"); selectSearchItem(d.id) end
    end)
    r.lvl:SetText(lvl > 0 and lvl or "")
    r.qty:SetText(d.qty or 0)
    r.price:SetText(priceText(d.price))
    r.seller.fs:SetText(d.self and ("|cffffd100" .. d.seller .. " (you)|r") or d.seller)
    if d.self then r.seller:SetScript("OnClick", function() ns.SelectTab("MINE") end)
    else r.seller:SetScript("OnClick", function() ns.SelectTab("SELLERS", d.seller) end) end
end

-- Sidebar tree row: a class header (click to expand/collapse) or a subclass (click to query).
local function formatSidebarRow(r, d)
    r.fs:ClearAllPoints(); r.fs:SetPoint("LEFT", d.indent, 0); r.fs:SetPoint("RIGHT", -2, 0)
    r.fs:SetText(d.label)
    r.fs:SetTextColor(d.r, d.g, d.b)
    r.sel:SetShown(d.selected)
    r:SetScript("OnClick", d.onClick)
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

-- Shared refresh lifecycle: bail unless this tab/subview is the one on screen, then wipe
-- the row buffer, let `build` fill and sort it, render, and let `status` set the footer.
-- Centralizing the order means a refresh can never forget to wipe or render.
local function refreshList(visible, build, status)
    if not main or not main:IsShown() or not visible then return end
    wipe(view)
    build()
    renderRows()
    if status then status() end
end

--========================================================================
-- refresh: Buy results
--========================================================================
function ns.RefreshBuy()
    refreshList(currentTab == "BUY" and buyMode == "SEARCH", function()
        -- results are keyed by seller+variant; a seller can return several random-enchant variants
        for _, o in pairs(ns.search.results) do
            view[#view + 1] = { seller = o.seller, suffix = o.suffix or 0, qty = o.qty, price = o.price, loc = o.loc, self = o.self }
        end
        table.sort(view, function(a, b)
            -- real prices ascending; "bid" offers (price 0) sink to the bottom
            local pa = (a.price or 0) > 0 and a.price or math.huge
            local pb = (b.price or 0) > 0 and b.price or math.huge
            if pa ~= pb then return pa < pb end
            if a.seller ~= b.seller then return a.seller < b.seller end
            return (a.suffix or 0) < (b.suffix or 0)
        end)
    end, function()
        if not ns.search.itemID then
            main.status:SetText("")
        elseif ns.search.active then
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText("Searching " .. itemName(ns.search.itemID) .. " ...")
        elseif #view == 0 then
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText("No online sellers for " .. itemName(ns.search.itemID) .. ".")
        else
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText(("%d offer(s), cheapest first."):format(#view))
        end
    end)
end

--========================================================================
-- refresh: My Items
--========================================================================
function ns.RefreshMine()
    refreshList(currentTab == "MINE", function()
        for key, o in pairs(GuildFoundMarketCharDB.offers) do
            view[#view + 1] = { id = o.id or tonumber(key), suffix = o.suffix or 0, qty = o.qty, price = o.price, key = key }
        end
        table.sort(view, function(a, b) return vName(a.id, a.suffix) < vName(b.id, b.suffix) end)
    end, function()
        if GuildFoundMarketCharDB.paused then
            main.status:SetTextColor(1, 0.6, 0.2)
            main.status:SetText("Listings paused: not answering searches. Click \"Offline\" to go back online.")
        elseif #view == 0 then
            main.status:SetTextColor(0.7, 0.7, 0.7)
            main.status:SetText("No items listed yet: pick one up and click the slot below to offer it.")
        else
            main.status:SetText("")
        end
    end)
end

--========================================================================
-- refresh: Sellers index (list of online sellers, client-side name filter)
--========================================================================
function ns.RefreshSellers()
    local filter   -- shared by build (to match names) and status (to report the filter)
    refreshList(currentTab == "SELLERS" and sellersView == "INDEX", function()
        filter = (main.sellerFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        local names = {}
        for s in pairs(ns.sellers.results) do
            if filter == "" or s:lower():find(filter, 1, true) then names[#names + 1] = s end
        end
        local asc = sellerSort.asc
        if sellerSort.col == "count" then
            table.sort(names, function(a, b)
                local ca, cb = ns.sellers.results[a].count or 0, ns.sellers.results[b].count or 0
                if ca ~= cb then return asc and ca < cb or (not asc and ca > cb) end
                return a < b   -- stable tiebreak: name ascending
            end)
        else
            table.sort(names, function(a, b) return asc and a < b or (not asc and a > b) end)
        end
        -- arrow on the active column (Blizzard arrow textures; the font lacks the glyphs)
        local up   = " |TInterface\\Buttons\\Arrow-Up-Up:12|t"
        local down = " |TInterface\\Buttons\\Arrow-Down-Up:12|t"
        main.h1:SetText("Seller" .. (sellerSort.col == "name"  and (asc and up or down) or ""))
        main.h2:SetText("Items"  .. (sellerSort.col == "count" and (asc and up or down) or ""))
        for _, s in ipairs(names) do
            local rec = ns.sellers.results[s]
            view[#view + 1] = { kind = "seller", seller = s, count = rec.count, loc = rec.loc }
        end
    end, function()
        main.status:SetTextColor(0.7, 0.7, 0.7)
        local sf = ns.sellers.filter
        if ns.sellers.scanning then
            main.status:SetText((sf and sf ~= "") and ("Searching sellers matching \"" .. sf .. "\" ...")
                or "Scanning your confederation for online sellers ...")
        elseif next(ns.sellers.results) == nil then
            main.status:SetText((sf and sf ~= "") and ("No online seller matches \"" .. sf .. "\".")
                or "No online sellers right now.")
        elseif #view == 0 then
            main.status:SetText("No seller matches \"" .. (filter or "") .. "\".")
        elseif ns.sellers.capped then
            main.status:SetText(("Showing %d online sellers (capped); type %d+ letters of a name and press Enter to find a specific one."):format(#view, ns.FILTER_MIN))
        else
            main.status:SetText(("%d online seller(s): click one to see their items."):format(#view))
        end
    end)
end

--========================================================================
-- refresh: Sellers show view (one seller's catalog, fetched lazily)
--========================================================================
function ns.RefreshSellerCatalog()
    local cat = ns.sellers.catalog
    refreshList(currentTab == "SELLERS" and sellersView == "SHOW", function()
        if cat then
            main.sellerHeader:SetText(cat.seller .. ((cat.loc and cat.loc ~= "") and ("  |cff888888" .. cat.loc .. "|r") or ""))
            local items = {}
            for _, it in pairs(cat.items) do items[#items + 1] = it end
            table.sort(items, function(a, b) return vName(a.id, a.suffix) < vName(b.id, b.suffix) end)
            for _, it in ipairs(items) do
                view[#view + 1] = { kind = "item", id = it.id, suffix = it.suffix or 0, qty = it.qty, price = it.price, seller = cat.seller }
            end
        end
    end, function()
        main.status:SetTextColor(0.7, 0.7, 0.7)
        if cat and cat.loading then
            main.status:SetText("Loading " .. cat.seller .. "'s items ...")
        elseif cat and next(cat.items) == nil then
            main.status:SetText(cat.seller .. " has nothing listed right now.")
        elseif cat then
            main.status:SetText(("%d item(s): click one to whisper %s."):format(#view, cat.seller))
        end
    end)
end

-- Switch between the seller index and a single seller's catalog.
function ns.SetSellersView(v)
    if not main then return end
    sellersView = v
    local index = (v == "INDEX")
    main.sellerFilter:SetShown(index); main.sellerFilterLabel:SetShown(index); main.sellerRefreshBtn:SetShown(index)
    main.sellerBackBtn:SetShown(not index); main.sellerHeader:SetShown(not index)
    main.sortName:SetShown(index); main.sortCount:SetShown(index)
    if index then
        main.h1:SetText("Seller"); main.h2:SetText("Items"); main.h3:SetText(""); main.h4:SetText("Location")
    else
        main.h1:SetText("Item"); main.h2:SetText("Qty"); main.h3:SetText("Price/unit"); main.h4:SetText("")
    end
    wipe(view)   -- avoid feeding the other view's stale rows to the formatter on scroll reset
    FauxScrollFrame_SetOffset(main.scroll, 0); main.scroll:SetVerticalScroll(0)
    if index then ns.RefreshSellers() else ns.RefreshSellerCatalog() end
end

--========================================================================
-- refresh: Browse (category) results + the category sidebar tree
--========================================================================
local SIDE_ROWS, SIDE_ROW_H = 22, 16

local function renderBrowseRows()
    local cur = FauxScrollFrame_GetOffset(main.browseScroll)
    local offset = math.min(cur, math.max(0, #browseView - ROWS))   -- clamp when the list shrinks
    FauxScrollFrame_Update(main.browseScroll, #browseView, ROWS, ROW_H)
    if offset ~= cur then FauxScrollFrame_SetOffset(main.browseScroll, offset); main.browseScroll:SetVerticalScroll(offset * ROW_H) end
    for i = 1, ROWS do
        local r = browseRows[i]
        local d = browseView[offset + i]
        if d then formatBrowseRow(r, d); r:Show() else r:Hide() end
    end
end

local function renderSidebarRows()
    local cur = FauxScrollFrame_GetOffset(main.sideScroll)
    local offset = math.min(cur, math.max(0, #sideView - SIDE_ROWS))   -- keep the top reachable when the tree shrinks
    FauxScrollFrame_Update(main.sideScroll, #sideView, SIDE_ROWS, SIDE_ROW_H)
    if offset ~= cur then FauxScrollFrame_SetOffset(main.sideScroll, offset); main.sideScroll:SetVerticalScroll(offset * SIDE_ROW_H) end
    for i = 1, SIDE_ROWS do
        local r = sideRows[i]
        local d = sideView[offset + i]
        if d then formatSidebarRow(r, d); r:Show() else r:Hide() end
    end
end

local function updateBrowseHeaders()
    local up   = " |TInterface\\Buttons\\Arrow-Up-Up:12|t"
    local down = " |TInterface\\Buttons\\Arrow-Down-Up:12|t"
    local function arr(col) return (browseSort.col == col) and (browseSort.asc and up or down) or "" end
    main.bhItem:SetText("Item" .. arr("qual"))
    main.bhLvl:SetText("Lvl" .. arr("lvl"))
    main.bhPrice:SetText("Price" .. arr("price"))
end

function ns.RefreshSidebar()
    if not main then return end
    wipe(sideView)
    for _, cls in ipairs(buildCats()) do
        local expanded = (browseExpanded == cls.id)
        sideView[#sideView + 1] = {
            label = (expanded and "- " or "+ ") .. cls.name, indent = 6, r = 1, g = 0.82, b = 0,
            onClick = function()
                if browseExpanded == cls.id then browseExpanded = nil else browseExpanded = cls.id end
                ns.RefreshSidebar()
            end,
        }
        if expanded then
            for _, sub in ipairs(cls.subs) do
                local sel = (browseSel.class == cls.id and browseSel.sub == sub.id)
                sideView[#sideView + 1] = {
                    label = sub.name, indent = 22, selected = sel,
                    r = sel and 1 or 0.85, g = sel and 0.82 or 0.85, b = sel and 0 or 0.85,
                    onClick = function()
                        browseSel.class, browseSel.sub = cls.id, sub.id
                        browseSel.label = cls.name .. " > " .. sub.name
                        ns.RefreshSidebar()
                        if ns.BrowseCategory then ns.BrowseCategory(cls.id, sub.id) end
                    end,
                }
            end
        end
    end
    renderSidebarRows()
end

function ns.RefreshBrowse()
    if not main or not main:IsShown() or currentTab ~= "BUY" or buyMode ~= "BROWSE" then return end
    updateBrowseHeaders()
    wipe(browseView)
    local filter = (main.browseFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local lmin, lmax = tonumber(main.bLvlMin:GetText()), tonumber(main.bLvlMax:GetText())
    local total = 0
    for _, o in pairs(ns.browseResults) do
        -- quality + level once per offer, so the sort comparator stays cheap at scale
        local q, lvl = itemQualLevel(o.id, o.suffix)
        local nameOK = filter == "" or vName(o.id, o.suffix):lower():find(filter, 1, true)
        local lvlOK = (not lmin or lvl >= lmin) and (not lmax or lvl <= lmax)
        if nameOK and lvlOK then
            total = total + 1
            browseView[#browseView + 1] = { id = o.id, suffix = o.suffix, qty = o.qty, price = o.price, seller = o.seller, self = o.self, q = q, lvl = lvl }
        end
    end
    local col, asc = browseSort.col, browseSort.asc
    table.sort(browseView, function(a, b)
        local va, vb
        if col == "price" then
            va = (a.price or 0) > 0 and a.price or math.huge
            vb = (b.price or 0) > 0 and b.price or math.huge
        elseif col == "qual" then va = a.q; vb = b.q
        else va = a.lvl; vb = b.lvl end
        if va ~= vb then return asc and va < vb or (not asc and va > vb) end
        local na, nb = vName(a.id, a.suffix), vName(b.id, b.suffix)
        if na ~= nb then return na < nb end
        return a.seller < b.seller
    end)
    local capped = #browseView > BROWSE_CAP
    if capped then for i = #browseView, BROWSE_CAP + 1, -1 do browseView[i] = nil end end
    renderBrowseRows()
    main.status:SetTextColor(0.7, 0.7, 0.7)
    if not browseSel.sub then
        main.status:SetText("Pick a category on the left to browse offers.")
    elseif ns.browsing then
        main.status:SetText("Browsing " .. (browseSel.label or "") .. " ...")
    elseif total == 0 then
        main.status:SetText("No offers for " .. (browseSel.label or "this category") .. " right now.")
    elseif capped then
        main.status:SetTextColor(1, 0.7, 0.2)
        main.status:SetText(("Showing %d of %d. Narrow with the level range or filter."):format(BROWSE_CAP, total))
    else
        main.status:SetText(("%d offer(s) in %s."):format(total, browseSel.label or "this category"))
    end
end

-- Switch the Buy tab between item Search and category Browse.
setBuyMode = function(mode)
    buyMode = mode
    if not main then return end
    local browse = (mode == "BROWSE")
    if main.modeToggle then main.modeToggle:SetText(browse and "<< Search" or "Browse >>") end
    main.searchBox:SetShown(not browse); main.searchLabel:SetShown(not browse); main.ac:Hide()
    main.dbPanel:SetShown(not browse); main.scroll:SetShown(not browse)
    main.h1:SetShown(not browse); main.h2:SetShown(not browse); main.h3:SetShown(not browse); main.h4:SetShown(not browse)
    main.sidebar:SetShown(browse); main.browseScroll:SetShown(browse)
    main.browseFilter:SetShown(browse); main.browseFilterLabel:SetShown(browse)
    main.bLvlLabel:SetShown(browse); main.bLvlMin:SetShown(browse); main.bLvlTo:SetShown(browse); main.bLvlMax:SetShown(browse)
    main.bhItem:SetShown(browse); main.bhLvl:SetShown(browse)
    main.bhQty:SetShown(browse); main.bhPrice:SetShown(browse); main.bhSeller:SetShown(browse)
    main.bSortItem:SetShown(browse); main.bSortLvl:SetShown(browse); main.bSortPrice:SetShown(browse)
    if browse then
        for i = 1, ROWS do rows[i]:Hide() end          -- clear the search table's rows
        ns.RefreshSidebar(); ns.RefreshBrowse()
    else
        for i = 1, ROWS do browseRows[i]:Hide() end    -- clear the browse table's rows
        ns.RefreshBuy()
    end
end

--========================================================================
-- Coalesced refreshes: network replies (R/C/K) and item-info events can arrive
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
        if p.browse  and ns.RefreshBrowse         then ns.RefreshBrowse() end
    end)
end
function ns.RefreshBuySoon()           scheduleRefresh("buy") end
function ns.RefreshMineSoon()          scheduleRefresh("mine") end
function ns.RefreshSellersSoon()       scheduleRefresh("sellers") end
function ns.RefreshSellerCatalogSoon() scheduleRefresh("catalog") end
function ns.RefreshBrowseSoon()        scheduleRefresh("browse") end

function ns.UpdateVersionDisplay()
    if not main or not main.versionFS then return end
    main.versionFS:SetTextColor(0.5, 0.5, 0.5)
    if ns.updateAvailable then
        main.versionFS:SetText(("v%s  |cffff6060update to v%s|r"):format(ns.version or "?", ns.updateAvailable))
    else
        main.versionFS:SetText("v" .. (ns.version or "?"))
    end
end

--========================================================================
-- build the window
--========================================================================
local function buildWindow()
    main = CreateFrame("Frame", "GuildFoundMarketFrame", UIParent, "BackdropTemplate")
    main:SetSize(760, 470)
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
    -- debug-log toggle (opens the copyable sidebar; available to everyone for bug
    -- reports). Lives on the Help tab, top right, shown only there.
    local debugBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    debugBtn:SetSize(60, 20); debugBtn:SetPoint("TOPRIGHT", -30, -64); debugBtn:SetText("Debug"); debugBtn:Hide()
    debugBtn:SetScript("OnClick", function() if ns.ToggleDebug then ns.ToggleDebug() end end)
    debugBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Debug log")
        GameTooltip:AddLine("Open a copyable log of searches, sellers, and any throttling, to send a bug/latency report.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    debugBtn:SetScript("OnLeave", GameTooltip_Hide)
    main.debugBtn = debugBtn
end

local function buildTabs()
    -- tabs. Right-aligned tabs stack leftward in array order, so Help stays rightmost and
    -- the gear sits just left of it. A tab with an `icon` renders that texture instead of a label.
    local TABS = {
        { tab = "BUY", label = "Buy", w = 70 },
        { tab = "SELLERS", label = "Sellers", w = 80 },
        { tab = "MINE", label = "My Items", w = 90 },
        { tab = "HELP", label = "Help", w = 50, right = true },
        { tab = "OPTIONS", icon = "Interface\\Buttons\\UI-OptionsButton", w = 28, right = true, tip = "Options" },
    }
    local tx, rx = 20, -14
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, main)
        b:SetSize(t.w, 24)
        if t.right then b:SetPoint("TOPRIGHT", rx, -36); rx = rx - (t.w + 6) else b:SetPoint("TOPLEFT", tx, -36); tx = tx + t.w + 8 end
        b.tab = t.tab
        local sel = b:CreateTexture(nil, "BACKGROUND"); sel:SetAllPoints(); sel:SetColorTexture(1, 0.82, 0, 0.18); sel:Hide(); b.sel = sel
        local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.10)
        if t.icon then
            local tex = b:CreateTexture(nil, "ARTWORK"); tex:SetPoint("CENTER"); tex:SetSize(16, 16); tex:SetTexture(t.icon); b.icon = tex
            b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_BOTTOM"); GameTooltip:SetText(t.tip or "Options"); GameTooltip:Show() end)
            b:SetScript("OnLeave", GameTooltip_Hide)
        else
            local txt = b:CreateFontString(nil, "OVERLAY", "GameFontNormal"); txt:SetPoint("CENTER"); txt:SetText(t.label); b.text = txt
        end
        b:SetScript("OnClick", function(self) ns.SelectTab(self.tab) end)
        tabButtons[i] = b
    end
end

local function buildSearchBox()
    -- search box (Buy)
    local searchLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", 16, -68); searchLabel:SetText("Search item:")
    main.searchLabel = searchLabel
    local searchBox = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    searchBox:SetPoint("TOPLEFT", 100, -64); searchBox:SetSize(460, 22); searchBox:SetAutoFocus(false)
    main.searchBox = searchBox
end

local function buildAutocomplete()
    -- autocomplete dropdown
    local ac = CreateFrame("Frame", nil, main, "BackdropTemplate")
    ac:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    ac:SetBackdropColor(0, 0, 0, 0.92); ac:SetBackdropBorderColor(0.4, 0.4, 0.4)
    ac:SetPoint("TOPLEFT", main.searchBox, "BOTTOMLEFT", -2, -2); ac:SetWidth(464); ac:SetFrameStrata("DIALOG"); ac:Hide()
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
        local matches = ns.ItemDB.Match(main.searchBox:GetText())
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
    main.searchBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        local linkID = self:GetText():match("|Hitem:(%d+)")   -- shift-clicked item link
        if linkID then
            local id = tonumber(linkID)
            ns.ItemDB.Learn(id); selectItem(id, itemName(id)); return
        end
        selectedSearchID = nil; updateAutocomplete()
    end)
    main.searchBox:SetScript("OnEscapePressed", function(self) ac:Hide(); self:ClearFocus() end)
    main.searchBox:SetScript("OnArrowPressed", function(self, key)
        if not ac:IsShown() or not ac.matches then return end
        local n = #ac.matches
        if n == 0 then return end
        if key == "DOWN" then
            ac.sel = (ac.sel >= n) and 1 or ac.sel + 1; highlightAC()
        elseif key == "UP" then
            ac.sel = (ac.sel <= 1) and n or ac.sel - 1; highlightAC()
        end
    end)
    main.searchBox:SetScript("OnEnterPressed", function(self)
        if ac:IsShown() and ac.sel and ac.sel > 0 and ac.matches and ac.matches[ac.sel] then
            local m = ac.matches[ac.sel]; selectItem(m.id, m.name); return
        end
        local matches = ns.ItemDB.Match(self:GetText())
        if selectedSearchID then ns.Search(selectedSearchID); ac:Hide(); self:ClearFocus()
        elseif matches[1] then selectItem(matches[1].id, matches[1].name) end
    end)
    -- shift-click an item link/bag item into the search box
    main.searchBox:SetScript("OnReceiveDrag", function(self)
        local t, id = GetCursorInfo()
        if t == "item" and id then ClearCursor(); ns.ItemDB.Learn(id); selectItem(id, itemName(id)) end
    end)
end

local function buildHeaders()
    -- column headers
    local function header(x) local fs = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); fs:SetPoint("TOPLEFT", x, -96); return fs end
    main.h1 = header(28); main.h2 = header(322); main.h3 = header(384); main.h4 = header(524)

    -- clickable overlays on the Seller/Items headers to sort the Sellers index (#5);
    -- shown only in that view (see SetSellersView / SelectTab). Toggle asc/desc on repeat.
    local function sortHeaderBtn(target, col, w)
        local b = CreateFrame("Button", nil, main)
        b:SetPoint("LEFT", target, "LEFT", -2, 0); b:SetSize(w, 16)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:SetScript("OnClick", function()
            if sellerSort.col == col then sellerSort.asc = not sellerSort.asc
            else sellerSort.col = col; sellerSort.asc = true end
            ns.RefreshSellers()
        end)
        b:Hide()
        return b
    end
    main.sortName  = sortHeaderBtn(main.h1, "name", 150)
    main.sortCount = sortHeaderBtn(main.h2, "count", 48)
end

local function buildRows()
    -- scroll + rows
    local scroll = CreateFrame("ScrollFrame", "GuildFoundMarketScroll", main, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -112); scroll:SetSize(720, ROWS * ROW_H)
    scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, ROW_H, renderRows) end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #view - ROWS)
        local off = math.min(maxOff, math.max(0, FauxScrollFrame_GetOffset(self) - delta))
        FauxScrollFrame_SetOffset(self, off); self:SetVerticalScroll(off * ROW_H); renderRows()
    end)
    main.scroll = scroll

    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, main); r:SetSize(720, ROW_H)
        if i == 1 then r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        else r:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0) end
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 4, 0)
        r.c1 = CreateFrame("Button", nil, r); r.c1:SetPoint("LEFT", 26, 0); r.c1:SetSize(280, ROW_H); r.c1:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.c1.fs = r.c1:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c1.fs:SetAllPoints(); r.c1.fs:SetJustifyH("LEFT")
        local c1hl = r.c1:CreateTexture(nil, "HIGHLIGHT"); c1hl:SetAllPoints(); c1hl:SetColorTexture(1, 1, 1, 0.12)
        r.c1:SetScript("OnEnter", function(self)
            if self.itemLink or self.itemID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                -- a reconstructed variant link carries the real suffix stats; the bare
                -- itemID does not, so prefer the link when we have one
                if self.itemLink then GameTooltip:SetHyperlink(self.itemLink)
                else GameTooltip:SetItemByID(self.itemID) end
                if self.tip then GameTooltip:AddLine(self.tip, 0.6, 0.6, 0.6, true) end
                GameTooltip:Show()
            elseif self.tip then
                GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
                GameTooltip:SetText(self.tip, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        r.c1:SetScript("OnLeave", GameTooltip_Hide)
        r.c2 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c2:SetPoint("LEFT", 322, 0); r.c2:SetWidth(50); r.c2:SetJustifyH("LEFT")
        r.c3 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c3:SetPoint("LEFT", 382, 0); r.c3:SetWidth(130); r.c3:SetJustifyH("LEFT")
        r.c4 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c4:SetPoint("LEFT", 524, 0); r.c4:SetWidth(190); r.c4:SetJustifyH("LEFT")
        r.x = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.x:SetSize(24, 20); r.x:SetPoint("RIGHT", -2, 0); r.x:SetText("X")
        r.edit = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); r.edit:SetSize(40, 20); r.edit:SetPoint("RIGHT", r.x, "LEFT", -2, 0); r.edit:SetText("Edit"); r.edit:Hide()
        r:Hide(); rows[i] = r
    end
end

local function buildStatusVersion()
    -- status line
    local status = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    status:SetPoint("BOTTOMLEFT", 18, 96); status:SetPoint("BOTTOMRIGHT", -18, 96); status:SetJustifyH("CENTER"); status:SetText("")
    main.status = status

    -- installed version (top-right, just left of the close button); turns into an
    -- update notice when a newer one is seen
    local versionFS = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    versionFS:SetPoint("TOPRIGHT", -44, -16); versionFS:SetJustifyH("RIGHT")
    main.versionFS = versionFS
    ns.UpdateVersionDisplay()
end

local function buildBrowse()
    --==================== Browse (category) sub-view (#3) ====================
    -- toggle between item Search and category Browse on the Buy tab
    local modeToggle = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    modeToggle:SetSize(96, 22); modeToggle:SetPoint("TOPRIGHT", -16, -62); modeToggle:SetText("Browse >>")
    modeToggle:SetScript("OnClick", function() setBuyMode(buyMode == "BROWSE" and "SEARCH" or "BROWSE") end)
    modeToggle:Hide(); main.modeToggle = modeToggle

    -- left sidebar: a Category > Subclass tree
    local sidebar = CreateFrame("Frame", nil, main)
    sidebar:SetPoint("TOPLEFT", 12, -90); sidebar:SetPoint("BOTTOMLEFT", 12, 88); sidebar:SetWidth(172); sidebar:Hide()
    local sbg = sidebar:CreateTexture(nil, "BACKGROUND"); sbg:SetAllPoints(); sbg:SetColorTexture(0, 0, 0, 0.25)
    main.sidebar = sidebar
    local sideScroll = CreateFrame("ScrollFrame", "GuildFoundMarketSideScroll", sidebar, "FauxScrollFrameTemplate")
    sideScroll:SetPoint("TOPLEFT", 6, -6); sideScroll:SetPoint("BOTTOMRIGHT", -26, 6)
    sideScroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, SIDE_ROW_H, renderSidebarRows) end)
    sideScroll:EnableMouseWheel(true)
    sideScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #sideView - SIDE_ROWS)
        local off = math.min(maxOff, math.max(0, FauxScrollFrame_GetOffset(self) - delta))
        FauxScrollFrame_SetOffset(self, off); self:SetVerticalScroll(off * SIDE_ROW_H); renderSidebarRows()
    end)
    main.sideScroll = sideScroll
    for i = 1, SIDE_ROWS do
        local r = CreateFrame("Button", nil, sidebar); r:SetSize(150, SIDE_ROW_H)
        if i == 1 then r:SetPoint("TOPLEFT", sideScroll, "TOPLEFT", 0, 0)
        else r:SetPoint("TOPLEFT", sideRows[i - 1], "BOTTOMLEFT", 0, 0) end
        r:RegisterForClicks("LeftButtonUp")
        r.sel = r:CreateTexture(nil, "BACKGROUND"); r.sel:SetAllPoints(); r.sel:SetColorTexture(1, 0.82, 0, 0.18); r.sel:Hide()
        local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.10)
        r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.fs:SetPoint("LEFT", 6, 0); r.fs:SetJustifyH("LEFT")
        r:Hide(); sideRows[i] = r
    end

    -- results: client-side filter + sortable headers + the 6-column table
    local browseFilterLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    browseFilterLabel:SetPoint("TOPLEFT", 192, -68); browseFilterLabel:SetText("Filter:"); browseFilterLabel:Hide()
    main.browseFilterLabel = browseFilterLabel
    local browseFilter = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    browseFilter:SetPoint("TOPLEFT", 236, -64); browseFilter:SetSize(180, 22); browseFilter:SetAutoFocus(false); browseFilter:Hide()
    browseFilter:SetScript("OnTextChanged", function() if ns.RefreshBrowse then ns.RefreshBrowse() end end)
    browseFilter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    main.browseFilter = browseFilter

    -- level-range filter (required level, matching the Lvl column), to narrow a big category
    local function smallLabel(x, text) local fs = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); fs:SetPoint("TOPLEFT", x, -68); fs:SetText(text); fs:Hide(); return fs end
    local function lvlBox(x)
        local b = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
        b:SetPoint("TOPLEFT", x, -64); b:SetSize(34, 22); b:SetAutoFocus(false); b:SetNumeric(true); b:SetMaxLetters(2); b:Hide()
        b:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then return end   -- ignore our own SetText below (avoids recursion)
            local t = self:GetText()
            local clean = t
            if t ~= "" then
                local n = tonumber(t) or 0
                if n > 60 then n = 60 end
                clean = (n >= 1) and tostring(n) or ""   -- 1..60, strips leading zeros; 0/invalid clears
            end
            if clean ~= t then self:SetText(clean) end
            if ns.RefreshBrowse then ns.RefreshBrowse() end
        end)
        b:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
        return b
    end
    main.bLvlLabel = smallLabel(428, "Lvl")
    main.bLvlMin   = lvlBox(452)
    main.bLvlTo    = smallLabel(492, "to")
    main.bLvlMax   = lvlBox(510)

    local function bheader(x, text) local fs = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); fs:SetPoint("TOPLEFT", x, -96); fs:SetText(text); fs:Hide(); return fs end
    main.bhItem   = bheader(212, "Item")
    main.bhLvl    = bheader(428, "Lvl")
    main.bhQty    = bheader(462, "Qty")
    main.bhPrice  = bheader(496, "Price")
    main.bhSeller = bheader(606, "Seller")
    local function browseSortBtn(target, col, w)
        local b = CreateFrame("Button", nil, main)
        b:SetPoint("LEFT", target, "LEFT", -2, 0); b:SetSize(w, 16)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:SetScript("OnClick", function()
            if browseSort.col == col then browseSort.asc = not browseSort.asc
            else browseSort.col = col; browseSort.asc = (col == "price") end   -- price asc, qual/lvl desc by default
            ns.RefreshBrowse()
        end)
        b:Hide(); return b
    end
    main.bSortItem  = browseSortBtn(main.bhItem,  "qual",  120)   -- Item header sorts by quality (the name colour)
    main.bSortLvl   = browseSortBtn(main.bhLvl,   "lvl",   40)
    main.bSortPrice = browseSortBtn(main.bhPrice, "price", 56)

    local browseScroll = CreateFrame("ScrollFrame", "GuildFoundMarketBrowseScroll", main, "FauxScrollFrameTemplate")
    browseScroll:SetPoint("TOPLEFT", 192, -112); browseScroll:SetSize(542, ROWS * ROW_H)
    browseScroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, ROW_H, renderBrowseRows) end)
    browseScroll:EnableMouseWheel(true)
    browseScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #browseView - ROWS)
        local off = math.min(maxOff, math.max(0, FauxScrollFrame_GetOffset(self) - delta))
        FauxScrollFrame_SetOffset(self, off); self:SetVerticalScroll(off * ROW_H); renderBrowseRows()
    end)
    browseScroll:Hide(); main.browseScroll = browseScroll
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, main); r:SetSize(542, ROW_H)
        if i == 1 then r:SetPoint("TOPLEFT", browseScroll, "TOPLEFT", 0, 0)
        else r:SetPoint("TOPLEFT", browseRows[i - 1], "BOTTOMLEFT", 0, 0) end
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 0, 0)
        r.c1 = CreateFrame("Button", nil, r); r.c1:SetPoint("LEFT", 20, 0); r.c1:SetSize(212, ROW_H); r.c1:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.c1.fs = r.c1:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.c1.fs:SetAllPoints(); r.c1.fs:SetJustifyH("LEFT")
        local hl = r.c1:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.12)
        r.c1:SetScript("OnEnter", function(self)
            if self.itemLink then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.itemLink)
                if self.tip then GameTooltip:AddLine(self.tip, 0.6, 0.6, 0.6, true) end
                GameTooltip:Show()
            end
        end)
        r.c1:SetScript("OnLeave", GameTooltip_Hide)
        r.lvl    = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.lvl:SetPoint("LEFT", 236, 0); r.lvl:SetWidth(30); r.lvl:SetJustifyH("LEFT")
        r.qty    = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.qty:SetPoint("LEFT", 270, 0); r.qty:SetWidth(30); r.qty:SetJustifyH("LEFT")
        r.price  = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.price:SetPoint("LEFT", 304, 0); r.price:SetWidth(105); r.price:SetJustifyH("LEFT")
        r.seller = CreateFrame("Button", nil, r); r.seller:SetPoint("LEFT", 414, 0); r.seller:SetSize(126, ROW_H); r.seller:RegisterForClicks("LeftButtonUp")
        r.seller.fs = r.seller:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.seller.fs:SetAllPoints(); r.seller.fs:SetJustifyH("LEFT")
        local shl = r.seller:CreateTexture(nil, "HIGHLIGHT"); shl:SetAllPoints(); shl:SetColorTexture(1, 1, 1, 0.12)
        r:Hide(); browseRows[i] = r
    end
end

local function buildPostPanel()
    --==================== My Items post panel ====================
    local panel = CreateFrame("Frame", nil, main)
    panel:SetPoint("BOTTOMLEFT", 16, 14); panel:SetPoint("BOTTOMRIGHT", -16, 14); panel:SetHeight(74)
    main.postPanel = panel

    -- key of the listing being edited; nil = composing a brand-new offer
    local editingKey = nil

    local slot = CreateFrame("Button", "GuildFoundMarketSlot", panel, "ItemButtonTemplate")
    slot:SetPoint("LEFT", 4, 0); slot:SetSize(36, 36)
    local function setDraft()
        local t, id, link = GetCursorInfo()
        if t == "item" and id then
            ClearCursor()
            -- dropping a fresh item means "new offer", so leave any edit-in-progress
            editingKey = nil
            if main.offerBtn then main.offerBtn:SetText("Offer") end
            draft.itemID = id
            draft.link = link
            draft.suffix = 0   -- carry the random-enchant suffix so we list the right variant
            if link then
                local str = link:match("(item:[%-%d:]+)")
                if str then local p = { strsplit(":", str) }; draft.suffix = tonumber(p[8]) or 0 end
            end
            ns.ItemDB.Learn(id)
            SetItemButtonTexture(slot, GetItemIcon(id)); SetItemButtonCount(slot, GetItemCount(id, true))
        end
    end
    slot:SetScript("OnClick", setDraft); slot:SetScript("OnReceiveDrag", setDraft)
    slot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if draft.link then GameTooltip:SetHyperlink(draft.link)
        elseif draft.itemID then GameTooltip:SetItemByID(draft.itemID)
        else GameTooltip:SetText("Pick up an item and click here") end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", GameTooltip_Hide)
    main.slot = slot

    local function label(text, x, y) local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); fs:SetPoint("BOTTOMLEFT", x, y); fs:SetText(text); return fs end
    label("Qty", 52, 30)
    local qtyBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    qtyBox:SetPoint("BOTTOMLEFT", 56, 10); qtyBox:SetSize(44, 20); qtyBox:SetAutoFocus(false); qtyBox:SetNumeric(true); qtyBox:SetText("1")
    main.qtyBox = qtyBox
    local priceLabel = label("", 124, 30)
    local priceBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    priceBox:SetPoint("BOTTOMLEFT", 128, 10); priceBox:SetSize(150, 20); priceBox:SetAutoFocus(false); priceBox:SetMaxLetters(20)
    main.priceBox = priceBox

    -- the price field follows the chosen format: label text, a live input restriction for the
    -- decimal format, and reformatting the current value when the setting changes.
    local function applyPriceFormat()
        if ns.GetSetting("priceFormat") == "currency" then
            priceLabel:SetText("Price/unit: e.g. 3.50 = 3g50s (leave empty to take bids)")
        else
            priceLabel:SetText("Price/unit: e.g. 1g20s34c (leave empty to take bids)")
        end
        local cur = parsePrice(priceBox:GetText())
        if cur > 0 then priceBox:SetText(priceToStr(cur)) end
    end
    applyPriceFormat()
    ns.On("setting:priceFormat", applyPriceFormat)

    -- decimal format: restrict typing to digits + one dot + two decimals, and pad to two
    -- decimals (with a leading zero) when the field loses focus. The coin format is free text
    -- (silver/copper are clamped to 0-99 in parsePrice).
    priceBox:SetScript("OnTextChanged", function(self, user)
        if not user or ns.GetSetting("priceFormat") ~= "currency" then return end
        local t = self:GetText()
        local dot = t:find("%.")
        local intp = (dot and t:sub(1, dot - 1) or t):gsub("%D", "")
        local frac = dot and t:sub(dot + 1):gsub("%D", ""):sub(1, 2)
        local clean = intp .. (dot and ("." .. frac) or "")
        if clean ~= t then self:SetText(clean) end
    end)
    priceBox:SetScript("OnEditFocusLost", function(self)
        if ns.GetSetting("priceFormat") ~= "currency" then return end
        local n = tonumber(self:GetText())
        if n and n > 0 then self:SetText(string.format("%.2f", n)) end
    end)
    local offerBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    offerBtn:SetSize(90, 24); offerBtn:SetPoint("BOTTOMRIGHT", -4, 8); offerBtn:SetText("Offer")
    main.offerBtn = offerBtn

    -- clear the compose panel back to the empty "new offer" state
    local function clearDraft()
        editingKey = nil
        draft.itemID = nil; draft.suffix = 0; draft.link = nil
        SetItemButtonTexture(slot, nil); SetItemButtonCount(slot, 0)
        qtyBox:SetText("1"); priceBox:SetText("")
        offerBtn:SetText("Offer")
    end

    -- Place a new offer or apply an edit. Shared by the button and by Enter in either box.
    local function submitOffer()
        local qty, price = tonumber(qtyBox:GetText()) or 1, parsePrice(priceBox:GetText())
        if editingKey then
            -- editing only changes qty/price; the item/variant stays the listing's own
            if ns.EditOffer(editingKey, qty, price) then clearDraft() end
        elseif ns.AddOffer(draft.itemID, draft.suffix or 0, qty, price) then
            clearDraft()
        end
    end
    offerBtn:SetScript("OnClick", submitOffer)
    -- Enter in the qty or price box commits the same as clicking Offer / Update.
    qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); submitOffer() end)
    priceBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); submitOffer() end)

    -- Load an existing listing into the compose panel for editing (Edit button on a row).
    -- Editing avoids the remove + re-list trip to the bank, so we don't require the item
    -- in inventory here; the slot just mirrors the listing.
    function ns.LoadOfferForEdit(key)
        local o = GuildFoundMarketCharDB.offers and GuildFoundMarketCharDB.offers[key]
        if not o then return end
        editingKey = key
        draft.itemID = o.id or tonumber(key); draft.suffix = o.suffix or 0
        draft.link = vLink(draft.itemID, draft.suffix)
        SetItemButtonTexture(slot, GetItemIcon(draft.itemID)); SetItemButtonCount(slot, GetItemCount(draft.itemID, true))
        qtyBox:SetText(tostring(o.qty or 1))
        priceBox:SetText(priceToStr(o.price))
        offerBtn:SetText("Update")
        priceBox:SetFocus(); priceBox:HighlightText()   -- price is the field most edits change
    end
end

local function buildDbPanel()
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
        GameTooltip:AddLine("May cause brief lag or latency while it runs; you can stop it anytime.", 1, 0.5, 0.2, true)
        GameTooltip:Show()
    end)
    dbBtn:SetScript("OnLeave", GameTooltip_Hide)

    C_Timer.NewTicker(1, function()
        if main:IsShown() and currentTab == "BUY" then ns.UpdateDBPanel() end
    end)
end

local function buildSellerWidgets()
    --==================== Sellers tab widgets (index + show) ====================
    local sellerFilterLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sellerFilterLabel:SetPoint("TOPLEFT", 16, -68); sellerFilterLabel:SetText("Find seller:"); sellerFilterLabel:Hide()
    main.sellerFilterLabel = sellerFilterLabel
    local sellerFilter = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    sellerFilter:SetPoint("TOPLEFT", 100, -64); sellerFilter:SetSize(300, 22); sellerFilter:SetAutoFocus(false); sellerFilter:Hide()
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
    sellerRefreshBtn:SetSize(80, 22); sellerRefreshBtn:SetPoint("TOPLEFT", 410, -64); sellerRefreshBtn:SetText("Refresh"); sellerRefreshBtn:Hide()
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
end

local function buildPauseAnnounce()
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
            GameTooltip:AddLine("Pause this while raiding or doing PvP; your items stay listed but stop answering, nothing to clear.", 1, 1, 1, true)
            GameTooltip:AddLine("Click to go offline.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end)
    pauseBtn:SetScript("OnLeave", GameTooltip_Hide)
    main.pauseBtn = pauseBtn

    -- Announce: a chat/note icon, right-aligned. Disabled while listings are paused.
    local announceBtn = CreateFrame("Button", nil, main)
    announceBtn:SetSize(24, 24); announceBtn:SetPoint("TOPRIGHT", -14, -64); announceBtn:Hide()
    announceBtn:SetNormalTexture("Interface\\FriendsFrame\\UI-Toast-ChatInviteIcon")
    announceBtn:SetPushedTexture("Interface\\FriendsFrame\\UI-Toast-ChatInviteIcon")
    announceBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    announceBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Announce your shop")
        if GuildFoundMarketCharDB.paused then
            GameTooltip:AddLine("Unavailable while your listings are offline. Go online first.", 1, 0.5, 0.2, true)
        else
            GameTooltip:AddLine("Drops a \"Shop is open!\" line, with a clickable shop link, into the chat picked on the left.", 1, 1, 1, true)
            GameTooltip:AddLine("Nothing is sent automatically. Add items or text, then press Enter yourself.", 1, 1, 1, true)
            GameTooltip:AddLine("GFM users who click the link browse your shop only after you answer on the marketplace channel, so it never leaks outside your confederation.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end)
    announceBtn:SetScript("OnLeave", GameTooltip_Hide)
    main.announceBtn = announceBtn

    --==================== Announce destination selector ====================
    local announceDest = GuildFoundMarketCharDB.announceDest or "guild"
    -- the fixed destinations; the configured trade channel is appended dynamically
    local DESTS = {
        { key = "guild",   label = "Guild",   avail = function() return IsInGuild() end,                    why = "Join a guild to use guild chat." },
        { key = "party",   label = "Party",   avail = function() return IsInGroup() and not IsInRaid() end, why = "Join a party (not a raid) for party chat." },
        { key = "raid",    label = "Raid",    avail = function() return IsInRaid() end,                      why = "Join a raid for raid chat." },
        { key = "whisper", label = "Whisper", avail = function() return true end },
    }
    local function tradeChan() return ns.config and ns.config.tradeChannel end
    local function destLabel(key)
        if key == "channel" then local tc = tradeChan(); return tc and tc.name or "Channel" end
        for _, d in ipairs(DESTS) do if d.key == key then return d.label end end
        return "Guild"
    end

    local whisperBox = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    whisperBox:SetSize(120, 20); whisperBox:SetAutoFocus(false); whisperBox:Hide()
    main.announceWhisper = whisperBox

    local destBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    destBtn:SetSize(96, 22); destBtn:SetPoint("RIGHT", announceBtn, "LEFT", -6, 0)
    whisperBox:SetPoint("RIGHT", destBtn, "LEFT", -8, 0)
    main.announceDestBtn = destBtn

    local function applyDest(key)
        announceDest = key
        GuildFoundMarketCharDB.announceDest = key
        destBtn:SetText(destLabel(key))
        whisperBox:SetShown(currentTab == "MINE" and key == "whisper")
        if main.announceWAC then main.announceWAC:Hide() end
    end

    local popup = CreateFrame("Frame", nil, main, "BackdropTemplate")
    popup:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    popup:SetBackdropColor(0, 0, 0, 0.95); popup:SetBackdropBorderColor(0.4, 0.4, 0.4)
    popup:SetPoint("TOPRIGHT", destBtn, "BOTTOMRIGHT", 0, -2); popup:SetWidth(140); popup:SetFrameStrata("DIALOG"); popup:Hide()
    popup.rows = {}
    main.announceDestPopup = popup
    local function popupRow(i)
        local r = popup.rows[i]
        if r then return r end
        r = CreateFrame("Button", nil, popup); r:SetSize(136, 18); r:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 18)
        local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.15)
        r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.fs:SetPoint("LEFT", 6, 0)
        popup.rows[i] = r
        return r
    end
    local function entries()
        local list = {}
        for _, d in ipairs(DESTS) do list[#list + 1] = d end
        local tc = tradeChan()
        if tc then
            list[#list + 1] = { key = "channel", label = tc.name,
                avail = function() return (GetChannelName(tc.name) or 0) > 0 end,
                join  = function() JoinPermanentChannel(tc.name, tc.password) end }
        end
        return list
    end
    local function refreshPopup()
        local list = entries()
        for i, d in ipairs(list) do
            local r = popupRow(i)
            local ok = d.avail()
            local joinable = (d.key == "channel" and not ok)
            r.fs:SetText(joinable and ("Join " .. d.label) or d.label)
            r.fs:SetTextColor(ok and 1 or (joinable and 1 or 0.5), ok and 1 or (joinable and 0.82 or 0.5), ok and 1 or (joinable and 0 or 0.5))
            r:SetScript("OnClick", function()
                if joinable then d.join(); popup:Hide(); ns.Feedback("Joining " .. d.label .. " ...", false)
                elseif ok then applyDest(d.key); popup:Hide() end
            end)
            r:SetScript("OnEnter", function(self)
                if not ok and not joinable and d.why then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(d.why); GameTooltip:Show()
                end
            end)
            r:SetScript("OnLeave", GameTooltip_Hide)
            r:Show()
        end
        for i = #list + 1, #popup.rows do popup.rows[i]:Hide() end
        popup:SetHeight(#list * 18 + 4)
    end
    destBtn:SetScript("OnClick", function()
        if popup:IsShown() then popup:Hide() else refreshPopup(); popup:Show() end
    end)

    -- guild-name autocomplete for the whisper field
    local wac = CreateFrame("Frame", nil, main, "BackdropTemplate")
    wac:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    wac:SetBackdropColor(0, 0, 0, 0.95); wac:SetBackdropBorderColor(0.4, 0.4, 0.4)
    wac:SetPoint("TOPLEFT", whisperBox, "BOTTOMLEFT", -2, -2); wac:SetWidth(124); wac:SetFrameStrata("DIALOG"); wac:Hide()
    wac.rows = {}
    main.announceWAC = wac
    local function wacRow(i)
        local r = wac.rows[i]; if r then return r end
        r = CreateFrame("Button", nil, wac); r:SetSize(120, 16); r:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 16)
        local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.15)
        r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.fs:SetPoint("LEFT", 5, 0)
        wac.rows[i] = r; return r
    end
    local function guildMatches(prefix)
        local out = {}
        if not IsInGuild() or prefix == "" then return out end
        prefix = prefix:lower()
        for i = 1, (GetNumGuildMembers() or 0) do
            local full = GetGuildRosterInfo(i)
            local name = full and Ambiguate(full, "short")
            if name and name:lower():find(prefix, 1, true) == 1 then
                out[#out + 1] = name
                if #out >= 10 then break end
            end
        end
        table.sort(out)
        return out
    end
    local function updateWAC()
        local matches = guildMatches(whisperBox:GetText() or "")
        if #matches == 0 then wac:Hide(); return end
        for i = 1, 10 do
            local r = wacRow(i)
            local nm = matches[i]
            if nm then
                r.fs:SetText(nm)
                r:SetScript("OnClick", function() whisperBox:SetText(nm); wac:Hide(); whisperBox:ClearFocus() end)
                r:Show()
            else r:Hide() end
        end
        wac:SetHeight(math.min(#matches, 10) * 16 + 4); wac:Show()
    end
    whisperBox:SetScript("OnTextChanged", function(_, user) if user then updateWAC() end end)
    whisperBox:SetScript("OnEditFocusGained", function()
        if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
    end)
    whisperBox:SetScript("OnEscapePressed", function(self) wac:Hide(); self:ClearFocus() end)
    whisperBox:SetScript("OnEnterPressed", function(self) wac:Hide(); self:ClearFocus() end)

    announceBtn:SetScript("OnClick", function() ns.AnnounceShop(announceDest, whisperBox:GetText()) end)
    applyDest(announceDest)
end

local HELP_USAGE = table.concat({
    "|cffff4040» FIRST TIME: open the Buy tab and click |r|cffffd100Build full DB|r|cffff4040 «|r",
    "|cffffffffRequired before you can search:|r until the database is built, autocomplete can't find items you don't already own. It's a safe one-time background scan that resumes if you stop.",
    "|cffffffffFaster with the |r|cffffd100aux|r|cffffffff addon:|r if you have aux installed, GFM seeds the classic item names from it instantly on login, so the scan only has to fetch the newer Season of Discovery items.",
    " ",
    "|cff00ff96Guild Found Market|r is a private, live marketplace for your guild confederation: only sellers who are |cffffffffonline right now|r answer.",
    " ",
    "|cffffd100Buy|r: find an item",
    "Type a name (or shift-click an item link) and pick it. Online sellers are listed cheapest first.",
    "• |cffffffffLeft-click|r a seller: open their full list of items.",
    "• |cffffffffRight-click|r a seller: whisper them about this item.",
    " ",
    "|cffffd100Sellers|r: browse who's online",
    "Click a seller to see everything they sell. On one of their items:",
    "• |cffffffffCtrl-click|r: search that item to find who else is selling it.",
    "• |cffffffffRight-click|r: whisper the seller, pre-filled with the item and price.",
    " ",
    "|cffffd100My Items|r: what you sell",
    "Add your items; your client answers searches automatically, no pop-ups.",
    "• |cffffffffOnline / Offline|r: pause answering while you raid or PvP. Your items are kept.",
    "• |cffffffffAnnounce|r: drop a \"shop is open\" line into the chat you pick (guild, party, raid, whisper, or your guild's trade channel). You send it yourself; GFM users who click it browse your shop live.",
    " ",
    "|cffffd100Spam filter|r",
    "In Options you can hide incoming shop links per surface (guild, party, whispers, channels). It only changes what you see, nothing for anyone else.",
    " ",
    "|cffffd100Opening & minimap|r",
    "Open with |cffffffff/gfm|r or |cffffffff/market|r, or the minimap button. Toggle the minimap icon with |cffffffff/gfm minimap|r.",
    " ",
    "|cffffd100Options|r",
    "The |cffffffffgear|r at the top right opens Options, where you can turn features on or off. Settings are saved per account.",
}, "\n")

local HELP_SETUP = table.concat({
    "|cffffd100Marketplace channel (required)|r",
    "The whole marketplace is one shared channel. Put this single line in a guild's Information text (Guild window > Information tab):",
    "    |cff66ff66GFMc:MyMarket:somesharedsecret|r",
    "Anyone whose guild information contains the identical line joins the same marketplace. If you run GreenWall, its GWc channel is reused automatically; when both are present, |cffffffffGFMc takes precedence|r. On login GFM prints which config it used.",
    " ",
    "|cffffd100Trade channel for announces (optional)|r",
    "To give the Announce button a shared trade channel, add a line naming it (password optional):",
    "    |cff66ff66GFMtc:FreshTrade|r   or   |cff66ff66GFMtc:FreshTrade:password|r",
    "Members then get that channel as an Announce destination and can one-click join it from the dropdown (using the password, if set).",
    " ",
    "|cffffd100Sister guilds: trading outside GreenWall|r",
    "To include guilds that are NOT in your GreenWall confederation, give them the |cffffffffsame GFMc line|r; that is all. (Peer-guild GFMp/GWp lines are not used.)",
    "• |cffff5555Do not share your GWc line|r with them: that is your GreenWall chat-bridge secret, and a sister guild running GreenWall would land in your private guild chat. Keep GWc for the confederation and use a separate GFMc for the market.",
    "• |cffffd100Consequence:|r the GFMc secret is the only gate. Everyone you hand it to can see and answer every search and browse all listed sellers. Share it only with guilds you trust to trade.",
}, "\n")

local function buildHelpPanel()
    --==================== Help tab: Usage / Guild Setup sub-sections ====================
    local helpScroll = CreateFrame("ScrollFrame", "GuildFoundMarketHelpScroll", main, "UIPanelScrollFrameTemplate")
    helpScroll:SetPoint("TOPLEFT", 24, -92); helpScroll:SetPoint("BOTTOMRIGHT", -30, 16); helpScroll:Hide()
    helpScroll:EnableMouseWheel(true)
    helpScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * 30)))
    end)
    local helpContent = CreateFrame("Frame", nil, helpScroll); helpContent:SetSize(700, 1)
    helpScroll:SetScrollChild(helpContent)
    local helpText = helpContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    helpText:SetPoint("TOPLEFT"); helpText:SetWidth(700)
    helpText:SetJustifyH("LEFT"); helpText:SetJustifyV("TOP"); helpText:SetSpacing(2)
    main.helpPanel = helpScroll
    main.helpContent = helpContent
    main.helpText = helpText

    -- two toggle buttons that swap the content (no nested-tab framework)
    local function sectionBtn(x, text)
        local b = CreateFrame("Button", nil, main); b:SetSize(96, 20); b:SetPoint("TOPLEFT", x, -66); b:Hide()
        local sel = b:CreateTexture(nil, "BACKGROUND"); sel:SetAllPoints(); sel:SetColorTexture(1, 0.82, 0, 0.18); sel:Hide(); b.sel = sel
        local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.10)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); fs:SetPoint("CENTER"); fs:SetText(text)
        return b
    end
    local usageBtn = sectionBtn(24, "Usage")
    local setupBtn = sectionBtn(124, "Guild Setup")
    main.helpUsageBtn, main.helpSetupBtn = usageBtn, setupBtn

    local function setHelp(which)
        helpText:SetText(which == "setup" and HELP_SETUP or HELP_USAGE)
        helpContent:SetHeight(helpText:GetStringHeight() + 8)
        helpScroll:SetVerticalScroll(0)
        usageBtn.sel:SetShown(which ~= "setup")
        setupBtn.sel:SetShown(which == "setup")
    end
    usageBtn:SetScript("OnClick", function() setHelp("usage") end)
    setupBtn:SetScript("OnClick", function() setHelp("setup") end)
    main.helpShowUsage = function() setHelp("usage") end
    setHelp("usage")
end

local function buildOptionsPanel()
    --==================== Options panel ====================
    -- Built entirely from ns.SettingsSchema: a checkbox per boolean entry, a radio group per
    -- "choice" entry. A control only ever calls ns.SetSetting; the matching reactor (or the
    -- code that reads the setting) does the actual work.
    local optPanel = CreateFrame("Frame", nil, main)
    optPanel:SetPoint("TOPLEFT", 24, -92); optPanel:SetPoint("BOTTOMRIGHT", -30, 16); optPanel:Hide()
    main.optionsPanel = optPanel
    local optTitle = optPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    optTitle:SetPoint("TOPLEFT", 4, -4); optTitle:SetText("Options")
    local optHint = optPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    optHint:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -4)
    optHint:SetText("Configure features here. Changes apply immediately and are saved per account.")

    -- shared tooltip for any control of a setting (label + wrapped tip + optional status line)
    local function showTip(owner, s)
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:SetText(s.label)
        if s.tip then GameTooltip:AddLine(s.tip, 1, 1, 1, true) end
        if s.status then
            local txt, r, g, b = s.status()
            if txt then GameTooltip:AddLine(" "); GameTooltip:AddLine(txt, r or 1, g or 1, b or 1, true) end
        end
        GameTooltip:Show()
    end

    local optChecks, optRadios = {}, {}
    local oy = -48
    for _, s in ipairs(ns.SettingsSchema) do
        if s.type == "choice" then
            local lbl = optPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            lbl:SetPoint("TOPLEFT", 8, oy); lbl:SetText(s.label)
            oy = oy - 22
            local rx = 12
            for _, opt in ipairs(s.options) do
                local rb = CreateFrame("CheckButton", nil, optPanel, "UIRadioButtonTemplate")
                rb:SetPoint("TOPLEFT", rx, oy); rb.key = s.key; rb.value = opt.value
                local rl = optPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                rl:SetPoint("LEFT", rb, "RIGHT", 3, 0); rl:SetText(opt.label)
                rb:SetHitRectInsets(0, -(rl:GetStringWidth() + 6), 0, 0)
                rb:SetScript("OnClick", function(self) ns.SetSetting(self.key, self.value) end)
                rb:SetScript("OnEnter", function(self) showTip(self, s) end)
                rb:SetScript("OnLeave", GameTooltip_Hide)
                optRadios[#optRadios + 1] = rb
                rx = rx + 24 + rl:GetStringWidth() + 18
            end
            oy = oy - 30
        else
            local cb = CreateFrame("CheckButton", nil, optPanel, "UICheckButtonTemplate")
            cb:SetPoint("TOPLEFT", 4, oy); cb:SetSize(26, 26); cb.key = s.key
            local lbl = optPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            lbl:SetPoint("LEFT", cb, "RIGHT", 4, 1); lbl:SetText(s.label)
            -- extend the click/hover area rightward over the label, so hovering or clicking the
            -- text behaves the same as the checkbox itself (tooltip + toggle)
            cb:SetHitRectInsets(0, -(lbl:GetStringWidth() + 8), 0, 0)
            cb:SetScript("OnClick", function(self) ns.SetSetting(self.key, self:GetChecked()) end)
            cb:SetScript("OnEnter", function(self) showTip(self, s) end)
            cb:SetScript("OnLeave", GameTooltip_Hide)
            optChecks[#optChecks + 1] = cb
            oy = oy - 30
        end
    end

    -- pull every control from the store; called on entering the tab and on any change
    -- elsewhere (e.g. a slash command), so the panel always mirrors the live settings.
    function ns.RefreshOptions()
        for _, cb in ipairs(optChecks) do cb:SetChecked(ns.GetSetting(cb.key)) end
        for _, rb in ipairs(optRadios) do rb:SetChecked(ns.GetSetting(rb.key) == rb.value) end
    end
    ns.On("setting", function()
        if main and main.optionsPanel and main.optionsPanel:IsShown() then ns.RefreshOptions() end
    end)
end

local function CreateUI()
    buildWindow()
    buildTabs()
    buildSearchBox()
    buildAutocomplete()
    buildHeaders()
    buildRows()
    buildStatusVersion()
    buildBrowse()
    buildPostPanel()
    buildDbPanel()
    buildSellerWidgets()
    buildPauseAnnounce()
    buildHelpPanel()
    buildOptionsPanel()
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
    ns.UpdateAnnounceButton()
end

-- The announce only makes sense while you're answering searches, so disable it
-- (greyed) whenever your listings are paused.
function ns.UpdateAnnounceButton()
    if not main or not main.announceBtn then return end
    local btn = main.announceBtn
    local paused = GuildFoundMarketCharDB.paused
    if paused then btn:Disable() else btn:Enable() end
    btn:SetAlpha(paused and 0.35 or 1)
    local tex = btn:GetNormalTexture()
    if tex then tex:SetDesaturated(paused) end
end

function ns.ToggleListings()
    GuildFoundMarketCharDB.paused = not GuildFoundMarketCharDB.paused
    ns.UpdatePauseButton()
    if ns.UpdateMinimapIcon then ns.UpdateMinimapIcon() end
    if currentTab == "MINE" then ns.RefreshMine() end
    ns.Feedback(GuildFoundMarketCharDB.paused
        and "Listings paused: you won't answer searches until you go online."
        or "Listings online: you're answering searches again.", false)
end

function ns.UpdateDBPanel()
    if not main or not main.dbInfo then return end
    main.dbInfo:SetText(("Item database: %d items"):format(ns.ItemDB.Count()))
    if ns.ItemDB.IsHarvesting() then
        local cur, max = ns.ItemDB.HarvestProgress()
        local pct = (max and max > 0) and math.floor(cur / max * 100) or 0
        main.dbBtn:SetText(("Stop (%d%%)"):format(pct))
    else
        main.dbBtn:SetText("Build full DB")
    end
end

--========================================================================
-- tab switching
--========================================================================
function ns.SelectTab(tab, goSeller, goLoc, findSeller)
    if not main then return end
    currentTab = tab
    for _, b in ipairs(tabButtons) do
        local on = (b.tab == tab)
        b.sel:SetShown(on)
        if b.text then b.text:SetTextColor(1, on and 0.82 or 1, on and 0 or 1) end
        if b.icon then b.icon:SetVertexColor(1, on and 0.82 or 1, on and 0 or 1) end
    end
    local buy     = (tab == "BUY")
    local mine    = (tab == "MINE")
    local sellers = (tab == "SELLERS")
    local help    = (tab == "HELP")
    local options = (tab == "OPTIONS")
    main.searchBox:SetShown(buy); main.searchLabel:SetShown(buy)
    main.ac:Hide()
    main.postPanel:SetShown(mine)
    main.dbPanel:SetShown(buy)
    if not sellers then   -- hide all seller widgets when on another tab
        main.sellerFilter:Hide(); main.sellerFilterLabel:Hide(); main.sellerRefreshBtn:Hide()
        main.sellerBackBtn:Hide(); main.sellerHeader:Hide()
        main.sortName:Hide(); main.sortCount:Hide()
    end
    main.modeToggle:SetShown(buy)
    if not buy then   -- leaving the Buy tab: hide all Browse widgets, restore the shared headers
        main.sidebar:Hide(); main.browseScroll:Hide(); main.browseFilter:Hide(); main.browseFilterLabel:Hide()
        main.bLvlLabel:Hide(); main.bLvlMin:Hide(); main.bLvlTo:Hide(); main.bLvlMax:Hide()
        main.bhItem:Hide(); main.bhLvl:Hide(); main.bhQty:Hide(); main.bhPrice:Hide(); main.bhSeller:Hide()
        main.bSortItem:Hide(); main.bSortLvl:Hide(); main.bSortPrice:Hide()
        for i = 1, ROWS do browseRows[i]:Hide() end
        main.h1:Show(); main.h2:Show(); main.h3:Show(); main.h4:Show()
    end
    main.pauseBtn:SetShown(mine); main.pauseLabel:SetShown(mine)
    main.announceBtn:SetShown(mine)
    main.announceDestBtn:SetShown(mine)
    main.announceWhisper:SetShown(mine and GuildFoundMarketCharDB.announceDest == "whisper")
    if main.announceDestPopup then main.announceDestPopup:Hide() end
    if main.announceWAC then main.announceWAC:Hide() end
    main.helpPanel:SetShown(help)
    main.debugBtn:SetShown(help)
    main.helpUsageBtn:SetShown(help); main.helpSetupBtn:SetShown(help)
    main.optionsPanel:SetShown(options)
    main.scroll:SetShown(not help and not options)
    if options then ns.RefreshOptions() end
    if mine then ns.UpdatePauseButton() end
    if buy then ns.UpdateDBPanel() end
    -- clear stale rows before resetting the scroll: SetVerticalScroll fires renderRows,
    -- and the old tab's data (e.g. sellers) would be fed to the new tab's row formatter
    wipe(view)
    FauxScrollFrame_SetOffset(main.scroll, 0); main.scroll:SetVerticalScroll(0)
    main.status:SetText("")
    if buy then
        main.h1:SetText("Seller"); main.h2:SetText("Qty"); main.h3:SetText("Price/unit"); main.h4:SetText("Location")
        setBuyMode(buyMode)   -- apply Search vs Browse sub-mode (handles visibility + refresh)
    elseif sellers then
        main.sellerFilter:SetText("")    -- fresh entry: clear any leftover name filter
        if goSeller then
            ns.SetSellersView("SHOW")    -- jump straight to one seller (e.g. from a Buy result)
            ns.OpenSeller(goSeller, goLoc)
            ns.ScanSellers("")           -- also populate the index so "< Back" has the full list
        elseif findSeller and findSeller ~= "" then
            -- from a clicked shop link: scan for just this seller over the private
            -- channel; Core auto-opens them once they answer (proof they're on it).
            ns.SetSellersView("INDEX")
            main.sellerFilter:SetText(findSeller)
            ns.ScanSellers(findSeller:lower())
            if ns.channelName then
                ns.sellers.pendingOpen = findSeller
                ns.Feedback(("Checking the marketplace for %s's shop…"):format(findSeller), false)
            end
        else
            ns.SetSellersView("INDEX")   -- sets its own headers + refresh
            ns.ScanSellers("")           -- auto-scan on entering (driven by the tab click = hardware event)
        end
    elseif help or options then
        main.h1:SetText(""); main.h2:SetText(""); main.h3:SetText(""); main.h4:SetText("")
        wipe(view); renderRows()
        if help then main.helpShowUsage() end   -- default to Usage; sizes the text + scrolls to top
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
            ns.Feedback("Not in a Guild Found confederation; open guild (J) once, then /gfm again.", true)
        end
    end
end

-- Open the window straight onto a Buy search for one item (alt-click in a bag/bank).
function ns.OpenAndSearch(itemID)
    if not itemID then return end
    if not main then CreateUI() end
    if not main:IsShown() then
        main:Show()
        if ns.RefreshConfig then ns.RefreshConfig() end
    end
    if ns.ItemDB then ns.ItemDB.Learn(itemID) end
    ns.SelectTab("BUY")
    selectSearchItem(itemID)
end

-- Open a shop from a clicked announce link. Routed through a name-filtered seller
-- scan (see Core) so the shop opens only if that seller answers on your private
-- channel, never straight from the link itself.
function ns.OpenShopLink(name)
    if not name or name == "" then return end
    if not main then CreateUI() end
    if not main:IsShown() then
        main:Show()
        if ns.RefreshConfig then ns.RefreshConfig() end
    end
    if name == playerName and not ns.selfTest then
        ns.SelectTab("MINE")
        ns.Feedback("That's your own shop link. Here are your items.", false)
        return
    end
    -- selftest falls through here, so your own link exercises the real scan/open path
    ns.SelectTab("SELLERS", nil, nil, name)
end
