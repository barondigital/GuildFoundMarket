local ADDON, ns = ...

--========================================================================
-- Version detection: ride our version along on the broadcasts (appended, so old clients
-- ignore it), track the highest seen, and flag when we're behind. ns.version /
-- ns.latestVersion are initialised in Core; this file owns the comparison + peer tracking.
--========================================================================
local function verNums(v) local t = {} for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end return t end
local function verNewer(a, b)   -- is version a strictly newer than b?
    local na, nb = verNums(a), verNums(b)
    for i = 1, math.max(#na, #nb) do
        local x, y = na[i] or 0, nb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end
ns.VerNewer = verNewer   -- exposed for the changelog service (only respond to peers genuinely behind us)

-- `sender` (may be nil on older call sites) is remembered as latestVersionPeer so the changelog
-- service can whisper the peer who actually runs the newest version to fetch its notes.
local function notePeerVersion(v, sender)
    if not v or v == "" or not verNewer(v, ns.latestVersion) then return end
    ns.latestVersion = v
    ns.latestVersionPeer = sender and Ambiguate(sender, "short") or nil
    if verNewer(v, ns.version) then
        ns.updateAvailable = v
        if not ns._updateNotified then
            ns._updateNotified = true
            ns.Feedback(("A newer version (%s) of Guild Found Market is out (you have %s). Please update."):format(v, ns.version), true)
        end
        if ns.UpdateVersionDisplay then ns.UpdateVersionDisplay() end
        -- ask that peer for the newest changelog so out-of-date clients can show it (opt-in on their side)
        if ns.RequestChangelog and ns.latestVersionPeer then ns.RequestChangelog(ns.latestVersionPeer, v) end
    end
end
ns.NotePeerVersion = notePeerVersion
