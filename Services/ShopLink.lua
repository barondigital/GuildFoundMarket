local ADDON, ns = ...

--========================================================================
-- "Shop is open" announce + clickable shop links.
-- The chat server strips custom hyperlinks, so the announce drops a plain-text
-- marker ({{GFM:Name}}) into guild chat. Every GFM client rewrites that marker
-- into a clickable link locally, so only GFM users ever see a clickable link and
-- the server never carries one. Clicking does NOT open the listing from the link:
-- it runs a name-filtered seller scan over the private channel and opens the shop
-- only once that seller actually answers (proof they're on your marketplace). We
-- never trust listing data carried inside the link.
--========================================================================
-- Compose the guild-chat line and hand it to the edit box WITHOUT sending it.
-- Announcing is the player's decision (and that avoids spam); they can still add
-- text or shift-click items in before pressing Enter.
function ns.AnnounceShop()
    if ns.IsPaused() then
        ns.Feedback("Your listings are offline. Go online before announcing your shop.", true); return
    end
    if not ns.channelName then
        ns.Feedback("No marketplace config in your guild info, so a shop link wouldn't resolve for anyone.", true); return
    end
    if not IsInGuild() then
        ns.Feedback("You're not in a guild, so there's no guild chat to announce in.", true); return
    end
    -- trailing space so the cursor sits clear of the marker, ready to shift-click items in
    ChatFrame_OpenChat(("/g Shop is open! {{GFM:%s}} "):format(ns.playerName))
    ns.Log("ANNOUNCE composed for guild chat (not sent, your call)")
end

-- Rewrite our plain-text marker into a clickable link on the receiving client.
-- The link DATA is a benign real item (Hearthstone), not a custom type: NovaWorldBuffs and
-- Questie securehook SetItemRef and call ItemRefTooltip:SetHyperlink(link) unconditionally,
-- which raises "Unknown link type" on a custom type. A real item link parses fine there; the
-- seller name rides in the visible text and we recover it in the SetItemRef hook below.
-- The capture excludes braces and pipes, so a crafted message can't inject escape codes.
local SHOP_LINK_ITEM = "item:6948"   -- Hearthstone: universally valid, shown briefly then hidden

-- Per-surface spam filter: each chat event maps to a "hide" setting. When that setting is on
-- the whole shop-link line is suppressed for this player only (local, changes nothing for
-- anyone else). Surfaces not listed here (e.g. raid) are never hidden, by design.
local HIDE_KEY_BY_EVENT = {
    CHAT_MSG_GUILD = "hideShopGuild", CHAT_MSG_OFFICER = "hideShopGuild",
    CHAT_MSG_PARTY = "hideShopParty", CHAT_MSG_PARTY_LEADER = "hideShopParty",
    CHAT_MSG_WHISPER = "hideShopWhisper", CHAT_MSG_WHISPER_INFORM = "hideShopWhisper",
    CHAT_MSG_CHANNEL = "hideShopChannels",
}

local function shareFilter(_, event, msg, ...)
    if not (msg and msg:find("{{GFM:", 1, true)) then return end
    local hideKey = HIDE_KEY_BY_EVENT[event]
    if hideKey and ns.GetSetting(hideKey) then return true end   -- spam-filtered: drop the line
    local changed = false
    local out = msg:gsub("{{GFM:([^{}|]+)}}", function(name)
        changed = true
        return ("|cff00ff96|H%s|h[GFM: browse %s's shop]|h|r"):format(SHOP_LINK_ITEM, name)
    end)
    if changed then return false, out, ... end
end

-- The Announce button only posts to guild, but rewrite the marker wherever it can
-- appear (incl. whisper + the outgoing whisper echo) so a hand-shared link also
-- clicks, and so it can be tested with a self-whisper.
local SHARE_EVENTS = {
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_CHANNEL",
}

-- Open a clicked shop link. Taint-safe: a post-hook on SetItemRef, never writing the global
-- (the old code REPLACED SetItemRef, which tainted it and leaked into Blizzard's secure
-- menu/clipboard path, blocking CopyToClipboard). We recognise our link by the seller name
-- in its visible text (the link data is a plain Hearthstone, see shareFilter), open the shop,
-- and hide the placeholder item tooltip that Blizzard/NWB/Questie put up for it.
local shareInstalled = false
local function installShareLinks()
    if shareInstalled then return end
    shareInstalled = true
    for _, e in ipairs(SHARE_EVENTS) do ChatFrame_AddMessageEventFilter(e, shareFilter) end
    hooksecurefunc("SetItemRef", function(_, text)
        local name = type(text) == "string" and text:match("|h%[GFM: browse (.-)'s shop%]|h")
        if name and ns.OpenShopLink then
            ns.OpenShopLink(name)
            if ItemRefTooltip then ItemRefTooltip:Hide() end   -- drop the placeholder tooltip
        end
    end)
end
ns.InstallShareLinks = installShareLinks
