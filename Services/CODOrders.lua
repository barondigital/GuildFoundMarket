local ADDON, ns = ...

--========================================================================
-- COD orders (seller side). A per-character to-do list of Cash On Delivery mails the
-- seller owes buyers: buyer + item (+ variant) + qty + unit price. Sellers keep their
-- shop open while out and about and pick these up at a mailbox later, so the point is to
-- capture the order as DATA at request time, not to scrape it back out of a whisper.
--
-- Phase 1 is self-contained: manual add + a review list. No protocol and no mailbox
-- automation yet (see COD-ORDERS-DESIGN.md). Stored as a flat, append-only array in
-- GuildFoundMarketCharDB.codOrders; a row leaves the list only when the seller marks it
-- done (fulfilled) or removes it (cancelled). Each order carries a stable id (codSeq) so
-- the UI and, later, the request protocol can refer to one without relying on array order.
--========================================================================
local function orders() return GuildFoundMarketCharDB.codOrders end

-- Any COD change (add / update up or down / done / cancel) moves an item's reserved stock, so
-- refresh both the COD list and My Items, whose qty column shows what's reserved and still
-- advertised. Availability itself is computed live, so nothing needs recomputing here beyond the
-- on-screen lists. Guarded so the data layer still runs headless (tests, no UI loaded).
local function refreshCODViews()
    if ns.RefreshCOD then ns.RefreshCOD() end
    if ns.RefreshMine then ns.RefreshMine() end
end

local function nextId()
    GuildFoundMarketCharDB.codSeq = (GuildFoundMarketCharDB.codSeq or 0) + 1
    return GuildFoundMarketCharDB.codSeq
end

-- Find an order's array position by identity (the UI hands back the record table itself,
-- so we never depend on a stale index).
local function indexOf(rec)
    for i, r in ipairs(orders()) do if r == rec then return i end end
end

-- Find an existing open order for the same (buyer, itemID, suffix). Anti-spam: a buyer who
-- Alt-clicks the same listing twice, or a seller who re-adds a line, must update the one row
-- rather than stack a duplicate.
local function findOpenCOD(buyer, itemID, suffix)
    for _, r in ipairs(orders()) do
        if r.buyer == buyer and r.itemID == itemID and (r.suffix or 0) == (suffix or 0) then return r end
    end
end

-- How many of (itemID, suffix) the seller currently owes `buyer` (0 = none). The seller's list is
-- the single source of truth: we can't mirror it to the buyer, so the buyer Alt-click asks for this
-- (see QueryCOD / the CQ~ message) before showing its qty popup.
function ns.CODOutstanding(buyer, itemID, suffix)
    local rec = findOpenCOD(buyer, itemID, suffix)
    return rec and rec.qty or 0
end

-- Total of (itemID, suffix) promised across ALL open COD orders (every buyer). Bag-synced listings
-- subtract this from their advertised stock (see Offers.offerList), so an item fully spoken-for by
-- CODs stops showing as available in search/browse/catalog until an order is mailed and cleared.
function ns.CODCommitted(itemID, suffix)
    local total = 0
    for _, r in ipairs(orders()) do
        if r.itemID == itemID and (r.suffix or 0) == (suffix or 0) then total = total + (r.qty or 0) end
    end
    return total
end

-- Validate + normalize the fields shared by add and edit. Emits the reason on failure and
-- returns nil, so callers can just `if not buyer then return end`.
local function normalizeOrder(buyer, itemID, suffix, qty, unit)
    if not itemID then ns.Feedback("Pick an item first.", true); return end
    buyer = tostring(buyer or ""):gsub("[~\r\n]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if buyer == "" then ns.Feedback("Enter the buyer's name.", true); return end
    return buyer, suffix or 0, math.max(1, qty or 1), math.max(0, unit or 0)
end

-- Add a COD order. `source` is "manual" (seller typed it) or "request" (a buyer's protocol
-- request, Phase 2). unit is the unit price in copper; total is stored so display never has
-- to recompute it. At most one open order per (buyer, itemID, suffix): a repeat updates the
-- existing row's qty/price (the newly requested amount is authoritative) instead of stacking a
-- duplicate. Returns true on success.
function ns.AddCODOrder(buyer, itemID, suffix, qty, unit, source)
    buyer, suffix, qty, unit = normalizeOrder(buyer, itemID, suffix, qty, unit)
    if not buyer then return end
    ns.ItemDB.Learn(itemID)
    local name = GetItemInfo(itemID) or ("item:" .. itemID)
    local existing = findOpenCOD(buyer, itemID, suffix)
    if existing then
        existing.qty, existing.unit, existing.total = qty, unit, unit * qty
        refreshCODViews()
        ns.Feedback(("Updated COD for %s: %s x%d%s."):format(buyer, name, qty,
            unit > 0 and (" @ " .. GetCoinTextureString(unit)) or ""), false)
        ns.Log(("COD updated: %s %s x%d @ %s (%s)"):format(buyer, name, qty,
            unit > 0 and (unit .. "c") or "no price", source or "manual"))
        return true
    end
    local rec = {
        id = nextId(), buyer = buyer, itemID = itemID, suffix = suffix,
        qty = qty, unit = unit, total = unit * qty,
        source = source or "manual", added = time(), done = false,
    }
    local o = orders()
    o[#o + 1] = rec
    refreshCODViews()
    ns.Feedback(("COD order for %s: %s x%d%s."):format(buyer, name, qty,
        unit > 0 and (" @ " .. GetCoinTextureString(unit)) or ""), false)
    ns.Log(("COD added: %s %s x%d @ %s (%s)"):format(buyer, name, qty,
        unit > 0 and (unit .. "c") or "no price", rec.source))
    return true
end

-- Edit an existing order in place. The COD tab's Edit action loads a row back into the add form
-- and saves through here, so the row keeps its id and list position; only the fields change.
function ns.EditCODOrder(rec, buyer, itemID, suffix, qty, unit)
    if not indexOf(rec) then return end
    buyer, suffix, qty, unit = normalizeOrder(buyer, itemID, suffix, qty, unit)
    if not buyer then return end
    rec.buyer, rec.itemID, rec.suffix = buyer, itemID, suffix
    rec.qty, rec.unit, rec.total = qty, unit, unit * qty
    ns.ItemDB.Learn(itemID)
    refreshCODViews()
    local name = GetItemInfo(itemID) or ("item:" .. itemID)
    ns.Feedback(("Updated COD for %s: %s x%d%s."):format(buyer, name, qty,
        unit > 0 and (" @ " .. GetCoinTextureString(unit)) or ""), false)
    ns.Log(("COD edited: %s %s x%d"):format(buyer, name, qty))
    return true
end

-- Remove an order. reason "done" = fulfilled, "cancel" = dropped; both delete the row in
-- Phase 1 (no fulfilment history kept), they only differ in the log/feedback wording.
function ns.RemoveCODOrder(rec, reason)
    local i = indexOf(rec)
    if not i then return end
    table.remove(orders(), i)
    local name = GetItemInfo(rec.itemID) or ("item:" .. (rec.itemID or "?"))
    if reason == "done" then
        ns.Feedback(("Marked done: %s for %s."):format(name, rec.buyer), false)
        ns.Log(("COD done: %s %s x%d"):format(rec.buyer, name, rec.qty or 1))
    else
        ns.Feedback(("Removed COD: %s for %s."):format(name, rec.buyer), false)
        ns.Log(("COD removed: %s %s x%d"):format(rec.buyer, name, rec.qty or 1))
    end
    refreshCODViews()
end

-- Drop the open order for (buyer, itemID, suffix) if there is one; returns true when something was
-- removed. Backs the buyer-initiated cancel (a COD request with qty 0): the buyer can clear an order
-- they placed without the seller having to touch their list.
function ns.RemoveCODOrderFor(buyer, itemID, suffix)
    local rec = findOpenCOD(buyer, itemID, suffix)
    if not rec then return false end
    ns.RemoveCODOrder(rec, "cancel")
    return true
end

-- The list the COD tab renders, oldest first (the order you should clear first sits on top).
-- Returns the live record tables so row actions can hand one straight back to RemoveCODOrder.
function ns.CODList()
    local list = {}
    for _, r in ipairs(orders()) do list[#list + 1] = r end
    table.sort(list, function(a, b) return (a.added or 0) < (b.added or 0) end)
    return list
end

-- Count of open orders, for the tab badge.
function ns.CODCount() return #orders() end

--========================================================================
-- Phase 2: buyer-initiated COD requests over the addon-whisper protocol.
--
--   buyer  -> seller : CO~itemID~suffix~qty~unit          (request a COD for a listing)
--   seller -> buyer  : OA~ok~~itemID~suffix                (accepted and queued)
--   seller -> buyer  : OA~no~reason~itemID~suffix          (declined: closed | stock | price)
--
-- The seller also sends a human-readable confirmation whisper (configurable, with tokens) on
-- accept. These are brand-new commands, so there's no old-client compat to preserve: a client
-- without this code simply never answers, and the buyer's request times out (handled below).
--========================================================================

-- A plaintext coin string for whispers/logs; ns.CoinText (UI) once loaded, else a bare copper count.
local function coin(c) return (ns.CoinText and ns.CoinText(c)) or ((c or 0) .. "c") end

-- Fill the configurable confirmation whisper's tokens. Returns "" when the template is empty
-- (meaning: send no whisper). Coins are plaintext (texture strings don't render in a whisper).
function ns.CODReplyText(buyer, itemID, qty, unit)
    local tmpl = ns.GetSetting("codReplyText") or ""
    if tmpl == "" then return "" end
    local name = GetItemInfo(itemID) or ("item:" .. tostring(itemID))
    local repl = {
        item = name, qty = tostring(qty or 1),
        unit = coin(unit), total = coin((unit or 0) * (qty or 1)), buyer = buyer or "",
    }
    return (tmpl:gsub("%%(%a+)", function(tok) return repl[tok] or ("%" .. tok) end))
end

-- Pending buyer-side requests, so a reply can be matched and a silent seller times out.
local pending = {}
local function pkey(seller, id, sfx) return seller .. "~" .. id .. "~" .. (sfx or 0) end

-- How many of (itemID, suffix) the seller can still promise `buyer`, or nil for "no cap". Only a
-- listing that follows the seller's bags (track) is capped: there qty is real stock, so the open
-- orders on it must not exceed it. We subtract what's already committed to OTHER buyers (this
-- buyer's own order is being replaced, not added to). A manual listing returns nil: its qty is a
-- soft claim, not inventory, so we don't police it. Computed live, so it self-corrects as bags
-- change and as orders are marked done (there is a brief window after a COD mail is sent but before
-- Done is clicked where stock has dropped yet the order still counts; it resolves on Done).
local function codCap(buyer, itemID, suffix)
    if not ns.OfferInfo then return nil end
    local stock, track = ns.OfferInfo(itemID, suffix)
    if not track then return nil end
    local committed = 0
    for _, r in ipairs(orders()) do
        if r.itemID == itemID and (r.suffix or 0) == suffix and r.buyer ~= buyer then
            committed = committed + (r.qty or 0)
        end
    end
    return math.max(0, (stock or 0) - committed)
end
ns.CODCap = codCap

-- Seller side: decide on an incoming COD request and, on accept, queue the order. Returns
-- (status, reason, unit, qty): status "ok" | "no"; reason set on decline (closed | stock | price);
-- unit is the amount to collect and qty the ACCEPTED amount (clamped to available stock) on accept.
-- Shared by the CO wire handler and the self-test path, so both apply exactly the same gate (accept
-- setting, pause, must be listed, must have a price, must have stock to spare on a bag-synced listing).
local function sellerDecideCOD(buyer, itemID, suffix, qty, buyerUnit)
    if not ns.GetSetting("codAccept") or ns.IsPaused() then return "no", "closed" end
    -- must be a listing I currently have; read the RAW offer (not OfferList, which now hides items
    -- fully reserved by CODs) so a buyer editing their own order still resolves. Take my own listed
    -- price as authoritative (fall back to what the buyer offered when I list it for bids).
    local _, _, listedPrice = ns.OfferInfo(itemID, suffix)
    if listedPrice == nil then return "no", "stock" end
    local unit = (listedPrice > 0) and listedPrice or buyerUnit
    if unit <= 0 then return "no", "price" end   -- a COD needs a concrete amount to collect
    local cap = codCap(buyer, itemID, suffix)
    if cap ~= nil then
        if cap <= 0 then return "no", "stock" end   -- bag-synced listing with nothing left to promise
        if qty > cap then qty = cap end             -- clamp to what's actually available (seller wins)
    end
    if not ns.AddCODOrder(buyer, itemID, suffix, qty, unit, "request") then return "no", "stock" end
    return "ok", nil, unit, qty
end

-- Self-test: exercise the whole round trip against your own shop with no wire traffic. You can't
-- SendChatMessage to yourself (WoW blocks self-whispers), so the seller's configured confirmation
-- is echoed into your chat as a SIMULATED incoming whisper instead, letting you eyeball exactly
-- what the buyer would receive. The OA answer is fed back through the real buyer handler too.
local function selfTestCOD(itemID, suffix, qty, buyerUnit, name, cancel)
    local buyer = ns.playerName
    if cancel then
        local removed = ns.RemoveCODOrderFor(buyer, itemID, suffix)
        ns.DispatchMessage(("OA~%s~~%d~%d"):format(removed and "cancelled" or "nocancel", itemID, suffix), buyer)
        return
    end
    local status, reason, unit, acceptedQty = sellerDecideCOD(buyer, itemID, suffix, qty, buyerUnit)
    if status == "ok" then
        local text = ns.CODReplyText(buyer, itemID, acceptedQty, unit)
        if text ~= "" then
            local info = ChatTypeInfo and ChatTypeInfo["WHISPER"]
            -- clickable link directly (AddMessage bypasses the marker-rewriting chat filter), so you
            -- can actually test the Cancel COD flow against your own shop
            local link = ns.CODCancelLink and (" " .. ns.CODCancelLink(buyer, itemID, suffix)) or ""
            DEFAULT_CHAT_FRAME:AddMessage(("%s |cffff80ff(self-test)|r whispers: %s%s"):format(buyer, text, link),
                info and info.r or 1, info and info.g or 0.5, info and info.b or 1)
        else
            ns.Feedback("Self-test: confirmation whisper template is empty (no whisper would be sent).", false)
        end
    end
    ns.DispatchMessage(("OA~%s~%s~%d~%d"):format(status, reason or "", itemID, suffix), buyer)
end

-- Buyer side: ask `seller` to COD one of their listings. Optimistic (no capability handshake):
-- if the seller isn't accepting, they answer OA~no and we tell the buyer.
function ns.RequestCOD(seller, itemID, suffix, qty, unit)
    if not ns.channelName then ns.Feedback("Not in a confederation, can't request a COD.", true); return end
    if not (seller and itemID) then return end
    -- qty 0 (or blank) means "cancel my order for this item", not "request none"; carry it on the
    -- wire as CO~...~0 so the seller drops the row and acks. Otherwise clamp to a real amount.
    local cancel = (qty ~= nil and qty <= 0)
    suffix, unit = suffix or 0, math.max(0, unit or 0)
    qty = cancel and 0 or math.max(1, qty or 1)
    local name = GetItemInfo(itemID) or ("item:" .. itemID)
    if seller == ns.playerName then
        if ns.selfTest then return selfTestCOD(itemID, suffix, qty, unit, name, cancel) end
        ns.Feedback("That's your own listing.", true); return
    end
    ns.EnqueueWhisper(("CO~%d~%d~%d~%d"):format(itemID, suffix, qty, unit), seller)
    if cancel then
        ns.Feedback(("Asked %s to cancel your COD for %s..."):format(seller, name), false)
    else
        ns.Feedback(("Asked %s to COD %s x%d. Waiting for their shop to confirm..."):format(seller, name, qty), false)
    end
    ns.Log(("COD %s -> %s: %s x%d @ %s"):format(cancel and "cancel" or "request", seller, name, qty, coin(unit)))
    local k = pkey(seller, itemID, suffix)
    pending[k] = cancel and "cancel" or true
    C_Timer.After(ns.QUERY_SETTLE or 5, function()
        if pending[k] then
            local wasCancel = pending[k] == "cancel"
            pending[k] = nil
            if wasCancel then
                ns.Feedback(("%s's shop didn't confirm the cancel (offline, or not running COD requests)."):format(seller), true)
            else
                ns.Feedback(("%s's shop didn't confirm your COD (offline, or not running COD requests). Try a normal whisper."):format(seller), true)
            end
        end
    end)
end

-- Seller side: a buyer wants a COD for one of my listings. Gate + queue via sellerDecideCOD,
-- then answer (addon OA + the configurable human whisper on accept).
ns.OnMessage("CO", function(a, b, c, d, _, _, sender)
    local buyer = Ambiguate(sender, "short")
    local itemID, suffix = tonumber(a), tonumber(b) or 0
    if not itemID then return end
    -- qty 0 = the buyer is cancelling their order for this item; drop it and ack either way.
    if (tonumber(c) or 1) <= 0 then
        local removed = ns.RemoveCODOrderFor(buyer, itemID, suffix)
        ns.EnqueueWhisper(("OA~%s~~%d~%d"):format(removed and "cancelled" or "nocancel", itemID, suffix), sender)
        ns.Log(("COD cancel from %s: %s (%s)"):format(buyer, GetItemInfo(itemID) or ("item:" .. itemID),
            removed and "removed" or "none on file"))
        return
    end
    local qty, buyerUnit = math.max(1, tonumber(c) or 1), math.max(0, tonumber(d) or 0)
    local status, reason, unit, acceptedQty = sellerDecideCOD(buyer, itemID, suffix, qty, buyerUnit)
    if status ~= "ok" then
        ns.EnqueueWhisper(("OA~no~%s~%d~%d"):format(reason, itemID, suffix), sender)
        ns.Log(("COD request from %s declined (%s)"):format(buyer, reason))
        return
    end
    ns.EnqueueWhisper(("OA~ok~~%d~%d"):format(itemID, suffix), sender)
    -- the confirmation whisper reports the ACCEPTED qty (clamped to available stock), so the buyer
    -- learns if they got fewer than they asked for. A "Cancel COD" link trails it (rewritten from a
    -- {{GFMCOD:...}} marker on the buyer's client), so the buyer can drop the whole order from chat
    -- even once the listing is fully reserved and no longer clickable in search/browse.
    local text = ns.CODReplyText(buyer, itemID, acceptedQty, unit)
    if text ~= "" then
        local marker = ns.CODCancelMarker and (" " .. ns.CODCancelMarker(itemID, suffix)) or ""
        SendChatMessage(text .. marker, "WHISPER", nil, sender)
    end
    ns.Log(("COD request from %s accepted: %s x%d"):format(buyer, GetItemInfo(itemID) or ("item:" .. itemID), acceptedQty))
end)

-- Buyer side: the seller's answer to my request.
ns.OnMessage("OA", function(a, b, c, d, _, _, sender)
    local seller = Ambiguate(sender, "short")
    local itemID, suffix = tonumber(c), tonumber(d) or 0
    if itemID then pending[pkey(seller, itemID, suffix)] = nil end
    local name = itemID and (GetItemInfo(itemID) or ("item:" .. itemID)) or "that item"
    if a == "ok" then
        ns.Feedback(("%s accepted your COD for %s. They'll mail it when they're next at a mailbox."):format(seller, name), false)
    elseif a == "cancelled" then
        ns.Feedback(("%s cancelled your COD for %s."):format(seller, name), false)
    elseif a == "nocancel" then
        ns.Feedback(("%s had no open COD for %s to cancel."):format(seller, name), false)
    else
        local why = (b == "stock" and "they don't currently list it")
            or (b == "price" and "that listing takes bids; whisper them to agree a price first")
            or "they're not taking COD orders right now"
        ns.Feedback(("%s couldn't take your COD for %s: %s."):format(seller, name, why), true)
    end
    ns.Log(("COD reply <- %s: %s %s"):format(seller, tostring(a), tostring(b or "")))
end)

--========================================================================
-- COD-outstanding query (buyer -> seller -> buyer). Before the Alt-click shows its qty popup, the
-- buyer asks the seller how many of this item they already have on order, so the popup can prefill
-- the real amount and the buyer edits it rather than stacking blind. The seller's list is
-- authoritative; there is no persistent buyer-side copy to drift out of sync.
--
--   buyer  -> seller : CQ~itemID~suffix          (how many do I have outstanding with you?)
--   seller -> buyer  : CQR~itemID~suffix~qty~cap  (outstanding qty; cap = max I can promise, -1 = none)
--========================================================================

-- Pending buyer-side queries: key -> callback(qty, cap). Answered by CQR, or by the caller's own
-- timeout with (nil, nil) ("couldn't reach the seller").
local codQueries = {}

-- Buyer side: ask `seller` for the outstanding qty + available cap of (itemID, suffix), then call
-- cb(qty|nil, cap|nil). Own shop resolves locally (you can't whisper yourself); nil qty means the
-- seller never answered; nil cap means "no cap" (manual listing / unreachable).
function ns.QueryCOD(seller, itemID, suffix, cb)
    if not (seller and itemID and cb) then return end
    suffix = suffix or 0
    if seller == ns.playerName then cb(ns.CODOutstanding(seller, itemID, suffix), codCap(seller, itemID, suffix)); return end
    if not ns.channelName then cb(nil); return end
    local k = pkey(seller, itemID, suffix)
    codQueries[k] = cb
    ns.EnqueueWhisper(("CQ~%d~%d"):format(itemID, suffix), seller)
    C_Timer.After(ns.COD_QUERY_TIMEOUT or 2, function()
        local pendingCb = codQueries[k]
        if pendingCb then codQueries[k] = nil; pendingCb(nil) end
    end)
end

-- Seller side: answer a buyer's outstanding-qty query straight from my order list (read-only, so no
-- codAccept gate: the honest answer is just how many I currently owe them, 0 included). Also report
-- the available cap so the buyer's popup can stop them ordering past a bag-synced listing's stock.
ns.OnMessage("CQ", function(a, b, _, _, _, _, sender)
    local buyer = Ambiguate(sender, "short")
    local itemID, suffix = tonumber(a), tonumber(b) or 0
    if not itemID then return end
    local cap = codCap(buyer, itemID, suffix)
    ns.EnqueueWhisper(("CQR~%d~%d~%d~%d"):format(itemID, suffix,
        ns.CODOutstanding(buyer, itemID, suffix), cap == nil and -1 or cap), sender)
end)

-- Buyer side: the seller's outstanding-qty answer; hand it (plus the cap) to the waiting callback.
ns.OnMessage("CQR", function(a, b, c, d, _, _, sender)
    local seller = Ambiguate(sender, "short")
    local itemID, suffix = tonumber(a), tonumber(b) or 0
    if not itemID then return end
    local k = pkey(seller, itemID, suffix)
    local cb = codQueries[k]
    if cb then
        codQueries[k] = nil
        local cap = tonumber(d)
        cb(math.max(0, tonumber(c) or 0), (cap and cap >= 0) and cap or nil)
    end
end)
