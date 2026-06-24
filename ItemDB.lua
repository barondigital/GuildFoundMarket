local ADDON, ns = ...

--========================================================================
-- Item name database for autocomplete.
-- Builds itself (no bundled data, auto-localized via GetItemInfo):
--   * learns item names from your bags, from queries seen on the channel,
--     and from offers you receive,
--   * optionally seeds once from aux's database if aux is installed.
-- Names resolve in the client's own language, so matching is multilingual.
--========================================================================
ns.ItemDB = {}
local ItemDB = ns.ItemDB

local MIN_QUERY = 2          -- need at least this many chars before we match
local MAX_RESULTS = 12

local searchList = {}        -- array of { id, name, norm, q }
local have      = {}         -- [itemID] = true (dedupe)
local pending   = {}         -- [itemID] = true (requested, awaiting GET_ITEM_INFO_RECEIVED)
local unused    = {}         -- [itemID] = true (server says it doesn't exist; don't retry)
local pendingCount = 0
local lastLearned             -- name of the most recently added item (for the debug panel)
local lastLoggedPct = -1      -- throttles harvest progress lines into the debug log
local lastLogTime = 0
local harvestTicker
-- The full-DB scan has two phases: brute-force the classic/vanilla range 1..CLASSIC_MAX
-- (aux usually covers these instantly), then fetch the bundled SoD item list (ns.SoDItems)
-- directly — so we never probe the ~46000 dead IDs in 200000-250000, which is slow and
-- can disconnect you. Both phases resolve names via GetItemInfo, so the DB stays localized.
local CLASSIC_MAX = 30000

local function normalize(s)
    return (s or ""):lower():gsub("[^%w]", "")   -- drop spaces/apostrophes/punctuation
end

local function add(itemID, name, q)
    if have[itemID] then return end
    have[itemID] = true
    searchList[#searchList + 1] = { id = itemID, name = name, norm = normalize(name), q = q or 1 }
    GuildFoundMarketDB.names[itemID] = name
    GuildFoundMarketDB.quals[itemID] = q or 1
    lastLearned = name
end

-- Learn an itemID: store its (localized) name now if cached, else request it.
function ItemDB.Learn(itemID)
    itemID = tonumber(itemID)
    if not itemID or have[itemID] or unused[itemID] then return end
    local name, _, q = GetItemInfo(itemID)
    if name then
        add(itemID, name, q)
    elseif not pending[itemID] then
        pending[itemID] = true; pendingCount = pendingCount + 1
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    end
end

function ItemDB.OnItemInfoReceived(itemID, success)
    itemID = tonumber(itemID)
    if not itemID or not pending[itemID] then return end
    pending[itemID] = nil; pendingCount = pendingCount - 1
    if success == false then
        unused[itemID] = true                 -- doesn't exist; never retry
    else
        local name, _, q = GetItemInfo(itemID)
        if name then add(itemID, name, q) end
    end
end

--========================================================================
-- Self-harvest: walk the item-ID windows (aux-style), throttled & resumable, so
-- the DB builds itself with no aux dependency. Bounded outstanding requests so
-- we never flood the server. The gap between windows (e.g. 30000..200000) is
-- skipped, so we don't waste requests on IDs that can't exist.
--========================================================================
local HARVEST_BATCH = 400   -- ids processed per tick (cached/known ones are instant, no request)
local HARVEST_TICK  = 0.1   -- seconds between ticks
local PENDING_CAP   = 25    -- max outstanding server requests at once — kept low so brute-force
                            -- probing can't flood the server (which risks a disconnect)

local function sodList()  return ns.SoDItems or {} end
local function totalRaw() return CLASSIC_MAX + #sodList() end
local function scannedRaw()
    local pos = GuildFoundMarketDB.harvestNext or 1
    local classicDone = math.min(pos - 1, CLASSIC_MAX)
    local sodDone = (pos > CLASSIC_MAX) and ((GuildFoundMarketDB.sodNext or 1) - 1) or 0
    return classicDone + sodDone
end
-- progress is measured from where THIS run started, so a SoD-only run (classic skipped
-- via aux) reads 0→100% instead of starting near 93%.
local function progressDone()  return scannedRaw() - (GuildFoundMarketDB.harvestStartScanned or 0) end
local function progressTotal() return totalRaw() - (GuildFoundMarketDB.harvestStartScanned or 0) end

local function logProgress()
    if not ns.Log then return end
    local pos = GuildFoundMarketDB.harvestNext or 1
    local pct = progressTotal() > 0 and math.floor(progressDone() / progressTotal() * 100) or 0
    if math.floor(pct / 10) > math.floor(lastLoggedPct / 10) or (GetTime() - lastLogTime) >= 5 then
        lastLoggedPct = pct; lastLogTime = GetTime()
        local where = (pos <= CLASSIC_MAX) and ("classic id " .. pos)
            or ("SoD item " .. math.min(GuildFoundMarketDB.sodNext or 1, #sodList()) .. "/" .. #sodList())
        ns.Log(("DBSCAN %d%% · %s · %d pending · %d items"):format(pct, where, pendingCount, #searchList))
    end
end

local function harvestTick()
    local pos = GuildFoundMarketDB.harvestNext or 1
    if pos <= CLASSIC_MAX then
        -- phase 1: brute-force the classic range
        local budget = HARVEST_BATCH
        while budget > 0 and pos <= CLASSIC_MAX and pendingCount < PENDING_CAP do
            ItemDB.Learn(pos); pos = pos + 1; budget = budget - 1
        end
        GuildFoundMarketDB.harvestNext = pos
    else
        -- phase 2: fetch the bundled SoD list (real IDs only, no dead probes)
        local list = sodList()
        local idx = GuildFoundMarketDB.sodNext or 1
        if idx > #list then
            ItemDB.StopHarvest()
            ns.Feedback(("Item harvest complete — %d items."):format(#searchList), false)
            if ns.Log then ns.Log(("DBSCAN complete — %d items"):format(#searchList)) end
            return
        end
        local budget = HARVEST_BATCH
        while budget > 0 and idx <= #list and pendingCount < PENDING_CAP do
            ItemDB.Learn(list[idx]); idx = idx + 1; budget = budget - 1
        end
        GuildFoundMarketDB.sodNext = idx
    end
    logProgress()
end

function ItemDB.StartHarvest()
    GuildFoundMarketDB.harvestNext = GuildFoundMarketDB.harvestNext or 1
    GuildFoundMarketDB.sodNext = GuildFoundMarketDB.sodNext or 1
    -- aux already seeded the classic names → skip the slow classic brute-force (and its
    -- disconnect-prone dead-ID probing) and go straight to the SoD list.
    if GuildFoundMarketDB.auxSeeded and GuildFoundMarketDB.harvestNext <= CLASSIC_MAX then
        GuildFoundMarketDB.harvestNext = CLASSIC_MAX + 1
    end
    if not harvestTicker then
        wipe(pending); pendingCount = 0   -- clear any stale outstanding requests so we never stall
        GuildFoundMarketDB.harvestStartScanned = scannedRaw()
        harvestTicker = C_Timer.NewTicker(HARVEST_TICK, harvestTick)
        lastLoggedPct = -1; lastLogTime = GetTime()
        if ns.Log then
            local pos = GuildFoundMarketDB.harvestNext
            local where = (pos <= CLASSIC_MAX) and ("classic id " .. pos)
                or ("SoD list (" .. #sodList() .. " items)" .. (GuildFoundMarketDB.auxSeeded and ", classic via aux" or ""))
            ns.Log(("DBSCAN started — %s · %d items so far"):format(where, #searchList))
        end
    end
end

function ItemDB.StopHarvest()
    if harvestTicker then harvestTicker:Cancel(); harvestTicker = nil end
end

function ItemDB.IsHarvesting() return harvestTicker ~= nil end
function ItemDB.HarvestProgress() return progressDone(), progressTotal() end

-- Wipe everything to simulate a clean install.
function ItemDB.Reset()
    ItemDB.StopHarvest()
    wipe(searchList); wipe(have); wipe(pending); wipe(unused)
    pendingCount = 0
    GuildFoundMarketDB.names = {}
    GuildFoundMarketDB.quals = {}
    GuildFoundMarketDB.harvestNext = 1
    GuildFoundMarketDB.sodNext = 1
    GuildFoundMarketDB.harvestStartScanned = 0
    GuildFoundMarketDB.auxSeeded = nil
end

-- Scan bags (+ open bank) and learn what you carry.
function ItemDB.LearnFromBags()
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id then ItemDB.Learn(id) end
        end
    end
end

-- One-time opportunistic seed from aux's item database (if present). aux stores
-- item_ids as { [lowercase_name] = itemID }; we use GetItemInfo for a proper-cased
-- name when the item is cached, else fall back to aux's name. No server requests
-- are fired here (so it can't flood/throttle) — full coverage, instantly.
function ItemDB.SeedFromAux()
    if GuildFoundMarketDB.disableAux or GuildFoundMarketDB.auxSeeded then return end
    local a = _G.aux
    if type(a) == "table" and type(a.account) == "table" and type(a.account.item_ids) == "table" then
        local isCached = C_Item and C_Item.IsItemDataCachedByID
        for lname, id in pairs(a.account.item_ids) do
            id = tonumber(id)
            if id and not have[id] then
                -- only resolve via GetItemInfo when already cached (no server fetch);
                -- otherwise use aux's name so we never flood requests on login.
                if isCached and C_Item.IsItemDataCachedByID(id) then
                    add(id, GetItemInfo(id) or lname, select(3, GetItemInfo(id)) or 1)
                else
                    add(id, lname, 1)
                end
            end
        end
        GuildFoundMarketDB.auxSeeded = true
    end
end

-- Rebuild the in-memory list from the persisted names (called on login).
-- IMPORTANT: never call GetItemInfo here — for uncached items that fires a server
-- request, and doing it for thousands of stored items freezes the client on login.
function ItemDB.Load()
    GuildFoundMarketDB.names = GuildFoundMarketDB.names or {}
    GuildFoundMarketDB.quals = GuildFoundMarketDB.quals or {}
    local quals = GuildFoundMarketDB.quals
    wipe(searchList); wipe(have)
    for id, name in pairs(GuildFoundMarketDB.names) do
        if not have[id] then
            have[id] = true
            searchList[#searchList + 1] = { id = id, name = name, norm = normalize(name), q = quals[id] or 1 }
        end
    end
end

-- Autocomplete: return up to MAX_RESULTS { id, name, q }, prefix matches first.
function ItemDB.Match(text)
    local qn = normalize(text)
    if #qn < MIN_QUERY then return {} end
    local prefix, sub = {}, {}
    for i = 1, #searchList do
        local e = searchList[i]
        local pos = e.norm:find(qn, 1, true)
        if pos == 1 then
            prefix[#prefix + 1] = e
        elseif pos then
            sub[#sub + 1] = e
        end
    end
    local function byName(a, b) return a.name < b.name end
    table.sort(prefix, byName)
    table.sort(sub, byName)
    local res = {}
    for _, e in ipairs(prefix) do res[#res + 1] = e; if #res >= MAX_RESULTS then return res end end
    for _, e in ipairs(sub)    do res[#res + 1] = e; if #res >= MAX_RESULTS then break end end
    return res
end

function ItemDB.Count() return #searchList end
