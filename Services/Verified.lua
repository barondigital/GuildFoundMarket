local ADDON, ns = ...

--========================================================================
-- Guild Found verification: show whether a trade partner's "SoD Guild Found" addon
-- (FreshSoD) reports them clean ("no tampering recorded").
--
-- Each client asks its OWN FreshSoD for its status and appends that as a 1-byte flag to
-- the replies that already carry the guild tag (search R, seller/buyer summaries C/WC,
-- buyer-find WR, category QR). The receiver caches it by name, exactly like ns.guilds.
-- No cross-addon network traffic and no polling: the flag rides messages we send anyway,
-- so it is as live as the reply it arrived on.
--
-- Backward compatible by construction: the flag is APPENDED LAST on every message (after
-- the guild field, itself an append), so an old client's positional read never shifts and
-- it simply ignores the extra field. A missing flag (older client, or no FreshSoD
-- installed) stays nil here and is DISPLAYED as unverified; only an explicit "0" means
-- FreshSoD itself recorded tampering.
--
-- Sending is unconditional whenever FreshSoD is present, so even players who keep the
-- check turned off still prove themselves to everyone else. The verifiedCheck setting
-- only governs what THIS client shows (tooltip lines, row tints) and whether the COD
-- Send buttons refuse an unverified recipient; it can do nothing without FreshSoD, so
-- the Options checkbox is locked while that addon is missing.
--========================================================================

ns.valids = ns.valids or {}   -- [shortName] = true/false  (learned from the wire this session)

-- Is the SoD Guild Found addon (FreshSoD) loaded beside us?
function ns.VerifiedAvailable()
    return type(_G.FreshSoD_AmIVerified) == "function"
end

-- Is the verification check active on this client? (setting on AND FreshSoD present)
function ns.VerifiedEnabled()
    return ns.VerifiedAvailable() and ns.GetSetting("verifiedCheck") and true or false
end

-- My own status as the 1-byte wire value: "1" clean, "0" tampering recorded, "" unknown
-- (no FreshSoD). pcall guards against a FreshSoD update changing that function under us.
function ns.MyValidFlag()
    if not ns.VerifiedAvailable() then return "" end
    local ok, verified = pcall(_G.FreshSoD_AmIVerified)
    if not ok then return "" end
    return verified and "1" or "0"
end

-- Remember a player's flag from a message they sent. Anything but "1"/"0" (older client,
-- no FreshSoD) is ignored so a known status never degrades to unknown mid-session.
function ns.NoteValid(sender, flag)
    if flag ~= "1" and flag ~= "0" then return end
    local s = sender and Ambiguate(sender, "short")
    if s then ns.valids[s] = (flag == "1") end
end

-- The status we know for a name: true (clean), false (tampering recorded), nil (unknown).
-- Our own is read live from FreshSoD so it shows without any wire traffic.
function ns.ValidOf(name)
    if not name then return nil end
    if name == ns.playerName then
        local flag = ns.MyValidFlag()
        if flag == "" then return nil end
        return flag == "1"
    end
    return ns.valids[name]
end

-- Tooltip line for a player (text, r, g, b), or nil while the check is off.
function ns.ValidLine(name)
    if not ns.VerifiedEnabled() then return nil end
    local v = ns.ValidOf(name)
    if v == true then return "Guild Found: verified, no tampering recorded", 0.4, 1, 0.4 end
    if v == false then return "Guild Found: NOT verified, tampering recorded", 1, 0.45, 0 end
    return "Guild Found: unverified (no status received; older client or addon missing)", 1, 0.82, 0
end

-- Row background tint for a player (r, g, b, a), or nil for no tint (verified / check off).
-- Orange marks confirmed tampering; yellow marks "couldn't confirm".
function ns.ValidTint(name)
    if not ns.VerifiedEnabled() then return nil end
    local v = ns.ValidOf(name)
    if v == true then return nil end
    if v == false then return 1, 0.45, 0, 0.12 end
    return 1, 0.82, 0, 0.07
end

-- Why a COD send to `buyer` is refused (a feedback/tooltip line), or nil when it may go
-- ahead. Unknown counts as unverified: the whole point is not mailing goods to someone
-- who can't prove a clean record.
function ns.CODSendBlocked(buyer)
    if not ns.VerifiedEnabled() then return nil end
    if ns.ValidOf(buyer) == true then return nil end
    return ("%s is not Guild Found verified, so the COD send is blocked. You can turn this check off under Options."):format(buyer or "?")
end
