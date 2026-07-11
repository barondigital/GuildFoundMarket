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

ns.CHANGELOG = [[Guild Found Market 0.19.1
The Buyers tab shows everything wanted, buyers per scanned bag item with one-click COD mail, a complete category browser, and solid COD mailing

- The Buyers tab now opens on everything the confederation wants to buy: every buyer's want list in one Item/Qty/Price/Buyer view. The item box doubles as a live filter; picking an item still asks the network directly. Refresh re-collects everything.
- Scan bags also asks who is buying: a Buyers column (coin icon) per scanned item opens a side window with every buyer, the amount they want and what they pay, best payer on top. Right-click a name to whisper; a Send button pre-fills a COD mail at their price, clamped to what your bags hold. The Find buyers coin on My Items opens the same window.
- The category browser is complete again: Consumable and Reagent are back, and an Armor subclass (all Cloth at once) can be browsed whole, like the Auction House. How many results are shown is a new slider in Options under Network.
- Locations show the zone in list columns (Orgrimmar instead of The Drag); hover the player for the exact spot.
- Fix: the "Mailed your COD" whisper no longer creates a phantom COD order on a buyer who lists the same item.
- Fix: the COD send-assist can now combine multiple stacks and split one for the remainder, so any order amount mails correctly; it refuses with honest messages when your bags cannot cover the order or it will not fit one mail.]]

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
