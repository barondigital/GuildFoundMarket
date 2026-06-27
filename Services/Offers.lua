local ADDON, ns = ...

--========================================================================
-- My Items (offers). Per-character; the source we auto-respond from. Keyed by variant
-- "itemID:suffixID", so random-enchant variants of one base item ("... of the Bear" vs
-- "... of the Eagle") list separately. suffixID 0 = a plain item, keyed "itemID:0".
--========================================================================
local function offers() return GuildFoundMarketCharDB.offers end

local function vkey(id, suffix) return id .. ":" .. (suffix or 0) end
ns.vkey = vkey

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

function ns.AddOffer(itemID, suffix, qty, price)
    if not ns.channelName then ns.Feedback("No confederation config in your guild info, can't offer.", true); return end
    if not itemID then ns.Feedback("Pick an item first.", true); return end
    suffix = suffix or 0
    price = math.max(0, price or 0)   -- 0 = no fixed price; the seller takes bids
    qty = math.max(1, qty or 1)
    local has = GetItemCount(itemID, true)
    if has < qty then ns.Feedback(("You only have %d (tried to offer %d)."):format(has, qty), true); return end
    local sawCopy, sawTradeable = bagBoundState(itemID)
    if sawCopy and not sawTradeable then
        ns.Feedback("That item is soulbound, so it can't be traded or listed.", true); return
    end
    offers()[vkey(itemID, suffix)] = { id = itemID, suffix = suffix, qty = qty, price = price }
    ns.ItemDB.Learn(itemID)
    if ns.RefreshMine then ns.RefreshMine() end
    ns.Feedback(("Offering %s x%d%s."):format(GetItemInfo(itemID) or ("item:" .. itemID), qty, price == 0 and " (bids)" or ""), false)
    ns.Log(("OFFER added: %s x%d @ %s"):format(GetItemInfo(itemID) or ("item:" .. itemID), qty, price == 0 and "bid" or (price .. "c")))
    return true
end

-- Edit qty/price of an EXISTING listing in place. No GetItemCount/soulbound checks:
-- the seller is just adjusting numbers on a listing they already own, and stock often
-- lives on a bank alt or in a vault they aren't standing at (the whole reason editing
-- exists instead of remove + re-list). The item/variant itself is never changed here.
function ns.EditOffer(key, qty, price)
    local o = offers()[key]
    if not o then ns.Feedback("That listing no longer exists.", true); return end
    o.qty = math.max(1, qty or o.qty or 1)
    o.price = math.max(0, price or 0)
    if ns.RefreshMine then ns.RefreshMine() end
    ns.Feedback(("Updated %s x%d%s."):format(GetItemInfo(o.id) or ("item:" .. (o.id or "?")), o.qty, o.price == 0 and " (bids)" or ""), false)
    ns.Log(("OFFER edited: %s x%d @ %s"):format(GetItemInfo(o.id) or ("item:" .. (o.id or "?")), o.qty, o.price == 0 and "bid" or (o.price .. "c")))
    return true
end

function ns.RemoveOffer(key)
    local o = offers()[key]
    offers()[key] = nil
    local id = (o and o.id) or tonumber(key)
    ns.Log("OFFER removed: " .. (id and (GetItemInfo(id) or ("item:" .. id)) or tostring(key)))
    if ns.RefreshMine then ns.RefreshMine() end
end

-- An offer is the seller's claim, not a mirror of their inventory. We deliberately
-- never verify it against bags/bank: sellers may keep stock on a bank alt, items go
-- in and out during play, and every trade is arranged face to face in whispers anyway.
-- So we never auto-edit or auto-remove offers; the seller owns their listings (and the
-- pause toggle hides them all at once). Returns an array of { id, suffix, qty, price }.
-- Tolerates legacy offers keyed by a bare numeric itemID (no stored id/suffix).
local function offerList()
    local list = {}
    for key, o in pairs(offers()) do
        list[#list + 1] = { id = o.id or tonumber(key), suffix = o.suffix or 0, qty = o.qty, price = o.price }
    end
    return list
end
ns.OfferList = offerList
