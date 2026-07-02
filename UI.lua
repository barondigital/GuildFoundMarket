local ADDON, ns = ...

local ROWS, ROW_H = 10, 24
local playerName = UnitName("player")

local main
local rows = {}
local view = {}            -- current rows being displayed (buy results / my offers / sellers)
local currentTab = "BUY"
local sellersView = "INDEX"  -- within the Sellers tab: "INDEX" (list) or "SHOW" (one seller)
local sellerSort = { col = "count", asc = false }  -- Sellers index sort: col "name"|"count", direction (default: most items first)
-- Buyers tab (buy-side mirror of Sellers): "INDEX" (browse buyers), "FIND" (buyers wanting a
-- picked item), "SHOW" (one buyer's want list). My Items has two sub-modes: "SELLING" | "WTB".
local buyersView = "INDEX"
-- Where a player-detail session began, so "< Back" returns correctly even after WTS/WTB toggles
-- cross-navigate between the Sellers and Buyers tabs. { tab = "SELLERS"|"BUYERS", view = "INDEX"|"FIND" }
local showOrigin = { tab = "SELLERS", view = "INDEX" }
local mineMode = "SELLING"
local buyerSort = { col = "count", asc = false }   -- Buyers index sort, mirrors sellerSort
local tabButtons = {}
local draft = { itemID = nil }     -- item being composed in the My Items post panel
local selectedSearchID = nil
-- When you open a seller/buyer from a place that already knows which item you care about
-- (a Buy result, a Browse row, a "who wants this" hit), we stash that item's name here so the
-- catalog opens pre-filtered to it instead of showing their whole list. Consumed (and cleared)
-- by SetSellersView / SetBuyersView the moment the catalog view is shown.
local pendingCatFilter = nil

-- Buy tab has two sub-modes: item Search (existing) and category Browse (#3).
local buyMode = "BROWSE"   -- "SEARCH" | "BROWSE" (Browse is the default view)
local BROWSE_CAP = 150     -- max Browse rows shown; beyond it the user narrows by level range / filter
local browseSort = { col = "lvl", asc = false }   -- Browse results sort: "qual"|"lvl"|"price"; default level desc
local browseSel = { class = nil, sub = nil, slot = nil }   -- selected category (nil = none picked yet)
local browseExpanded = nil                        -- classID currently expanded in the sidebar (accordion)
local browseExpandedSub = nil                     -- Armor subID expanded to its slot leaves (3rd level)
local browseRows, browseView = {}, {}             -- the 6-column results table
local sideRows, sideView = {}, {}                 -- the category sidebar tree
local setBuyMode                                  -- forward declaration (defined with the other refreshers)
local setMineMode                                 -- My Items Selling/WTB sub-tab toggle (forward decl)

-- Per-view sort state for the shared item lists. Each view keeps its own column + direction
-- so its default sticks: Buy search stays cheapest-first; the item lists open on quality.
local buySort     = { col = "price", asc = true }   -- Buy search rows: name(seller)|qty|price
local mineSort    = { col = "name",  asc = true }   -- My Items rows:   item(qual/name)|qty|price; opens alphabetical
local catalogSort = { col = "name",  asc = true }   -- Seller catalog:  item(qual/name)|qty|price; opens alphabetical
-- Buyers-side item-list sort states, mirroring the seller-side ones above
local findBuyersSort     = { col = "price", asc = true }   -- "who wants X" results: name(buyer)|qty|price
local wantSort           = { col = "name",  asc = true }   -- My WTB list:        item(qual/name)|qty|price
local buyerCatalogSort   = { col = "name",  asc = true }   -- one buyer's wants:  item(qual/name)|qty|price
-- First click on a qty/price/seller column picks this direction; clicking it again toggles.
local SORT_DEFAULT_ASC = { name = true, qty = false, price = true, count = false }
local SORT_UP   = " |TInterface\\Buttons\\Arrow-Up-Up:12|t"
local SORT_DOWN = " |TInterface\\Buttons\\Arrow-Down-Up:12|t"
local function sortArrow(sort, col) return sort.col == col and (sort.asc and SORT_UP or SORT_DOWN) or "" end

-- The Item header cycles four ways on repeated clicks: quality desc -> quality asc ->
-- alphabetical asc -> alphabetical desc -> (back to quality desc). Coming from another
-- column (qty/price) restarts the cycle at quality desc.
local function nextItemSort(s)
    if s.col == "qual" and not s.asc then return "qual", true  end   -- qual desc -> qual asc
    if s.col == "qual" and s.asc     then return "name", true  end   -- qual asc  -> name asc
    if s.col == "name" and s.asc     then return "name", false end   -- name asc  -> name desc
    return "qual", false                                             -- name desc / elsewhere -> qual desc
end

-- forward decls (defined with the refreshers; referenced by header click handlers built earlier)
local activeItemSort, refreshActiveItemView, updateSharedSortHeaders

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
ns.PriceToStr = priceToStr   -- exposed for the price-tooltip (PriceDB.lua), which formats in the chosen format

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

-- Qty prompt for a mail order (mail icon on a Buy result / seller-catalog row). The buyer
-- commits to qty x price; on accept ns.PlaceOrder whispers the seller and tracks the order
-- under My Items > Orders. Native StaticPopup: one field is all this needs.
StaticPopupDialogs["GFM_MAIL_ORDER"] = {
    text = "Order %s\nfrom %s by COD mail. Quantity:",
    button1 = "Order",
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 4,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
    OnShow = function(self)
        self.editBox:SetNumeric(true)
        self.editBox:SetText(tostring(self.data.qty))
        self.editBox:HighlightText()
    end,
    OnAccept = function(self)
        local d = self.data
        local q = math.min(d.qty, math.max(1, tonumber(self.editBox:GetText()) or 1))
        ns.PlaceOrder(d.seller, d.id, d.suffix, q, d.price)
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["GFM_MAIL_ORDER"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

local function promptOrder(seller, id, suffix, qty, price)
    StaticPopup_Show("GFM_MAIL_ORDER", vLink(id, suffix) or vName(id, suffix), seller,
        { seller = seller, id = id, suffix = suffix or 0, qty = qty or 1, price = price })
end

-- The sell-side mirror: commit to mail someone's COD want. Same one-field prompt; the
-- buyer already committed to the price, so ns.FulfillWant needs no acceptance step.
StaticPopupDialogs["GFM_MAIL_FULFILL"] = {
    text = "Mail %s\nto %s COD (they pay on delivery). Quantity:",
    button1 = "Commit",
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 4,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
    OnShow = StaticPopupDialogs["GFM_MAIL_ORDER"].OnShow,
    OnAccept = function(self)
        local d = self.data
        local q = math.min(d.qty, math.max(1, tonumber(self.editBox:GetText()) or 1))
        ns.FulfillWant(d.buyer, d.id, d.suffix, q, d.price)
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["GFM_MAIL_FULFILL"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

local function promptFulfill(buyer, id, suffix, qty, price)
    StaticPopup_Show("GFM_MAIL_FULFILL", vLink(id, suffix) or vName(id, suffix), buyer,
        { buyer = buyer, id = id, suffix = suffix or 0, qty = qty or 1, price = price })
end

-- pick an item into the search box and fire a search (used by autocomplete + shift-click)
local function selectSearchItem(id, name)
    if not main then return end
    selectedSearchID = id
    main.searchBox:SetText(name or itemName(id)); main.searchBox:SetCursorPosition(0); main.searchBox:ClearFocus()
    main.ac:Hide()
    if currentTab == "BUYERS" then   -- the same picker, but it finds buyers of the item
        ns.SetBuyersView("FIND")
        if ns.FindBuyersForItem then ns.FindBuyersForItem(id) end
        return
    end
    if setBuyMode and buyMode ~= "SEARCH" then setBuyMode("SEARCH") end   -- a picked search item always lands in the Search view
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

-- Want price cell: a coin string tagged COD (firm, paid on delivery) or "max" (a ceiling),
-- or "Offers" when the buyer set no price (open to offers).
local function wantPriceText(price, cod)
    if (price or 0) <= 0 then return "|cffffd100Offers|r" end
    return GetCoinTextureString(price) .. (cod and " |cffff8800COD|r" or " |cff888888max|r")
end

-- Append the Bag-sync cache freshness to a tooltip: that the count is bags(live) plus the bank
-- and mail snapshots, when each was last seen, and a nudge to open the mailbox when unread mail
-- is waiting (so the player knows that part of the count may be short until they do).
local function appendStockReliability(tip)
    if not ns.Stock then return end
    local r = ns.Stock.Reliability()
    local age = ns.PriceDB and ns.PriceDB.AgeString
    local function seen(at) return (at and at > 0 and age) and (age(at) .. " ago") or "not yet" end
    tip:AddLine(" ")
    tip:AddLine(("Counts bags (live) + this character's bank (%s) + mail (%s)."):format(seen(r.bankAt), seen(r.mailAt)), 0.7, 0.7, 0.7, true)
    if r.newMail then
        tip:AddLine("New mail waiting: open your mailbox to update the count.", 1, 0.6, 0.2, true)
    end
end

-- Reset a pooled row to a known baseline before a formatter fills in only its differences.
-- Rows are shared across the Buy / My Items / Sellers tabs, so anything a previous row set
-- (scripts, colour, the trailing buttons, the hover link) must be cleared here.
local function resetRow(r)
    r.icon:Hide()
    r.c1:EnableMouse(true)
    r.c1.fs:SetTextColor(1, 1, 1)
    r.c1.tip = nil
    r.c1.itemID = nil; r.c1.itemLink = nil; r.c1.player = nil
    r.c1:SetScript("OnClick", nil)
    r.c2:SetText(""); r.c3:SetText("")
    r.c4:SetText(""); r.c4:Hide()
    r.c4:SetWidth(190)
    r.x:Hide(); r.x:SetScript("OnClick", nil)
    r.edit:Hide(); r.edit:SetScript("OnClick", nil); r.edit:SetText("Edit")
    r.orderBtn:Hide(); r.orderBtn:SetScript("OnClick", nil); r.orderBtn.fulfill = nil
    r.noteBtn:Hide(); r.noteBtn.seller = nil; r.noteBtn.store = nil
    r.findBtn:Hide(); r.findBtn:SetScript("OnClick", nil)
    r.track:Hide(); r.track:SetScript("OnClick", nil)
    r.itemID = nil
end

-- A transparent, mouse-only overlay on a header FontString (the open seller/buyer name). It
-- stays empty until SetHeaderPlayer sizes it to the header text and shows it; on hover it
-- reveals "Name <Guild>", so the guild appears on the header without taking any layout space.
local function makeHeaderHover(header)
    local b = CreateFrame("Button", nil, main)
    b:SetPoint("LEFT", header, "LEFT", 0, 0); b:SetHeight(18); b:SetWidth(1); b:Hide()
    b:SetScript("OnEnter", function(self)
        if not self.player then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText(ns.PlayerTitle(self.player), 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

-- Point a header's hover overlay at `name`, size it to the current header text, and show it.
-- The catalog refresh calls this right after writing the header; the view switches keep its
-- shown state in step with the header itself.
function ns.SetHeaderPlayer(hover, header, name)
    if not hover then return end
    hover.player = name
    hover:SetWidth(math.max(1, header:GetStringWidth() or 1))
    hover:Show()
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
            else
                pendingCatFilter = itemName(ns.search.itemID)   -- open their shop filtered to the item you searched
                ns.SelectTab("SELLERS", d.seller, d.loc)
            end
        end)
        -- mail-order icon: only on fixed-price offers (COD needs a price; bids are whispers)
        if (d.price or 0) > 0 then
            r.orderBtn:Show()
            r.orderBtn:SetScript("OnClick", function() promptOrder(d.seller, ns.search.itemID, d.suffix, d.qty, d.price) end)
        end
    end
    r.c2:SetText(d.qty or 0)
    r.c3:SetText(priceText(d.price))
    r.c4:SetText(d.loc or ""); r.c4:Show()
    -- hover shows the exact variant (stats), so use the reconstructed link, not the base ID
    r.c1.itemLink = vLink(ns.search.itemID, d.suffix)
    r.c1.player = d.seller   -- seller name; the item hover adds a "Name <Guild>" line below
end

local function formatMineRow(r, d)
    resetRow(r)
    local parked = (d.qty or 0) <= 0   -- qty 0 = hidden from others, shown only here
    r.icon:SetTexture(GetItemIcon(d.id)); r.icon:Show()
    r.c1.fs:SetText(vLink(d.id, d.suffix) or vName(d.id, d.suffix))
    r.c1.tip = parked
        and "Parked (qty 0): hidden from others, only you see it. Edit and set a qty above 0 to go live. · Ctrl-click to find who else sells this"
        or "Ctrl-click to find who else sells this · shift-click to drop into your open chat message"
    r.c1.itemLink = vLink(d.id, d.suffix)
    r.c1:SetScript("OnClick", function()
        if IsModifiedClick("CHATLINK") then
            local link = vLink(d.id, d.suffix)
            if link then ChatEdit_InsertLink(link) end
        elseif IsControlKeyDown() then ns.SelectTab("BUY"); selectSearchItem(d.id) end
    end)
    r.c2:SetText(parked and "|cffff88000|r" or (d.qty or 0))   -- orange 0 flags a parked (hidden) listing
    r.c3:SetText(priceText(d.price))
    r.x:Show(); r.x:SetScript("OnClick", function() ns.RemoveOffer(d.key) end)
    r.edit:Show(); r.edit:SetScript("OnClick", function() ns.LoadOfferForEdit(d.key) end)
    -- "Find buyers": jump to the Buyers tab and query who wants this item (via the shared
    -- picker, which on the Buyers tab switches to the FIND view and runs the WQ query)
    r.findBtn:Show(); r.findBtn:SetScript("OnClick", function()
        ns.SelectTab("BUYERS"); selectSearchItem(d.id)
    end)
    r.track:Show(); r.track:SetChecked(d.track and true or false)
    r.track:SetScript("OnClick", function(self) ns.SetOfferTrack(d.key, self:GetChecked()) end)
    r.itemID = d.id
end

-- Sellers tab: either an index row (a seller) or, in the show view, one of their items.
local function formatSellerRow(r, d)
    resetRow(r)
    if d.kind == "seller" then
        r.c1.fs:SetText(d.seller)
        r.c1.fs:SetTextColor(0.4, 1, 0.4)        -- green: online right now
        r.c1.player = d.seller                   -- hover tooltip titles with "Name <Guild>"
        r.c1.tip = "Click to see " .. d.seller .. "'s items"
        r.c1:SetScript("OnClick", function(_, button)
            if button ~= "RightButton" then showOrigin = { tab = "SELLERS", view = "INDEX" }; ns.OpenSeller(d.seller); ns.SetSellersView("SHOW") end
        end)
        r.c2:SetText(d.count or 0)
        r.c4:SetText(d.loc or ""); r.c4:Show()
        if d.hasNote then
            -- a chat-bubble icon just after the location; click loads the note, then hover shows it
            r.noteBtn.seller = d.seller; r.noteBtn.store = ns.sellers.results
            r.noteBtn:ClearAllPoints()
            r.noteBtn:SetPoint("LEFT", r.c4, "LEFT", (r.c4:GetStringWidth() or 0) + 6, 0)
            r.noteBtn:Show()
        end
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
        if (d.price or 0) > 0 and d.seller ~= playerName then
            r.orderBtn:Show()
            r.orderBtn:SetScript("OnClick", function() promptOrder(d.seller, d.id, d.suffix, d.qty, d.price) end)
        end
    end
end

-- Orders view row: one mail order, incoming ("from Buyer") or outgoing ("to Seller").
-- The price column shows the order's TOTAL (that's the COD amount on the mail).
local ORDER_STATUS = {   -- [dir .. status] = display text
    innew       = "|cffffd100New order|r",
    inaccepted  = "Accepted: mail it COD",
    insent      = "|cff40ff40Mailed|r",
    outpending  = "Sending ...",
    outnoreply  = "|cffff5555Not delivered (offline?)|r",
    outreceived = "Awaiting seller",
    outaccepted = "|cff40ff40Accepted: mail incoming|r",
    outdeclined = "|cffff5555Declined|r",
    outmailed   = "|cff40ff40Mailed: check your mailbox|r",
}
local function formatOrderRow(r, d)
    resetRow(r)
    local incoming = d.dir == "in"
    r.icon:SetTexture(GetItemIcon(d.id)); r.icon:Show()
    r.c1.fs:SetText((vLink(d.id, d.suffix) or vName(d.id, d.suffix))
        .. " |cff888888" .. (incoming and "from " or "to ") .. d.who .. "|r")
    r.c1.itemLink = vLink(d.id, d.suffix)
    r.c1.player = d.who
    r.c1.tip = "Right-click to whisper " .. d.who
    r.c1:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ChatFrame_OpenChat("/w " .. d.who .. " ") end
    end)
    r.c2:SetText(d.qty or 0)
    r.c3:SetText(GetCoinTextureString((d.qty or 0) * (d.price or 0)))
    r.c4:SetWidth(120)   -- keep clear of the Accept/X buttons on the right
    r.c4:SetText(ORDER_STATUS[d.dir .. d.status] or d.status); r.c4:Show()
    if incoming and d.status == "new" then
        r.edit:SetText("Accept"); r.edit:Show()
        r.edit:SetScript("OnClick", function() ns.AcceptOrder(d.oid) end)
    end
    r.x:Show()
    r.x:SetScript("OnClick", function()
        if incoming then ns.DeclineOrder(d.oid) else ns.CancelOrder(d.oid) end
    end)
end

-- My WTB list row: like a Selling row but for a wanted item (Remove + Edit, no Find buyers).
local function formatWantRow(r, d)
    resetRow(r)
    r.icon:SetTexture(GetItemIcon(d.id)); r.icon:Show()
    r.c1.fs:SetText(vLink(d.id, d.suffix) or vName(d.id, d.suffix))
    r.c1.tip = "Ctrl-click to find sellers of this · shift-click to drop into your open chat message"
    r.c1.itemLink = vLink(d.id, d.suffix)
    r.c1:SetScript("OnClick", function()
        if IsModifiedClick("CHATLINK") then
            local link = vLink(d.id, d.suffix)
            if link then ChatEdit_InsertLink(link) end
        elseif IsControlKeyDown() then ns.SelectTab("BUY"); selectSearchItem(d.id) end
    end)
    r.c2:SetText(d.qty or 0)
    r.c3:SetText(wantPriceText(d.price, d.cod))
    r.x:Show(); r.x:SetScript("OnClick", function() ns.RemoveWant(d.key) end)
    r.edit:Show(); r.edit:SetScript("OnClick", function() ns.LoadWantForEdit(d.key) end)
    r.itemID = d.id
end

-- Buyers tab row: an index buyer, a "who wants X" result, or one of an open buyer's wants.
local function formatBuyerRow(r, d)
    resetRow(r)
    if d.kind == "buyer" then
        r.c1.fs:SetText(d.self and (d.buyer .. " (you)") or d.buyer)
        r.c1.fs:SetTextColor(d.self and 1 or 0.4, d.self and 0.82 or 1, d.self and 0 or 0.4)
        r.c1.player = d.buyer                     -- hover tooltip titles with "Name <Guild>"
        r.c1.tip = "Click to see what " .. d.buyer .. " wants · right-click to whisper"
        r.c1:SetScript("OnClick", function(_, button)
            if button == "RightButton" then ChatFrame_OpenChat("/w " .. d.buyer .. " ")
            else showOrigin = { tab = "BUYERS", view = "INDEX" }; ns.OpenBuyer(d.buyer); ns.SetBuyersView("SHOW") end
        end)
        r.c2:SetText(d.count or 0)
        r.c4:SetText(d.loc or ""); r.c4:Show()
        if d.hasNote then
            r.noteBtn.seller = d.buyer; r.noteBtn.store = ns.buyers.results
            r.noteBtn:ClearAllPoints()
            r.noteBtn:SetPoint("LEFT", r.c4, "LEFT", (r.c4:GetStringWidth() or 0) + 6, 0)
            r.noteBtn:Show()
        end
    elseif d.kind == "findbuyer" then
        local id = ns.buyers.find.itemID
        r.c1.fs:SetText(d.self and (d.buyer .. " (you)") or d.buyer)
        r.c1.fs:SetTextColor(d.self and 1 or 0.4, d.self and 0.82 or 1, d.self and 0 or 0.4)
        r.c1.tip = "Click for their wants · right-click to whisper about this item"
        r.c1.itemLink = id and vLink(id, d.suffix)
        r.c1.player = d.buyer                     -- the item hover adds a "Name <Guild>" line below
        r.c1:SetScript("OnClick", function(_, button)
            if button == "RightButton" then whisperItem(d.buyer, id, d.suffix, d.price)
            else
                pendingCatFilter = id and itemName(id)   -- open their wants filtered to the item you searched
                showOrigin = { tab = "BUYERS", view = "FIND" }; ns.OpenBuyer(d.buyer); ns.SetBuyersView("SHOW")
            end
        end)
        r.c2:SetText(d.qty or 0)
        r.c3:SetText(wantPriceText(d.price, d.cod))
        r.c4:SetText(d.loc or ""); r.c4:Show()
        -- fulfil-by-mail icon: only on COD wants (the buyer committed to that price on delivery)
        if d.cod and (d.price or 0) > 0 and not d.self then
            r.orderBtn:Show(); r.orderBtn.fulfill = true
            r.orderBtn:SetScript("OnClick", function() promptFulfill(d.buyer, id, d.suffix, d.qty, d.price) end)
        end
    else   -- "wantitem": one item the open buyer wants
        r.icon:SetTexture(GetItemIcon(d.id)); r.icon:Show()
        r.c1.fs:SetText(vLink(d.id, d.suffix) or vName(d.id, d.suffix))
        r.c1.tip = "Right-click to whisper " .. (d.buyer or "") .. " · ctrl-click to find sellers"
        r.c1.itemLink = vLink(d.id, d.suffix)
        r.c1:SetScript("OnClick", function(_, button)
            if button == "RightButton" then whisperItem(d.buyer, d.id, d.suffix, d.price)
            elseif IsControlKeyDown() then ns.SelectTab("BUY"); selectSearchItem(d.id) end
        end)
        r.c2:SetText(d.qty or 0)
        r.c3:SetText(wantPriceText(d.price, d.cod))
        if d.cod and (d.price or 0) > 0 and d.buyer ~= playerName then
            r.orderBtn:Show(); r.orderBtn.fulfill = true
            r.orderBtn:SetScript("OnClick", function() promptFulfill(d.buyer, d.id, d.suffix, d.qty, d.price) end)
        end
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
    r.seller.player = d.seller   -- hover shows "Name <Guild>" (the column is too narrow for it inline)
    -- the seller's location below it: from this browse reply, else a location we already learned
    -- for them in a Sellers scan (covers sellers on an older client that sent no loc on QR)
    local sloc = ns.sellers.results[d.seller]
    r.seller.loc = (d.loc and d.loc ~= "" and d.loc) or (sloc and sloc.loc) or nil
    if d.self then r.seller:SetScript("OnClick", function() ns.SelectTab("MINE") end)
    else r.seller:SetScript("OnClick", function()
        pendingCatFilter = itemName(d.id)   -- open their shop filtered to this browsed item
        ns.SelectTab("SELLERS", d.seller)
    end) end
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
            elseif currentTab == "BUYERS" then formatBuyerRow(r, d)
            elseif currentTab == "MINE" and mineMode == "WTB" then formatWantRow(r, d)
            elseif currentTab == "MINE" and mineMode == "ORDERS" then formatOrderRow(r, d)
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

-- Sort one of the shared item lists in place. `nameOf(d)` yields the row's sort name
-- (seller for Buy search, item name for My Items / catalog). Quality uses the precomputed
-- d.q. Ties always fall back to name ascending, then suffix, for a stable order.
local function sortItemView(list, sort, nameOf)
    local col, asc = sort.col, sort.asc
    table.sort(list, function(a, b)
        if col == "qty" then
            local qa, qb = a.qty or 0, b.qty or 0
            if qa ~= qb then return asc == (qa < qb) end
        elseif col == "price" then
            local pa = (a.price or 0) > 0 and a.price or math.huge
            local pb = (b.price or 0) > 0 and b.price or math.huge
            if pa ~= pb then return asc == (pa < pb) end
        elseif col == "qual" then
            local qa, qb = a.q or 0, b.q or 0
            if qa ~= qb then return asc == (qa < qb) end
        else   -- name
            local na, nb = nameOf(a), nameOf(b)
            if na ~= nb then return asc == (na < nb) end
        end
        local na, nb = nameOf(a), nameOf(b)
        if na ~= nb then return na < nb end
        return (a.suffix or 0) < (b.suffix or 0)
    end)
end

-- Write the three shared headers with a sort arrow on the active column. The first column
-- doubles as the quality/name "Item" sort when qualCol is true (My Items / catalog), or is a
-- plain name sort otherwise (Buy search's "Seller").
local function applyItemHeaderArrows(sort, nameLabel, qualCol)
    local onName = (sort.col == "name") or (qualCol and sort.col == "qual")
    main.h1:SetText(nameLabel .. (onName and (sort.asc and SORT_UP or SORT_DOWN) or ""))
    main.h2:SetText("Qty" .. sortArrow(sort, "qty"))
    main.h3:SetText("Price/unit" .. sortArrow(sort, "price"))
end

-- The sort state of whichever shared item list is on screen (nil if none is).
function activeItemSort()
    if currentTab == "MINE" then
        if mineMode == "ORDERS" then return nil end   -- orders come newest-first, no column sort
        return mineMode == "WTB" and wantSort or mineSort
    end
    if currentTab == "BUY" and buyMode == "SEARCH" then return buySort end
    if currentTab == "SELLERS" and sellersView == "SHOW" then return catalogSort end
    if currentTab == "BUYERS" then
        if buyersView == "SHOW" then return buyerCatalogSort end
        if buyersView == "FIND" then return findBuyersSort end
    end
end

function refreshActiveItemView()
    if currentTab == "MINE" then
        if mineMode == "WTB" then ns.RefreshWant()
        elseif mineMode == "ORDERS" then ns.RefreshOrders()
        else ns.RefreshMine() end
    elseif currentTab == "BUY" then ns.RefreshBuy()
    elseif currentTab == "SELLERS" then ns.RefreshSellerCatalog()
    elseif currentTab == "BUYERS" then if buyersView == "SHOW" then ns.RefreshBuyerCatalog() else ns.RefreshFindBuyers() end end
end

-- Show the sort-header overlays that fit the current view: the item-column overlays for the
-- shared item lists, the index overlays for the Sellers/Buyers index, neither elsewhere.
function updateSharedSortHeaders()
    if not main or not main.itemSort1 then return end
    local itemView  = (currentTab == "MINE" and mineMode ~= "ORDERS")
        or (currentTab == "BUY" and buyMode == "SEARCH")
        or (currentTab == "SELLERS" and sellersView == "SHOW")
        or (currentTab == "BUYERS" and (buyersView == "SHOW" or buyersView == "FIND"))
    local sellerIndex = (currentTab == "SELLERS" and sellersView == "INDEX")
    local buyerIndex  = (currentTab == "BUYERS" and buyersView == "INDEX")
    main.itemSort1:SetShown(itemView); main.itemSort2:SetShown(itemView); main.itemSort3:SetShown(itemView)
    main.sortName:SetShown(sellerIndex); main.sortCount:SetShown(sellerIndex)
    main.buyerSortName:SetShown(buyerIndex); main.buyerSortCount:SetShown(buyerIndex)
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
        applyItemHeaderArrows(buySort, "Seller", false)
        sortItemView(view, buySort, function(d) return d.seller or "" end)
    end, function()
        if not ns.search.itemID then
            main.status:SetText("")
        elseif ns.search.active then
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText("Searching " .. itemName(ns.search.itemID) .. " ...")
        elseif #view == 0 then
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText("No online sellers for " .. itemName(ns.search.itemID) .. ".")
        else
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText(("%d offer(s); click a column to sort."):format(#view))
        end
    end)
end

--========================================================================
-- refresh: My Items
--========================================================================
function ns.RefreshMine()
    local filter, hasOffers, parked   -- shared by build (to match names) and status (to report empties/parked)
    refreshList(currentTab == "MINE", function()
        filter = (main.mineFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        for key, o in pairs(GuildFoundMarketCharDB.offers) do
            hasOffers = true
            local id, suffix = o.id or tonumber(key), o.suffix or 0
            if filter == "" or vName(id, suffix):lower():find(filter, 1, true) then
                if (o.qty or 0) <= 0 then parked = (parked or 0) + 1 end
                view[#view + 1] = { id = id, suffix = suffix, qty = o.qty, price = o.price, track = o.track, key = key, q = (itemQualLevel(id, suffix)) }
            end
        end
        applyItemHeaderArrows(mineSort, "Item", true)
        sortItemView(view, mineSort, function(d) return vName(d.id, d.suffix) end)
    end, function()
        if GuildFoundMarketCharDB.paused then
            main.status:SetTextColor(1, 0.6, 0.2)
            main.status:SetText("Listings paused: not answering searches. Click \"Offline\" to go back online.")
        elseif not hasOffers then
            main.status:SetTextColor(0.7, 0.7, 0.7)
            main.status:SetText("No items listed yet: pick one up and click the slot below to offer it.")
        elseif #view == 0 then
            main.status:SetTextColor(0.7, 0.7, 0.7)
            main.status:SetText("No listed item matches \"" .. (filter or "") .. "\".")
        elseif parked then
            main.status:SetTextColor(1, 0.6, 0.2)
            main.status:SetText(parked == 1
                and "1 listing is parked (qty 0): hidden from others, only you see it. Edit it to set a qty above 0."
                or (parked .. " listings are parked (qty 0): hidden from others, only you see them. Edit one to set a qty above 0."))
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
            view[#view + 1] = { kind = "seller", seller = s, count = rec.count, loc = rec.loc, hasNote = rec.hasNote }
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

-- A seller's note just arrived (NR): if its bubble is on screen and the cursor is over it,
-- re-show the tooltip so a note clicked a moment ago appears without moving the mouse.
function ns.NoteArrived(seller)
    if ns.RefreshShopLinkTooltip then ns.RefreshShopLinkTooltip(seller) end   -- chat-link hover, no window needed
    if not main or not main:IsShown() then return end
    for i = 1, ROWS do
        local b = rows[i].noteBtn
        if b:IsShown() and b.seller == seller and b:IsMouseOver() then
            local onEnter = b:GetScript("OnEnter"); if onEnter then onEnter(b) end
        end
    end
end

--========================================================================
-- refresh: Sellers show view (one seller's catalog, fetched lazily)
--========================================================================
function ns.RefreshSellerCatalog()
    local cat = ns.sellers.catalog
    local filter, hasItems   -- shared by build (to match names) and status (to report empties)
    refreshList(currentTab == "SELLERS" and sellersView == "SHOW", function()
        if cat then
            main.sellerHeader:SetText(cat.seller .. ((cat.loc and cat.loc ~= "") and ("  |cff888888" .. cat.loc .. "|r") or ""))
            ns.SetHeaderPlayer(main.sellerHeaderHover, main.sellerHeader, cat.seller)
            if cat.note and cat.note ~= "" then
                main.sellerNoteText:SetText(cat.note)
                main.sellerNotePanel:SetHeight(math.min(86, math.max(40, main.sellerNoteText:GetStringHeight() + 26)))
                main.sellerNotePanel:Show()
            else
                main.sellerNotePanel:Hide()
            end
            filter = (main.catalogFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
            for _, it in pairs(cat.items) do
                hasItems = true
                local suffix = it.suffix or 0
                if filter == "" or vName(it.id, suffix):lower():find(filter, 1, true) then
                    view[#view + 1] = { kind = "item", id = it.id, suffix = suffix, qty = it.qty, price = it.price, seller = cat.seller, q = (itemQualLevel(it.id, suffix)) }
                end
            end
            applyItemHeaderArrows(catalogSort, "Item", true)
            sortItemView(view, catalogSort, function(d) return vName(d.id, d.suffix) end)
        end
    end, function()
        main.status:SetTextColor(0.7, 0.7, 0.7)
        if cat and cat.loading then
            main.status:SetText("Loading " .. cat.seller .. "'s items ...")
        elseif cat and not hasItems then
            main.status:SetText(cat.seller .. " has nothing listed right now.")
        elseif cat and #view == 0 then
            main.status:SetText("No item matches \"" .. (filter or "") .. "\".")
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
    main.sellerHeaderHover:SetShown(not index)
    main.sellerWtsBtn:SetShown(not index); main.sellerWtbBtn:SetShown(not index)
    main.sellerWtsBtn.sel:SetShown(not index); main.sellerWtbBtn.sel:Hide()   -- WTS is the active facet here
    main.catalogFilter:SetShown(not index); main.catalogFilterLabel:SetShown(not index)
    -- fresh seller: drop any leftover filter, unless we were opened "for" a specific item
    -- (a Buy result / Browse row), in which case pre-filter their shop to it
    if not index then main.catalogFilter:SetText(pendingCatFilter or ""); pendingCatFilter = nil end
    if index then main.sellerNotePanel:Hide() end          -- shown again by the catalog refresh when a note loads
    updateSharedSortHeaders()
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
-- refresh: My WTB list (your own wanted items) — buy-side mirror of RefreshMine
--========================================================================
function ns.RefreshWant()
    local filter, hasWants
    refreshList(currentTab == "MINE" and mineMode == "WTB", function()
        filter = (main.wtbFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        for key, w in pairs(GuildFoundMarketCharDB.wants) do
            hasWants = true
            local id, suffix = w.id or tonumber(key), w.suffix or 0
            if filter == "" or vName(id, suffix):lower():find(filter, 1, true) then
                view[#view + 1] = { id = id, suffix = suffix, qty = w.qty, price = w.price, cod = w.cod, key = key, q = (itemQualLevel(id, suffix)) }
            end
        end
        applyItemHeaderArrows(wantSort, "Item", true)
        sortItemView(view, wantSort, function(d) return vName(d.id, d.suffix) end)
    end, function()
        if GuildFoundMarketCharDB.paused then
            main.status:SetTextColor(1, 0.6, 0.2)
            main.status:SetText("Listings paused: not answering buyer searches. Click \"Offline\" to go back online.")
        elseif not hasWants then
            main.status:SetTextColor(0.7, 0.7, 0.7)
            main.status:SetText("Nothing wanted yet: pick an item below to add it to your WTB list.")
        elseif #view == 0 then
            main.status:SetTextColor(0.7, 0.7, 0.7)
            main.status:SetText("No wanted item matches \"" .. (filter or "") .. "\".")
        else
            main.status:SetText("")
        end
    end)
end

--========================================================================
-- refresh: Orders (My Items sub-tab): incoming and outgoing mail orders, newest first
--========================================================================
function ns.RefreshOrders()
    -- badge on the sub-tab: how many incoming orders await a decision. Updated even when the
    -- view itself isn't on screen, so an order arriving mid-session shows up on the tab.
    if main and main.mineOrdersBtn then
        local n = ns.NewOrderCount()
        main.mineOrdersBtn.fs:SetText(n > 0 and ("Orders |cffff8800(" .. n .. ")|r") or "Orders")
    end
    refreshList(currentTab == "MINE" and mineMode == "ORDERS", function()
        for _, d in ipairs(ns.OrderRows()) do view[#view + 1] = d end
    end, function()
        main.status:SetTextColor(0.7, 0.7, 0.7)
        if #view == 0 then
            main.status:SetText("No mail orders. Buyers order from your shop with the mail icon; your orders to sellers land here too.")
        else
            main.status:SetText("Accept an incoming order, then mail it COD from any mailbox (GFM fills in the mail for you).")
        end
    end)
end

--========================================================================
-- refresh: Buyers index (online buyers with a want list) — mirror of RefreshSellers
--========================================================================
function ns.RefreshBuyers()
    local filter
    refreshList(currentTab == "BUYERS" and buyersView == "INDEX", function()
        filter = (main.buyerFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        local names = {}
        for s in pairs(ns.buyers.results) do
            if filter == "" or s:lower():find(filter, 1, true) then names[#names + 1] = s end
        end
        local asc = buyerSort.asc
        if buyerSort.col == "count" then
            table.sort(names, function(a, b)
                local ca, cb = ns.buyers.results[a].count or 0, ns.buyers.results[b].count or 0
                if ca ~= cb then return asc and ca < cb or (not asc and ca > cb) end
                return a < b
            end)
        else
            table.sort(names, function(a, b) return asc and a < b or (not asc and a > b) end)
        end
        main.h1:SetText("Buyer" .. (buyerSort.col == "name"  and (asc and SORT_UP or SORT_DOWN) or ""))
        main.h2:SetText("Wants" .. (buyerSort.col == "count" and (asc and SORT_UP or SORT_DOWN) or ""))
        for _, s in ipairs(names) do
            local rec = ns.buyers.results[s]
            view[#view + 1] = { kind = "buyer", buyer = s, count = rec.count, loc = rec.loc, hasNote = rec.hasNote, self = (s == playerName) }
        end
    end, function()
        main.status:SetTextColor(0.7, 0.7, 0.7)
        local sf = ns.buyers.filter
        if ns.buyers.scanning then
            main.status:SetText((sf and sf ~= "") and ("Searching buyers matching \"" .. sf .. "\" ...")
                or "Scanning your confederation for buyers ...")
        elseif next(ns.buyers.results) == nil then
            main.status:SetText((sf and sf ~= "") and ("No buyer matches \"" .. sf .. "\".")
                or "No buyers with a want list right now.")
        elseif #view == 0 then
            main.status:SetText("No buyer matches \"" .. (filter or "") .. "\".")
        elseif ns.buyers.capped then
            main.status:SetText(("Showing %d buyers (capped); type %d+ letters of a name and press Enter."):format(#view, ns.FILTER_MIN))
        else
            main.status:SetText(("%d buyer(s): click one to see what they want."):format(#view))
        end
    end)
end

--========================================================================
-- refresh: "who wants this item?" results — buy-side mirror of RefreshBuy
--========================================================================
function ns.RefreshFindBuyers()
    refreshList(currentTab == "BUYERS" and buyersView == "FIND", function()
        for _, o in pairs(ns.buyers.find.results) do
            view[#view + 1] = { kind = "findbuyer", buyer = o.buyer, suffix = o.suffix or 0, qty = o.qty, price = o.price, cod = o.cod, loc = o.loc, self = o.self }
        end
        applyItemHeaderArrows(findBuyersSort, "Buyer", false)
        sortItemView(view, findBuyersSort, function(d) return d.buyer or "" end)
    end, function()
        local id = ns.buyers.find.itemID
        if not id then
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText("Type an item above to find buyers who want it.")
        elseif ns.buyers.find.active then
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText("Looking for buyers of " .. itemName(id) .. " ...")
        elseif #view == 0 then
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText("No one is looking for " .. itemName(id) .. " right now.")
        else
            main.status:SetTextColor(0.7, 0.7, 0.7); main.status:SetText(("%d buyer(s) want %s; right-click to whisper."):format(#view, itemName(id)))
        end
    end)
end

--========================================================================
-- refresh: one buyer's full want list — mirror of RefreshSellerCatalog
--========================================================================
function ns.RefreshBuyerCatalog()
    local cat = ns.buyers.catalog
    local filter, hasItems
    refreshList(currentTab == "BUYERS" and buyersView == "SHOW", function()
        if cat then
            main.buyerHeader:SetText(cat.buyer .. ((cat.loc and cat.loc ~= "") and ("  |cff888888" .. cat.loc .. "|r") or ""))
            ns.SetHeaderPlayer(main.buyerHeaderHover, main.buyerHeader, cat.buyer)
            if cat.note and cat.note ~= "" then
                main.buyerNoteText:SetText(cat.note)
                main.buyerNotePanel:SetHeight(math.min(86, math.max(40, main.buyerNoteText:GetStringHeight() + 26)))
                main.buyerNotePanel:Show()
            else
                main.buyerNotePanel:Hide()
            end
            filter = (main.buyerCatalogFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
            for _, it in pairs(cat.items) do
                hasItems = true
                local suffix = it.suffix or 0
                if filter == "" or vName(it.id, suffix):lower():find(filter, 1, true) then
                    view[#view + 1] = { kind = "wantitem", id = it.id, suffix = suffix, qty = it.qty, price = it.price, cod = it.cod, buyer = cat.buyer, q = (itemQualLevel(it.id, suffix)) }
                end
            end
            applyItemHeaderArrows(buyerCatalogSort, "Item", true)
            sortItemView(view, buyerCatalogSort, function(d) return vName(d.id, d.suffix) end)
        end
    end, function()
        main.status:SetTextColor(0.7, 0.7, 0.7)
        if cat and cat.loading then
            main.status:SetText("Loading " .. cat.buyer .. "'s want list ...")
        elseif cat and not hasItems then
            main.status:SetText(cat.buyer .. " wants nothing right now.")
        elseif cat and #view == 0 then
            main.status:SetText("No wanted item matches \"" .. (filter or "") .. "\".")
        elseif cat then
            main.status:SetText(("%d wanted item(s): right-click one to whisper %s."):format(#view, cat.buyer))
        end
    end)
end

-- Switch the Buyers tab between the index, "who wants X" results, and one buyer's want list.
function ns.SetBuyersView(v)
    if not main then return end
    buyersView = v
    local index = (v == "INDEX")
    local show  = (v == "SHOW")
    local find  = (v == "FIND")
    -- INDEX = search buyers by name (+ "Search by item »"); FIND = search an item (+ "« Find
    -- buyer"); SHOW = one buyer's want list (+ "< Back"). Each mode shows only its own chrome.
    main.buyerFilter:SetShown(index); main.buyerFilterLabel:SetShown(index)
    main.buyerRefreshBtn:SetShown(index); main.buyerToItemBtn:SetShown(index)
    main.searchBox:SetShown(find); main.searchLabel:SetShown(find); main.buyerToIndexBtn:SetShown(find)
    main.buyerFindRefreshBtn:SetShown(find)
    main.buyerBackBtn:SetShown(show); main.buyerHeader:SetShown(show)
    main.buyerHeaderHover:SetShown(show)
    main.buyerWtsBtn:SetShown(show); main.buyerWtbBtn:SetShown(show)
    main.buyerWtbBtn.sel:SetShown(show); main.buyerWtsBtn.sel:Hide()   -- WTB is the active facet here
    main.buyerCatalogFilter:SetShown(show); main.buyerCatalogFilterLabel:SetShown(show)
    if not show then main.buyerNotePanel:Hide() end   -- the catalog refresh re-shows it when a note loads
    -- fresh buyer: clear the filter, unless we were opened "for" a specific item (a "who wants
    -- this" hit), in which case pre-filter their want list to it
    if show then main.buyerCatalogFilter:SetText(pendingCatFilter or ""); pendingCatFilter = nil end
    if find then main.searchLabel:SetText("Find item:"); main.searchBox:SetWidth(300) end
    main.ac:Hide()
    updateSharedSortHeaders()
    if index then
        main.h1:SetText("Buyer"); main.h2:SetText("Wants"); main.h3:SetText(""); main.h4:SetText("Location")
    elseif find then
        main.h1:SetText("Buyer"); main.h2:SetText("Qty"); main.h3:SetText("Price"); main.h4:SetText("Location")
    else
        main.h1:SetText("Item"); main.h2:SetText("Qty"); main.h3:SetText("Price"); main.h4:SetText("")
    end
    wipe(view)
    FauxScrollFrame_SetOffset(main.scroll, 0); main.scroll:SetVerticalScroll(0)
    if index then ns.RefreshBuyers() elseif find then ns.RefreshFindBuyers() else ns.RefreshBuyerCatalog() end
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
    -- the Item header carries the arrow for either of its sort keys (quality or name)
    local itemArr = (browseSort.col == "qual" or browseSort.col == "name") and (browseSort.asc and up or down) or ""
    main.bhItem:SetText("Item" .. itemArr)
    main.bhLvl:SetText("Lvl" .. arr("lvl"))
    main.bhQty:SetText("Qty" .. arr("qty"))
    main.bhPrice:SetText("Price" .. arr("price"))
end

-- Armor subclasses get a third sidebar level by equip slot, so the QC query can narrow by
-- slot instead of fetching the whole subclass. The slot lists are fixed per subclass (we no
-- longer fetch the whole subclass to discover them). 0=Misc, 1=Cloth, 2=Leather, 3=Mail, 4=Plate.
local ARMOR_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
local BODY = { "INVTYPE_HEAD", "INVTYPE_SHOULDER", "INVTYPE_CHEST", "INVTYPE_WRIST", "INVTYPE_HAND", "INVTYPE_WAIST", "INVTYPE_LEGS", "INVTYPE_FEET" }
-- cloaks classify as Cloth, so Back belongs only under Cloth, not Leather/Mail/Plate
local CLOTH = { unpack(BODY) }; CLOTH[#CLOTH + 1] = "INVTYPE_CLOAK"
local ACCESSORY = { "INVTYPE_NECK", "INVTYPE_FINGER", "INVTYPE_TRINKET", "INVTYPE_HOLDABLE" }
local ARMOR_SUB_SLOTS = { [0] = ACCESSORY, [1] = CLOTH, [2] = BODY, [3] = BODY, [4] = BODY }

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
                local slots = (cls.id == ARMOR_CLASS) and ARMOR_SUB_SLOTS[sub.id] or nil
                if slots then
                    -- Armor subclass: a branch that expands to slot leaves (no query on its own)
                    local subOpen = (browseExpandedSub == sub.id)
                    sideView[#sideView + 1] = {
                        label = (subOpen and "- " or "+ ") .. sub.name, indent = 22, r = 0.85, g = 0.85, b = 0.85,
                        onClick = function()
                            -- explicit if/else: `x and nil or y` would never clear it (true and nil -> y)
                            if browseExpandedSub == sub.id then browseExpandedSub = nil else browseExpandedSub = sub.id end
                            ns.RefreshSidebar()
                        end,
                    }
                    if subOpen then
                        for _, loc in ipairs(slots) do
                            local label = _G[loc] or loc
                            local s = (browseSel.class == cls.id and browseSel.sub == sub.id and browseSel.slot == loc)
                            sideView[#sideView + 1] = {
                                label = label, indent = 38, selected = s,
                                r = s and 1 or 0.8, g = s and 0.82 or 0.8, b = s and 0 or 0.8,
                                onClick = function()
                                    browseSel.class, browseSel.sub, browseSel.slot = cls.id, sub.id, loc
                                    browseSel.label = cls.name .. " > " .. sub.name .. " > " .. label
                                    ns.RefreshSidebar()
                                    if ns.BrowseCategory then ns.BrowseCategory(cls.id, sub.id, loc) end
                                end,
                            }
                        end
                    end
                else
                    -- non-Armor subclass: a leaf that queries the whole subclass (no slot)
                    local sel = (browseSel.class == cls.id and browseSel.sub == sub.id and not browseSel.slot)
                    sideView[#sideView + 1] = {
                        label = sub.name, indent = 22, selected = sel,
                        r = sel and 1 or 0.85, g = sel and 0.82 or 0.85, b = sel and 0 or 0.85,
                        onClick = function()
                            browseSel.class, browseSel.sub, browseSel.slot = cls.id, sub.id, nil
                            browseSel.label = cls.name .. " > " .. sub.name
                            ns.RefreshSidebar()
                            if ns.BrowseCategory then ns.BrowseCategory(cls.id, sub.id) end
                        end,
                    }
                end
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
        local slotOK = (not browseSel.slot) or ns.EquipSlot(o.id) == browseSel.slot   -- drop old sellers' over-replies
        if nameOK and lvlOK and slotOK then
            total = total + 1
            browseView[#browseView + 1] = { id = o.id, suffix = o.suffix, qty = o.qty, price = o.price, seller = o.seller, loc = o.loc, self = o.self, q = q, lvl = lvl }
        end
    end
    local col, asc = browseSort.col, browseSort.asc
    table.sort(browseView, function(a, b)
        if col == "name" then
            local na, nb = vName(a.id, a.suffix), vName(b.id, b.suffix)
            if na ~= nb then return asc == (na < nb) end
            return a.seller < b.seller
        end
        local va, vb
        if col == "price" then
            va = (a.price or 0) > 0 and a.price or math.huge
            vb = (b.price or 0) > 0 and b.price or math.huge
        elseif col == "qual" then va = a.q; vb = b.q
        elseif col == "qty" then va = a.qty or 0; vb = b.qty or 0
        else va = a.lvl; vb = b.lvl end
        if va ~= vb then return asc == (va < vb) end
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
    main.bSortItem:SetShown(browse); main.bSortLvl:SetShown(browse); main.bSortQty:SetShown(browse); main.bSortPrice:SetShown(browse)
    updateSharedSortHeaders()   -- show the item-column overlays in Search, hide them in Browse
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
        if p.want    and ns.RefreshWant           then ns.RefreshWant() end
        if p.buyers  and ns.RefreshBuyers         then ns.RefreshBuyers() end
        if p.findbuy and ns.RefreshFindBuyers     then ns.RefreshFindBuyers() end
        if p.bcat    and ns.RefreshBuyerCatalog   then ns.RefreshBuyerCatalog() end
        if p.orders  and ns.RefreshOrders         then ns.RefreshOrders() end
    end)
end
function ns.RefreshBuySoon()           scheduleRefresh("buy") end
function ns.RefreshMineSoon()          scheduleRefresh("mine") end
function ns.RefreshSellersSoon()       scheduleRefresh("sellers") end
function ns.RefreshSellerCatalogSoon() scheduleRefresh("catalog") end
function ns.RefreshBrowseSoon()        scheduleRefresh("browse") end
function ns.RefreshWantSoon()          scheduleRefresh("want") end
function ns.RefreshBuyersSoon()        scheduleRefresh("buyers") end
function ns.RefreshFindBuyersSoon()    scheduleRefresh("findbuy") end
function ns.RefreshBuyerCatalogSoon()  scheduleRefresh("bcat") end
function ns.RefreshOrdersSoon()        scheduleRefresh("orders") end

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
        { tab = "BUYERS", label = "Buyers", w = 80 },
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

-- A one-click reset "x" pinned inside the right edge of a search/find/filter box. It shows only
-- while the box holds text and, on click, runs `onClear` (the same reset the box's Escape key
-- does). Hooking OnTextChanged means the "x" also appears/disappears when we set the text in code
-- (e.g. pre-filtering a catalog), not just on typing.
local function addClearButton(box, onClear)
    local btn = CreateFrame("Button", nil, box)
    btn:SetSize(14, 14); btn:SetPoint("RIGHT", -3, 0)
    btn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")   -- a small red x, present in Classic
    btn:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    btn:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Clear"); GameTooltip:Show() end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
    btn:SetScript("OnClick", function() onClear(box); box:ClearFocus() end)
    local function sync() btn:SetShown((box:GetText() or "") ~= "") end
    box:HookScript("OnTextChanged", sync)
    sync()
    box.clearBtn = btn
    return btn
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
            if not (main and main:IsShown() and (currentTab == "BUY" or currentTab == "BUYERS") and main.searchBox and main.searchBox:HasFocus()) then return end
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
        if selectedSearchID then selectItem(selectedSearchID, self:GetText()); ac:Hide(); self:ClearFocus()
        elseif matches[1] then selectItem(matches[1].id, matches[1].name) end
    end)
    -- shift-click an item link/bag item into the search box
    main.searchBox:SetScript("OnReceiveDrag", function(self)
        local t, id = GetCursorInfo()
        if t == "item" and id then ClearCursor(); ns.ItemDB.Learn(id); selectItem(id, itemName(id)) end
    end)
    -- reset: empty the box, drop the picked item, and clear whatever it was showing (Buy sellers
    -- or, on the Buyers tab, the "who wants this" hits)
    addClearButton(main.searchBox, function(b)
        b:SetText(""); ac:Hide(); selectedSearchID = nil
        if currentTab == "BUYERS" then
            ns.buyers.find.itemID = nil; wipe(ns.buyers.find.results)
            if ns.RefreshFindBuyers then ns.RefreshFindBuyers() end
        else
            ns.search.itemID = nil; wipe(ns.search.results)
            if ns.RefreshBuy then ns.RefreshBuy() end
        end
    end)
end

local function buildHeaders()
    -- column headers
    local function header(x) local fs = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); fs:SetPoint("TOPLEFT", x, -96); return fs end
    main.h1 = header(28); main.h2 = header(322); main.h3 = header(384); main.h4 = header(524)

    -- clickable overlays on the index Name/Count headers (Sellers and Buyers); shown only in
    -- the matching index view (see SetSellersView/SetBuyersView). Toggle asc/desc on repeat.
    local function sortHeaderBtn(target, col, w, sortState, refresh)
        local b = CreateFrame("Button", nil, main)
        b:SetPoint("LEFT", target, "LEFT", -2, 0); b:SetSize(w, 16)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:SetScript("OnClick", function()
            if sortState.col == col then sortState.asc = not sortState.asc
            else sortState.col = col; sortState.asc = true end
            refresh()
        end)
        b:Hide()
        return b
    end
    main.sortName       = sortHeaderBtn(main.h1, "name",  150, sellerSort, function() ns.RefreshSellers() end)
    main.sortCount      = sortHeaderBtn(main.h2, "count", 48,  sellerSort, function() ns.RefreshSellers() end)
    main.buyerSortName  = sortHeaderBtn(main.h1, "name",  150, buyerSort,  function() ns.RefreshBuyers() end)
    main.buyerSortCount = sortHeaderBtn(main.h2, "count", 48,  buyerSort,  function() ns.RefreshBuyers() end)

    -- clickable overlays on the Item/Qty/Price headers, shared by the three item lists
    -- (Buy search, My Items, seller catalog). The first header sorts by quality/name (a
    -- 4-way cycle on the item lists) or plainly by seller name on the Buy results.
    local function itemSortBtn(target, kind, w)
        local b = CreateFrame("Button", nil, main)
        b:SetPoint("LEFT", target, "LEFT", -2, 0); b:SetSize(w, 16)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:SetScript("OnClick", function()
            local s = activeItemSort()
            if not s then return end
            if kind == "name" then
                if s == buySort or s == findBuyersSort then   -- results lists: first column is a plain name (seller/buyer) toggle, no quality
                    if s.col == "name" then s.asc = not s.asc else s.col = "name"; s.asc = SORT_DEFAULT_ASC.name end
                elseif s.itemSorted then       -- already cycling the Item column: advance one step
                    s.col, s.asc = nextItemSort(s)
                else                           -- first Item click from the alphabetical default: start at quality desc
                    s.col, s.asc, s.itemSorted = "qual", false, true
                end
            else
                local col = (kind == "qty") and "qty" or "price"
                if s.col == col then s.asc = not s.asc else s.col = col; s.asc = SORT_DEFAULT_ASC[col] end
                s.itemSorted = false           -- leaving the Item column restarts its cycle on the next click
            end
            refreshActiveItemView()
        end)
        b:Hide(); return b
    end
    main.itemSort1 = itemSortBtn(main.h1, "name",  290)
    main.itemSort2 = itemSortBtn(main.h2, "qty",   56)
    main.itemSort3 = itemSortBtn(main.h3, "price", 130)
end

-- Whole-row hover highlight. A HIGHLIGHT texture only lights the single frame under the
-- cursor, so hovering a child button (the item name, the seller, X/Edit) would otherwise
-- highlight just that cell. Instead we drive one row-wide bar from hover events on the row
-- and each of its interactive children, keeping it lit while the cursor is anywhere on the
-- row. The bar sits on BACKGROUND so it never tints the icon or text.
local function addRowHighlight(r, ...)
    r.rowHL = r:CreateTexture(nil, "BACKGROUND")
    r.rowHL:SetAllPoints(); r.rowHL:SetColorTexture(1, 1, 1, 0.14); r.rowHL:Hide()
    r:EnableMouse(true)
    local function show() r.rowHL:Show() end
    local function hide() if not r:IsMouseOver() then r.rowHL:Hide() end end   -- still over a child? stay lit
    r:SetScript("OnEnter", show); r:SetScript("OnLeave", hide)
    for i = 1, select("#", ...) do
        local child = select(i, ...)
        child:HookScript("OnEnter", show)   -- HookScript: coexists with the child's tooltip/click handlers
        child:HookScript("OnLeave", hide)
    end
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
        r.c1:SetScript("OnEnter", function(self)
            if self.itemLink or self.itemID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                -- a reconstructed variant link carries the real suffix stats; the bare
                -- itemID does not, so prefer the link when we have one
                if self.itemLink then GameTooltip:SetHyperlink(self.itemLink)
                else GameTooltip:SetItemByID(self.itemID) end
                if self.tip then GameTooltip:AddLine(self.tip, 0.6, 0.6, 0.6, true) end
                -- on an offer/want row the column is a player: add their name + guild below the item
                if self.player then GameTooltip:AddLine(ns.PlayerTitle(self.player), 1, 1, 1) end
                GameTooltip:Show()
            elseif self.player then
                -- a pure player cell (Sellers/Buyers index): name + guild as the title, tip below
                GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
                GameTooltip:SetText(ns.PlayerTitle(self.player), 1, 1, 1)
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
        -- chat-bubble icon for a player's note (Sellers and Buyers index rows). Positioned after
        -- the location by the formatter, which also sets self.store (the index table to read/cache
        -- in). The note text is fetched on hover (click to retry a failed load); state read live by name.
        r.noteBtn = CreateFrame("Button", nil, r); r.noteBtn:SetSize(16, 16)
        r.noteBtn:SetNormalTexture("Interface\\GossipFrame\\GossipGossipIcon")
        r.noteBtn:RegisterForClicks("LeftButtonUp")
        r.noteBtn:SetScript("OnEnter", function(self)
            -- hovering pulls the note on demand (RequestNote dedupes/guards); NoteArrived refreshes
            -- this tooltip in place when the answer lands, so no click is needed.
            if self.seller and self.store and ns.RequestNote then ns.RequestNote(self.seller, self.store) end
            local rec = self.seller and self.store and self.store[self.seller]
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Note", 1, 0.82, 0)
            if rec and rec.note and rec.note ~= "" then
                ns.AddShopNoteLines(GameTooltip, rec.note)   -- same blurb + bulleted-items format as the link hover
            elseif rec and rec.note == "" then
                GameTooltip:AddLine("This player has no note.", 0.7, 0.7, 0.7, true)
            elseif rec and rec.noteFailed then
                GameTooltip:AddLine("Couldn't load (offline?). Click to retry.", 0.7, 0.7, 0.7, true)
            else
                GameTooltip:AddLine("Loading...", 0.7, 0.7, 0.7, true)
            end
            GameTooltip:Show()
        end)
        r.noteBtn:SetScript("OnLeave", GameTooltip_Hide)
        r.noteBtn:SetScript("OnClick", function(self)
            local rec = self.seller and self.store and self.store[self.seller]
            if rec then rec.noteFailed = nil end   -- explicit retry after a failed hover-load
            if self.seller and self.store and ns.RequestNote then ns.RequestNote(self.seller, self.store) end
            local onEnter = self:GetScript("OnEnter"); if onEnter then onEnter(self) end   -- reflect new state
        end)
        r.noteBtn:Hide()
        -- "Find buyers" icon (My Items › Selling rows only): jumps to the Buyers tab and queries
        -- who wants this item. Positioned left of Edit; OnClick wired per-row in formatMineRow.
        r.findBtn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.findBtn:SetSize(20, 20); r.findBtn:SetPoint("RIGHT", r.edit, "LEFT", -2, 0)
        r.findBtn:RegisterForClicks("LeftButtonUp")
        local fb = r.findBtn:CreateTexture(nil, "ARTWORK"); fb:SetSize(14, 14); fb:SetPoint("CENTER")
        fb:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
        r.findBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Find buyers for this item"); GameTooltip:Show()
        end)
        r.findBtn:SetScript("OnLeave", GameTooltip_Hide)
        r.findBtn:Hide()
        -- "Order by mail" icon (Buy results + seller-catalog rows with a fixed price): sits in
        -- the X button's spot, which those views never show. OnClick wired per-row.
        r.orderBtn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.orderBtn:SetSize(24, 20); r.orderBtn:SetPoint("RIGHT", -2, 0)
        r.orderBtn:RegisterForClicks("LeftButtonUp")
        local ob = r.orderBtn:CreateTexture(nil, "ARTWORK"); ob:SetSize(14, 14); ob:SetPoint("CENTER")
        ob:SetTexture("Interface\\Icons\\INV_Letter_15")
        r.orderBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if self.fulfill then
                GameTooltip:SetText("Fulfil by mail")
                GameTooltip:AddLine("Commit to mail this COD; the buyer already committed to pay the posted price on delivery.", 1, 1, 1, true)
            else
                GameTooltip:SetText("Order by mail")
                GameTooltip:AddLine("Ask the seller to mail you this item COD (you pay the listed price when you collect it).", 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        r.orderBtn:SetScript("OnLeave", GameTooltip_Hide)
        r.orderBtn:Hide()
        -- "Sync" column (My Items rows only): per-listing "follow my bags" toggle, under the h4
        -- header. Wired per-row in formatMineRow; hidden by resetRow on every other tab.
        r.track = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
        r.track:SetSize(24, 24); r.track:SetPoint("LEFT", 524, 0)
        r.track:RegisterForClicks("LeftButtonUp")
        r.track:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Bag sync")
            GameTooltip:AddLine("On: this listing's quantity tracks your stock (0 = parked, hidden but kept). Off: a manual claim, the right choice for stock on another character.", 1, 1, 1, true)
            appendStockReliability(GameTooltip)
            GameTooltip:Show()
        end)
        r.track:SetScript("OnLeave", GameTooltip_Hide)
        r.track:Hide()
        addRowHighlight(r, r.c1, r.x, r.edit, r.noteBtn, r.findBtn, r.track, r.orderBtn)
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
    addClearButton(browseFilter, function(b) b:SetText(""); if ns.RefreshBrowse then ns.RefreshBrowse() end end)

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
            if col == "qual" then browseSort.col, browseSort.asc = nextItemSort(browseSort)   -- Item header: 4-way quality/name cycle
            elseif browseSort.col == col then browseSort.asc = not browseSort.asc
            else browseSort.col = col; browseSort.asc = (col == "price") end   -- price asc, lvl/qty desc by default
            ns.RefreshBrowse()
        end)
        b:Hide(); return b
    end
    main.bSortItem  = browseSortBtn(main.bhItem,  "qual",  120)   -- Item header sorts by quality, then name (cycled)
    main.bSortLvl   = browseSortBtn(main.bhLvl,   "lvl",   40)
    main.bSortQty   = browseSortBtn(main.bhQty,   "qty",   30)
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
        -- the narrow seller column can't fit the guild inline, so reveal "Name <Guild>" on hover
        r.seller:SetScript("OnEnter", function(self)
            if not self.player then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
            GameTooltip:SetText(ns.PlayerTitle(self.player), 1, 1, 1)
            if self.loc and self.loc ~= "" then GameTooltip:AddLine(self.loc, 0.7, 0.7, 0.7, true) end
            GameTooltip:AddLine("Click to see their items", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        r.seller:SetScript("OnLeave", GameTooltip_Hide)
        addRowHighlight(r, r.c1, r.seller)
        r:Hide(); browseRows[i] = r
    end
end

local function buildPostPanel()
    --==================== My Items post panel ====================
    local panel = CreateFrame("Frame", nil, main)
    panel:SetPoint("BOTTOMLEFT", 16, 14); panel:SetPoint("BOTTOMRIGHT", -16, 14); panel:SetHeight(74)
    main.postPanel = panel

    -- shop note: a one-line blurb buyers see beside your name in the Sellers index (a bubble
    -- they click to load it). It travels in its own NR reply, so it can be long; capped to
    -- 240 bytes to fit one ~255-byte addon message. Saved on Enter / focus loss.
    local noteLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    noteLabel:SetPoint("TOPLEFT", 4, -3); noteLabel:SetText("Shop note:")
    local noteBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    noteBox:SetPoint("TOPLEFT", noteLabel, "TOPRIGHT", 12, 3); noteBox:SetHeight(16)
    noteBox:SetAutoFocus(false); noteBox:SetMaxBytes(240)
    -- Preview: hover to see your own note exactly as readers do (same renderer + the format setting).
    local previewBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    previewBtn:SetSize(62, 18); previewBtn:SetPoint("TOPRIGHT", -6, 1); previewBtn:SetText("Preview")
    noteBox:SetPoint("TOPRIGHT", previewBtn, "TOPLEFT", -6, -1)
    previewBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Note preview", 1, 0.82, 0)
        local note = noteBox:GetText() or ""
        if note ~= "" then ns.AddShopNoteLines(GameTooltip, note)
        else GameTooltip:AddLine("Your note is empty.", 0.7, 0.7, 0.7, true) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("How your note looks to readers.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    previewBtn:SetScript("OnLeave", GameTooltip_Hide)
    main.notePreviewBtn = previewBtn
    local function saveNote() noteBox:SetText(ns.SetShopNote(noteBox:GetText())) end
    noteBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); saveNote() end)
    noteBox:SetScript("OnEditFocusLost", saveNote)
    noteBox:SetScript("OnEscapePressed", function(self) self:SetText(ns.GetShopNote()); self:ClearFocus() end)
    noteBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Shop note")
        GameTooltip:AddLine("A short line buyers see next to your name in the Sellers list (chat-bubble icon). Leave empty for none.", 1, 1, 1, true)
        GameTooltip:AddLine("Shift-click an item to add its link to the note.", 0.7, 1, 0.7, true)
        GameTooltip:Show()
    end)
    noteBox:SetScript("OnLeave", GameTooltip_Hide)
    -- Shift-click an item anywhere to drop its link into the note (buyers see the items you sell).
    -- Honour the 240-byte cap: refuse a link that won't fit rather than letting it be silently cut.
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        if link and noteBox:HasFocus() then
            if #(noteBox:GetText() or "") + #link > 240 then
                ns.Feedback("That item link won't fit in your shop note.", true)
            else
                noteBox:Insert(link)
            end
        end
    end)
    main.noteBox = noteBox

    -- key of the listing being edited; nil = composing a brand-new offer
    local editingKey = nil
    -- forward decl: defined once the qty box + "Follow my bags" checkbox exist below. Mirrors
    -- the checkbox onto the qty box (fills the live bag count and greys it out while tracking).
    local applyTrack

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
            if applyTrack then applyTrack() end   -- a tracked new offer shows the live bag count
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
    -- Tab moves between qty and price (Shift+Tab too)
    qtyBox:SetScript("OnTabPressed", function() priceBox:SetFocus(); priceBox:HighlightText() end)
    priceBox:SetScript("OnTabPressed", function() qtyBox:SetFocus(); qtyBox:HighlightText() end)

    -- "Follow my bags": when ticked, this listing's qty tracks how many you carry (0 = parked,
    -- hidden but kept, never deleted). Off = a manual claim, the right choice for stock you keep
    -- on a bank alt. New offers start from the per-account default (the trackDefault setting).
    local trackCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    trackCheck:SetPoint("BOTTOMLEFT", 300, 6); trackCheck:SetSize(26, 26)
    main.trackCheck = trackCheck
    local trackLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    trackLabel:SetPoint("LEFT", trackCheck, "RIGHT", 2, 1); trackLabel:SetText("Follow my bags")
    trackCheck:SetHitRectInsets(0, -(trackLabel:GetStringWidth() + 6), 0, 0)
    trackCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Bag sync")
        GameTooltip:AddLine("Keep this listing's quantity in step with your stock: your bags right now, plus the last-seen contents of this character's bank and mailbox. It falls as you sell or use them and rises as you restock; at 0 it parks (hidden from buyers but kept here), never deleted.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Stock on another character (a bank alt) isn't counted, so leave it off for those listings.", 0.8, 0.8, 0.8, true)
        appendStockReliability(GameTooltip)
        GameTooltip:Show()
    end)
    trackCheck:SetScript("OnLeave", GameTooltip_Hide)

    -- Reflect the checkbox onto the qty box. Tracking on: show the live bag count and grey the
    -- box out (the engine owns the number). Off: a normal editable qty.
    function applyTrack()
        local on = trackCheck:GetChecked()
        if on and draft.itemID and ns.Stock then qtyBox:SetText(tostring(ns.Stock.Count(draft.itemID, draft.suffix or 0))) end
        if on then qtyBox:Disable() else qtyBox:Enable() end
        qtyBox:SetTextColor(on and 0.6 or 1, on and 0.6 or 1, on and 0.6 or 1)
    end
    trackCheck:SetScript("OnClick", applyTrack)
    trackCheck:SetChecked(ns.GetSetting("trackDefault") and true or false); applyTrack()   -- initial state
    -- The trackDefault option only seeds NEW listings, so reflect a change in the Options panel
    -- onto the compose checkbox live (but never stomp a checkbox we're showing for an edit).
    ns.On("setting:trackDefault", function()
        if not editingKey then trackCheck:SetChecked(ns.GetSetting("trackDefault") and true or false); applyTrack() end
    end)

    -- The input accepts BOTH notations (parsePrice reads coins and decimal alike), same as the
    -- WTB field. The priceFormat setting only chooses the FILL format: the example in the label,
    -- the edit prefill (priceToStr), and reformatting the current value when the setting changes.
    local function applyPriceFormat()
        if ns.GetSetting("priceFormat") == "currency" then
            priceLabel:SetText("Price/unit: e.g. 3.50 = 3g50s (also accepts 3g50s; empty to take bids)")
        else
            priceLabel:SetText("Price/unit: e.g. 1g20s34c (also accepts 3.50; empty to take bids)")
        end
        local cur = parsePrice(priceBox:GetText())
        if cur > 0 then priceBox:SetText(priceToStr(cur)) end
    end
    applyPriceFormat()
    ns.On("setting:priceFormat", applyPriceFormat)

    local offerBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    offerBtn:SetSize(90, 24); offerBtn:SetPoint("BOTTOMRIGHT", -4, 8); offerBtn:SetText("Offer")
    main.offerBtn = offerBtn

    -- clear the compose panel back to the empty "new offer" state
    local function clearDraft()
        editingKey = nil
        draft.itemID = nil; draft.suffix = 0; draft.link = nil
        SetItemButtonTexture(slot, nil); SetItemButtonCount(slot, 0)
        qtyBox:SetText("1"); priceBox:SetText("")
        trackCheck:SetChecked(ns.GetSetting("trackDefault") and true or false)
        applyTrack()
        offerBtn:SetText("Offer")
    end

    -- Place a new offer or apply an edit. Shared by the button and by Enter in either box.
    local function submitOffer()
        local qty, price = tonumber(qtyBox:GetText()) or 1, parsePrice(priceBox:GetText())
        local track = trackCheck:GetChecked() and true or false
        if editingKey then
            -- editing only changes qty/price/track; the item/variant stays the listing's own
            if ns.EditOffer(editingKey, qty, price, track) then clearDraft() end
        elseif ns.AddOffer(draft.itemID, draft.suffix or 0, qty, price, track) then
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
        trackCheck:SetChecked(o.track and true or false)
        applyTrack()   -- if tracked, greys the qty box and shows the live bag count
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

-- A small highlighted sub-tab button, shared by the My Items WTS/WTB tabs and the WTS/WTB toggle
-- on a player's detail view, so both look identical (one builder, no duplication).
local function subTabButton(x, text, w)
    local b = CreateFrame("Button", nil, main); b:SetSize(w or 56, 22); b:SetPoint("TOPLEFT", x, -64); b:Hide()
    local sel = b:CreateTexture(nil, "BACKGROUND"); sel:SetAllPoints(); sel:SetColorTexture(1, 0.82, 0, 0.18); sel:Hide(); b.sel = sel
    local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.10)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); fs:SetPoint("CENTER"); fs:SetText(text)
    b.fs = fs
    return b
end

-- Attach an explanatory tooltip (title + wrapped body) to a sub-tab button.
local function attachSubTip(btn, title, body)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(title)
        GameTooltip:AddLine(body, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
end

-- "< Back" from a player's detail view returns to wherever the session began (seller index, buyer
-- index, or buyer find results), even after toggling WTS/WTB across the Sellers/Buyers tabs.
local function goBackToOrigin()
    local o = showOrigin or { tab = "SELLERS", view = "INDEX" }
    if o.tab == "BUYERS" then
        if currentTab ~= "BUYERS" then ns.SelectTab("BUYERS") end
        ns.SetBuyersView(o.view or "INDEX")
    elseif currentTab ~= "SELLERS" then
        ns.SelectTab("SELLERS")
    else
        ns.SetSellersView("INDEX")
    end
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
    addClearButton(sellerFilter, function(b) b:SetText(""); ns.ScanSellers("") end)
    local sellerRefreshBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    sellerRefreshBtn:SetSize(80, 22); sellerRefreshBtn:SetPoint("TOPLEFT", 410, -64); sellerRefreshBtn:SetText("Refresh"); sellerRefreshBtn:Hide()
    sellerRefreshBtn:SetScript("OnClick", function()
        local t = sellerFilterText(); ns.ScanSellers((#t >= ns.FILTER_MIN) and t or "")
    end)
    main.sellerRefreshBtn = sellerRefreshBtn

    local sellerBackBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    sellerBackBtn:SetSize(70, 22); sellerBackBtn:SetPoint("TOPLEFT", 16, -64); sellerBackBtn:SetText("< Back"); sellerBackBtn:Hide()
    sellerBackBtn:SetScript("OnClick", goBackToOrigin)
    main.sellerBackBtn = sellerBackBtn
    -- WTS/WTB toggle for the open seller: WTS is this view; WTB cross-navigates to the SAME player's
    -- want list on the Buyers tab (origin preserved, so "< Back" still returns where you started).
    local sellerWtsBtn = subTabButton(92, "WTS"); main.sellerWtsBtn = sellerWtsBtn
    local sellerWtbBtn = subTabButton(150, "WTB"); main.sellerWtbBtn = sellerWtbBtn
    attachSubTip(sellerWtsBtn, "WTS - Want To Sell", "What this player is offering for sale (this view).")
    attachSubTip(sellerWtbBtn, "WTB - Want To Buy", "What this player wants to buy. Opens their want list.")
    sellerWtbBtn:SetScript("OnClick", function()
        local cat = ns.sellers.catalog
        if not (cat and cat.seller) then return end
        local origin, p, loc = showOrigin, cat.seller, cat.loc
        ns.SelectTab("BUYERS"); ns.OpenBuyer(p, loc); ns.SetBuyersView("SHOW")
        showOrigin = origin
    end)
    local sellerHeader = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sellerHeader:SetPoint("LEFT", sellerWtbBtn, "RIGHT", 12, 0); sellerHeader:SetText(""); sellerHeader:Hide()
    main.sellerHeader = sellerHeader
    -- a transparent hover area over the header name, so the guild shows on the header too (sized
    -- to the text and toggled with the header by SetHeaderPlayer / the view switches below)
    main.sellerHeaderHover = makeHeaderHover(sellerHeader)

    -- the open seller's shop note (arrives bundled with their catalog): an outlined block at the
    -- bottom of the view, under the status line, with a "Shop note" title and the wrapped text.
    local notePanel = CreateFrame("Frame", nil, main, "BackdropTemplate")
    notePanel:SetPoint("BOTTOMLEFT", 16, 14); notePanel:SetPoint("BOTTOMRIGHT", -16, 14); notePanel:SetHeight(48)
    notePanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    notePanel:SetBackdropColor(0, 0, 0, 0.35); notePanel:SetBackdropBorderColor(0.5, 0.5, 0.5)
    notePanel:Hide()
    local noteTitle = notePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    noteTitle:SetPoint("TOPLEFT", 8, -6); noteTitle:SetText("Shop note"); noteTitle:SetTextColor(1, 0.82, 0)
    local noteText = notePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    noteText:SetPoint("TOPLEFT", noteTitle, "BOTTOMLEFT", 0, -4); noteText:SetPoint("RIGHT", notePanel, "RIGHT", -8, 0)
    noteText:SetJustifyH("LEFT"); noteText:SetJustifyV("TOP")
    main.sellerNotePanel = notePanel
    main.sellerNoteText = noteText

    -- substring filter over the open seller's loaded items (client-side, like the Browse filter)
    local catalogFilterLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    catalogFilterLabel:SetPoint("TOPRIGHT", -222, -70); catalogFilterLabel:SetText("Find item:"); catalogFilterLabel:Hide()
    main.catalogFilterLabel = catalogFilterLabel
    local catalogFilter = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    catalogFilter:SetPoint("TOPRIGHT", -40, -66); catalogFilter:SetSize(170, 22); catalogFilter:SetAutoFocus(false); catalogFilter:Hide()
    catalogFilter:SetScript("OnTextChanged", function(_, user) if user then ns.RefreshSellerCatalog() end end)
    catalogFilter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); ns.RefreshSellerCatalog() end)
    main.catalogFilter = catalogFilter
    addClearButton(catalogFilter, function(b) b:SetText(""); ns.RefreshSellerCatalog() end)
end

local function buildBuyerWidgets()
    --==================== Buyers tab widgets (index + find + show) ====================
    -- Two explicit modes you toggle between: INDEX (search buyers by name) and FIND (search an
    -- item, reusing the shared main.searchBox / main.ac). SHOW opens one buyer's want list.
    local buyerFilterLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    buyerFilterLabel:SetPoint("TOPLEFT", 16, -68); buyerFilterLabel:SetText("Find buyer:"); buyerFilterLabel:Hide()
    main.buyerFilterLabel = buyerFilterLabel
    local buyerFilter = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    buyerFilter:SetPoint("TOPLEFT", 100, -64); buyerFilter:SetSize(290, 22); buyerFilter:SetAutoFocus(false); buyerFilter:Hide()
    local function buyerFilterText() return (buyerFilter:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower() end
    buyerFilter:SetScript("OnTextChanged", function(_, user) if user then ns.RefreshBuyers() end end)
    buyerFilter:SetScript("OnEnterPressed", function(self)
        local t = buyerFilterText(); self:ClearFocus()
        if t == "" then ns.ScanBuyers("")
        elseif #t >= ns.FILTER_MIN then ns.ScanBuyers(t)
        else ns.Feedback(("Type at least %d letters of a name to search buyers."):format(ns.FILTER_MIN), true) end
    end)
    buyerFilter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); ns.ScanBuyers("") end)
    main.buyerFilter = buyerFilter
    addClearButton(buyerFilter, function(b) b:SetText(""); ns.ScanBuyers("") end)
    local buyerRefreshBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    buyerRefreshBtn:SetSize(70, 22); buyerRefreshBtn:SetPoint("TOPLEFT", 398, -64); buyerRefreshBtn:SetText("Refresh"); buyerRefreshBtn:Hide()
    buyerRefreshBtn:SetScript("OnClick", function()
        local t = buyerFilterText(); ns.ScanBuyers((#t >= ns.FILTER_MIN) and t or "")
    end)
    main.buyerRefreshBtn = buyerRefreshBtn

    -- mode toggles: INDEX shows "Search by item", FIND shows "Back to buyers". Each clears the
    -- item query so the two modes start clean.
    local function clearFind()
        wipe(ns.buyers.find.results); ns.buyers.find.itemID = nil
        if main.searchBox then main.searchBox:SetText("") end
    end
    local toItemBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    toItemBtn:SetSize(120, 22); toItemBtn:SetPoint("TOPLEFT", 474, -64); toItemBtn:SetText("Search by item »"); toItemBtn:Hide()
    toItemBtn:SetScript("OnClick", function() clearFind(); ns.SetBuyersView("FIND"); main.searchBox:SetFocus() end)
    main.buyerToItemBtn = toItemBtn
    local toIndexBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    toIndexBtn:SetSize(120, 22); toIndexBtn:SetPoint("TOPLEFT", 474, -64); toIndexBtn:SetText("« Find buyer"); toIndexBtn:Hide()
    toIndexBtn:SetScript("OnClick", function() clearFind(); ns.SetBuyersView("INDEX"); ns.ScanBuyers("") end)
    main.buyerToIndexBtn = toIndexBtn

    -- Refresh on the find view: re-run the item query for the current item
    local findRefreshBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    findRefreshBtn:SetSize(64, 22); findRefreshBtn:SetPoint("TOPLEFT", 406, -64); findRefreshBtn:SetText("Refresh"); findRefreshBtn:Hide()
    findRefreshBtn:SetScript("OnClick", function()
        local id = ns.buyers.find.itemID
        if id and ns.FindBuyersForItem then ns.FindBuyersForItem(id) end
    end)
    main.buyerFindRefreshBtn = findRefreshBtn

    local buyerBackBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    buyerBackBtn:SetSize(70, 22); buyerBackBtn:SetPoint("TOPLEFT", 16, -64); buyerBackBtn:SetText("< Back"); buyerBackBtn:Hide()
    buyerBackBtn:SetScript("OnClick", goBackToOrigin)
    main.buyerBackBtn = buyerBackBtn
    -- WTS/WTB toggle for the open buyer: WTB is this view; WTS cross-navigates to the SAME player's
    -- shop on the Sellers tab (origin preserved, so "< Back" still returns where you started).
    local buyerWtsBtn = subTabButton(92, "WTS"); main.buyerWtsBtn = buyerWtsBtn
    local buyerWtbBtn = subTabButton(150, "WTB"); main.buyerWtbBtn = buyerWtbBtn
    attachSubTip(buyerWtsBtn, "WTS - Want To Sell", "What this player is offering for sale. Opens their shop.")
    attachSubTip(buyerWtbBtn, "WTB - Want To Buy", "What this player wants to buy (this view).")
    buyerWtsBtn:SetScript("OnClick", function()
        local cat = ns.buyers.catalog
        if not (cat and cat.buyer) then return end
        local origin, p, loc = showOrigin, cat.buyer, cat.loc
        ns.SelectTab("SELLERS"); ns.SetSellersView("SHOW"); ns.OpenSeller(p, loc)
        showOrigin = origin
    end)
    local buyerHeader = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    buyerHeader:SetPoint("LEFT", buyerWtbBtn, "RIGHT", 12, 0); buyerHeader:SetText(""); buyerHeader:Hide()
    main.buyerHeader = buyerHeader
    main.buyerHeaderHover = makeHeaderHover(buyerHeader)

    local buyerCatalogFilterLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    buyerCatalogFilterLabel:SetPoint("TOPRIGHT", -222, -70); buyerCatalogFilterLabel:SetText("Find item:"); buyerCatalogFilterLabel:Hide()
    main.buyerCatalogFilterLabel = buyerCatalogFilterLabel
    local buyerCatalogFilter = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    buyerCatalogFilter:SetPoint("TOPRIGHT", -40, -66); buyerCatalogFilter:SetSize(170, 22); buyerCatalogFilter:SetAutoFocus(false); buyerCatalogFilter:Hide()
    buyerCatalogFilter:SetScript("OnTextChanged", function(_, user) if user then ns.RefreshBuyerCatalog() end end)
    buyerCatalogFilter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); ns.RefreshBuyerCatalog() end)
    main.buyerCatalogFilter = buyerCatalogFilter
    addClearButton(buyerCatalogFilter, function(b) b:SetText(""); ns.RefreshBuyerCatalog() end)

    -- the open buyer's note (bundled with their want list): an outlined block at the bottom, mirror
    -- of the seller note panel
    local notePanel = CreateFrame("Frame", nil, main, "BackdropTemplate")
    notePanel:SetPoint("BOTTOMLEFT", 16, 14); notePanel:SetPoint("BOTTOMRIGHT", -16, 14); notePanel:SetHeight(48)
    notePanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    notePanel:SetBackdropColor(0, 0, 0, 0.35); notePanel:SetBackdropBorderColor(0.5, 0.5, 0.5)
    notePanel:Hide()
    local noteTitle = notePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    noteTitle:SetPoint("TOPLEFT", 8, -6); noteTitle:SetText("Note"); noteTitle:SetTextColor(1, 0.82, 0)
    local noteText = notePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    noteText:SetPoint("TOPLEFT", noteTitle, "BOTTOMLEFT", 0, -4); noteText:SetPoint("RIGHT", notePanel, "RIGHT", -8, 0)
    noteText:SetJustifyH("LEFT"); noteText:SetJustifyV("TOP")
    main.buyerNotePanel = notePanel
    main.buyerNoteText = noteText
end

local function buildPauseAnnounce()
    --==================== My Items: online/offline toggle ====================
    -- (the "Listings:" label is gone; the Selling/WTB sub-tab buttons live at the far left now,
    -- and the pause button's own text says Online/Offline. Kept as a hidden field for safety.)
    local pauseLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pauseLabel:SetPoint("TOPLEFT", 16, -70); pauseLabel:SetText(""); pauseLabel:Hide()
    main.pauseLabel = pauseLabel
    local pauseBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    pauseBtn:SetSize(104, 22); pauseBtn:SetPoint("TOPLEFT", 204, -64); pauseBtn:Hide()
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

    -- substring filter over your listed items (client-side), sitting between the pause button
    -- and the announce controls
    local mineFilterLabel = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mineFilterLabel:SetPoint("TOPLEFT", 316, -68); mineFilterLabel:SetText("Find item:"); mineFilterLabel:Hide()
    main.mineFilterLabel = mineFilterLabel
    local mineFilter = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    mineFilter:SetPoint("TOPLEFT", 380, -64); mineFilter:SetSize(100, 22); mineFilter:SetAutoFocus(false); mineFilter:Hide()
    mineFilter:SetScript("OnTextChanged", function(_, user) if user then ns.RefreshMine() end end)
    mineFilter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); ns.RefreshMine() end)
    main.mineFilter = mineFilter
    addClearButton(mineFilter, function(b) b:SetText(""); ns.RefreshMine() end)

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
        { key = "guild",   label = "Guild",   avail = function() return IsInGuild() end, why = "Join a guild to use guild chat." },
        { key = "party",   label = "Party",   avail = function() return IsInGroup() end, why = "Join a party for party chat." },
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
        -- the trade channel is always listed, greyed when the guild has not configured one
        local tc = tradeChan()
        list[#list + 1] = {
            key = "channel", configured = tc ~= nil,
            label = tc and tc.name or "Trade channel",
            avail = function() return tc ~= nil and (GetChannelName(tc.name) or 0) > 0 end,
            join  = function() if tc then JoinPermanentChannel(tc.name, tc.password) end end,
            why   = "No trade channel set in your guild info (a GFMtc line).",
        }
        return list
    end
    local function refreshPopup()
        local list = entries()
        for i, d in ipairs(list) do
            local r = popupRow(i)
            local ok = d.avail()
            local joinable = (d.key == "channel" and d.configured and not ok)
            r.fs:SetText(joinable and ("Join " .. d.label) or d.label)
            r.fs:SetTextColor(ok and 1 or (joinable and 1 or 0.5), ok and 1 or (joinable and 0.82 or 0.5), ok and 1 or (joinable and 0 or 0.5))
            r:SetScript("OnClick", function()
                if joinable then
                    popup:Hide(); ns.Feedback("Joining " .. d.label .. " ...", false); d.join()
                    -- the join is async; poll briefly, then auto-select the channel and confirm
                    local name, tries, ticker = d.label, 0
                    ticker = C_Timer.NewTicker(0.3, function()
                        tries = tries + 1
                        if (GetChannelName(name) or 0) > 0 then
                            ticker:Cancel(); applyDest("channel"); ns.Feedback("Joined " .. name .. ".", false)
                        elseif tries >= 10 then
                            ticker:Cancel(); ns.Feedback("Could not join " .. name .. " (wrong password?).", true)
                        end
                    end)
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
    "|cffffd100Mail orders|r",
    "On a fixed-price offer (a Buy result or a seller's shop), click the |cffffffffmail icon|r to order it by COD mail: pick a quantity and the seller gets the order.",
    "• The seller reviews it under |cffffffffMy Items > Orders|r and accepts or declines.",
    "• At any mailbox, GFM lists your accepted orders and one click fills in the mail: recipient, the items, and the price as COD. Check it and press Send.",
    "• The buyer pays when collecting the mail, so neither side needs to be online at the same time after the order is accepted.",
    "• Sellers can fulfil a |cffffffffCOD want|r the same way: the mail icon on a WTB row commits you to mail it. No acceptance needed; the buyer already committed to that price.",
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

local function buildWTB()
    --==================== My Items: Selling/WTB sub-tabs + WTB compose ====================
    -- two small sub-tab buttons at the far left (the pause button moved right to make room)
    main.mineSellBtn = subTabButton(16, "WTS")
    main.mineWtbBtn  = subTabButton(74, "WTB")
    main.mineOrdersBtn = subTabButton(132, "Orders", 64)
    attachSubTip(main.mineSellBtn, "WTS - Want To Sell", "Items you're offering for sale.")
    attachSubTip(main.mineWtbBtn,  "WTB - Want To Buy", "Items you want to buy.")
    attachSubTip(main.mineOrdersBtn, "Mail orders", "Orders placed with you and orders you placed with sellers, settled by COD mail.")
    main.mineSellBtn:SetScript("OnClick", function() setMineMode("SELLING") end)
    main.mineWtbBtn:SetScript("OnClick", function() setMineMode("WTB") end)
    main.mineOrdersBtn:SetScript("OnClick", function() setMineMode("ORDERS") end)

    -- substring filter over your WTB list (shares the "Find item:" label with Selling)
    local wtbFilter = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    wtbFilter:SetPoint("TOPLEFT", 380, -64); wtbFilter:SetSize(100, 22); wtbFilter:SetAutoFocus(false); wtbFilter:Hide()
    wtbFilter:SetScript("OnTextChanged", function(_, user) if user then ns.RefreshWant() end end)
    wtbFilter:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); ns.RefreshWant() end)
    main.wtbFilter = wtbFilter
    addClearButton(wtbFilter, function(b) b:SetText(""); ns.RefreshWant() end)

    --==================== WTB compose panel (item via autocomplete, qty, price, COD) ====
    local panel = CreateFrame("Frame", nil, main)
    panel:SetPoint("BOTTOMLEFT", 16, 14); panel:SetPoint("BOTTOMRIGHT", -16, 14); panel:SetHeight(74); panel:Hide()
    main.wtbPanel = panel

    local editingWantKey = nil
    local wantDraft = { itemID = nil, suffix = 0 }

    -- fields stay inline on one row (item | qty | price | COD | Want); the labels sit above
    local itemLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemLabel:SetPoint("BOTTOMLEFT", 6, 52); itemLabel:SetText("Item (type to search):")
    local itemBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    itemBox:SetPoint("BOTTOMLEFT", 10, 30); itemBox:SetSize(250, 20); itemBox:SetAutoFocus(false)

    -- compact autocomplete for the item field; opens downward like the Buy search picker, with
    -- arrow-key navigation. Floats below the panel on DIALOG strata.
    local ac = CreateFrame("Frame", nil, main, "BackdropTemplate")
    ac:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    ac:SetBackdropColor(0, 0, 0, 0.92); ac:SetBackdropBorderColor(0.4, 0.4, 0.4)
    ac:SetPoint("TOPLEFT", itemBox, "BOTTOMLEFT", -2, -2); ac:SetWidth(254); ac:SetFrameStrata("DIALOG"); ac:Hide()
    ac.rows = {}; ac.sel = 0
    for i = 1, 8 do
        local row = CreateFrame("Button", nil, ac); row:SetSize(250, 18)
        row:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 18)
        local hl = row:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.15)
        row.selTex = row:CreateTexture(nil, "BACKGROUND"); row.selTex:SetAllPoints(); row.selTex:SetColorTexture(1, 0.82, 0, 0.25); row.selTex:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(14, 14); row.icon:SetPoint("LEFT", 2, 0)
        row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.fs:SetPoint("LEFT", 20, 0)
        row:Hide(); ac.rows[i] = row
    end
    local function highlightAC()
        for i, row in ipairs(ac.rows) do row.selTex:SetShown(ac.sel == i and row:IsShown()) end
    end

    local function pickItem(id, name)
        wantDraft.itemID = id; wantDraft.suffix = 0
        ns.ItemDB.Learn(id)
        itemBox:SetText(name or itemName(id)); itemBox:SetCursorPosition(0); itemBox:ClearFocus()
        ac:Hide()
    end
    local function updateAC()
        local matches = ns.ItemDB.Match(itemBox:GetText())
        ac.matches = matches; ac.sel = 0
        if #matches == 0 then ac:Hide(); return end
        for i, row in ipairs(ac.rows) do
            local m = matches[i]
            row.selTex:Hide()
            if m then
                row.icon:SetTexture(GetItemIcon(m.id))
                local col = ITEM_QUALITY_COLORS[m.q] or ITEM_QUALITY_COLORS[1]
                row.fs:SetText(m.name); row.fs:SetTextColor(col.r, col.g, col.b)
                row:SetScript("OnClick", function() pickItem(m.id, m.name) end)
                row:SetScript("OnEnter", function() ac.sel = i; highlightAC() end)
                row:Show()
            else row:Hide() end
        end
        ac:SetHeight(math.min(#matches, 8) * 18 + 4); ac:Show()
    end
    itemBox:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        local linkID = self:GetText():match("|Hitem:(%d+)")
        if linkID then pickItem(tonumber(linkID), itemName(tonumber(linkID))); return end
        wantDraft.itemID = nil; updateAC()
    end)
    itemBox:SetScript("OnArrowPressed", function(self, key)
        if not ac:IsShown() or not ac.matches then return end
        local n = #ac.matches
        if n == 0 then return end
        if key == "DOWN" then ac.sel = (ac.sel >= n) and 1 or ac.sel + 1; highlightAC()
        elseif key == "UP" then ac.sel = (ac.sel <= 1) and n or ac.sel - 1; highlightAC() end
    end)
    itemBox:SetScript("OnEnterPressed", function(self)
        if ac:IsShown() and ac.sel and ac.sel > 0 and ac.matches and ac.matches[ac.sel] then
            local m = ac.matches[ac.sel]; pickItem(m.id, m.name); return
        end
        local matches = ns.ItemDB.Match(self:GetText())
        if matches[1] then pickItem(matches[1].id, matches[1].name) end
    end)
    itemBox:SetScript("OnEscapePressed", function(self) ac:Hide(); self:ClearFocus() end)
    itemBox:SetScript("OnReceiveDrag", function(self)
        local t, id = GetCursorInfo()
        if t == "item" and id then ClearCursor(); pickItem(id, itemName(id)) end
    end)

    local function label(text, x, y) local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); fs:SetPoint("BOTTOMLEFT", x, y); fs:SetText(text); return fs end
    label("Qty", 276, 52)
    local qtyBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    qtyBox:SetPoint("BOTTOMLEFT", 280, 30); qtyBox:SetSize(40, 20); qtyBox:SetAutoFocus(false); qtyBox:SetNumeric(true); qtyBox:SetText("1")
    label("Price (empty = open to offers)", 336, 52)
    local priceBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    priceBox:SetPoint("BOTTOMLEFT", 340, 30); priceBox:SetSize(130, 20); priceBox:SetAutoFocus(false); priceBox:SetMaxLetters(20)

    -- Tab cycles Item -> Qty -> Price (Shift+Tab reverses). Tabbing out of the item field first
    -- accepts the highlighted suggestion, so type + Tab is a quick way to pick an item.
    itemBox:SetScript("OnTabPressed", function()
        if IsShiftKeyDown() then priceBox:SetFocus(); priceBox:HighlightText(); return end
        local m = ac:IsShown() and ac.matches and ac.matches[ac.sel > 0 and ac.sel or 1]
        if m then pickItem(m.id, m.name) end
        qtyBox:SetFocus(); qtyBox:HighlightText()
    end)
    qtyBox:SetScript("OnTabPressed", function()
        if IsShiftKeyDown() then itemBox:SetFocus() else priceBox:SetFocus(); priceBox:HighlightText() end
    end)
    priceBox:SetScript("OnTabPressed", function()
        if IsShiftKeyDown() then qtyBox:SetFocus(); qtyBox:HighlightText() else itemBox:SetFocus() end
    end)

    local codCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    codCheck:SetSize(24, 24); codCheck:SetPoint("BOTTOMLEFT", 484, 28)
    local codLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    codLabel:SetPoint("LEFT", codCheck, "RIGHT", 2, 1); codLabel:SetText("COD")
    codCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Cash on delivery")
        GameTooltip:AddLine("You'll pay this exact price on delivery. COD needs a price.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    codCheck:SetScript("OnLeave", GameTooltip_Hide)

    local wantBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    wantBtn:SetSize(90, 24); wantBtn:SetPoint("BOTTOMRIGHT", -4, 28); wantBtn:SetText("Want")
    main.wantBtn = wantBtn

    local function clearWant()
        editingWantKey = nil
        wantDraft.itemID = nil; wantDraft.suffix = 0
        itemBox:SetText(""); qtyBox:SetText("1"); priceBox:SetText(""); codCheck:SetChecked(false)
        wantBtn:SetText("Want")
    end
    local function submitWant()
        local qty = tonumber(qtyBox:GetText()) or 1
        local price = parsePrice(priceBox:GetText())
        local cod = codCheck:GetChecked() and true or false
        if editingWantKey then
            if ns.EditWant(editingWantKey, qty, price, cod) then clearWant() end
        elseif ns.AddWant(wantDraft.itemID, wantDraft.suffix or 0, qty, price, cod) then
            clearWant()
        end
    end
    wantBtn:SetScript("OnClick", submitWant)
    qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); submitWant() end)
    priceBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); submitWant() end)

    -- load an existing want into the compose panel for editing (Edit button on a row)
    function ns.LoadWantForEdit(key)
        local w = GuildFoundMarketCharDB.wants and GuildFoundMarketCharDB.wants[key]
        if not w then return end
        editingWantKey = key
        wantDraft.itemID = w.id or tonumber(key); wantDraft.suffix = w.suffix or 0
        itemBox:SetText(vName(wantDraft.itemID, wantDraft.suffix))
        qtyBox:SetText(tostring(w.qty or 1)); priceBox:SetText(priceToStr(w.price)); codCheck:SetChecked(w.cod and true or false)
        wantBtn:SetText("Update")
        priceBox:SetFocus(); priceBox:HighlightText()
    end

    -- Selling/WTB sub-tab switch (mirrors setBuyMode). Toggles the bottom panels, the announce
    -- controls (Selling only), and the active filter box, then refreshes the right list.
    setMineMode = function(mode)
        mineMode = mode
        if not main then return end
        local wtb, orders = (mode == "WTB"), (mode == "ORDERS")
        local selling = not wtb and not orders
        main.mineSellBtn.sel:SetShown(selling); main.mineWtbBtn.sel:SetShown(wtb); main.mineOrdersBtn.sel:SetShown(orders)
        main.postPanel:SetShown(selling); main.wtbPanel:SetShown(wtb)
        main.announceBtn:SetShown(selling); main.announceDestBtn:SetShown(selling)
        main.announceWhisper:SetShown(selling and GuildFoundMarketCharDB.announceDest == "whisper")
        if main.announceDestPopup then main.announceDestPopup:Hide() end
        if main.announceWAC then main.announceWAC:Hide() end
        main.mineFilter:SetShown(selling); main.wtbFilter:SetShown(wtb)
        main.mineFilterLabel:SetShown(not orders)
        ac:Hide()
        if orders then
            main.h1:SetText("Order"); main.h2:SetText("Qty"); main.h3:SetText("COD total"); main.h4:SetText("Status")
        else
            main.h1:SetText("Item"); main.h2:SetText("Qty"); main.h3:SetText(wtb and "Price" or "Price/unit"); main.h4:SetText(wtb and "" or "Bag sync")
        end
        updateSharedSortHeaders()
        wipe(view); FauxScrollFrame_SetOffset(main.scroll, 0); main.scroll:SetVerticalScroll(0)
        if wtb then clearWant(); ns.RefreshWant()
        elseif selling then ns.RefreshMine() end
        ns.RefreshOrders()   -- the orders list when in Orders mode; otherwise just the sub-tab badge
    end
end

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

    -- Render one schema entry as a control at column x, starting at vertical oy; return next oy.
    local function renderOption(s, x, oy)
        if s.type == "choice" then
            local lbl = optPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            lbl:SetPoint("TOPLEFT", x + 4, oy); lbl:SetText(s.label)
            oy = oy - 22
            local rx = x + 8
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
            return oy - 30
        end
        local cb = CreateFrame("CheckButton", nil, optPanel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", x, oy); cb:SetSize(26, 26); cb.key = s.key
        local lbl = optPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("LEFT", cb, "RIGHT", 4, 1); lbl:SetText(s.label)
        -- extend the click/hover area rightward over the label, so hovering or clicking the
        -- text behaves the same as the checkbox itself (tooltip + toggle)
        cb:SetHitRectInsets(0, -(lbl:GetStringWidth() + 8), 0, 0)
        cb:SetScript("OnClick", function(self) ns.SetSetting(self.key, self:GetChecked()) end)
        cb:SetScript("OnEnter", function(self) showTip(self, s) end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
        optChecks[#optChecks + 1] = cb
        return oy - 30
    end

    -- Two columns so the list never runs past the panel: general feature checkboxes on the left;
    -- the format choices (price fill, shop-note items) and the hide-shop-link toggles on the right.
    local LEFT_X, RIGHT_X, TOP_Y = 4, 340, -48
    local lY, rY = TOP_Y, TOP_Y
    for _, s in ipairs(ns.SettingsSchema) do
        if s.type == "choice" or s.key:find("^hideShop") then
            rY = renderOption(s, RIGHT_X, rY)
        else
            lY = renderOption(s, LEFT_X, lY)
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
    buildBuyerWidgets()
    buildPauseAnnounce()
    buildWTB()
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
    local buyers  = (tab == "BUYERS")
    local help    = (tab == "HELP")
    local options = (tab == "OPTIONS")
    main.searchBox:SetShown(buy); main.searchLabel:SetShown(buy)   -- buyers re-shows it via SetBuyersView
    main.ac:Hide()
    main.postPanel:SetShown(mine)
    main.dbPanel:SetShown(buy)
    if not sellers then   -- hide all seller widgets when on another tab
        main.sellerFilter:Hide(); main.sellerFilterLabel:Hide(); main.sellerRefreshBtn:Hide()
        main.sellerBackBtn:Hide(); main.sellerHeader:Hide(); main.sellerHeaderHover:Hide()
        main.sellerWtsBtn:Hide(); main.sellerWtbBtn:Hide()
        main.sortName:Hide(); main.sortCount:Hide()
        main.catalogFilter:Hide(); main.catalogFilterLabel:Hide()
        main.sellerNotePanel:Hide()
    end
    if not buyers then   -- hide all buyer widgets when on another tab
        main.buyerFilter:Hide(); main.buyerFilterLabel:Hide(); main.buyerRefreshBtn:Hide()
        main.buyerBackBtn:Hide(); main.buyerHeader:Hide(); main.buyerHeaderHover:Hide()
        main.buyerWtsBtn:Hide(); main.buyerWtbBtn:Hide()
        main.buyerSortName:Hide(); main.buyerSortCount:Hide()
        main.buyerCatalogFilter:Hide(); main.buyerCatalogFilterLabel:Hide()
        main.buyerToItemBtn:Hide(); main.buyerToIndexBtn:Hide(); main.buyerFindRefreshBtn:Hide()
        main.buyerNotePanel:Hide()
    end
    main.modeToggle:SetShown(buy)
    if not buy then   -- leaving the Buy tab: hide all Browse widgets, restore the shared headers
        main.sidebar:Hide(); main.browseScroll:Hide(); main.browseFilter:Hide(); main.browseFilterLabel:Hide()
        main.bLvlLabel:Hide(); main.bLvlMin:Hide(); main.bLvlTo:Hide(); main.bLvlMax:Hide()
        main.bhItem:Hide(); main.bhLvl:Hide(); main.bhQty:Hide(); main.bhPrice:Hide(); main.bhSeller:Hide()
        main.bSortItem:Hide(); main.bSortLvl:Hide(); main.bSortQty:Hide(); main.bSortPrice:Hide()
        for i = 1, ROWS do browseRows[i]:Hide() end
        main.h1:Show(); main.h2:Show(); main.h3:Show(); main.h4:Show()
    end
    main.pauseBtn:SetShown(mine)
    main.mineSellBtn:SetShown(mine); main.mineWtbBtn:SetShown(mine); main.mineOrdersBtn:SetShown(mine)
    main.mineFilterLabel:SetShown(mine)
    if not mine then main.mineFilter:Hide(); main.wtbFilter:Hide(); main.wtbPanel:Hide() end
    main.announceBtn:SetShown(mine)
    main.announceDestBtn:SetShown(mine)
    main.announceWhisper:SetShown(mine and mineMode == "SELLING" and GuildFoundMarketCharDB.announceDest == "whisper")
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
        main.searchLabel:SetText("Search item:"); main.searchBox:SetWidth(460)
        main.h1:SetText("Seller"); main.h2:SetText("Qty"); main.h3:SetText("Price/unit"); main.h4:SetText("Location")
        setBuyMode(buyMode)   -- apply Search vs Browse sub-mode (handles visibility + refresh)
    elseif buyers then
        main.searchBox:SetText("")
        main.buyerFilter:SetText("")
        ns.SetBuyersView("FIND")    -- default to item search (the seller's "who wants this?"); the
                                    -- buyer scan runs only when you toggle to "Find buyer"
    elseif sellers then
        main.sellerFilter:SetText("")    -- fresh entry: clear any leftover name filter
        if goSeller then
            showOrigin = { tab = "SELLERS", view = "INDEX" }   -- a direct jump: Back goes to the seller index
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
    else   -- MINE
        main.mineFilter:SetText(""); main.wtbFilter:SetText("")   -- fresh entry: clear leftover filters
        main.noteBox:SetText(ns.GetShopNote())
        setMineMode(mineMode)   -- Selling/WTB sub-tab: sets headers, panels, announce, filter, refresh
    end
    updateSharedSortHeaders()   -- show/hide the column-sort overlays to match the new view
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

--========================================================================
-- Mailbox helper: while the mailbox is open and you have accepted orders, a side panel
-- lists them; clicking one fills in the Send Mail form (recipient, subject, COD amount)
-- and attaches the items from your bags. The seller checks it and presses Send themselves;
-- the SendMail hook in Orders.lua then marks the order sent and tells the buyer.
--========================================================================
local mailPanel

-- Attach up to `qty` of the order's exact variant from the bags, largest stacks first so
-- the fewest attachment slots are used; at most one final split. Returns how many were
-- (or will shortly be) attached.
-- ponytail: at most 12 attachment slots; an order needing more stacks attaches short and the
-- seller tops it up (or sends a second mail) by hand.
local function attachOrderItems(o)
    -- Collect matching stacks. isLocked skips stacks already sitting in an attachment slot
    -- (they stay in the bags, locked, until the mail is sent), so re-clicking can't
    -- double-attach.
    local stacks = {}
    for bag = 0, 4 do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == o.id and not info.isBound and not info.isLocked
                and ns.Stock.LinkSuffix(info.hyperlink) == (o.suffix or 0) then
                stacks[#stacks + 1] = { bag = bag, slot = slot, n = info.stackCount or 1 }
            end
        end
    end
    table.sort(stacks, function(a, b) return a.n > b.n end)

    local remaining = o.qty
    for _, st in ipairs(stacks) do
        if remaining <= 0 then break end
        if st.n <= remaining then
            ns.Log(("order attach: whole stack of %d from bag %d slot %d"):format(st.n, st.bag, st.slot))
            C_Container.UseContainerItem(st.bag, st.slot)   -- attaches while Send Mail is open
            remaining = remaining - st.n
        else
            -- Stack is bigger than what's left: one split covers the rest. Placing a split
            -- straight from the cursor into a mail slot attaches the WHOLE source stack on
            -- the Era client (ClickSendMailItemButton bug), so: split into an empty bag
            -- slot, wait for the server to confirm the new stack, then attach that stack
            -- whole via the UseContainerItem path.
            local eb, es
            for b = 0, 4 do
                for s = 1, (C_Container.GetContainerNumSlots(b) or 0) do
                    if not C_Container.GetContainerItemInfo(b, s) then eb, es = b, s; break end
                end
                if eb then break end
            end
            if not eb then
                ns.Log("order attach: no empty bag slot to split into; attaching short")
                return o.qty - remaining
            end
            ns.Log(("order attach: splitting %d off bag %d slot %d into bag %d slot %d"):format(remaining, st.bag, st.slot, eb, es))
            C_Container.SplitContainerItem(st.bag, st.slot, remaining)
            C_Container.PickupContainerItem(eb, es)   -- drop the split into the empty slot
            local tries = 0
            local function attachSplit()
                tries = tries + 1
                if not (SendMailFrame and SendMailFrame:IsShown()) then return end
                local si = C_Container.GetContainerItemInfo(eb, es)
                if si and si.itemID == o.id and not si.isLocked then
                    ns.Log(("order attach: attaching the split stack of %d"):format(si.stackCount or 0))
                    C_Container.UseContainerItem(eb, es)
                elseif tries < 10 then
                    C_Timer.After(0.2, attachSplit)   -- new stack not confirmed yet
                else
                    ns.Log("order attach: split stack never settled; attach it by hand")
                end
            end
            C_Timer.After(0.2, attachSplit)
            remaining = 0
        end
    end
    return o.qty - remaining
end

local function fillOrderMail(o)
    if MailFrameTab2 then MailFrameTab2:Click() end   -- switch to the Send Mail tab
    SendMailNameEditBox:SetText(o.buyer)
    SendMailSubjectEditBox:SetText(("GFM order: %s x%d"):format(itemName(o.id), o.qty):sub(1, 64))
    MoneyInputFrame_SetCopper(SendMailMoney, o.qty * o.price)
    if SendMailCODButton and not SendMailCODButton:GetChecked() then SendMailCODButton:Click() end
    local attached = attachOrderItems(o)
    if attached < o.qty then
        ns.Feedback(("Attached %d of %d: not enough %s in your bags."):format(attached, o.qty, itemName(o.id)), true)
    else
        ns.Feedback("Order filled in. Check the attachments and COD amount, then press Send.", false)
    end
end

local function buildMailPanel()
    mailPanel = CreateFrame("Frame", "GuildFoundMarketMailOrders", MailFrame, "BackdropTemplate")
    mailPanel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 2, -12)
    mailPanel:SetWidth(260)
    mailPanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    mailPanel:SetBackdropColor(0, 0, 0, 0.8); mailPanel:SetBackdropBorderColor(0.5, 0.5, 0.5)
    local title = mailPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -8); title:SetText("GFM: accepted mail orders"); title:SetTextColor(1, 0.82, 0)
    local hint = mailPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 8, 8); hint:SetPoint("BOTTOMRIGHT", -8, 8)
    hint:SetJustifyH("LEFT")
    hint:SetText("Click an order to fill in the mail, check it, then press Send.")
    mailPanel.rows = {}
end

-- MAIL_SHOW can fire before MailFrame is actually shown (order depends on other
-- addons' hooks), so the panel is driven off the frame's own OnShow instead.
if MailFrame then
    MailFrame:HookScript("OnShow", function() ns.UpdateMailOrderPanel() end)
end

local MAIL_ORDER_ROWS = 8
function ns.UpdateMailOrderPanel()
    if not (MailFrame and MailFrame:IsShown()) then
        if mailPanel then mailPanel:Hide() end
        return
    end
    local list = ns.AcceptedOrders()
    if #list == 0 then
        if mailPanel then mailPanel:Hide() end
        return
    end
    if not mailPanel then buildMailPanel() end
    for i = 1, MAIL_ORDER_ROWS do
        local r = mailPanel.rows[i]
        if not r then
            r = CreateFrame("Button", nil, mailPanel)
            r:SetSize(244, 18); r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * 18)
            local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.12)
            r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.fs:SetAllPoints(); r.fs:SetJustifyH("LEFT")
            mailPanel.rows[i] = r
        end
        local rec = list[i]
        if rec then
            local o = rec.o
            r.fs:SetText(("%s: %s x%d - %s"):format(o.buyer, itemName(o.id), o.qty, coinShort(o.qty * o.price)))
            r:SetScript("OnClick", function()
                local ok, err = pcall(fillOrderMail, o)
                if not ok then
                    ns.Log("mail-order fill FAILED: " .. tostring(err))
                    ns.Feedback("Filling the mail failed; see the GFM Debug log.", true)
                end
            end)
            r:Show()
        else
            r:Hide()
        end
    end
    local shown = math.min(#list, MAIL_ORDER_ROWS)
    mailPanel:SetHeight(24 + shown * 18 + 30)
    mailPanel:Show()
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
