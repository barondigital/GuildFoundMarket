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
        default = true,
    },
    {
        key = "trackDefault",
        label = "New listings use Bag sync",
        tip = "Sets the starting position of the \"Bag sync\" switch when you create a NEW listing on the My Items tab. "
            .. "It changes nothing for listings you already have; flip the switch per listing any time.\n\n"
            .. "When Bag sync is on, GFM keeps the quantity in step with your stock: your bags, plus the last-seen contents of "
            .. "this character's bank and mailbox. It falls as you sell or use them and rises as you restock. "
            .. "At 0 the listing is |cffffd100parked|r (hidden from buyers but kept in your My Items), never deleted.\n\n"
            .. "Stock on another character (a bank alt) isn't counted, so leave this off if you list from one.",
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
        key = "showPriceTooltip",
        label = "Show recent prices on item tooltips",
        tip = "Add a couple of lines to an item's tooltip showing the most recent prices GFM has "
            .. "seen for it (seller count, range, and how long ago), built from your own searches, "
            .. "browses and seller views.\n\n"
            .. "Turn this off if you'd rather keep tooltips clean.",
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
        key = "announceShopNote",
        label = "Announce your shop note",
        tip = "When you press Announce and you have a shop note set, post that note (followed by your clickable shop link) instead of the default \"Shop is open!\" line.\n\n"
            .. "With no shop note, or this turned off, the default announce line is used.",
        default = false,
    },
    {
        key = "codAccept",
        label = "Accept COD order requests",
        tip = "Let other GFM users request a Cash On Delivery straight from one of your listings (Alt-click a row in your shop, the Buy results, or the category Browse).\n\n"
            .. "When on, an incoming request is added to your COD list (My Items > COD) and the buyer gets the automatic confirmation whisper below. "
            .. "Requests for items you don't currently list, or made while your listings are offline, are declined automatically.",
        default = true,
    },
    {
        key = "codReplyText",
        type = "text",
        label = "COD confirmation whisper",
        tip = "The whisper sent back automatically when you accept a COD request. Leave empty to send no whisper (the order is still added to your list).\n\n"
            .. "Tokens filled in for you: |cffffffff%item|r, |cffffffff%qty|r, |cffffffff%unit|r, |cffffffff%total|r, |cffffffff%buyer|r.",
        default = "Got your COD for %item x%qty @ %unit (%total). I'll mail it next time I'm at a mailbox, thanks %buyer!",
        maxLetters = 200,
    },
    {
        key = "codSentText",
        type = "text",
        label = "COD mailed whisper",
        tip = "The whisper sent to the buyer when you mark a COD order Done (mailed). Leave empty to send no whisper.\n\n"
            .. "Tokens filled in for you: |cffffffff%item|r, |cffffffff%qty|r, |cffffffff%unit|r, |cffffffff%total|r, |cffffffff%buyer|r.",
        default = "Mailed your COD: %item x%qty (%total). It's on its way, thanks %buyer!",
        maxLetters = 200,
    },
    {
        key = "codWhisperCapture",
        label = "Capture COD from whispers",
        tip = "When a buyer whispers you \"cod\", \"cod me 3\", \"cod 20\", etc. about one of your listings, add it to your COD list automatically at your listed price.\n\n"
            .. "The item is taken from a link in the whisper, or from the last item linked in your conversation. Only items you currently list are captured; adjust a negotiated price on the COD row. Requires \"Accept COD order requests\".",
        default = true,
    },
    {
        key = "codCreateLink",
        label = "Add a Create COD link to buyer whispers",
        tip = "When a buyer whispers you an item link for one of your listings, append a clickable [Create COD] to the message. Click it to place a COD order for that buyer and item (a small popup asks the quantity).\n\n"
            .. "Only affects what you see, and only for items you currently list.",
        default = true,
    },
    {
        key = "announceChangelog",
        label = "Share changelog with out-of-date players",
        tip = "When you're on the newest version, answer other GFM users who are behind with this build's changelog, so they see what's new in an overlay.\n\n"
            .. "Only shares when you're actually up to date, and only your own bundled notes. Turn off to never send your changelog.",
        default = true,
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
    if not (s and (s.type == "choice" or s.type == "text")) then value = value and true or false end   -- only booleans get coerced
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
