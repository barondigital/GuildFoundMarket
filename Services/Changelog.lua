local ADDON, ns = ...

--========================================================================
-- Changelog sharing (peer to peer). A client can't show the notes for a version it doesn't have,
-- so an out-of-date client fetches them from a peer who does: it whispers the peer running the
-- newest version for its bundled changelog, and shows the reassembled text in an overlay.
--
--   out-of-date -> peer : CLQ~myVersion            (please send me your changelog)
--   peer -> out-of-date : CLR~version~more~chunk    (changelog text, chunked like the catalog K~)
--
-- The peer only answers if it opted in (announceChangelog) AND is not itself behind, so an
-- announcer always actually runs the version whose notes it sends. The requester only accepts a
-- reply that is genuinely newer than itself and matches the highest version it has seen.
--
-- ns.CHANGELOG is this build's own notes; keep it current at release time. It is CUMULATIVE
-- over the whole minor (all 0.x.* patches, compactly worded): a peer who is several patches
-- behind only ever sees the newest build's message, so a patch-only note would hide the
-- minor's features from them. Reset the list when a new minor starts. The second line is the
-- one-line summary the overlay's Announce button puts in chat. It travels `~`-free and with
-- newlines encoded, so it survives the tilde-delimited wire and the chat transport.
--========================================================================

ns.CHANGELOG = [[Guild Found Market 0.21.1
Updated for game client 1.15.9 so GFM loads without the out-of-date checkbox; the 0.21 line adds the WTB seller scan, WTB/WTS whisper tags and a Bag sync that skips soulbound copies

- Updated for game client 1.15.9: the addon is no longer flagged as out of date.
- Scan sellers on My Items > WTB: one button sweeps the market for everything on your WTB list and opens a sellers window next to the main one. Each wanted item is a header with everyone selling it below, stock and price, cheapest first. Live progress, a Stop button, right-click a seller to whisper. Leaving the WTB view closes the window and stops the scan; every price seen feeds your item tooltips.
- Item whispers state your intent: whispering a seller pre-fills [WTB], whispering a buyer pre-fills [WTS], followed by the item link and the discussed price. The buyers and sellers side windows pre-fill the item too instead of an empty whisper.
- Bag sync fix: bound (soulbound or quest-bound) copies no longer count. A copy that turns soulbound, for example by equipping a BoE, drops out of your listed quantity on the next bag update. A bank snapshot from before this update corrects on your next bank visit.]]

-- Encode for the wire: drop the `~` field delimiter and turn newlines into a token that survives
-- chat, so the text can ride the tilde-delimited protocol. Chunks are concatenated before decode,
-- so a token split across a chunk boundary still recombines.
local function encode(s) return (tostring(s or ""):gsub("~", "-"):gsub("\n", "<NL>")) end
local function decode(s) return (tostring(s or ""):gsub("<NL>", "\n")) end

--========================================================================
-- Requester side: ask a peer for its changelog, then reassemble and cache the answer.
--========================================================================
local clBuf, clVer = "", nil          -- reassembly buffer + the version it belongs to

-- Whisper `peer` for the changelog of `forVersion`. Guarded so we ask once per version per session
-- and never re-ask for notes we already hold.
function ns.RequestChangelog(peer, forVersion)
    if not (peer and ns.channelName) then return end
    if ns.newerChangelog and ns.newerChangelog.version == forVersion then return end
    if ns._clRequested == forVersion then return end
    ns._clRequested = forVersion
    clBuf, clVer = "", nil
    ns.EnqueueWhisper(("CLQ~%s"):format(ns.version), peer)
    ns.Log(("CHANGELOG request -> %s for %s"):format(peer, forVersion))
end

-- Do we hold the changelog for the very version we're behind on? The UI overlay checks this (plus
-- "the window is open") before showing, and re-checks after each fetch. Kept here so it's testable
-- without the UI frames.
function ns.ShouldShowChangelog()
    return ns.updateAvailable ~= nil and ns.newerChangelog ~= nil
        and ns.newerChangelog.version == ns.updateAvailable
end

ns.OnMessage("CLR", function(a, b, c, _, _, _, sender)
    local version, more, chunk = a, b, c or ""
    if not (version and ns.VerNewer and ns.VerNewer(version, ns.version)) then return end   -- must be newer than mine
    if ns.latestVersion and ns.VerNewer(ns.latestVersion, version) then return end          -- a newer one exists; wait for it
    if clVer ~= version then clBuf, clVer = "", version end                                 -- start of a new transfer
    clBuf = clBuf .. chunk
    if more ~= "1" then
        ns.newerChangelog = { version = version, text = decode(clBuf) }
        clBuf, clVer = "", nil
        ns.Log(("CHANGELOG received from %s: %s (%d chars)"):format(Ambiguate(sender, "short"), version, #ns.newerChangelog.text))
        if ns.OnChangelogReady then ns.OnChangelogReady() end
    end
end)

--========================================================================
-- Announcer side: reply to a request, but only when opted in and actually current.
--========================================================================
ns.OnMessage("CLQ", function(a, _, _, _, _, _, sender)
    if not ns.GetSetting("announceChangelog") then return end   -- opted out of sharing
    if ns.updateAvailable then return end                        -- I'm behind myself: I'm not the latest
    local reqVer = a
    if not (ns.VerNewer and ns.VerNewer(ns.version, reqVer)) then return end   -- nothing newer to offer them
    local wire = encode(ns.CHANGELOG)
    local n = #wire
    if n == 0 then ns.EnqueueWhisper(("CLR~%s~0~"):format(ns.version), sender); return end
    local pos = 1
    while pos <= n do
        local piece = wire:sub(pos, pos + 179)
        pos = pos + 180
        ns.EnqueueWhisper(("CLR~%s~%d~%s"):format(ns.version, (pos <= n) and 1 or 0, piece), sender)
    end
    ns.Log(("CHANGELOG sent to %s (%s, %d chars)"):format(Ambiguate(sender, "short"), ns.version, n))
end)
