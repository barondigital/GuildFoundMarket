local ADDON, ns = ...

--========================================================================
-- Known-craftables snapshot. BYOM ("bring your own materials") only makes sense on an item
-- the seller can actually craft, so the compose panel gates the checkbox on this set.
--
-- Like the bank/mail snapshots in Stock: recipes are only readable while a profession window
-- is open. Classic Era splits them over two APIs: TradeSkill (smithing, alchemy, ...) and
-- Craft (enchanting). Both are walked on their open/update events and the crafted itemIDs
-- merge into GuildFoundMarketCharDB.crafts. Merge-only, never wiped: each window shows one
-- profession at a time, so a rebuild from one window would drop the others. The rare stale
-- entry after unlearning a profession just leaves the checkbox available; harmless.
--========================================================================

ns.Crafts = ns.Crafts or {}

local function store()
    GuildFoundMarketCharDB.crafts = GuildFoundMarketCharDB.crafts or {}
    return GuildFoundMarketCharDB.crafts
end

local function idFromLink(link)
    return link and tonumber(link:match("item:(%d+)")) or nil
end

-- Walk whichever profession windows are open and merge their crafted items into the set.
function ns.Crafts.Learn()
    local crafts, added = store(), 0
    for i = 1, (GetNumTradeSkills and GetNumTradeSkills() or 0) do
        local id = idFromLink(GetTradeSkillItemLink and GetTradeSkillItemLink(i))
        if id and not crafts[id] then crafts[id] = true; added = added + 1 end
    end
    -- the Craft API (enchanting): only rods and the like yield an item link; pure enchants don't
    for i = 1, (GetNumCrafts and GetNumCrafts() or 0) do
        local id = idFromLink(GetCraftItemLink and GetCraftItemLink(i))
        if id and not crafts[id] then crafts[id] = true; added = added + 1 end
    end
    if added > 0 then
        ns.Log(("CRAFTS learned %d new craftable item(s)"):format(added))
        if ns.Emit then ns.Emit("crafts:learned") end   -- the compose panel's BYOM gate may open up
    end
end

-- Debounced: TRADE_SKILL_UPDATE/CRAFT_UPDATE fire in bursts (filters, rank-ups).
local pending = false
function ns.Crafts.LearnSoon()
    if pending then return end
    pending = true
    C_Timer.After(0.5, function() pending = false; ns.Crafts.Learn() end)
end

-- Can this character craft the item? (false until its profession window was opened once)
function ns.Crafts.Knows(itemID)
    return itemID and store()[itemID] and true or false
end

-- Has any recipe scan ever run? Steers the checkbox tooltip toward "open your profession
-- window once" instead of flatly claiming the item isn't craftable.
function ns.Crafts.HasAny()
    return next(store()) ~= nil
end
