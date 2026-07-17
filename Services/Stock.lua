local ADDON, ns = ...

--========================================================================
-- Per-character item stock cache.
--
-- Bags are always readable, so they're counted live. The bank and the mailbox can only be
-- read while their window is open, so we keep a snapshot of each (a count per variant) plus
-- the time we last saw it. ns.Stock.Count sums bags(live) + bank + mail, which is exactly what
-- a "Follow my bags" (Bag sync) listing tracks. Only tradeable copies count: bound items are
-- excluded from the bag and bank scans (the mail API exposes no bound flag, but a bound item
-- in the inbox is a support-ticket rarity). Persisted in GuildFoundMarketCharDB.stock.
--
-- A snapshot is only ever refreshed while its source is open (the SetBankOpen/SetMailOpen
-- flags gate it): scanning the bank while away returns nothing, and overwriting the snapshot
-- with that would wipe stock we genuinely have. So a snapshot stays put until the next visit,
-- and the stored timestamp (plus HasNewMail for incoming mail) tells the player how stale it is.
--========================================================================

ns.Stock = ns.Stock or {}

local BAG_CONTAINERS  = { 0, 1, 2, 3, 4 }            -- backpack + 4 bag slots
local BANK_CONTAINERS = { -1, 5, 6, 7, 8, 9, 10, 11 }   -- Classic Era: main bank + 7 bank-bag slots

local bankOpen, mailOpen = false, false

local function store()
    GuildFoundMarketCharDB.stock = GuildFoundMarketCharDB.stock or {}
    local s = GuildFoundMarketCharDB.stock
    s.bank = s.bank or { at = 0, counts = {} }
    s.mail = s.mail or { at = 0, counts = {} }
    return s
end

local function vkey(itemID, suffix) return itemID .. ":" .. (suffix or 0) end

-- suffixID is field 8 of an item link's itemString (negative for random enchants); 0 = plain.
local function linkSuffix(link)
    local str = link and link:match("item:[%-%d:]+")
    if not str then return 0 end
    local p = { strsplit(":", str) }
    return tonumber(p[8]) or 0
end
ns.Stock.LinkSuffix = linkSuffix

-- Scan a set of container IDs into a { "itemID:suffix" = total } table. The suffix is read per
-- slot from the item link, so random-enchant variants count separately (same key as offers).
-- Bound copies (soulbound or quest-bound) are skipped: they can't be traded or mailed, so a
-- Bag-sync listing must not count them. A copy that BECOMES bound (equipping a BoE) drops out
-- of the totals on the next scan, exactly like a copy that left the bags.
local function scanContainers(ids)
    local counts = {}
    for _, bag in ipairs(ids) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                local key = vkey(info.itemID, linkSuffix(info.hyperlink))
                counts[key] = (counts[key] or 0) + (info.stackCount or 1)
            end
        end
    end
    return counts
end
ns.Stock.ScanContainers = scanContainers

-- Scan the mail inbox into a { "itemID:suffix" = total } table. A single mail can carry several
-- item attachments (one "package" icon, many slots), so we walk every attachment slot of every
-- inbox mail and sum the stack counts. Readable only while the mail window is open.
local function scanMail()
    local counts = {}
    for i = 1, (GetInboxNumItems() or 0) do
        for j = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
            local _, itemID, _, count = GetInboxItem(i, j)
            if itemID then
                local key = vkey(itemID, linkSuffix(GetInboxItemLink(i, j)))
                counts[key] = (counts[key] or 0) + (count or 1)
            end
        end
    end
    return counts
end
ns.Stock.ScanMail = scanMail

function ns.Stock.SetBankOpen(v) bankOpen = v and true or false end
function ns.Stock.SetMailOpen(v) mailOpen = v and true or false end
function ns.Stock.IsBankOpen() return bankOpen end
function ns.Stock.IsMailOpen() return mailOpen end

-- Refresh the bank snapshot from the open bank. No-op when the bank is closed: the scan would
-- read empty and wipe stock we actually hold.
function ns.Stock.RefreshBank()
    if not bankOpen then return end
    local s = store()
    s.bank.counts, s.bank.at = scanContainers(BANK_CONTAINERS), time()
    if ns.Emit then ns.Emit("stock:bank") end
    if ns.SyncTrackedOffersSoon then ns.SyncTrackedOffersSoon() end
    if ns.RefreshMineSoon then ns.RefreshMineSoon() end
end

-- Refresh the mail snapshot from the open mailbox (same wipe-guard as the bank).
function ns.Stock.RefreshMail()
    if not mailOpen then return end
    local s = store()
    s.mail.counts, s.mail.at = scanMail(), time()
    if ns.Emit then ns.Emit("stock:mail") end
    if ns.SyncTrackedOffersSoon then ns.SyncTrackedOffersSoon() end
    if ns.RefreshMineSoon then ns.RefreshMineSoon() end
end

-- Debounced refreshers: bank/mail events arrive in bursts (a single deposit fires several), so
-- coalesce them into one scan a moment later.
local bankPending, mailPending = false, false
function ns.Stock.RefreshBankSoon()
    if bankPending then return end
    bankPending = true
    C_Timer.After(0.5, function() bankPending = false; ns.Stock.RefreshBank() end)
end
function ns.Stock.RefreshMailSoon()
    if mailPending then return end
    mailPending = true
    C_Timer.After(0.5, function() mailPending = false; ns.Stock.RefreshMail() end)
end

-- The live bag totals, the bank snapshot, and the mail snapshot (each a { key = count } table).
-- The sync loop pulls all three once and adds them up per offer.
function ns.Stock.BagTotals()  return scanContainers(BAG_CONTAINERS) end
function ns.Stock.BankCounts() return store().bank.counts end
function ns.Stock.MailCounts() return store().mail.counts end

-- Total of one exact variant across bags(live) + bank snapshot + mail snapshot.
function ns.Stock.Count(itemID, suffix)
    local key = vkey(itemID, suffix)
    local s = store()
    return (ns.Stock.BagTotals()[key] or 0) + (s.bank.counts[key] or 0) + (s.mail.counts[key] or 0)
end

-- Freshness of the cached sources, for the Bag-sync tooltip: when each snapshot was last taken
-- (0 = never) and whether unread mail is waiting (the minimap envelope), which means the mail
-- snapshot may be missing items until the player opens the mailbox.
function ns.Stock.Reliability()
    local s = store()
    return { bankAt = s.bank.at, mailAt = s.mail.at, newMail = HasNewMail() and true or false }
end
