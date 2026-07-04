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
-- ns.CHANGELOG is this build's own notes; keep it current at release time. It travels `~`-free and
-- with newlines encoded, so it survives the tilde-delimited wire and the chat transport.
--========================================================================

ns.CHANGELOG = [[Guild Found Market 0.17.0
Cash On Delivery orders

A new COD tab on My Items keeps a to-do list of the Cash On Delivery mails you owe buyers, so you can keep your shop open while you're out and send the mails at a mailbox later.

- Buyers request a COD straight from one of your listings (Alt-click on the Buy results, your shop, or the category Browse). The order lands on your list and the buyer gets your confirmation whisper. Turn it on with "Accept COD order requests" in Options, where you can also edit the whisper.
- Add COD orders by hand too: buyer, item, quantity, unit price.
- The request popup shows how many the buyer already has on order, and on a bag-synced listing caps the amount to your free stock.
- Cancel from chat: the confirmation whisper carries a Cancel COD link (or set the quantity to 0).
- Mailbox send-assist: at a mailbox, the Send button pre-fills the mail (recipient, the item from your bags, the COD amount, a subject). You review it and press Send yourself.]]

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
