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
local harvestTicker
local MAX_ITEM_ID  = 30000

local function normalize(s)
    return (s or ""):lower():gsub("[^%w]", "")   -- drop spaces/apostrophes/punctuation
end

local function add(itemID, name, q)
    if have[itemID] then return end
    have[itemID] = true
    searchList[#searchList + 1] = { id = itemID, name = name, norm = normalize(name), q = q or 1 }
    GuildFoundMarketDB.names[itemID] = name
    GuildFoundMarketDB.quals[itemID] = q or 1
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
-- Self-harvest: iterate all itemIDs (aux-style), throttled & resumable, so the
-- DB builds itself with no aux dependency. Bounded outstanding requests so we
-- never flood the server.
--========================================================================
local HARVEST_BATCH = 400   -- ids processed per tick (cached ones are instant, no request)
local HARVEST_TICK  = 0.05  -- seconds between ticks
local PENDING_CAP   = 100   -- max outstanding server requests at once (bounds uncached rate)

local function harvestTick()
    local n = GuildFoundMarketDB.harvestNext or 1
    if n > MAX_ITEM_ID then
        ItemDB.StopHarvest()
        ns.Feedback(("Item harvest complete — %d items."):format(#searchList), false)
        return
    end
    local budget = HARVEST_BATCH
    while budget > 0 and n <= MAX_ITEM_ID and pendingCount < PENDING_CAP do
        ItemDB.Learn(n); n = n + 1; budget = budget - 1
    end
    GuildFoundMarketDB.harvestNext = n
end

function ItemDB.StartHarvest()
    GuildFoundMarketDB.harvestNext = GuildFoundMarketDB.harvestNext or 1
    if not harvestTicker then harvestTicker = C_Timer.NewTicker(HARVEST_TICK, harvestTick) end
end

function ItemDB.StopHarvest()
    if harvestTicker then harvestTicker:Cancel(); harvestTicker = nil end
end

function ItemDB.IsHarvesting() return harvestTicker ~= nil end
function ItemDB.HarvestProgress() return GuildFoundMarketDB.harvestNext or 1, MAX_ITEM_ID end

-- Wipe everything to simulate a clean install.
function ItemDB.Reset()
    ItemDB.StopHarvest()
    wipe(searchList); wipe(have); wipe(pending); wipe(unused)
    pendingCount = 0
    GuildFoundMarketDB.names = {}
    GuildFoundMarketDB.quals = {}
    GuildFoundMarketDB.harvestNext = 1
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
