local ADDON, ns = ...

--========================================================================
-- Alt-click search: alt + left-click an item in any bag or bank to open GFM and search it.
--
-- Bag-addon agnostic via a single global hook. Every bag UI built on Blizzard's
-- ContainerFrameItemButtonTemplate (default bags, Baganator, Bagnon/Combuctor, AdiBags,
-- BetterBags, ...) calls HandleModifiedItemClick(itemLink) at the top of its click path.
-- It returns false for Alt (no built-in alt action), so the click proceeds normally, but
-- it WAS called with the link, which is all we need. We post-hook it, and when only Alt is
-- held we run the search. Some addons (e.g. Baganator) also bind Alt-click to their own
-- feature; we simply coexist. ClearCursor on the next frame undoes a pickup if one happened.
--========================================================================
local function onItemClick(link)
    if not ns.GetSetting("altClickSearch") then return end
    if not (IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown()) then return end
    if type(link) ~= "string" then return end
    local id = GetItemInfoInstant(link)
    if not id then return end
    ns.Log("ALT-SEARCH: item click id " .. tostring(id))
    if ns.OpenAndSearch then ns.OpenAndSearch(id) end
    C_Timer.After(0, function() ClearCursor() end)   -- if the click also picked the item up, drop it back
end

local bagSearchInstalled = false
local function installBagSearch()
    if bagSearchInstalled then return end
    bagSearchInstalled = true
    if type(HandleModifiedItemClick) == "function" then
        hooksecurefunc("HandleModifiedItemClick", onItemClick)
        ns.Log("ALT-SEARCH: hooked HandleModifiedItemClick")
    else
        ns.Log("ALT-SEARCH: HandleModifiedItemClick missing; cannot install")
    end
end

-- install lazily the first time the feature is switched on (never for users who leave it off)
ns.On("setting:altClickSearch", function(on) if on then installBagSearch() end end)
