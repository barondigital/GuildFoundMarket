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
-- The capture excludes braces and pipes, so a crafted message can't inject
-- escape codes (and we never reach gsub for those).
local function shareFilter(_, _, msg, ...)
    if msg and msg:find("{{GFM:", 1, true) then
        local changed = false
        local out = msg:gsub("{{GFM:([^{}|]+)}}", function(name)
            changed = true
            return ("|cff00ff96|Hgfmshop:%s|h[GFM: browse shop]|h|r"):format(name)
        end)
        if changed then return false, out, ... end
    end
end

-- The Announce button only posts to guild, but rewrite the marker wherever it can
-- appear (incl. whisper + the outgoing whisper echo) so a hand-shared link also
-- clicks, and so it can be tested with a self-whisper.
local SHARE_EVENTS = {
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
}

-- Open a clicked shop link. We REPLACE SetItemRef (capturing the existing chain) and
-- short-circuit our custom gfmshop: link here, so it reaches neither Blizzard's
-- SetItemRef nor any other addon's SetItemRef hook. This is deliberate over two
-- alternatives that each break:
--   * A plain hooksecurefunc on SetItemRef lets the link reach NovaWorldBuffs/Questie,
--     which securehook SetItemRef and call SetHyperlink(link) unconditionally. Our
--     unknown type raises "Unknown link type", and that error aborts the rest of the
--     secure-hook chain, so our own handler never runs and the link does nothing.
--   * Replacing the chat frame's OnHyperlinkClick script taints the chat frames, which
--     then intermittently blocks our SendChatMessage channel broadcasts
--     (ADDON_ACTION_BLOCKED), breaking search and the Sellers scan.
-- Replacing the global SetItemRef touches no chat-frame widget (so search/scan stay
-- untainted) and our link never reaches the unconditional SetHyperlink (so no error).
-- Real links fall through to the original chain unchanged. We install at PLAYER_LOGIN,
-- after other addons have hooked, so our replacement wraps their chain (not vice versa).
local shareInstalled = false
local function installShareLinks()
    if shareInstalled then return end
    shareInstalled = true
    for _, e in ipairs(SHARE_EVENTS) do ChatFrame_AddMessageEventFilter(e, shareFilter) end
    local origSetItemRef = SetItemRef
    SetItemRef = function(link, ...)
        local name = type(link) == "string" and link:match("^gfmshop:(.+)$")
        if name then
            if ns.OpenShopLink then ns.OpenShopLink(name) end
            return
        end
        return origSetItemRef(link, ...)
    end
end
ns.InstallShareLinks = installShareLinks
