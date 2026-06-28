local ADDON, ns = ...

--========================================================================
-- Local price snapshot DB (#13). Built purely from data we already receive (item searches,
-- category browses, seller catalogs); no protocol change. Per item we keep only the LAST
-- observation { low, high, count, t } - a newer one overwrites it - and surface it on the item
-- tooltip. Snapshot, not history: offline sellers' prices stop mattering, and a re-scan refreshes.
--========================================================================
ns.PriceDB = ns.PriceDB or {}

local CAP = 2000   -- max stored items; oldest pruned beyond this
local function store() return GuildFoundMarketDB and GuildFoundMarketDB.prices end

-- Drop the oldest entries (by timestamp) when the table grows past the cap.
local function prune()
    local db = store(); if not db then return end
    local n = 0; for _ in pairs(db) do n = n + 1 end
    if n <= CAP then return end
    local arr = {}
    for k, v in pairs(db) do arr[#arr + 1] = { k = k, t = v.t or 0 } end
    table.sort(arr, function(a, b) return a.t < b.t end)
    local target = math.floor(CAP * 0.9)
    for i = 1, n - target do db[arr[i].k] = nil end
end

-- Record a snapshot from a list of { id, suffix, price } observations. Prices <= 0 (bids) are
-- ignored for the range; count is the number of priced offers seen. Overwrites per variant.
function ns.PriceDB.Record(list)
    local db = store()
    if not db or not list then return end
    local groups = {}
    for _, o in ipairs(list) do
        local p = o.price or 0
        if o.id and p > 0 then
            local key = ns.vkey(o.id, o.suffix or 0)
            local g = groups[key]
            if not g then groups[key] = { low = p, high = p, count = 1 }
            else
                if p < g.low then g.low = p end
                if p > g.high then g.high = p end
                g.count = g.count + 1
            end
        end
    end
    local now = time()
    local wrote = false
    for key, g in pairs(groups) do
        db[key] = { low = g.low, high = g.high, count = g.count, t = now }
        wrote = true
    end
    if wrote then prune() end
end

function ns.PriceDB.Get(id, suffix)
    local db = store(); if not db then return nil end
    return db[ns.vkey(id, suffix or 0)]
end

-- now - t as a single rounded unit (m / h / d); no weeks/months, no combinations.
function ns.PriceDB.AgeString(t)
    local s = time() - (t or 0)
    if s < 0 then s = 0 end
    if s < 3600 then return math.max(1, math.floor(s / 60 + 0.5)) .. "m"
    elseif s < 86400 then return math.floor(s / 3600 + 0.5) .. "h"
    else return math.floor(s / 86400 + 0.5) .. "d" end
end

--========================================================================
-- Tooltip: two lines on item tooltips (toggle in Options, default on). Prices use the configured
-- fill format via ns.PriceToStr (exposed by UI). Installed once at load.
--========================================================================
-- Compact coloured coin notation: "1g3s34c" -> "1.3.34" with gold/silver/copper each in its own
-- colour. Leading empty denominations are dropped (34c -> "34", 3s34c -> "3.34"); once a higher
-- coin is present the lower ones show even if zero (1g -> "1.0.0").
local GOLD, SILVER, COPPER = "ffffd100", "ffffffff", "ffeda55f"
local function fmt(c)
    c = math.floor((c or 0) + 0.5)
    local g = math.floor(c / 10000); local rem = c % 10000
    local s = math.floor(rem / 100); local cp = rem % 100
    if g > 0 then
        return ("|c%s%d|r.|c%s%d|r.|c%s%d|r"):format(GOLD, g, SILVER, s, COPPER, cp)
    elseif s > 0 then
        return ("|c%s%d|r.|c%s%d|r"):format(SILVER, s, COPPER, cp)
    else
        return ("|c%s%d|r"):format(COPPER, cp)
    end
end

local function addLines(tooltip, id)
    if not id then return end
    if ns.GetSetting and not ns.GetSetting("showPriceTooltip") then return end
    local rec = ns.PriceDB.Get(id, 0)
    if not rec then
        -- no data yet: nudge to scan, but only when alt-click-to-search is actually enabled
        if ns.GetSetting and ns.GetSetting("altClickSearch") then
            tooltip:AddLine("|cff00ff96GFM:|r alt click to scan", 0.7, 0.7, 0.7)
        end
        return
    end
    local sellers = (rec.count or 1) == 1 and "1 seller" or ((rec.count or 0) .. " sellers")
    local range = (rec.low == rec.high) and fmt(rec.low) or (fmt(rec.low) .. " - " .. fmt(rec.high))
    tooltip:AddLine(("|cff00ff96GFM:|r %s \194\183 %s"):format(sellers, range), 1, 1, 1)
    tooltip:AddLine(("|cff00ff96GFM:|r scanned %s ago"):format(ns.PriceDB.AgeString(rec.t)), 0.7, 0.7, 0.7)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
        if tt == GameTooltip or tt == ItemRefTooltip then addLines(tt, data and data.id) end
    end)
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", function(self)
        local _, link = self:GetItem()
        local id = link and tonumber(tostring(link):match("item:(%d+)"))
        addLines(self, id)
    end)
end
