-- Unit test for the COD mailbox send-assist (Services/CODMail.lua).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package. Run from the addon
-- root with:  lua tests/cod_mail.lua
--
-- It loads the REAL Services/CODMail.lua against a stubbed WoW + mail API and asserts that
-- ns.CODSendAssist:
--   * refuses (with an error) when no mailbox is open, and prefills nothing;
--   * refuses when the item isn't in bags in a big enough combined stock;
--   * on the happy path fills recipient + subject, attaches the exact item, switches to COD mode,
--     and sets the COD money to the order total;
--   * splits a larger stack down to the ordered qty by landing the split in a bag slot and
--     attaching that (never off the cursor into a mail slot, which over-attaches the whole stack);
--   * combines multiple stacks, largest first, splitting only the last one needed.

local failures = 0
local function check(name, cond)
    io.write(cond and ("  ok   " .. name .. "\n") or ("  FAIL " .. name .. "\n"))
    if not cond then failures = failures + 1 end
end

--========================================================================
-- Stubbed WoW + mail API. `calls` records everything CODSendAssist drives.
--========================================================================
function GetItemInfo(id) return "Item " .. id end
function GetCoinTextureString(c) return tostring(c) .. "c" end
NUM_BAG_SLOTS = 4

local calls = {}
local function reset() calls = { attached = {}, split = nil, name = nil, subject = nil, cod = nil, money = nil, tab = nil, cleared = false } end
reset()

-- bags: [bag][slot] = { itemID, suffix, count }. linkSuffix reads a "sfx=N" marker off our fake link.
local bags = {}
local function setBag(bag, slot, itemID, suffix, count) bags[bag] = bags[bag] or {}; bags[bag][slot] = { itemID = itemID, suffix = suffix, count = count } end

C_Container = {
    GetContainerNumSlots = function(bag) return bags[bag] and 20 or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local it = bags[bag] and bags[bag][slot]
        if not it then return nil end
        return { itemID = it.itemID, stackCount = it.count, hyperlink = ("item:%d:0:0:0:0:0:%d:0"):format(it.itemID, it.suffix or 0) }
    end,
    UseContainerItem = function(bag, slot) calls.attached[#calls.attached + 1] = { bag = bag, slot = slot, whole = true } end,
    -- Mirrors the real split-then-pickup two-step: the split amount rides an intermediate
    -- "cursor" and only lands in bags once PickupContainerItem drops it into a slot.
    SplitContainerItem = function(bag, slot, qty)
        calls.split = { bag = bag, slot = slot, qty = qty }
        local src = bags[bag][slot]
        calls.cursor = { itemID = src.itemID, suffix = src.suffix, count = qty }
        src.count = src.count - qty
    end,
    PickupContainerItem = function(bag, slot)
        if calls.cursor then
            setBag(bag, slot, calls.cursor.itemID, calls.cursor.suffix, calls.cursor.count)
            calls.cursor = nil
        end
    end,
}
C_Timer = { After = function(delay, fn) fn() end }   -- run the split-confirm check immediately
function ClearSendMail() calls.cleared = true end
function MailFrameTab_OnClick(_, id) calls.tab = id end
function SendMailRadioButton_OnClick(index) calls.cod = (index == 2) end
function MoneyInputFrame_SetCopper(_, copper) calls.money = copper end
function SendMailFrame_Update() end
function SendMailFrame_CanSend() calls.canSend = true end
SendMailNameEditBox = { SetText = function(_, t) calls.name = t end }
SendMailSubjectEditBox = { SetText = function(_, t) calls.subject = t end }
SendMailMoney = {}

-- MailFrame + MAIL_SHOW/MAIL_CLOSED plumbing. Capture the module's OnEvent so we can toggle it.
local mailShown = false
MailFrame = { IsShown = function() return mailShown end }
local moduleOnEvent
function CreateFrame() return {
    RegisterEvent = function() end,
    SetScript = function(_, _, fn) moduleOnEvent = fn end,
} end

local lastFeedback
local ns = {
    Feedback = function(msg, isError) lastFeedback = { msg = msg, isError = isError } end,
    Log = function() end,
    Stock = { LinkSuffix = function(link) return tonumber(link and link:match("item:%d+:0:0:0:0:0:(%-?%d+)")) or 0 end },
}

local function loadModule(path) local chunk = assert(loadfile(path)); return chunk("GuildFoundMarket", ns) end
loadModule("Services/CODMail.lua")

local function openMailbox() mailShown = true; moduleOnEvent(nil, "MAIL_SHOW") end
local function closeMailbox() mailShown = false; moduleOnEvent(nil, "MAIL_CLOSED") end

--========================================================================
-- 1. No mailbox open: refuse, prefill nothing
--========================================================================
reset(); closeMailbox()
setBag(0, 1, 100, 0, 1)
ns.CODSendAssist({ buyer = "Ann", itemID = 100, suffix = 0, qty = 1, total = 15000 })
check("no mailbox: error feedback", lastFeedback and lastFeedback.isError == true)
check("no mailbox: nothing prefilled", calls.name == nil and #calls.attached == 0)

--========================================================================
-- 2. Item not in bags: refuse
--========================================================================
reset(); openMailbox()
bags = {}   -- empty bags
ns.CODSendAssist({ buyer = "Ann", itemID = 100, suffix = 0, qty = 1, total = 15000 })
check("missing item: error feedback", lastFeedback and lastFeedback.isError == true)
check("missing item: nothing attached", #calls.attached == 0)

--========================================================================
-- 3. Happy path, exact stack: recipient/subject/COD/money set, whole stack attached
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 3, 100, 0, 5)
ns.CODSendAssist({ buyer = "Ann", itemID = 100, suffix = 0, qty = 5, total = 75000 })
check("exact: switched to Send tab", calls.tab == 2)
check("exact: cleared leftover state", calls.cleared == true)
check("exact: recipient set", calls.name == "Ann")
check("exact: subject is the item name", calls.subject == "Item 100")
check("exact: whole stack attached from the right slot", #calls.attached == 1 and calls.attached[1].bag == 0 and calls.attached[1].slot == 3 and calls.attached[1].whole)
check("exact: no split needed", calls.split == nil)
check("exact: COD mode selected", calls.cod == true)
check("exact: COD money = order total", calls.money == 75000)
check("exact: send button enabled", calls.canSend == true)
check("exact: non-error feedback", lastFeedback and lastFeedback.isError == false)

--========================================================================
-- 4. Larger stack: split down to the ordered qty, never over-attach the whole source stack
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 2, 100, 0, 20)   -- 20 in stock, order is for 3
ns.CODSendAssist({ buyer = "Bob", itemID = 100, suffix = 0, qty = 3, total = 30000 })
check("split: split 3 off the stack", calls.split ~= nil and calls.split.qty == 3 and calls.split.bag == 0 and calls.split.slot == 2)
check("split: the split stack (not the source) is attached", #calls.attached == 1
    and calls.attached[1].bag == 0 and calls.attached[1].slot ~= 2 and calls.attached[1].whole)
check("split: COD money = order total", calls.money == 30000)

--========================================================================
-- 4b. Regression: order for 6 out of a stack of 7 must attach exactly 6, never the whole 7
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 2, 100, 0, 7)   -- 7 in stock, order is for 6
ns.CODSendAssist({ buyer = "Gil", itemID = 100, suffix = 0, qty = 6, total = 60000 })
check("6-of-7: split 6 off the stack, not the whole 7", calls.split ~= nil and calls.split.qty == 6)
check("6-of-7: attaches the split stack of 6, not the source stack of 7",
    #calls.attached == 1 and calls.attached[1].slot ~= 2)

--========================================================================
-- 5b. Multiple stacks: two smaller stacks combine, largest first, no split needed
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 5); setBag(0, 2, 100, 0, 3)   -- 5 + 3 = 8, order is for 8
ns.CODSendAssist({ buyer = "Deb", itemID = 100, suffix = 0, qty = 8, total = 40000 })
check("multi-stack: both whole stacks attached", #calls.attached == 2
    and calls.attached[1].bag == 0 and calls.attached[1].slot == 1 and calls.attached[1].whole
    and calls.attached[2].bag == 0 and calls.attached[2].slot == 2 and calls.attached[2].whole)
check("multi-stack: no split needed", calls.split == nil)
check("multi-stack: non-error feedback", lastFeedback and lastFeedback.isError == false)

--========================================================================
-- 5c. Multiple stacks: largest stacks attach whole, the last covers the remainder via a split
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 10); setBag(0, 2, 100, 0, 4)   -- order is for 12: 10 whole + 2 split off the 4
ns.CODSendAssist({ buyer = "Ed", itemID = 100, suffix = 0, qty = 12, total = 60000 })
check("multi-stack split: largest stack attached whole first", #calls.attached == 2
    and calls.attached[1].bag == 0 and calls.attached[1].slot == 1 and calls.attached[1].whole)
check("multi-stack split: remainder split off the second stack", calls.split ~= nil and calls.split.qty == 2 and calls.split.bag == 0 and calls.split.slot == 2)
check("multi-stack split: the split stack (not the source) is attached",
    calls.attached[2].bag == 0 and calls.attached[2].slot ~= 2 and calls.attached[2].whole)
check("multi-stack split: COD money = order total", calls.money == 60000)

--========================================================================
-- 5d. Stock spread across bags is insufficient: refuse, prefill nothing
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 5); setBag(0, 2, 100, 0, 3)   -- 8 in bags, order wants 20
ns.CODSendAssist({ buyer = "Fay", itemID = 100, suffix = 0, qty = 20, total = 100000 })
check("insufficient combined stock: error feedback", lastFeedback and lastFeedback.isError == true)
check("insufficient combined stock: nothing attached", #calls.attached == 0)

--========================================================================
-- 5. Variant match: a different suffix in the same slot is not the item
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 7, 5)   -- suffix 7 in bags, order wants suffix 0
ns.CODSendAssist({ buyer = "Cat", itemID = 100, suffix = 0, qty = 1, total = 15000 })
check("variant: wrong-suffix stack is not attached", #calls.attached == 0 and lastFeedback.isError == true)

io.write(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
