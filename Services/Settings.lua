local ADDON, ns = ...

--========================================================================
-- Feature settings: a single source of truth that announces every change.
--
-- The schema below is pure data (key + label + tip + default). It drives the Options
-- panel directly, so adding a toggle is one line here plus one reactor somewhere with
-- ns.On("setting:<key>", fn). No behaviour lives in this file: it only stores values and
-- emits "setting:<key>" (and a generic "setting") so reactors can apply the effect.
--========================================================================

-- Order here is the order shown in the Options panel.
-- tip    = wrapped description shown on mouseover (may contain colour codes).
-- status = optional fn returning (text, r, g, b): a live status line appended to the
--          tooltip, e.g. whether an optional dependency is actually installed.
-- type   = "choice" for a multi-option setting (needs `options` = { {value, label}, ... });
--          omitted means a boolean toggle.
ns.SettingsSchema = {
    {
        key = "minimapButton",
        label = "Minimap button",
        tip = "Show the Guild Found Market icon on the minimap.\n\n"
            .. "Left-click it to open or close the window; right-click to toggle your listings online/offline. "
            .. "You can always open the window with |cffffffff/gfm|r too.",
        default = true,
    },
    {
        key = "altClickSearch",
        label = "Alt-click an item to search it",
        tip = "Alt + left-click any item in your bags or bank to open Guild Found Market and instantly search for that item.\n\n"
            .. "Some bag addons also use Alt-click for their own features. Disable this option if it conflicts with another addon.",
        default = false,
    },
    {
        key = "auxSeed",
        label = "Import item names from the aux addon",
        tip = "Optional speed-up, only useful if you also run the |cffffd100aux|r auction addon.\n\n"
            .. "When on, GFM copies aux's item-name list on login so search autocomplete works right away, "
            .. "instead of slowly building that list itself over time.\n\n"
            .. "Safe to leave on: it simply does nothing if you don't have aux.",
        status = function()
            if type(_G.aux) == "table" then
                return "aux addon detected: this option is active.", 0.4, 1, 0.4
            end
            return "aux addon not installed: this option currently has no effect.", 1, 0.82, 0
        end,
        default = true,
    },
    {
        key = "priceFormat",
        type = "choice",
        label = "Price fill format",
        tip = "How a price is filled in for you (the edit prefill and example) on the My Items "
            .. "and Buyers tabs. You can always TYPE either notation; this only sets the format "
            .. "shown back to you.\n\n"
            .. "|cffffffff3g50s|r: gold/silver/copper coins.\n"
            .. "|cffffffff3.50|r: decimal gold, where the two decimals are silver (3.05 = 3g5s).\n\n"
            .. "Search results always show the standard coin icons, whichever you pick.",
        default = "gsc",
        options = {
            { value = "gsc",      label = "3g50s (coins)" },
            { value = "currency", label = "3.50 (decimal gold)" },
        },
    },
    {
        key = "hideShopGuild",
        label = "Hide shop links in guild chat",
        tip = "Suppress incoming \"shop is open\" announce lines in guild and officer chat. Only hides them for you; it changes nothing for anyone else.",
        default = false,
    },
    {
        key = "hideShopParty",
        label = "Hide shop links in party chat",
        tip = "Suppress incoming shop-link lines in party chat. Local to you only.",
        default = false,
    },
    {
        key = "hideShopWhisper",
        label = "Hide shop links in whispers",
        tip = "Suppress incoming shop-link lines in whispers. Local to you only.",
        default = false,
    },
    {
        key = "hideShopChannels",
        label = "Hide shop links in channels",
        tip = "Suppress incoming shop-link lines in chat channels (e.g. the trade channel). Local to you only.",
        default = false,
    },
}

local byKey = {}
for _, s in ipairs(ns.SettingsSchema) do byKey[s.key] = s end
ns.SettingByKey = byKey

local function store()
    GuildFoundMarketDB.settings = GuildFoundMarketDB.settings or {}
    return GuildFoundMarketDB.settings
end

-- Current value, falling back to the schema default when unset.
function ns.GetSetting(key)
    local v = store()[key]
    if v == nil then
        local s = byKey[key]
        return s and s.default
    end
    return v
end

-- Persist a value and announce it. Always emits (even on an unchanged write) so a forced
-- re-apply is possible; reactors must therefore be idempotent.
function ns.SetSetting(key, value)
    local s = byKey[key]
    if not (s and s.type == "choice") then value = value and true or false end   -- booleans stay boolean
    store()[key] = value
    ns.Emit("setting:" .. key, value)
    ns.Emit("setting", key, value)
end

-- Toggle helper for slash commands / right-clicks.
function ns.ToggleSetting(key)
    ns.SetSetting(key, not ns.GetSetting(key))
    return ns.GetSetting(key)
end

-- One-time migration from the pre-settings storage, so existing users keep their state.
-- Maps the old fields onto the new keys only when the new key is still unset.
local function migrate()
    local s = store()
    if s.minimapButton == nil and type(GuildFoundMarketDB.minimap) == "table" then
        s.minimapButton = not GuildFoundMarketDB.minimap.hide
    end
    if s.auxSeed == nil then
        s.auxSeed = not GuildFoundMarketDB.disableAux
    end
end

-- Call once at login (after reactors are registered and the minimap is created): pushes the
-- saved value of every setting onto the bus so reactors sync to it.
function ns.ApplySettings()
    migrate()
    for _, s in ipairs(ns.SettingsSchema) do
        ns.Emit("setting:" .. s.key, ns.GetSetting(s.key))
    end
end
