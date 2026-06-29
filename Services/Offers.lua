local ADDON, ns = ...

--========================================================================
-- My Items (offers). Per-character; the source we auto-respond from. Keyed by variant
-- "itemID:suffixID", so random-enchant variants of one base item ("... of the Bear" vs
-- "... of the Eagle") list separately. suffixID 0 = a plain item, keyed "itemID:0".
--========================================================================
local function offers() return GuildFoundMarketCharDB.offers end

local function vkey(id, suffix) return id .. ":" .. (suffix or 0) end
ns.vkey = vkey

-- Shop note: one free-text line a seller shows to buyers, surfaced beside their name in the
-- Sellers index. Stored per character (like offers/paused). We strip "~" (the wire field
-- separator) and newlines; the input field caps the length so it always fits one
-- addon-message reply.
function ns.GetShopNote() return GuildFoundMarketCharDB.note or "" end
function ns.SetShopNote(s)
    s = (s or ""):gsub("[~\r\n]", " "):gsub("%s+$", "")
    GuildFoundMarketCharDB.note = s
    return s
end

-- Scan the player's bags for an item's bound state. Returns (sawCopy, sawTradeable):
-- sawTradeable is true if at least one UNbound copy exists. We block a listing only
-- when we saw copies and every one was bound (soulbound or quest-bound = untradeable);
-- if we saw none (e.g. it's only in the bank), we fail open and allow it.
local function bagBoundState(itemID)
    local sawCopy, sawTradeable = false, false
    for bag = 0, 4 do
        for s = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, s)
            if info and info.itemID == itemID then
                sawCopy = true
                if not info.isBound then sawTradeable = true end
            end
        end
    end
    return sawCopy, sawTradeable
end

-- Count how many of an EXACT variant (itemID + suffix) sit in the player's bags (0-4).
-- Bags only, never the bank: "follow my bags" is the whole contract, and a bank read is
-- unreliable away from the bank (one of the transients behind #2). We read each slot's suffix
-- from its item link (field 8 of the itemString) so random-enchant variants count
-- separately, the same way offers are keyed.
local function bagCount(itemID, suffix)
    suffix = suffix or 0
    local total = 0
    for bag = 0, 4 do
        for s = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, s)
            if info and info.itemID == itemID then
                local sfx, str = 0, info.hyperlink and info.hyperlink:match("item:[%-%d:]+")
                if str then local p = { strsplit(":", str) }; sfx = tonumber(p[8]) or 0 end
                if sfx == suffix then total = total + (info.stackCount or 1) end
            end
        end
    end
    return total
end
ns.BagCount = bagCount

function ns.AddOffer(itemID, suffix, qty, price, track)
    if not ns.channelName then ns.Feedback("No confederation config in your guild info, can't offer.", true); return end
    if not itemID then ns.Feedback("Pick an item first.", true); return end
    suffix = suffix or 0
    price = math.max(0, price or 0)   -- 0 = no fixed price; the seller takes bids
    qty = math.max(1, qty or 1)       -- a NEW listing is always live; park it (edit to 0) later
    if track == nil then track = ns.GetSetting("trackDefault") end   -- per-account default for new listings
    track = track and true or false
    local has = GetItemCount(itemID, true)
    if has < qty then ns.Feedback(("You only have %d (tried to offer %d)."):format(has, qty), true); return end
    local sawCopy, sawTradeable = bagBoundState(itemID)
    if sawCopy and not sawTradeable then
        ns.Feedback("That item is soulbound, so it can't be traded or listed.", true); return
    end
    offers()[vkey(itemID, suffix)] = { id = itemID, suffix = suffix, qty = qty, price = price, track = track }
    ns.ItemDB.Learn(itemID)
    if ns.RefreshMine then ns.RefreshMine() end
    ns.Feedback(("Offering %s x%d%s%s."):format(GetItemInfo(itemID) or ("item:" .. itemID), qty,
        price == 0 and " (bids)" or "", track and " (following your bags)" or ""), false)
    ns.Log(("OFFER added: %s x%d @ %s%s"):format(GetItemInfo(itemID) or ("item:" .. itemID), qty,
        price == 0 and "bid" or (price .. "c"), track and " [track]" or ""))
    if track and ns.SyncTrackedOffersSoon then ns.SyncTrackedOffersSoon() end   -- reconcile to bags at once
    return true
end

-- Edit qty/price of an EXISTING listing in place. No GetItemCount/soulbound checks:
-- the seller is just adjusting numbers on a listing they already own, and stock often
-- lives on a bank alt or in a vault they aren't standing at (the whole reason editing
-- exists instead of remove + re-list). The item/variant itself is never changed here.
function ns.EditOffer(key, qty, price, track)
    local o = offers()[key]
    if not o then ns.Feedback("That listing no longer exists.", true); return end
    -- qty 0 is allowed and means "parked": the listing stays in My Items but is hidden from
    -- everyone else (OfferList filters it out, so it never answers a search, seller-browse or
    -- shop-link). Set a qty above 0 to go live again. This is the soft alternative to Remove
    -- for a seller who is temporarily out of stock but wants to keep the price/variant around.
    o.qty = math.max(0, qty or o.qty or 0)
    o.price = math.max(0, price or 0)
    if track ~= nil then o.track = track and true or false end   -- "follow my bags" switch for this listing
    if ns.RefreshMine then ns.RefreshMine() end
    local name = GetItemInfo(o.id) or ("item:" .. (o.id or "?"))
    if o.qty == 0 then
        ns.Feedback(("Parked %s (qty 0): hidden from others, still listed in your My Items."):format(name), false)
    else
        ns.Feedback(("Updated %s x%d%s%s."):format(name, o.qty, o.price == 0 and " (bids)" or "",
            o.track and " (following your bags)" or ""), false)
    end
    ns.Log(("OFFER edited: %s x%d @ %s%s"):format(name, o.qty, o.price == 0 and "bid" or (o.price .. "c"), o.track and " [track]" or ""))
    if o.track and ns.SyncTrackedOffersSoon then ns.SyncTrackedOffersSoon() end
    return true
end

function ns.RemoveOffer(key)
    local o = offers()[key]
    offers()[key] = nil
    local id = (o and o.id) or tonumber(key)
    ns.Log("OFFER removed: " .. (id and (GetItemInfo(id) or ("item:" .. id)) or tostring(key)))
    if ns.RefreshMine then ns.RefreshMine() end
end

-- Flip the "follow my bags" switch on a listing straight from its My Items row checkbox.
-- Turning it on reconciles to bags shortly after (qty drops to the bag count, 0 = parked).
function ns.SetOfferTrack(key, on)
    local o = offers()[key]
    if not o then return end
    o.track = on and true or false
    ns.Log(("OFFER track %s: %s"):format(o.track and "on" or "off", GetItemInfo(o.id) or ("item:" .. (o.id or "?"))))
    if ns.RefreshMine then ns.RefreshMine() end
    if o.track and ns.SyncTrackedOffersSoon then ns.SyncTrackedOffersSoon() end
end

-- An offer is the seller's claim, not a mirror of their inventory. We deliberately
-- never verify it against bags/bank: sellers may keep stock on a bank alt, items go
-- in and out during play, and every trade is arranged face to face in whispers anyway.
-- So we never auto-edit or auto-remove offers; the seller owns their listings (and the
-- pause toggle hides them all at once). Returns an array of { id, suffix, qty, price }.
--
-- qty 0 = a "parked" listing: kept in the seller's My Items but hidden from everyone else,
-- so we skip it here. This is the single gate for that: every outward path (search,
-- seller-browse, category-browse, the L~ catalog and the shop-link scan reply) reads through
-- OfferList, so a parked listing never leaves this client.
-- Tolerates legacy offers keyed by a bare numeric itemID (no stored id/suffix).
local function offerList()
    local list = {}
    for key, o in pairs(offers()) do
        if (o.qty or 0) > 0 then
            list[#list + 1] = { id = o.id or tonumber(key), suffix = o.suffix or 0, qty = o.qty, price = o.price }
        end
    end
    return list
end
ns.OfferList = offerList

-- Auto-sync every "tracked" listing to its live bag count. Only offers with track=true are
-- touched; a manual listing (track nil/false) is never read against inventory, so stock kept
-- on a bank alt is left exactly as the seller posted it. Two guards keep the transient bad
-- reads that caused #2 from doing harm: bail entirely while the cursor holds an item (mid
-- stack-split or move), and skip any item whose info isn't cached yet (just after a loading
-- screen). And since qty 0 now means "parked" (kept and hidden), never a delete, even a stray
-- 0 is fully recoverable on the next bag change.
function ns.SyncTrackedOffers()
    if CursorHasItem() then return end
    local changed = false
    for _, o in pairs(offers()) do
        if o.track and o.id and GetItemInfo(o.id) ~= nil then
            local has = bagCount(o.id, o.suffix)
            if has ~= o.qty then o.qty = has; changed = true end
        end
    end
    if changed and ns.RefreshMine then ns.RefreshMine() end
end

-- Debounced trigger: bag events arrive in bursts and a stack split flickers for a frame, so
-- wait for things to settle and never run more than once per window.
local syncPending = false
function ns.SyncTrackedOffersSoon()
    if syncPending then return end
    syncPending = true
    C_Timer.After(1.5, function() syncPending = false; ns.SyncTrackedOffers() end)
end
