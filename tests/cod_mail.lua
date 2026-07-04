-- Unit test for the COD mailbox send-assist (Services/CODMail.lua).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package. Run from the addon
-- root with:  lua tests/cod_mail.lua
--
-- It loads the REAL Services/CODMail.lua against a stubbed WoW + mail API and asserts that
-- ns.CODSendAssist:
--   * refuses (with an error) when no mailbox is open, and prefills nothing;
--   * refuses when the item isn't in bags in a big enough single stack;
--   * on the happy path fills recipient + subject, attaches the exact item, switches to COD mode,
--     and sets the COD money to the order total;
--   * splits a larger stack down to the ordered qty instead of over-attaching.

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
    SplitContainerItem = function(bag, slot, qty) calls.split = { bag = bag, slot = slot, qty = qty }; calls.cursor = qty end,
}
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
check("split: placed into a free mail slot", #calls.attached == 1 and calls.attached[1].split == 3)
check("split: COD money = order total", calls.money == 30000)

--========================================================================
-- 5. Variant match: a different suffix in the same slot is not the item
--========================================================================
reset(); openMailbox()
bags = {}; setBag(0, 1, 100, 7, 5)   -- suffix 7 in bags, order wants suffix 0
ns.CODSendAssist({ buyer = "Cat", itemID = 100, suffix = 0, qty = 1, total = 15000 })
check("variant: wrong-suffix stack is not attached", #calls.attached == 0 and lastFeedback.isError == true)

io.write(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
