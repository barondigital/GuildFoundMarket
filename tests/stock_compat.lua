-- Unit test for the per-character item stock cache (Services/Stock.lua).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package (.pkgmeta
-- ignore). Run from the addon root with:  lua tests/stock_compat.lua
--
-- It loads the REAL Services/Stock.lua against a stubbed WoW API (bags/bank via C_Container,
-- mail via the GetInbox* family) and asserts:
--   * bag/bank/mail scans count per exact variant (itemID:suffix), summing stacks;
--   * a single mail with several item attachments is fully counted (the "package" case);
--   * Count totals bags(live) + bank snapshot + mail snapshot;
--   * a snapshot is only refreshed while its source is open, so walking away never wipes it;
--   * Reliability reports the snapshot timestamps and the HasNewMail flag.

local failures = 0
local function check(name, cond)
    io.write(cond and ("  ok   " .. name .. "\n") or ("  FAIL " .. name .. "\n"))
    if not cond then failures = failures + 1 end
end

--========================================================================
-- Minimal WoW API stubs
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

local NOW = 1000
function time() return NOW end
C_Timer = { After = function(_, fn) fn() end }    -- run debounced work inline
ATTACHMENTS_MAX_RECEIVE = 16
function GetItemInfo(id) return "Item " .. id end  -- cache always warm in tests

local NEWMAIL = false
function HasNewMail() return NEWMAIL end

-- an itemString with the suffixID in field 8 (item:id:ench:g1:g2:g3:g4:suffix)
local function link(id, suffix) return ("item:%d:0:0:0:0:0:%d"):format(id, suffix or 0) end

-- bag/bank containers: CONT[bag] = { n = slots, [slot] = {itemID, hyperlink, stackCount} }
local CONT = {}
C_Container = {
    GetContainerNumSlots = function(bag) local b = CONT[bag]; return b and b.n or 0 end,
    GetContainerItemInfo = function(bag, slot) local b = CONT[bag]; return b and b[slot] or nil end,
}
local function clearContainers() for k in pairs(CONT) do CONT[k] = nil end end
local function setSlot(bag, slot, id, suffix, count)
    CONT[bag] = CONT[bag] or { n = 0 }
    if slot > CONT[bag].n then CONT[bag].n = slot end
    CONT[bag][slot] = { itemID = id, hyperlink = link(id, suffix), stackCount = count }
end

-- mail inbox: MAIL[i] = { [j] = {itemID, count, link} }; one mail can hold several attachments
local MAIL = {}
function GetInboxNumItems() return #MAIL end
function GetInboxItem(i, j) local m = MAIL[i] and MAIL[i][j]; if m then return "name", m.itemID, "tex", m.count end end
function GetInboxItemLink(i, j) local m = MAIL[i] and MAIL[i][j]; return m and m.link end
local function clearMail() for k in pairs(MAIL) do MAIL[k] = nil end end
local function addMail(attachments)
    local m = {}
    for idx, a in ipairs(attachments) do m[idx] = { itemID = a.id, count = a.count, link = link(a.id, a.suffix or 0) } end
    MAIL[#MAIL + 1] = m
end

GuildFoundMarketCharDB = {}
local ns = { Emit = function() end, RefreshMineSoon = function() end, SyncTrackedOffersSoon = function() end }

local function loadModule(path) local chunk = assert(loadfile(path)); return chunk("GuildFoundMarket", ns) end
loadModule("Services/Stock.lua")

--========================================================================
-- 1. Suffix parsing from an item link
--========================================================================
do
    check("linkSuffix plain = 0",   ns.Stock.LinkSuffix(link(123, 0)) == 0)
    check("linkSuffix suffixed",    ns.Stock.LinkSuffix(link(123, 137)) == 137)
    check("linkSuffix negative",    ns.Stock.LinkSuffix(link(123, -45)) == -45)
    check("linkSuffix nil = 0",     ns.Stock.LinkSuffix(nil) == 0)
end

--========================================================================
-- 2. Bag scan: sum stacks, keep variants apart, count across bags
--========================================================================
do
    clearContainers()
    setSlot(0, 1, 100, 0, 3)      -- 3x plain item 100
    setSlot(0, 2, 100, 0, 2)      -- +2x plain item 100 -> 5
    setSlot(0, 3, 100, 137, 1)    -- 1x item 100, suffix 137 (separate variant)
    setSlot(1, 1, 200, 0, 1)
    local bags = ns.Stock.BagTotals()
    check("bags sum stacks of same variant", bags["100:0"] == 5)
    check("bags keep suffix variants apart", bags["100:137"] == 1)
    check("bags count across bag containers", bags["200:0"] == 1)
    check("Count uses live bags", ns.Stock.Count(100, 0) == 5)
end

--========================================================================
-- 3. Bank snapshot only while open; walking away never wipes it
--========================================================================
do
    clearContainers()
    setSlot(-1, 1, 300, 0, 4)     -- main bank
    setSlot(5, 1, 301, 0, 2)      -- a bank bag

    ns.Stock.RefreshBank()        -- bank closed: must be a no-op
    check("bank refresh ignored while closed", ns.Stock.BankCounts()["300:0"] == nil)

    ns.Stock.SetBankOpen(true)
    ns.Stock.RefreshBank()
    check("bank scanned while open", ns.Stock.BankCounts()["300:0"] == 4 and ns.Stock.BankCounts()["301:0"] == 2)
    check("Count includes the bank snapshot", ns.Stock.Count(300, 0) == 4)

    ns.Stock.SetBankOpen(false)
    clearContainers()             -- away from the bank: containers read empty
    ns.Stock.RefreshBank()
    check("bank snapshot survives once closed", ns.Stock.BankCounts()["300:0"] == 4)
end

--========================================================================
-- 4. Mail scan: one mail with several attachments (the "package" case)
--========================================================================
do
    ns.Stock.SetMailOpen(true)
    clearMail()
    addMail({ { id = 400, count = 5 }, { id = 401, count = 1 }, { id = 400, count = 2 } })  -- one mail, 3 slots
    ns.Stock.RefreshMail()
    check("mail sums attachments within one mail", ns.Stock.MailCounts()["400:0"] == 7)
    check("mail counts a second attached item", ns.Stock.MailCounts()["401:0"] == 1)

    addMail({ { id = 400, suffix = 88, count = 1 } })   -- a second mail, a variant
    ns.Stock.RefreshMail()
    check("mail keeps suffix variants apart", ns.Stock.MailCounts()["400:88"] == 1)
    check("mail re-scan walks every inbox mail", ns.Stock.MailCounts()["400:0"] == 7)
end

--========================================================================
-- 5. Count totals bags(live) + bank snapshot + mail snapshot
--========================================================================
do
    clearContainers(); clearMail()
    ns.Stock.SetBankOpen(true); ns.Stock.SetMailOpen(true)
    setSlot(0, 1, 500, 0, 2)                 -- 2 in bags
    setSlot(-1, 1, 500, 0, 3)                -- 3 in bank
    addMail({ { id = 500, count = 4 } })     -- 4 in mail
    ns.Stock.RefreshBank(); ns.Stock.RefreshMail()
    check("Count totals bags + bank + mail", ns.Stock.Count(500, 0) == 9)
end

--========================================================================
-- 6. Reliability: timestamps + the new-mail flag
--========================================================================
do
    NEWMAIL = true
    local r = ns.Stock.Reliability()
    check("reliability reports new mail",    r.newMail == true)
    check("reliability carries bank stamp",  r.bankAt == NOW)
    check("reliability carries mail stamp",  r.mailAt == NOW)
    NEWMAIL = false
    check("reliability clears new mail",     ns.Stock.Reliability().newMail == false)
end

io.write(failures == 0 and "\nAll stock cache checks passed.\n"
                        or ("\n" .. failures .. " check(s) FAILED.\n"))
os.exit(failures == 0 and 0 or 1)
