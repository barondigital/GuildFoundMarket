local ADDON, ns = ...

--========================================================================
-- Mail orders. A buyer clicks the mail icon on a fixed-price offer and commits to buy
-- qty x price; the seller accepts and mails the items COD, so the exchange settles through
-- the game's own cash-on-delivery mail (which works even while the buyer is offline).
--
-- Both sides keep their half of an order per character:
--   ordersOut[oid] (buyer):  { seller, id, suffix, qty, price, t, status }
--       status: pending (in flight) -> received (seller's client stored it) ->
--               accepted / declined -> mailed. noreply = the MO was never acked.
--   ordersIn[oid] (seller):  { buyer, id, suffix, qty, price, t, status }
--       status: new -> accepted -> sent.
--
-- Wire (new commands; old clients have no handler and ignore them, so this is append-only
-- compatible like every protocol addition so far):
--   MO~oid~id~qty~price~sfx   buyer -> seller   place an order (suffix last, house style)
--   MOA~oid                   seller -> buyer   auto-ack: the order was received and stored
--   MOD~oid~s                 seller -> buyer   decision/progress: A ccepted, D eclined, S ent
--   MOX~oid                   buyer -> seller   cancel a pending/accepted order
--
-- An order is a claim, like an offer: we never verify the seller's stock here. The COD mail
-- itself is the settlement, and any mail-legality rules (guild-locked communities) are
-- enforced by the mail layer / policing addons, not by us.
--========================================================================

local function ordersIn()  return GuildFoundMarketCharDB.ordersIn end
local function ordersOut() return GuildFoundMarketCharDB.ordersOut end

local orderSeq = 0

local function chatNote(msg)
    print("|cff00ff96GFM|r: " .. msg)
end

local function orderItemName(o)
    return GetItemInfo(o.id) or ("item:" .. o.id)
end

local function refreshOrders()
    if ns.RefreshOrdersSoon then ns.RefreshOrdersSoon() end
    if ns.UpdateMailOrderPanel then ns.UpdateMailOrderPanel() end
end

--========================================================================
-- Buyer side
--========================================================================
function ns.PlaceOrder(seller, itemID, suffix, qty, price)
    if not ns.channelName then ns.Feedback("Not in a confederation, can't order.", true); return end
    if not (seller and itemID) or seller == ns.playerName then return end
    qty = math.max(1, qty or 1)
    suffix = suffix or 0
    price = price or 0
    if price <= 0 then ns.Feedback("That offer has no fixed price; whisper the seller instead.", true); return end
    orderSeq = orderSeq + 1
    local oid = ("%s#%d.%d"):format(ns.playerName, time(), orderSeq)   -- unique across sessions (persisted)
    ordersOut()[oid] = { seller = seller, id = itemID, suffix = suffix, qty = qty, price = price, t = time(), status = "pending" }
    ns.EnqueueWhisper(("MO~%s~%d~%d~%d~%d"):format(oid, itemID, qty, price, suffix), seller)
    ns.ItemDB.Learn(itemID)
    ns.Feedback(("Order sent to %s: %s x%d for %s COD."):format(seller, orderItemName(ordersOut()[oid]), qty, GetCoinTextureString(qty * price)), false)
    ns.Log(("ORDER placed -> %s: item %d x%d @ %dc (%s)"):format(seller, itemID, qty, price, oid))
    refreshOrders()
    -- no ack in time = the seller is offline or not running GFM; keep the row so the buyer
    -- sees what happened, they can X it away
    C_Timer.After(ns.QUERY_SETTLE * 2, function()
        local o = ordersOut()[oid]
        if o and o.status == "pending" then
            o.status = "noreply"
            ns.Feedback(("%s didn't respond to your order; they may be offline."):format(seller), true)
            refreshOrders()
        end
    end)
    return true
end

-- Buyer cancels: tell the seller (best effort) and drop our half.
function ns.CancelOrder(oid)
    local o = ordersOut()[oid]
    if not o then return end
    if o.status == "received" or o.status == "accepted" then
        ns.EnqueueWhisper("MOX~" .. oid, o.seller)
    end
    ordersOut()[oid] = nil
    ns.Log("ORDER cancelled: " .. oid)
    refreshOrders()
end

-- MOA~oid: the seller's client stored our order.
ns.OnMessage("MOA", function(a)
    local o = ordersOut()[a]
    if not o or o.status ~= "pending" then return end
    o.status = "received"
    ns.Log("ORDER acked: " .. a)
    refreshOrders()
end)

-- MOD~oid~s: the seller accepted (A), declined (D) or mailed (S) our order.
ns.OnMessage("MOD", function(a, b, _, _, _, _, sender)
    local o = ordersOut()[a]
    if not o or Ambiguate(sender, "short") ~= o.seller then return end   -- unsolicited / stale
    local name = orderItemName(o)
    if b == "A" then
        o.status = "accepted"
        chatNote(("%s accepted your order (%s x%d). It will arrive as COD mail."):format(o.seller, name, o.qty))
    elseif b == "D" then
        o.status = "declined"
        chatNote(("%s declined your order (%s x%d)."):format(o.seller, name, o.qty))
    elseif b == "S" then
        o.status = "mailed"
        chatNote(("%s mailed your order (%s x%d). Check your mailbox; pay the COD to collect."):format(o.seller, name, o.qty))
    end
    ns.Log(("ORDER %s <- %s: %s"):format(a, o.seller, tostring(b)))
    refreshOrders()
end)

--========================================================================
-- WTB fulfilment: the sell-side mirror. A COD want is the buyer's standing commitment to
-- pay its price on delivery, so there is no accept round-trip: the seller commits by
-- initiating, the order lands on both sides already "accepted", and the usual mailbox /
-- sent / cancel machinery settles it.
--   MW~oid~id~qty~price~sfx   seller -> buyer   "I'll mail your want COD" (suffix last)
--========================================================================
function ns.FulfillWant(buyer, itemID, suffix, qty, price)
    if not ns.channelName then ns.Feedback("Not in a confederation, can't fulfil a want.", true); return end
    if not (buyer and itemID) or buyer == ns.playerName then return end
    qty = math.max(1, qty or 1)
    suffix = suffix or 0
    price = price or 0
    if price <= 0 then ns.Feedback("That want has no COD price; whisper the buyer instead.", true); return end
    orderSeq = orderSeq + 1
    local oid = ("%s#%d.%d"):format(ns.playerName, time(), orderSeq)
    ordersIn()[oid] = { buyer = buyer, id = itemID, suffix = suffix, qty = qty, price = price, t = time(), status = "accepted" }
    ns.EnqueueWhisper(("MW~%s~%d~%d~%d~%d"):format(oid, itemID, qty, price, suffix), buyer)
    ns.ItemDB.Learn(itemID)
    ns.Feedback(("Committed to mail %s x%d to %s for %s COD. Fill it in at any mailbox."):format(
        orderItemName(ordersIn()[oid]), qty, buyer, GetCoinTextureString(qty * price)), false)
    ns.Log(("ORDER fulfil -> %s: item %d x%d @ %dc (%s)"):format(buyer, itemID, qty, price, oid))
    refreshOrders()
    return true
end

-- MW~oid~id~qty~price~sfx: a seller will mail one of our COD wants. Track it so the Orders
-- tab shows the incoming mail. Validated against the want itself (right variant, COD, the
-- posted price, no more than we asked for), so a stray MW can't invent a commitment we
-- never made; an offline/mismatched buyer just gets the COD mail untracked, which is fine.
ns.OnMessage("MW", function(a, b, c, d, e, _, sender)
    local itemID, qty, price = tonumber(b), tonumber(c), tonumber(d)
    if not (a and itemID and qty and price) or qty < 1 or price < 1 then return end
    local seller = Ambiguate(sender, "short")
    if seller == ns.playerName then return end
    if ordersOut()[a] then return end   -- duplicate
    local w = GuildFoundMarketCharDB.wants[ns.vkey(itemID, tonumber(e) or 0)]
    if not (w and w.cod and price == (w.price or 0) and qty <= (w.qty or 0)) then return end
    ordersOut()[a] = { seller = seller, id = itemID, suffix = tonumber(e) or 0, qty = qty, price = price, t = time(), status = "accepted" }
    chatNote(("%s will mail you %s x%d for %s COD (your WTB). Collect it from your mailbox."):format(
        seller, GetItemInfo(itemID) or ("item:" .. itemID), qty, GetCoinTextureString(qty * price)))
    ns.Log(("ORDER fulfil <- %s: item %d x%d @ %dc (%s)"):format(seller, itemID, qty, price, a))
    refreshOrders()
end)

--========================================================================
-- Seller side
--========================================================================

-- MO~oid~id~qty~price~sfx: someone placed an order with us. Store it and ack. A direct,
-- deliberate act by the buyer, so it's accepted even while listings are paused.
ns.OnMessage("MO", function(a, b, c, d, e, _, sender)
    local itemID, qty, price = tonumber(b), tonumber(c), tonumber(d)
    if not (a and itemID and qty and price) or qty < 1 or price < 1 then return end
    local buyer = Ambiguate(sender, "short")
    if buyer == ns.playerName then return end
    local fresh = ordersIn()[a] == nil
    ordersIn()[a] = ordersIn()[a] or { buyer = buyer, id = itemID, suffix = tonumber(e) or 0, qty = qty, price = price, t = time(), status = "new" }
    ns.EnqueueWhisper("MOA~" .. a, sender)   -- ack even a duplicate: the first ack may have been lost
    if fresh then
        ns.ItemDB.Learn(itemID)
        chatNote(("New mail order from %s: %s x%d for %s COD. Review it under My Items > Orders (/gfm)."):format(
            buyer, GetItemInfo(itemID) or ("item:" .. itemID), qty, GetCoinTextureString(qty * price)))
        ns.Log(("ORDER received <- %s: item %d x%d @ %dc (%s)"):format(buyer, itemID, qty, price, a))
        refreshOrders()
    end
end)

-- MOX~oid: the buyer cancelled. Drop our half so we don't mail it.
ns.OnMessage("MOX", function(a, _, _, _, _, _, sender)
    local o = ordersIn()[a]
    if not o or Ambiguate(sender, "short") ~= o.buyer then return end
    ordersIn()[a] = nil
    chatNote(("%s cancelled their order (%s x%d)."):format(o.buyer, orderItemName(o), o.qty))
    ns.Log("ORDER cancelled by buyer: " .. a)
    refreshOrders()
end)

function ns.AcceptOrder(oid)
    local o = ordersIn()[oid]
    if not o or o.status ~= "new" then return end
    o.status = "accepted"
    ns.EnqueueWhisper("MOD~" .. oid .. "~A", o.buyer)
    ns.Feedback(("Accepted %s's order. Mail %s x%d COD %s from any mailbox (GFM helps you there)."):format(
        o.buyer, orderItemName(o), o.qty, GetCoinTextureString(o.qty * o.price)), false)
    ns.Log("ORDER accepted: " .. oid)
    refreshOrders()
end

function ns.DeclineOrder(oid)
    local o = ordersIn()[oid]
    if not o then return end
    ns.EnqueueWhisper("MOD~" .. oid .. "~D", o.buyer)
    ordersIn()[oid] = nil
    ns.Log("ORDER declined: " .. oid)
    refreshOrders()
end

local function markSent(o, oid)
    o.status = "sent"
    ns.EnqueueWhisper("MOD~" .. oid .. "~S", o.buyer)
    ns.Log("ORDER sent: " .. oid)
    refreshOrders()
end

-- Watch outgoing mail: a mail to a buyer with an accepted order marks that order sent (and
-- tells the buyer). Matched by recipient only, oldest accepted order first.
-- ponytail: no item/COD verification of the mail's contents; the seller owns what they send.
local function onSendMail(recipient)
    local to = recipient and Ambiguate(recipient, "short")
    if not to or to == "" then return end
    local bestOid, bestT
    for oid, o in pairs(ordersIn()) do
        if o.status == "accepted" and o.buyer == to and (not bestT or o.t < bestT) then
            bestOid, bestT = oid, o.t
        end
    end
    if bestOid then markSent(ordersIn()[bestOid], bestOid) end
end

-- Called once from Core at PLAYER_LOGIN (after the saved tables exist).
function ns.StartOrders()
    hooksecurefunc("SendMail", onSendMail)
end

-- Accepted orders, oldest first, for the mailbox helper panel.
function ns.AcceptedOrders()
    local list = {}
    for oid, o in pairs(ordersIn()) do
        if o.status == "accepted" then list[#list + 1] = { oid = oid, o = o } end
    end
    table.sort(list, function(a, b) return a.o.t < b.o.t end)
    return list
end

-- Rows for the Orders view: both directions merged, newest first. `dir` tags each row.
function ns.OrderRows()
    local list = {}
    for oid, o in pairs(ordersIn()) do
        list[#list + 1] = { oid = oid, dir = "in", who = o.buyer, id = o.id, suffix = o.suffix, qty = o.qty, price = o.price, t = o.t, status = o.status }
    end
    for oid, o in pairs(ordersOut()) do
        list[#list + 1] = { oid = oid, dir = "out", who = o.seller, id = o.id, suffix = o.suffix, qty = o.qty, price = o.price, t = o.t, status = o.status }
    end
    table.sort(list, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.oid < b.oid
    end)
    return list
end

-- Incoming orders awaiting a decision, for the sub-tab badge.
function ns.NewOrderCount()
    local n = 0
    for _, o in pairs(ordersIn()) do if o.status == "new" then n = n + 1 end end
    return n
end
