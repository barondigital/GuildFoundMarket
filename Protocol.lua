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
--========================================================================
local handlers = {}

-- Register a handler for a wire command (e.g. "Q", "R"). One handler per command.
function ns.OnMessage(cmd, fn)
    handlers[cmd] = fn
end

-- Split an incoming line and route it to the registered handler (if any).
function ns.DispatchMessage(text, sender)
    local cmd, a, b, c, d, e, f = strsplit("~", text)
    local h = handlers[cmd]
    if h then h(a, b, c, d, e, f, sender) end
end
