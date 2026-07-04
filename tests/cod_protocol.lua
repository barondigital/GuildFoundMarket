-- Unit test for the Phase 2 COD request protocol (Services/CODOrders.lua + Services/Protocol.lua).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package (.pkgmeta
-- ignore). Run from the addon root with:  lua tests/cod_protocol.lua
--
-- It loads the REAL Protocol.lua (the ~ dispatcher) and CODOrders.lua against a stubbed WoW API,
-- then drives incoming CO requests and OA replies and asserts:
--   * an accepted request queues an order, sends OA~ok, and sends the filled confirmation whisper;
--   * requests are declined (with the right reason, no order, no whisper) when COD is off, while
--     paused, when the item isn't listed, and when the listing has no fixed price (bids);
--   * the seller's own listed price wins over the price the buyer sent;
--   * the buyer-side RequestCOD puts a CO on the wire and refuses to request from yourself;
--   * confirmation-whisper token substitution.

local failures = 0
local function check(name, cond)
    io.write(cond and ("  ok   " .. name .. "\n") or ("  FAIL " .. name .. "\n"))
    if not cond then failures = failures + 1 end
end

--========================================================================
-- Minimal WoW API + addon-namespace stubs
--========================================================================
local unpack = table.unpack or unpack
function strsplit(sep, s)
    local res, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then res[#res + 1] = s:sub(start); break end
        res[#res + 1] = s:sub(start, i - 1); start = i + #sep
    end
    return unpack(res)
end
function GetItemInfo(id) return "Item " .. id end
function GetCoinTextureString(c) return tostring(c) .. "c" end
function Ambiguate(name) return name end                 -- already short in tests
function SendChatMessage(text, chan, _, to) sentWhispers[#sentWhispers + 1] = { text = text, chan = chan, to = to } end
C_Timer = { After = function() end }                     -- swallow the request-timeout timer
function time() return 4242 end
ChatTypeInfo = { WHISPER = { r = 1, g = 0.5, b = 1 } }
local chatMessages = {}  -- captured DEFAULT_CHAT_FRAME:AddMessage (the self-test simulated whisper)
DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) chatMessages[#chatMessages + 1] = text end }

sentWhispers = {}
local wire = {}          -- captured EnqueueWhisper: { msg, to }
local feedback = {}      -- captured Feedback: { msg, isError }
local settings = { codAccept = true, codReplyText = "Got %item x%qty (%total) for %buyer" }
local listings = {}      -- OfferList result
local paused = false

local ns = {
    playerName = "Me",
    channelName = "chan",
    QUERY_SETTLE = 5,
    Log = function() end,
    Feedback = function(msg, isError) feedback[#feedback + 1] = { msg = msg, isError = isError } end,
    ItemDB = { Learn = function() end },
    RefreshCOD = function() end,
    CoinText = function(c) return (c or 0) .. "c" end,
    GetSetting = function(k) return settings[k] end,
    OfferList = function() return listings end,
    OfferInfo = function(id, sfx)   -- (qty, track, price) for the seller's own listing, or nil
        for _, it in ipairs(listings) do
            if it.id == id and (it.suffix or 0) == (sfx or 0) then return it.qty or 0, it.track and true or false, it.price end
        end
    end,
    IsPaused = function() return paused end,
    EnqueueWhisper = function(msg, to) wire[#wire + 1] = { msg = msg, to = to } end,
    CODCancelMarker = function(id, sfx) return ("{{GFMCOD:Me:%d:%d}}"):format(id, sfx or 0) end,
}

GuildFoundMarketCharDB = { codOrders = {} }

local function loadModule(path) local chunk = assert(loadfile(path)); return chunk("GuildFoundMarket", ns) end
loadModule("Services/Protocol.lua")    -- ns.OnMessage / ns.DispatchMessage
loadModule("Services/CODOrders.lua")   -- registers CO/OA, defines RequestCOD/AddCODOrder/...

local function reset(tbl) for i = #tbl, 1, -1 do tbl[i] = nil end end
local function resetAll()
    reset(wire); reset(sentWhispers); reset(feedback); reset(chatMessages)
    for i = #GuildFoundMarketCharDB.codOrders, 1, -1 do GuildFoundMarketCharDB.codOrders[i] = nil end
end
local function lastWire() return wire[#wire] end
local function wireHas(prefix)
    for _, w in ipairs(wire) do if w.msg:sub(1, #prefix) == prefix then return w end end
end

--========================================================================
-- 1. Accept: order queued, OA~ok sent, confirmation whisper filled + sent
--========================================================================
resetAll()
settings.codAccept, paused = true, false
listings = { { id = 100, suffix = 0, qty = 9, price = 15000 } }
ns.DispatchMessage("CO~100~0~5~15000", "Buyerman")
check("accepted: one order queued", ns.CODCount() == 1)
local o = ns.CODList()[1]
check("accepted: order fields", o and o.buyer == "Buyerman" and o.itemID == 100 and o.qty == 5 and o.unit == 15000 and o.source == "request")
local ok = wireHas("OA~ok")
check("accepted: OA~ok on the wire to buyer", ok ~= nil and ok.to == "Buyerman")
check("accepted: OA~ok echoes item+suffix", ok and ok.msg == "OA~ok~~100~0")
check("accepted: one confirmation whisper sent", #sentWhispers == 1 and sentWhispers[1].to == "Buyerman")
check("accepted: whisper tokens filled", sentWhispers[1]
    and sentWhispers[1].text:find("Got Item 100 x5 (75000c) for Buyerman", 1, true) == 1)
check("accepted: whisper carries a Cancel COD marker", sentWhispers[1]
    and sentWhispers[1].text:find("{{GFMCOD:Me:100:0}}", 1, true) ~= nil)

--========================================================================
-- 2. Decline: COD off -> closed, no order, no whisper
--========================================================================
resetAll()
settings.codAccept = false
ns.DispatchMessage("CO~100~0~5~15000", "Buyerman")
check("cod off: no order", ns.CODCount() == 0)
check("cod off: OA~no~closed", (wireHas("OA~no") or {}).msg == "OA~no~closed~100~0")
check("cod off: no whisper", #sentWhispers == 0)

--========================================================================
-- 3. Decline: paused -> closed
--========================================================================
resetAll()
settings.codAccept, paused = true, true
ns.DispatchMessage("CO~100~0~5~15000", "Buyerman")
check("paused: no order", ns.CODCount() == 0)
check("paused: OA~no~closed", (wireHas("OA~no") or {}).msg == "OA~no~closed~100~0")

--========================================================================
-- 4. Decline: item not listed -> stock
--========================================================================
resetAll()
settings.codAccept, paused = true, false
listings = { { id = 999, suffix = 0, qty = 1, price = 5000 } }
ns.DispatchMessage("CO~100~0~1~5000", "Buyerman")
check("not listed: no order", ns.CODCount() == 0)
check("not listed: OA~no~stock", (wireHas("OA~no") or {}).msg == "OA~no~stock~100~0")

--========================================================================
-- 5. Decline: listed for bids (price 0) and no buyer price -> price
--========================================================================
resetAll()
listings = { { id = 100, suffix = 0, qty = 3, price = 0 } }
ns.DispatchMessage("CO~100~0~2~0", "Buyerman")
check("bids: no order", ns.CODCount() == 0)
check("bids: OA~no~price", (wireHas("OA~no") or {}).msg == "OA~no~price~100~0")

--========================================================================
-- 6. Seller's listed price is authoritative over the buyer's sent price
--========================================================================
resetAll()
listings = { { id = 100, suffix = 0, qty = 3, price = 20000 } }
ns.DispatchMessage("CO~100~0~1~15000", "Buyerman")   -- buyer sent 15000, seller lists 20000
check("price authority: order uses seller price", ns.CODList()[1] and ns.CODList()[1].unit == 20000)

--========================================================================
-- 7. Buyer side: RequestCOD emits CO; self-request is refused
--========================================================================
resetAll()
ns.RequestCOD("Selleria", 100, 0, 1, 20000)
check("request: CO on the wire to seller", (wireHas("CO") or {}).msg == "CO~100~0~1~20000" and (wireHas("CO") or {}).to == "Selleria")
resetAll()
ns.RequestCOD("Me", 100, 0, 1, 20000)   -- can't COD your own listing
check("self-request: nothing sent", #wire == 0)
check("self-request: error feedback", feedback[#feedback] and feedback[#feedback].isError == true)

--========================================================================
-- 8. Buyer side: OA reply drives feedback (ok = not an error, decline = error)
--========================================================================
resetAll()
ns.DispatchMessage("OA~ok~~100~0", "Selleria")
check("reply ok: non-error feedback", feedback[#feedback] and feedback[#feedback].isError == false)
resetAll()
ns.DispatchMessage("OA~no~stock~100~0", "Selleria")
check("reply decline: error feedback", feedback[#feedback] and feedback[#feedback].isError == true)

--========================================================================
-- 9. Self-test: requesting from your own shop simulates the round trip locally (no wire)
--========================================================================
resetAll()
ns.selfTest = true
settings.codAccept, paused = true, false
listings = { { id = 100, suffix = 0, qty = 3, price = 20000 } }
ns.RequestCOD("Me", 100, 0, 2, 20000)
check("selftest: order queued locally", ns.CODCount() == 1 and ns.CODList()[1].source == "request")
check("selftest: nothing put on the wire", #wire == 0)
check("selftest: nothing sent as a real self-whisper", #sentWhispers == 0)
local function chatHas(sub) for _, m in ipairs(chatMessages) do if m:find(sub, 1, true) then return true end end end
check("selftest: confirmation echoed to chat as a simulated whisper", chatHas("Got Item 100 x2 (40000c) for Me") == true)
check("selftest: buyer feedback fired (OA dispatched locally)", feedback[#feedback] and feedback[#feedback].isError == false)
ns.selfTest = false

--========================================================================
-- 10. Token substitution leaves unknown tokens intact, empty template = no whisper
--========================================================================
check("tokens: filled", ns.CODReplyText("Bob", 100, 2, 3000) == "Got Item 100 x2 (6000c) for Bob")
settings.codReplyText = ""
check("empty template: returns empty (no whisper)", ns.CODReplyText("Bob", 100, 2, 3000) == "")
settings.codReplyText = "Got %item x%qty (%total) for %buyer"
settings.codSentText = "Mailed %item x%qty (%total) to %buyer"
check("sent tokens: filled", ns.CODSentText("Bob", 100, 2, 3000) == "Mailed Item 100 x2 (6000c) to Bob")
settings.codSentText = ""
check("sent empty template: no whisper", ns.CODSentText("Bob", 100, 2, 3000) == "")

--========================================================================
-- 11. Outstanding-qty query (CQ/CQR): buyer asks, seller answers from its own list
--========================================================================
resetAll()
settings.codAccept, paused = true, false
check("outstanding is 0 with no order", ns.CODOutstanding("Buyerman", 100, 0) == 0)
ns.AddCODOrder("Buyerman", 100, 0, 6, 15000, "request")
check("outstanding reads the order qty", ns.CODOutstanding("Buyerman", 100, 0) == 6)
check("outstanding is per (buyer,item,suffix)", ns.CODOutstanding("Buyerman", 100, 3) == 0)

-- seller side: a CQ from Buyerman is answered with a CQR carrying the outstanding qty and cap
-- (cap -1 = uncapped, since the listing here is manual / not bag-synced)
resetAll()
listings = {}
ns.AddCODOrder("Buyerman", 100, 0, 6, 15000, "request")
ns.DispatchMessage("CQ~100~0", "Buyerman")
check("seller answers CQ with CQR", lastWire() and lastWire().msg == "CQR~100~0~6~-1" and lastWire().to == "Buyerman")

-- seller answers 0 (not just silence) when it owes the buyer nothing, so the popup can still open
resetAll()
listings = {}
ns.DispatchMessage("CQ~100~0", "Stranger")
check("seller answers 0 when nothing is owed", lastWire() and lastWire().msg == "CQR~100~0~0~-1")

-- buyer side: QueryCOD sends CQ, and a CQR reply drives the callback with the qty
resetAll()
local gotQty
ns.QueryCOD("Aldo", 100, 0, function(q) gotQty = q end)
check("QueryCOD puts CQ on the wire", lastWire() and lastWire().msg == "CQ~100~0" and lastWire().to == "Aldo")
ns.DispatchMessage("CQR~100~0~4", "Aldo")
check("CQR resolves the query callback with the qty", gotQty == 4)

-- own shop: QueryCOD resolves locally (no wire), reading your own list
resetAll()
ns.AddCODOrder("Me", 100, 0, 2, 15000, "request")
local selfQty = -1
ns.QueryCOD("Me", 100, 0, function(q) selfQty = q end)
check("QueryCOD on own shop resolves locally", selfQty == 2)
check("QueryCOD on own shop puts nothing on the wire", #wire == 0)

--========================================================================
-- 12. Cancel (qty 0): buyer clears an order, seller drops the row and acks
--========================================================================
-- buyer side: RequestCOD with qty 0 puts a cancel (CO~...~0) on the wire, not a clamped x1
resetAll()
settings.codAccept, paused = true, false
ns.RequestCOD("Aldo", 100, 0, 0, 15000)
check("cancel: buyer sends CO with qty 0", lastWire() and lastWire().msg == "CO~100~0~0~15000" and lastWire().to == "Aldo")

-- seller side: a CO with qty 0 removes the matching order and replies OA~cancelled
resetAll()
ns.AddCODOrder("Buyerman", 100, 0, 5, 15000, "request")
check("cancel setup: order present", ns.CODCount() == 1)
ns.DispatchMessage("CO~100~0~0~0", "Buyerman")
check("cancel: order removed on seller", ns.CODCount() == 0)
check("cancel: seller acks OA~cancelled", lastWire() and lastWire().msg == "OA~cancelled~~100~0")

-- seller side: a cancel with nothing on file acks OA~nocancel (no crash, no order)
resetAll()
ns.DispatchMessage("CO~100~0~0~0", "Buyerman")
check("cancel with nothing on file: OA~nocancel", lastWire() and lastWire().msg == "OA~nocancel~~100~0")

-- buyer side: OA~cancelled / OA~nocancel give non-error feedback
resetAll()
ns.DispatchMessage("OA~cancelled~~100~0", "Aldo")
check("cancel reply: non-error feedback", feedback[#feedback] and feedback[#feedback].isError == false
    and feedback[#feedback].msg:find("cancelled", 1, true) ~= nil)
ns.DispatchMessage("OA~nocancel~~100~0", "Aldo")
check("nocancel reply: non-error feedback", feedback[#feedback] and feedback[#feedback].isError == false)

-- self-test: cancelling your own shop removes locally, no wire
resetAll()
ns.selfTest = true
ns.AddCODOrder("Me", 100, 0, 3, 15000, "request")
ns.RequestCOD("Me", 100, 0, 0, 15000)
check("selftest cancel: order removed locally", ns.CODCount() == 0)
check("selftest cancel: nothing on the wire", #wire == 0)
ns.selfTest = false

-- clicking your OWN Cancel COD link (not in self-test): cancels the local order and confirms it,
-- so the buyer sees the cancel came through even solo
resetAll()
ns.AddCODOrder("Me", 100, 0, 3, 15000, "request")
ns.RequestCOD("Me", 100, 0, 0, 15000)
check("self-cancel: order removed without self-test", ns.CODCount() == 0)
check("self-cancel: nothing on the wire", #wire == 0)
check("self-cancel: buyer sees a cancelled confirmation", feedback[#feedback]
    and feedback[#feedback].isError == false and feedback[#feedback].msg:find("cancelled", 1, true) ~= nil)

--========================================================================
-- 13. Bag-synced cap: seller clamps to available stock and reports the free amount in CQR
--========================================================================
resetAll()
settings.codAccept, paused = true, false

-- request more than stock on a tracked listing -> order clamped to 5, whisper reports the clamped qty
listings = { { id = 100, suffix = 0, qty = 5, price = 15000, track = true } }
ns.DispatchMessage("CO~100~0~10~0", "Greedy")
check("cap: order clamped to available stock", ns.CODCount() == 1 and ns.CODList()[1].qty == 5)
check("cap: confirmation whisper reports clamped qty", sentWhispers[#sentWhispers]
    and sentWhispers[#sentWhispers].text:find("Got Item 100 x5 (75000c) for Greedy", 1, true) == 1)

-- CQR cap: another buyer sees 0 free when others already hold all the stock
resetAll()
listings = { { id = 100, suffix = 0, qty = 5, price = 15000, track = true } }
ns.AddCODOrder("Greedy", 100, 0, 5, 15000, "request")
ns.DispatchMessage("CQ~100~0", "Newbie")
check("cap: CQR reports 0 free when others hold all stock", lastWire().msg == "CQR~100~0~0~0")

-- a buyer's own commitment doesn't count against their own cap (they're editing, not adding)
resetAll()
listings = { { id = 100, suffix = 0, qty = 5, price = 15000, track = true } }
ns.AddCODOrder("Greedy", 100, 0, 2, 15000, "request")
ns.DispatchMessage("CQ~100~0", "Greedy")
check("cap: own order excluded from own cap", lastWire().msg == "CQR~100~0~2~5")

-- a fully-committed bag-synced listing declines a new buyer with `stock`
resetAll()
listings = { { id = 100, suffix = 0, qty = 5, price = 15000, track = true } }
ns.AddCODOrder("Greedy", 100, 0, 5, 15000, "request")
ns.DispatchMessage("CO~100~0~1~0", "Newbie")
check("cap: fully-committed listing declines new buyer (stock)", lastWire().msg == "OA~no~stock~100~0")
check("cap: no order added for the declined buyer", ns.CODCount() == 1)

-- a manual (untracked) listing is never capped: the asked qty goes through as-is
resetAll()
listings = { { id = 100, suffix = 0, qty = 5, price = 15000, track = false } }
ns.DispatchMessage("CO~100~0~50~0", "Bulk")
check("no cap on manual listing: qty honored", ns.CODCount() == 1 and ns.CODList()[1].qty == 50)

--========================================================================
-- 14. CaptureCOD (whisper capture): listed price is used, gates on listing / bid-only
--========================================================================
resetAll()
settings.codAccept, paused = true, false
listings = { { id = 100, suffix = 0, qty = 8, price = 20000 } }
ns.CaptureCOD("Whisperer", 100, 0, 3)
check("capture: order queued at the listed price", ns.CODCount() == 1
    and ns.CODList()[1].qty == 3 and ns.CODList()[1].unit == 20000 and ns.CODList()[1].buyer == "Whisperer")
check("capture: confirmation whisper sent", sentWhispers[#sentWhispers] and sentWhispers[#sentWhispers].to == "Whisperer")

resetAll()
listings = { { id = 100, suffix = 0, qty = 8, price = 20000 } }
ns.CaptureCOD("Whisperer", 100, 0, "all")
check("capture: 'all' becomes the listed quantity", ns.CODCount() == 1 and ns.CODList()[1].qty == 8)

resetAll()
listings = {}
ns.CaptureCOD("Whisperer", 100, 0, 3)
check("capture: an unlisted item is ignored", ns.CODCount() == 0)

resetAll()
listings = { { id = 100, suffix = 0, qty = 8, price = 0 } }
ns.CaptureCOD("Whisperer", 100, 0, 3)
check("capture: a bid-only listing is not auto-captured", ns.CODCount() == 0)

io.write(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
