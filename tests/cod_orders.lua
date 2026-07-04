-- Unit test for the seller-side COD order list (Services/CODOrders.lua).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package (.pkgmeta
-- ignore). Run from the addon root with:  lua tests/cod_orders.lua
--
-- It loads the REAL Services/CODOrders.lua against a stubbed WoW API and asserts:
--   * a valid add stores the exact record (buyer/item/qty/unit, total = unit*qty, done=false);
--   * ids increment and survive removals (a stable handle for the UI / later protocol);
--   * validation: no item and no buyer are rejected; qty/unit are clamped; the buyer is trimmed;
--   * CODList returns the orders oldest-first, and removal drops exactly the record passed in.

local failures = 0
local function check(name, cond)
    io.write(cond and ("  ok   " .. name .. "\n") or ("  FAIL " .. name .. "\n"))
    if not cond then failures = failures + 1 end
end

--========================================================================
-- Minimal WoW API + addon-namespace stubs
--========================================================================
function GetItemInfo(id) return "Item " .. id end
function GetCoinTextureString(c) return tostring(c) .. "c" end

local fakeNow = 1000
function time() return fakeNow end   -- controllable clock so we can assert the oldest-first order

local lastFeedback   -- { msg, isError }
local refreshes = 0
local ns = {
    Feedback = function(msg, isError) lastFeedback = { msg = msg, isError = isError } end,
    Log = function() end,
    ItemDB = { Learn = function() end },
    RefreshCOD = function() refreshes = refreshes + 1 end,
    OnMessage = function() end,   -- CODOrders registers CO/OA handlers at load; this test only covers the data layer
}

GuildFoundMarketCharDB = { codOrders = {} }

local function loadModule(path) local chunk = assert(loadfile(path)); return chunk("GuildFoundMarket", ns) end
loadModule("Services/CODOrders.lua")

--========================================================================
-- 1. A valid add stores the exact record
--========================================================================
local ok = ns.AddCODOrder("Buyerman", 13468, 0, 5, 15000, "manual")
check("valid add returns true", ok == true)
check("count is 1 after add", ns.CODCount() == 1)
check("refresh fired on add", refreshes == 1)

local list = ns.CODList()
local rec = list[1]
check("buyer stored", rec and rec.buyer == "Buyerman")
check("itemID stored", rec and rec.itemID == 13468)
check("qty stored", rec and rec.qty == 5)
check("unit stored", rec and rec.unit == 15000)
check("total = unit * qty", rec and rec.total == 75000)
check("source stored", rec and rec.source == "manual")
check("not done yet", rec and rec.done == false)
check("first id is 1", rec and rec.id == 1)
check("added stamped from clock", rec and rec.added == 1000)

--========================================================================
-- 2. Validation: no item / no buyer are rejected, list untouched
--========================================================================
local before = ns.CODCount()
check("add without item rejected", ns.AddCODOrder("Buyerman", nil, 0, 1, 1) == nil)
check("add without item feedback is an error", lastFeedback.isError == true)
check("add with blank buyer rejected", ns.AddCODOrder("   ", 111, 0, 1, 1) == nil)
check("count unchanged after rejects", ns.CODCount() == before)

--========================================================================
-- 3. Clamping + buyer trimming
--========================================================================
fakeNow = 1001
ns.AddCODOrder("  Trim~me \n ", 222, 3, 0, -50, "manual")   -- qty 0 -> 1, unit -50 -> 0
local trimmed
for _, r in ipairs(ns.CODList()) do if r.itemID == 222 then trimmed = r end end
check("buyer trimmed and tildes/newlines scrubbed", trimmed and trimmed.buyer == "Trim me")
check("qty clamped up to 1", trimmed and trimmed.qty == 1)
check("unit clamped up to 0", trimmed and trimmed.unit == 0)
check("total is 0 when unit is 0", trimmed and trimmed.total == 0)
check("suffix preserved", trimmed and trimmed.suffix == 3)

--========================================================================
-- 4. Ids increment; CODList is oldest-first
--========================================================================
fakeNow = 1002
ns.AddCODOrder("Third", 333, 0, 1, 100)
check("second add got id 2", ns.CODList()[2].id == 2)
check("third add got id 3", ns.CODList()[3].id == 3)
local ordered = ns.CODList()
check("oldest-first ordering", ordered[1].added <= ordered[2].added and ordered[2].added <= ordered[3].added)

--========================================================================
-- 5. Removal drops exactly the record passed in
--========================================================================
local target = ns.CODList()[1]
refreshes = 0
ns.RemoveCODOrder(target, "done")
check("count drops by one after done", ns.CODCount() == 2)
check("refresh fired on remove", refreshes == 1)
local stillThere
for _, r in ipairs(ns.CODList()) do if r.id == target.id then stillThere = true end end
check("removed record is gone", not stillThere)

-- Removing a record not in the list is a harmless no-op
local phantom = { id = 999 }
ns.RemoveCODOrder(phantom, "cancel")
check("removing an unknown record is a no-op", ns.CODCount() == 2)

--========================================================================
-- 6. Dedupe: re-adding the same (buyer, itemID, suffix) updates qty/price, no new row
--========================================================================
GuildFoundMarketCharDB = { codOrders = {} }
fakeNow = 2000
ns.AddCODOrder("Dupe", 500, 0, 2, 100)
local firstId = ns.CODList()[1].id
fakeNow = 2001
ns.AddCODOrder("Dupe", 500, 0, 7, 250)   -- same buyer+item+suffix -> update, not append
check("dedupe keeps a single row", ns.CODCount() == 1)
local d = ns.CODList()[1]
check("dedupe keeps the original id", d.id == firstId)
check("dedupe takes the newest qty (authoritative)", d.qty == 7)
check("dedupe takes the newest unit", d.unit == 250)
check("dedupe recomputes total", d.total == 1750)
check("dedupe keeps the original added stamp / position", d.added == 2000)

-- a different suffix is a different variant -> a genuine second row
ns.AddCODOrder("Dupe", 500, 3, 1, 100)
check("different suffix is not deduped", ns.CODCount() == 2)

--========================================================================
-- 7. EditCODOrder mutates the row in place, keeping id and position
--========================================================================
GuildFoundMarketCharDB = { codOrders = {} }
fakeNow = 3000
ns.AddCODOrder("Alice", 600, 0, 1, 100)
local target7 = ns.CODList()[1]
local okEdit = ns.EditCODOrder(target7, "Bob", 601, 2, 4, 500)
check("edit returns true", okEdit == true)
check("edit does not add a row", ns.CODCount() == 1)
check("edit keeps the id", ns.CODList()[1].id == target7.id)
check("edit updates buyer", ns.CODList()[1].buyer == "Bob")
check("edit updates itemID", ns.CODList()[1].itemID == 601)
check("edit updates suffix", ns.CODList()[1].suffix == 2)
check("edit updates qty", ns.CODList()[1].qty == 4)
check("edit recomputes total", ns.CODList()[1].total == 2000)
check("editing an unknown record is rejected", ns.EditCODOrder({ id = 42 }, "X", 1, 0, 1, 1) == nil)
check("edit with blank buyer rejected", ns.EditCODOrder(target7, "  ", 601, 0, 1, 1) == nil)

--========================================================================
-- 8. CODCommitted: total promised across all buyers for an item (drives stock reservation)
--========================================================================
GuildFoundMarketCharDB = { codOrders = {} }
check("committed is 0 with no orders", ns.CODCommitted(700, 0) == 0)
ns.AddCODOrder("Ann", 700, 0, 3, 100)
ns.AddCODOrder("Bob", 700, 0, 4, 100)
ns.AddCODOrder("Cat", 700, 2, 9, 100)   -- different suffix: a separate variant
check("committed sums all buyers for the variant", ns.CODCommitted(700, 0) == 7)
check("committed is per suffix", ns.CODCommitted(700, 2) == 9)
local annRec
for _, r in ipairs(ns.CODList()) do if r.buyer == "Ann" then annRec = r end end
ns.RemoveCODOrder(annRec, "done")   -- Ann's order done -> frees her 3
check("committed drops after done", ns.CODCommitted(700, 0) == 4)

io.write(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
