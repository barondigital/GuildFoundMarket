-- Regression test for the mail-order protocol (MO / MOA / MOD / MOX).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package
-- (.pkgmeta ignore). Run from the addon root with:  lua tests/orders_compat.lua
--
-- It loads the REAL Services/Protocol.lua and Services/Orders.lua against a stubbed
-- WoW API and asserts:
--   * the MO wire keeps suffix LAST (house style: append-only fields for old clients)
--   * a received order is stored once, acked (even on a duplicate MO), and bad ones dropped
--   * the buyer's status walks pending -> received -> accepted, and the no-ack timeout
--     only fires when no ack ever came
--   * decisions from the wrong sender are ignored
--   * accept/decline/cancel/sent all put the right message on the wire
--   * the SendMail hook marks the oldest accepted order for that recipient as sent

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
        res[#res + 1] = s:sub(start, i - 1)
        start = i + #sep
    end
    return unpack(res)
end

function Ambiguate(name) return (name:gsub("%-.*", "")) end
function GetItemInfo(id) return "Item" .. id end
function GetCoinTextureString(c) return tostring(c) .. "c" end
local now = 1000
function time() now = now + 1; return now end

-- deferred timers, run by hand so the no-ack timeout can be tested both ways
local deferred = {}
C_Timer = { After = function(_, fn) deferred[#deferred + 1] = fn end }
local function runDeferred()
    local d = deferred; deferred = {}
    for _, fn in ipairs(d) do fn() end
end

-- capture the SendMail hook that StartOrders installs
local sendMailHook
function hooksecurefunc(name, fn) if name == "SendMail" then sendMailHook = fn end end

local printed = {}
local rawprint = print
function print(msg) printed[#printed + 1] = msg end

GuildFoundMarketCharDB = { ordersIn = {}, ordersOut = {} }

local sentWhispers = {}
local ns = {
    playerName   = "Me",
    channelName  = "GFM",
    QUERY_SETTLE = 3,
    Feedback = function() end,
    Log = function() end,
    EnqueueWhisper = function(msg, to) sentWhispers[#sentWhispers + 1] = { msg = msg, to = to } end,
    ItemDB = { Learn = function() end },
}
local function reset() sentWhispers = {} end
local function lastMsg() return sentWhispers[#sentWhispers] end

--========================================================================
-- Load the real protocol + feature against the stubs
--========================================================================
local function loadModule(path)
    local chunk = assert(loadfile(path))
    return chunk("GuildFoundMarket", ns)
end
loadModule("Services/Protocol.lua")
loadModule("Services/Orders.lua")
ns.StartOrders()

--========================================================================
-- 1. Buyer places an order: wire format, suffix last
--========================================================================
local buyerOid
do
    reset()
    check("PlaceOrder succeeds", ns.PlaceOrder("Bob", 100, 7, 3, 5000))
    local w = lastMsg()
    check("order whispered to the seller", w and w.to == "Bob")
    local cmd, oid, id, qty, price, sfx = strsplit("~", w.msg)
    buyerOid = oid
    check("MO carries id/qty/price", cmd == "MO" and id == "100" and qty == "3" and price == "5000")
    check("MO keeps suffix last", sfx == "7")
    check("buyer half stored as pending", GuildFoundMarketCharDB.ordersOut[oid].status == "pending")
    check("a bid (price 0) can't be ordered", not ns.PlaceOrder("Bob", 100, 0, 1, 0))
end

--========================================================================
-- 2. Ack flips pending -> received; the timeout then leaves it alone
--========================================================================
do
    ns.DispatchMessage("MOA~" .. buyerOid, "Bob-Realm")
    check("MOA flips the order to received", GuildFoundMarketCharDB.ordersOut[buyerOid].status == "received")
    runDeferred()   -- the no-ack timeout fires now, but the ack already landed
    check("acked order never goes noreply", GuildFoundMarketCharDB.ordersOut[buyerOid].status == "received")
end

--========================================================================
-- 3. No ack = noreply after the timeout
--========================================================================
do
    reset()
    ns.PlaceOrder("Ghost", 100, 0, 1, 5000)
    local _, oid = strsplit("~", lastMsg().msg)
    runDeferred()
    check("unacked order goes noreply", GuildFoundMarketCharDB.ordersOut[oid].status == "noreply")
    GuildFoundMarketCharDB.ordersOut[oid] = nil
end

--========================================================================
-- 4. Seller receives an order: stored once, acked every time, bad ones dropped
--========================================================================
do
    reset()
    ns.DispatchMessage("MO~Alice#1.1~200~2~4000~0", "Alice-Realm")
    local o = GuildFoundMarketCharDB.ordersIn["Alice#1.1"]
    check("incoming order stored as new", o and o.status == "new" and o.buyer == "Alice" and o.qty == 2)
    check("incoming order acked", lastMsg().msg == "MOA~Alice#1.1" and lastMsg().to == "Alice-Realm")
    local notified = #printed
    reset()
    ns.DispatchMessage("MO~Alice#1.1~200~2~4000~0", "Alice-Realm")   -- duplicate (lost ack)
    check("duplicate MO re-acked, not re-stored", lastMsg().msg == "MOA~Alice#1.1" and #printed == notified)
    ns.DispatchMessage("MO~Bad#1~200~0~4000~0", "Alice-Realm")       -- qty 0
    ns.DispatchMessage("MO~Bad#2~200~2~0~0", "Alice-Realm")          -- price 0
    check("bad qty/price orders dropped", not GuildFoundMarketCharDB.ordersIn["Bad#1"] and not GuildFoundMarketCharDB.ordersIn["Bad#2"])
end

--========================================================================
-- 5. Accept / decline put the right decision on the wire
--========================================================================
do
    reset()
    ns.AcceptOrder("Alice#1.1")
    check("accept sends MOD~oid~A to the buyer", lastMsg().msg == "MOD~Alice#1.1~A" and lastMsg().to == "Alice")
    check("order now accepted", GuildFoundMarketCharDB.ordersIn["Alice#1.1"].status == "accepted")
    check("accepted orders listed for the mailbox helper", ns.AcceptedOrders()[1].oid == "Alice#1.1")
end

--========================================================================
-- 6. Buyer-side decision handling (right sender only)
--========================================================================
do
    ns.DispatchMessage("MOD~" .. buyerOid .. "~A", "Mallory-Realm")
    check("MOD from the wrong sender ignored", GuildFoundMarketCharDB.ordersOut[buyerOid].status == "received")
    ns.DispatchMessage("MOD~" .. buyerOid .. "~A", "Bob-Realm")
    check("MOD~A marks the order accepted", GuildFoundMarketCharDB.ordersOut[buyerOid].status == "accepted")
    ns.DispatchMessage("MOD~" .. buyerOid .. "~S", "Bob-Realm")
    check("MOD~S marks the order mailed", GuildFoundMarketCharDB.ordersOut[buyerOid].status == "mailed")
end

--========================================================================
-- 7. The SendMail hook marks the accepted order sent and tells the buyer
--========================================================================
do
    reset()
    sendMailHook("Alice-Realm", "whatever", "body")
    check("mail to the buyer marks the order sent", GuildFoundMarketCharDB.ordersIn["Alice#1.1"].status == "sent")
    check("buyer told the order was mailed", lastMsg().msg == "MOD~Alice#1.1~S")
    reset()
    sendMailHook("Alice-Realm", "again", "body")
    check("a second mail to the same buyer is not re-matched", #sentWhispers == 0)
end

--========================================================================
-- 8. Buyer cancel: MOX on the wire, seller drops their half
--========================================================================
do
    reset()
    ns.CancelOrder(buyerOid)   -- already mailed: just drops our half, no MOX
    check("cancelling a mailed order stays silent", #sentWhispers == 0)
    check("buyer half removed", GuildFoundMarketCharDB.ordersOut[buyerOid] == nil)
    GuildFoundMarketCharDB.ordersOut["Me#9.9"] = { seller = "Bob", id = 100, suffix = 0, qty = 1, price = 100, t = time(), status = "accepted" }
    ns.CancelOrder("Me#9.9")
    check("cancelling an accepted order sends MOX to the seller", lastMsg().msg == "MOX~Me#9.9" and lastMsg().to == "Bob")
    check("cancelled half removed", GuildFoundMarketCharDB.ordersOut["Me#9.9"] == nil)
    GuildFoundMarketCharDB.ordersIn["Alice#2.1"] = { buyer = "Alice", id = 200, suffix = 0, qty = 1, price = 100, t = time(), status = "new" }
    ns.DispatchMessage("MOX~Alice#2.1", "Mallory-Realm")
    check("MOX from the wrong sender ignored", GuildFoundMarketCharDB.ordersIn["Alice#2.1"] ~= nil)
    ns.DispatchMessage("MOX~Alice#2.1", "Alice-Realm")
    check("MOX drops the seller's half", GuildFoundMarketCharDB.ordersIn["Alice#2.1"] == nil)
end

print = rawprint
io.write(failures == 0 and "\nAll order protocol checks passed.\n"
                        or ("\n" .. failures .. " check(s) FAILED.\n"))
os.exit(failures == 0 and 0 or 1)
