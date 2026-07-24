local ADDON, ns = ...

--========================================================================
-- Protocol: routing for the tilde-delimited wire format. A feature registers a handler
-- per command with ns.OnMessage("R", fn); ns.DispatchMessage splits an incoming line and
-- calls the matching handler with the fields a..f and the sender. This is the one place
-- that knows a message is "cmd~a~b~...".
--
-- The wire format is deliberately unchanged here: existing clients (0.9.0 and older) must
-- keep interoperating, so encode still happens at each send site and the field order is
-- fixed (notably suffix-last on R/K/QR). Any future format change must stay readable by old
-- clients (e.g. append-only fields), which is why centralizing it lives here.
--
-- Handlers receive (a, b, c, d, e, f, sender, g, h, i): the six payload fields, then the sender,
-- then the seventh, eighth and ninth payload fields `g`, `h` and `i` last. Keeping `sender` in
-- its original 7th slot lets every existing handler stay untouched; only those that opted into
-- an appended field read the later args. `g` is how the guild tag rides along, `h` carries the
-- Guild Found valid flag and `i` the BYOM flag on R (all append-only, ignored by old clients).
--========================================================================
local handlers = {}

-- Register a handler for a wire command (e.g. "Q", "R"). One handler per command.
function ns.OnMessage(cmd, fn)
    handlers[cmd] = fn
end

-- Replies that carry the requester's scan id in their first field. Reported to NetStats,
-- so answers landing after the scan's collection window show up as "late replies" in the
-- Network view (the health signal for "the confederation answers slower than we wait").
local SCAN_REPLIES = { R = true, C = true, K = true, QR = true, WR = true, WC = true, WK = true }

-- Split an incoming line and route it to the registered handler (if any).
function ns.DispatchMessage(text, sender)
    local cmd, a, b, c, d, e, f, g, h, i = strsplit("~", text)
    if SCAN_REPLIES[cmd] and ns.NetStats then ns.NetStats.NoteReply(a) end
    local fn = handlers[cmd]
    if fn then fn(a, b, c, d, e, f, sender, g, h, i) end
end
