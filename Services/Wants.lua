local ADDON, ns = ...

--========================================================================
-- WTB / wants (buyer side). Per-character; the source we answer buyer scans and "who wants
-- this?" queries from. Keyed by variant "itemID:suffix" exactly like offers, so random-enchant
-- variants list separately. A want is a CLAIM ("I'm looking for this"), so unlike ns.AddOffer
-- there is NO inventory / soulbound check: you don't own what you want.
--
-- COD ("cash on delivery"): when set, the buyer commits to a concrete price paid on delivery,
-- so a price is required. price 0 with cod off = "open to offers" (mirrors the seller bid rule).
--========================================================================
local function wants() return GuildFoundMarketCharDB.wants end

function ns.AddWant(itemID, suffix, qty, price, cod)
    if not ns.channelName then ns.Feedback("No confederation config in your guild info, can't post a want.", true); return end
    if not itemID then ns.Feedback("Pick an item first.", true); return end
    suffix = suffix or 0
    price = math.max(0, price or 0)
    qty = math.max(1, qty or 1)
    cod = cod and true or false
    if cod and price <= 0 then ns.Feedback("COD needs a price (the amount paid on delivery).", true); return end
    wants()[ns.vkey(itemID, suffix)] = { id = itemID, suffix = suffix, qty = qty, price = price, cod = cod }
    ns.ItemDB.Learn(itemID)
    if ns.RefreshWant then ns.RefreshWant() end
    ns.Feedback(("Looking for %s x%d%s."):format(
        GetItemInfo(itemID) or ("item:" .. itemID), qty,
        cod and " (COD)" or (price == 0 and " (open to offers)" or "")), false)
    ns.Log(("WANT added: %s x%d @ %s"):format(GetItemInfo(itemID) or ("item:" .. itemID), qty,
        cod and ("COD " .. price .. "c") or (price == 0 and "offers" or (price .. "c"))))
    return true
end

-- Edit qty/price/cod of an existing want in place; the item/variant stays the want's own.
function ns.EditWant(key, qty, price, cod)
    local w = wants()[key]
    if not w then ns.Feedback("That want no longer exists.", true); return end
    cod = cod and true or false
    price = math.max(0, price or 0)
    if cod and price <= 0 then ns.Feedback("COD needs a price (the amount paid on delivery).", true); return end
    w.qty = math.max(1, qty or w.qty or 1)
    w.price = price
    w.cod = cod
    if ns.RefreshWant then ns.RefreshWant() end
    ns.Feedback(("Updated want %s x%d%s."):format(GetItemInfo(w.id) or ("item:" .. (w.id or "?")), w.qty,
        cod and " (COD)" or (price == 0 and " (open to offers)" or "")), false)
    ns.Log(("WANT edited: %s x%d"):format(GetItemInfo(w.id) or ("item:" .. (w.id or "?")), w.qty))
    return true
end

function ns.RemoveWant(key)
    local w = wants()[key]
    wants()[key] = nil
    local id = (w and w.id) or tonumber(key)
    ns.Log("WANT removed: " .. (id and (GetItemInfo(id) or ("item:" .. id)) or tostring(key)))
    if ns.RefreshWant then ns.RefreshWant() end
end

-- Array of { id, suffix, qty, price, cod }. Tolerates legacy keys, mirroring ns.OfferList.
local function wantList()
    local list = {}
    for key, w in pairs(wants()) do
        list[#list + 1] = { id = w.id or tonumber(key), suffix = w.suffix or 0, qty = w.qty, price = w.price, cod = w.cod and true or false }
    end
    return list
end
ns.WantList = wantList
