-- Static analysis config for luacheck (https://github.com/lunarmodules/luacheck).
-- Install: luarocks install luacheck   Run from the addon root: luacheck .
--
-- WoW addons run on Lua 5.1 and share one namespace via the `...` vararg
-- (`local ADDON, ns = ...`), so ADDON is often unused. The read_globals list below is the
-- WoW client API this addon actually touches; add to it if luacheck reports a new W113 for
-- a real Blizzard global. (Authored without a local luacheck to run it against, so the
-- first run may surface a couple of globals to add here.)

std = "lua51"
max_line_length = false
codes = true
exclude_files = { "Libs/" }

ignore = {
    "211/ADDON",   -- ADDON name from the vararg is frequently unused
    "212/ADDON",
    "212/_",       -- underscore placeholders
    "542",         -- empty if branch (used a few times as an intentional no-op)
}

-- Globals this addon defines (writes).
globals = {
    "GuildFoundMarketDB",
    "GuildFoundMarketCharDB",
    "SLASH_GFMARKET1",
    "SLASH_GFMARKET2",
}

-- WoW client API + UI globals the addon reads.
read_globals = {
    -- namespaced API
    "C_AddOns", "C_ChatInfo", "C_Container", "C_GuildInfo", "C_Item", "C_Timer", "C_EventUtils",
    -- libs / core
    "LibStub", "hooksecurefunc", "Enum", "UIParent", "UISpecialFrames",
    "CreateFrame", "GameTooltip", "GameTooltip_Hide", "GetAddOnMetadata",
    -- item / money
    "GetItemInfo", "GetItemInfoInstant", "GetItemIcon", "GetItemCount",
    "GetCoinTextureString", "ITEM_QUALITY_COLORS", "BANK_CONTAINER",
    "SetItemButtonTexture", "SetItemButtonCount", "SetItemRef", "HandleModifiedItemClick",
    -- player / world
    "UnitName", "GetTime", "GetSubZoneText", "GetZoneText", "Ambiguate",
    "GetGuildInfoText", "GetGuildInfo",
    -- channels / chat
    "GetChannelName", "GetChannelList", "JoinTemporaryChannel", "LeaveChannelByName",
    "SendChatMessage", "ChatEdit_InsertLink", "ChatEdit_OpenChat", "ChatFrame_OpenChat",
    "ChatFrame_AddMessageEventFilter",
    -- cursor / modifiers
    "GetCursorInfo", "ClearCursor", "IsAltKeyDown", "IsControlKeyDown", "IsShiftKeyDown",
    "IsModifiedClick", "IsModifierKeyDown",
    -- scroll frames
    "FauxScrollFrame_OnVerticalScroll", "FauxScrollFrame_GetOffset",
    "FauxScrollFrame_SetOffset", "FauxScrollFrame_Update",
}
