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
-- Compose a shop-announce line into the chat box for `dest` WITHOUT sending it (the player
-- presses Enter themselves; anti-spam). Only the chat prefix changes per destination.
-- dest: "guild"|"officer"|"party"|"raid"|"whisper"|"channel"; name = whisper target.
local DEST_PREFIX = { guild = "/g", party = "/p", raid = "/raid" }
function ns.AnnounceShop(dest, name)
    dest = dest or "guild"
    if ns.IsPaused() then
        ns.Feedback("Your listings are offline. Go online before announcing your shop.", true); return
    end
    if not ns.channelName then
        ns.Feedback("No marketplace config in your guild info, so a shop link wouldn't resolve for anyone.", true); return
    end
    -- A shop link runs a seller-scan on click; with no live listings nobody would get an
    -- answer, so the link would resolve to an empty shop. Block it (parked qty-0 listings
    -- don't count, same as everywhere OfferList is read).
    if #ns.OfferList() == 0 then
        ns.Feedback("You have no active listings to show. Add one (or unhide a parked listing) before announcing your shop.", true); return
    end
    local prefix = DEST_PREFIX[dest]
    if dest == "whisper" then
        if not name or name == "" then ns.Feedback("Enter a name to whisper your shop to.", true); return end
        prefix = "/w " .. name
    elseif dest == "channel" then
        local tc = ns.config and ns.config.tradeChannel
        local idx = tc and GetChannelName(tc.name)
        if not (idx and idx > 0) then ns.Feedback("Join the trade channel first to announce there.", true); return end
        prefix = "/" .. idx
    elseif dest == "guild" and not IsInGuild() then
        ns.Feedback("You're not in a guild, so there's no guild chat to announce in.", true); return
    end
    if not prefix then ns.Feedback("Pick where to announce your shop.", true); return end
    -- With the option on and a note set, announce the note followed by the shop-link marker
    -- (same as the default line: the clickable link trails). No option / no note falls back
    -- to "Shop is open!".
    -- trailing space so the cursor sits clear of the marker, ready to shift-click items in
    local note = ns.GetSetting("announceShopNote") and ns.GetShopNote()
    if note and note ~= "" then
        ChatFrame_OpenChat(("%s %s @{{GFM:%s}} "):format(prefix, note, ns.playerName))
    else
        ChatFrame_OpenChat(("%s Shop is open! {{GFM:%s}} "):format(prefix, ns.playerName))
    end
    ns.Log("ANNOUNCE composed for " .. dest .. " (not sent, your call)")
end

-- Rewrite our plain-text marker into a clickable link on the receiving client.
-- The link uses Blizzard's sanctioned "addon:" hyperlink type, not a real item: clicking it
-- fires SetItemRef WITHOUT popping a tooltip, and hovering shows nothing by default, so there
-- is no stray placeholder to chase. (The old code carried a Hearthstone item and had to hide
-- its tooltip on click; that leaked through on hover, and on any error before the hide.) The
-- seller name rides in the link payload AND the visible text. The capture excludes braces and
-- pipes, and we strip colons, so a crafted message can't inject escape codes or extra fields.
local SHOP_LINK_NS = "addon:GuildFoundMarket"   -- custom link type; no item, no placeholder tooltip

-- A clickable "Cancel COD" link. Same taint-safe "addon:" hyperlink type as the shop link, but a
-- `cod:` payload carrying (seller, itemID, suffix) so a click cancels that order. It rides in the
-- seller's confirmation whisper as a {{GFMCOD:...}} marker the recipient rewrites, giving the buyer
-- a cancel entry point that survives even when the listing is fully reserved and hidden from search.
local function codLink(seller, itemID, suffix)
    return ("|cffff6060|H%s:cod:%s:%d:%d|h[Cancel COD]|h|r"):format(SHOP_LINK_NS, seller, itemID, suffix or 0)
end

-- Wire marker (plain text; the chat server strips real hyperlinks). ns.playerName = the seller, so
-- a click knows who to send the cancel to. The recipient's shareFilter rewrites it into codLink.
function ns.CODCancelMarker(itemID, suffix)
    return ("{{GFMCOD:%s:%d:%d}}"):format(ns.playerName, itemID, suffix or 0)
end
-- Ready-made clickable link for LOCAL display (e.g. the self-test's simulated whisper, which uses
-- AddMessage and so never passes through the incoming-chat filter that rewrites markers).
function ns.CODCancelLink(seller, itemID, suffix) return codLink(seller, itemID, suffix) end

-- Per-surface spam filter: each chat event maps to a "hide" setting. When that setting is on
-- the whole shop-link line is suppressed for this player only (local, changes nothing for
-- anyone else). Surfaces not listed here (e.g. raid) are never hidden, by design.
local HIDE_KEY_BY_EVENT = {
    CHAT_MSG_GUILD = "hideShopGuild", CHAT_MSG_OFFICER = "hideShopGuild",
    CHAT_MSG_PARTY = "hideShopParty", CHAT_MSG_PARTY_LEADER = "hideShopParty",
    CHAT_MSG_WHISPER = "hideShopWhisper", CHAT_MSG_WHISPER_INFORM = "hideShopWhisper",
    CHAT_MSG_CHANNEL = "hideShopChannels",
}

-- A chat filter runs once per chat window the message would show in, and a self-whisper
-- fires two events, so one announce hits shareFilter several times. Log only once per
-- distinct message+frame so the debug log shows one "hid" line per blocked announce.
local lastHiddenMsg, lastHiddenAt = nil, 0
local function shareFilter(_, event, msg, ...)
    if not msg then return end
    local hasShop = msg:find("{{GFM:", 1, true) ~= nil
    local hasCancel = msg:find("{{GFMCOD:", 1, true) ~= nil
    if not (hasShop or hasCancel) then return end
    -- the spam filter is for shop-announce lines only; a COD confirmation whisper with a cancel
    -- link is a transactional reply, never suppressed
    if hasShop then
        local hideKey = HIDE_KEY_BY_EVENT[event]
        if hideKey and ns.GetSetting(hideKey) then
            local now = GetTime()
            if ns.Log and (msg ~= lastHiddenMsg or now ~= lastHiddenAt) then
                lastHiddenMsg, lastHiddenAt = msg, now
                ns.Log("SPAM-FILTER: hid a shop link (" .. tostring(event) .. ")")
            end
            return true   -- spam-filtered: drop the line for this client
        end
    end
    local changed = false
    local out = msg:gsub("{{GFM:([^{}|]+)}}", function(name)
        name = name:gsub(":", "")   -- colon is our payload delimiter; real names never contain one
        changed = true
        return ("|cff00ff96|H%s:%s|h[%s's shop]|h|r"):format(SHOP_LINK_NS, name, name)
    end)
    out = out:gsub("{{GFMCOD:([^{}|]+)}}", function(payload)
        local seller, id, sfx = payload:match("^([^:]+):(%d+):(%d+)$")   -- reject anything malformed
        if not seller then return nil end
        changed = true
        return codLink(seller, tonumber(id), tonumber(sfx))
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

-- Recover the seller name from a clicked/hovered shop link's payload ("addon:GuildFoundMarket:Name").
local function linkSeller(link)
    return type(link) == "string" and link:match("^addon:GuildFoundMarket:(.+)$") or nil
end

-- Open a clicked shop link. Taint-safe and placeholder-free: the "addon:" link fires SetItemRef
-- with no tooltip, and we never write the global SetItemRef (the old code REPLACED it, tainting
-- the secure menu/clipboard path and blocking CopyToClipboard). EventRegistry is Blizzard's own
-- callback, so nothing leaks and there is no placeholder to hide.
-- Recover a cancel link's payload ("addon:GuildFoundMarket:cod:Seller:itemID:suffix").
local function linkCancel(link)
    if type(link) ~= "string" then return nil end
    return link:match("^addon:GuildFoundMarket:cod:([^:]+):(%d+):(%d+)$")
end

local function openClickedLink(link)
    local seller, id, sfx = linkCancel(link)   -- a "Cancel COD" link: send a cancel (qty 0) for it
    if seller then
        if ns.RequestCOD then ns.RequestCOD(seller, tonumber(id), tonumber(sfx), 0, 0) end
        return
    end
    local name = linkSeller(link)
    if name and ns.OpenShopLink then ns.OpenShopLink(name) end
end

-- Hover tooltip on the link itself. The "addon:" link shows nothing by default, so this is
-- entirely ours: the seller name, a call to action, and their shop note. We actively pull the
-- note the moment you hover (same NQ/NR whisper the Sellers-list bubble uses), so you no longer
-- have to open the seller first; when it lands, NoteArrived re-shows this tooltip in place.
ns.shopLinkNotes = ns.shopLinkNotes or {}   -- seller -> {note=, noteLoading=}, our own note store
local linkTipShown, activeLink = false, nil

-- The seller's note from wherever we already hold it: a hover-pull, or a prior Sellers-list scan.
local function linkNote(name)
    local l = ns.shopLinkNotes[name]
    if l and l.note and l.note ~= "" then return l.note end
    local s = ns.sellers and ns.sellers.results and ns.sellers.results[name]
    if s and s.note and s.note ~= "" then return s.note end
    return nil
end

-- Render a shop note into a tooltip, exactly as written (wrapped on one line). Item links carry
-- their own colour and name, so they render with or without item data cached.
local function addNoteLines(tt, note)
    note = note:gsub("^%s+", ""):gsub("%s+$", "")
    if note ~= "" then tt:AddLine(note, 0.95, 0.85, 0.6, true) end
end
ns.AddShopNoteLines = addNoteLines   -- reused by the Sellers/Buyers note bubbles for one consistent look

local function showLinkTooltip(owner, link)
    if linkCancel(link) then   -- a "Cancel COD" link: its own tooltip, not a shop tooltip
        GameTooltip:SetOwner(owner or UIParent, "ANCHOR_CURSOR")
        GameTooltip:AddLine("Cancel COD", 1, 0.4, 0.4)
        GameTooltip:AddLine("Click to cancel this order with the seller.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
        linkTipShown = true; activeLink = nil
        return
    end
    local name = linkSeller(link)
    if not name then return end   -- not our link: leave other tooltips untouched
    GameTooltip:SetOwner(owner or UIParent, "ANCHOR_CURSOR")
    GameTooltip:AddLine("GFM Shop", 1, 0.82, 0)   -- GFM gold title, distinct from GFC's green
    -- name picked out in the link's own mint so it reads as "this seller"; rest stays quiet
    GameTooltip:AddLine(("Click to browse |cff00ff96%s|r's shop"):format(name), 0.9, 0.9, 0.9)
    local note = linkNote(name)
    if note and note ~= "" then
        GameTooltip:AddLine(" ")
        addNoteLines(GameTooltip, note)
    end
    GameTooltip:Show()
    linkTipShown = true
    activeLink = { owner = owner, name = name, link = link }
    -- don't have the note yet? pull it now, exactly like clicking the bubble would (dup/loading
    -- guards live in RequestNote). NoteArrived will refresh this tooltip when the answer lands.
    if not note and ns.RequestNote then
        ns.shopLinkNotes[name] = ns.shopLinkNotes[name] or {}
        ns.RequestNote(name, ns.shopLinkNotes)
    end
end
local function hideLinkTooltip()
    if linkTipShown then GameTooltip:Hide() end   -- only our own tooltip, never someone else's
    linkTipShown, activeLink = false, nil
end

-- A hovered seller's note just arrived: re-render the tooltip in place, but only if it's still
-- ours and still up (the cursor hasn't left and nothing else has claimed GameTooltip).
function ns.RefreshShopLinkTooltip(name)
    if not (linkTipShown and activeLink and activeLink.name == name) then return end
    if GameTooltip:GetOwner() ~= activeLink.owner then return end
    showLinkTooltip(activeLink.owner, activeLink.link)
end

local shareInstalled = false
local function installShareLinks()
    if shareInstalled then return end
    shareInstalled = true
    for _, e in ipairs(SHARE_EVENTS) do ChatFrame_AddMessageEventFilter(e, shareFilter) end

    -- Click: prefer EventRegistry (Blizzard's taint-safe callback for "addon:" links); fall back
    -- to a post-hook on SetItemRef on any client without it. Only one path is installed per run.
    if EventRegistry and type(EventRegistry.RegisterCallback) == "function" then
        EventRegistry:RegisterCallback("SetItemRef", function(_, link) openClickedLink(link) end)
    else
        hooksecurefunc("SetItemRef", function(link) openClickedLink(link) end)
    end

    -- Hover: our own tooltip on each chat frame's hyperlinks.
    local frames = tonumber(NUM_CHAT_WINDOWS) or 10
    for i = 1, frames do
        local frame = _G["ChatFrame" .. i]
        if frame and frame.HookScript and not frame.gfmShopLinkHooked then
            frame.gfmShopLinkHooked = true
            frame:HookScript("OnHyperlinkEnter", function(self, link) showLinkTooltip(self, link) end)
            frame:HookScript("OnHyperlinkLeave", hideLinkTooltip)
        end
    end
end
ns.InstallShareLinks = installShareLinks
