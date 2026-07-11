-- Unit test for the COD mailbox send-assist (Services/CODMail.lua).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package. Run from the addon
-- root with:  lua tests/cod_mail.lua
--
-- It loads the REAL Services/CODMail.lua against a stubbed WoW + mail API and asserts that
-- ns.CODSendAssist:
--   * refuses (with an error) when no mailbox is open, and prefills nothing;
--   * refuses when the bags hold fewer of the item than ordered;
--   * on the happy path fills recipient + subject, attaches the exact item, switches to COD mode,
--     and sets the COD money to the order total;
--   * splits a larger stack down to the ordered qty instead of over-attaching;
--   * gathers an order across multiple stacks (whole stacks + at most one split), preferring an
--     exact-size stack and consuming fractured stacks first;
--   * refuses BEFORE touching the mail frame when the order can't fit one mail's attachment
--     slots, re-planning largest-first (fewest slots) before giving up;
--   * parks a split remainder in a free bag slot first and attaches the parked stack once it
--     settles (attaching straight from a split cursor mails the whole source stack in-game),
--     refusing up front when no bag slot is free to park in.

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
ATTACHMENTS_MAX_SEND = 12

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
    SplitContainerItem = function(bag, slot, qty)
        calls.split = { bag = bag, slot = slot, qty = qty }
        local it = bags[bag] and bags[bag][slot]
        if it then it.count = it.count - qty; calls.cursorItem = it.itemID; calls.cursorSuffix = it.suffix end
        calls.cursor = qty
    end,
    -- with an item on the cursor this PLACES it (park), with an empty cursor it PICKS UP the stack
    PickupContainerItem = function(bag, slot)
        if calls.cursor then
            bags[bag] = bags[bag] or {}
            bags[bag][slot] = { itemID = calls.cursorItem, suffix = calls.cursorSuffix, count = calls.cursor }
            calls.parked = { bag = bag, slot = slot, qty = calls.cursor }
            calls.cursor = nil
        else
            local it = bags[bag] and bags[bag][slot]
            if it then calls.cursor = it.count; calls.cursorItem = it.itemID; calls.cursorSuffix = it.suffix; bags[bag][slot] = nil end
        end
    end,
}
C_Timer = { After = function(_, fn) fn() end }   -- timers fire instantly: the parked stack is already there
function HasSendMailItem(i) return false end   -- all mail slots free
function ClickSendMailItemButton(i) calls.attached[#calls.attached + 1] = { slot = i, split = calls.cursor }; calls.cursor = nil end
function ClearCursor() calls.cursor = nil end
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
-- 4. Larger stack: split down to the ordered qty, never over-attach
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 2, 100, 0, 20)   -- 20 in stock, order is for 3
ns.CODSendAssist({ buyer = "Bob", itemID = 100, suffix = 0, qty = 3, total = 30000 })
check("split: split 3 off the stack", calls.split ~= nil and calls.split.qty == 3 and calls.split.slot == 2)
check("split: remainder parked in a free bag slot first", calls.parked ~= nil and calls.parked.qty == 3)
check("split: parked stack placed into a free mail slot", #calls.attached == 1 and calls.attached[1].split == 3)
check("split: COD money = order total", calls.money == 30000)

--========================================================================
-- 5. Variant match: a different suffix in the same slot is not the item
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 7, 5)   -- suffix 7 in bags, order wants suffix 0
ns.CODSendAssist({ buyer = "Cat", itemID = 100, suffix = 0, qty = 1, total = 15000 })
check("variant: wrong-suffix stack is not attached", #calls.attached == 0 and lastFeedback.isError == true)

--========================================================================
-- 6. Order larger than one full stack: gather across stacks (20 whole + split 1 = 21)
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 20); setBag(0, 2, 100, 0, 20)
ns.CODSendAssist({ buyer = "Dan", itemID = 100, suffix = 0, qty = 21, total = 315000 })
local wholes, splits = 0, 0
for _, a in ipairs(calls.attached) do if a.whole then wholes = wholes + 1 else splits = splits + 1 end end
check("multi: 21 of 2x20 = one whole stack + one split", wholes == 1 and splits == 1)
check("multi: the split takes exactly the remainder (1)", calls.split ~= nil and calls.split.qty == 1)
check("multi: the remainder was parked before attaching", calls.parked ~= nil and calls.parked.qty == 1)
check("multi: non-error feedback", lastFeedback and lastFeedback.isError == false)

--========================================================================
-- 7. Small max stacks: 14 out of 4x5 = two whole fives + split 4
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 5); setBag(0, 2, 100, 0, 5); setBag(0, 3, 100, 0, 5); setBag(0, 4, 100, 0, 5)
ns.CODSendAssist({ buyer = "Eve", itemID = 100, suffix = 0, qty = 14, total = 210000 })
wholes, splits = 0, 0
for _, a in ipairs(calls.attached) do if a.whole then wholes = wholes + 1 else splits = splits + 1 end end
check("fives: 14 of 4x5 = two whole stacks + one split", wholes == 2 and splits == 1)
check("fives: the split takes exactly the remainder (4)", calls.split ~= nil and calls.split.qty == 4)

--========================================================================
-- 8. An exact-size stack wins over splitting a bigger one
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 20); setBag(0, 2, 100, 0, 14)
ns.CODSendAssist({ buyer = "Fay", itemID = 100, suffix = 0, qty = 14, total = 210000 })
check("exact-fit: the 14-stack attaches whole", #calls.attached == 1 and calls.attached[1].whole and calls.attached[1].slot == 2)
check("exact-fit: no split", calls.split == nil)

--========================================================================
-- 9. Bags hold fewer than ordered: refuse with what you actually have
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 20)
ns.CODSendAssist({ buyer = "Gus", itemID = 100, suffix = 0, qty = 21, total = 315000 })
check("short: error feedback", lastFeedback and lastFeedback.isError == true)
check("short: message says 20 of the 21", lastFeedback.msg:find("20 of the 21", 1, true) ~= nil)
check("short: nothing attached", #calls.attached == 0)

--========================================================================
-- 10. Fractured stacks are consumed before a full one is broken
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 20); setBag(0, 2, 100, 0, 3)
ns.CODSendAssist({ buyer = "Hal", itemID = 100, suffix = 0, qty = 14, total = 210000 })
wholes, splits = 0, 0
local wholeSlot
for _, a in ipairs(calls.attached) do
    if a.whole then wholes = wholes + 1; wholeSlot = a.slot else splits = splits + 1 end
end
check("fractured: the loose 3 goes whole, the 20 is split", wholes == 1 and wholeSlot == 2 and splits == 1)
check("fractured: the split takes 11 off the full stack", calls.split ~= nil and calls.split.slot == 1 and calls.split.qty == 11)

--========================================================================
-- 11. Several uneven fractured stacks: all consumed whole before the full stack is split
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 20); setBag(0, 2, 100, 0, 3); setBag(1, 4, 100, 0, 7)
ns.CODSendAssist({ buyer = "Ida", itemID = 100, suffix = 0, qty = 14, total = 210000 })
wholes, splits = 0, 0
local wholeSlots = {}
for _, a in ipairs(calls.attached) do
    if a.whole then wholes = wholes + 1; wholeSlots[a.slot] = true else splits = splits + 1 end
end
check("uneven: both fractured stacks (3 + 7) go whole", wholes == 2 and wholeSlots[2] and wholeSlots[4])
check("uneven: one split covers the rest", splits == 1)
check("uneven: the split takes 4 off the full stack", calls.split ~= nil and calls.split.slot == 1 and calls.split.qty == 4)

--========================================================================
-- 12. Fractured stacks alone cover the order exactly: no split at all
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 20); setBag(0, 2, 100, 0, 3); setBag(0, 3, 100, 0, 5); setBag(0, 4, 100, 0, 6)
ns.CODSendAssist({ buyer = "Joy", itemID = 100, suffix = 0, qty = 14, total = 210000 })
wholes, splits = 0, 0
wholeSlots = {}
for _, a in ipairs(calls.attached) do
    if a.whole then wholes = wholes + 1; wholeSlots[a.slot] = true else splits = splits + 1 end
end
check("cover: 3 + 5 + 6 attach whole, the 20 stays untouched",
    wholes == 3 and wholeSlots[2] and wholeSlots[3] and wholeSlots[4] and not wholeSlots[1])
check("cover: nothing split", splits == 0 and calls.split == nil)

--========================================================================
-- 13. Mixed max-stack sizes (5 / 20 / 100 in the same bags): counts drive the plan, not
--     any assumed stack size
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 0, 100); setBag(0, 2, 100, 0, 20); setBag(0, 3, 100, 0, 5)
ns.CODSendAssist({ buyer = "Kim", itemID = 100, suffix = 0, qty = 117, total = 1755000 })
wholes, splits = 0, 0
wholeSlots = {}
for _, a in ipairs(calls.attached) do
    if a.whole then wholes = wholes + 1; wholeSlots[a.slot] = true else splits = splits + 1 end
end
check("mixed: the 5 and the 20 attach whole", wholes == 2 and wholeSlots[2] and wholeSlots[3])
check("mixed: 92 split off the 100-stack", splits == 1 and calls.split ~= nil and calls.split.slot == 1 and calls.split.qty == 92)

--========================================================================
-- 14. Order can't fit one mail (20 stacks of max-5 items): clear error, mail frame untouched
--========================================================================
reset(); openMailbox()
bags = {}
for slot = 1, 20 do setBag(0, slot, 100, 0, 5) end   -- 100 items, but 20 attachments needed
ns.CODSendAssist({ buyer = "Lea", itemID = 100, suffix = 0, qty = 100, total = 1500000 })
check("nofit: error feedback", lastFeedback and lastFeedback.isError == true)
check("nofit: message says 20 attachments vs 12", lastFeedback.msg:find("needs 20 attachments", 1, true) ~= nil and lastFeedback.msg:find("holds 12", 1, true) ~= nil)
check("nofit: mail frame untouched", calls.name == nil and calls.cleared == false and #calls.attached == 0)

--========================================================================
-- 15. Heavy fragmentation: smallest-first would blow the slot cap, largest-first still fits
--========================================================================
reset(); openMailbox()
bags = {}
for slot = 1, 12 do setBag(0, slot, 100, 0, 1) end   -- twelve loose singles
setBag(1, 1, 100, 0, 20); setBag(1, 2, 100, 0, 20)
ns.CODSendAssist({ buyer = "Mia", itemID = 100, suffix = 0, qty = 40, total = 600000 })
wholes, splits = 0, 0
for _, a in ipairs(calls.attached) do if a.whole then wholes = wholes + 1 else splits = splits + 1 end end
check("replan: the two full 20s attach whole, singles left alone", wholes == 2 and splits == 0 and calls.split == nil)
check("replan: non-error feedback", lastFeedback and lastFeedback.isError == false)

--========================================================================
-- 16. A split is needed but no bag slot is free to park it: clear error, frame untouched
--========================================================================
reset(); openMailbox()
bags = {}
for slot = 1, 20 do setBag(0, slot, 100, 0, 20) end   -- every slot full, order needs a split
ns.CODSendAssist({ buyer = "Ned", itemID = 100, suffix = 0, qty = 21, total = 315000 })
check("nopark: error feedback", lastFeedback and lastFeedback.isError == true)
check("nopark: message asks for a free bag slot", lastFeedback.msg:find("free bag slot", 1, true) ~= nil)
check("nopark: mail frame untouched", calls.name == nil and calls.cleared == false and #calls.attached == 0)

io.write(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
