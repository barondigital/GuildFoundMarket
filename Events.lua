local ADDON, ns = ...

--========================================================================
-- Tiny synchronous pub/sub bus.
--
-- The whole point: code that *changes* a thing and code that *reacts* to it never
-- reference each other. A producer calls ns.Emit("setting:foo", value); any number of
-- reactors registered with ns.On("setting:foo", fn) run, in registration order. Add a new
-- feature by subscribing, never by editing a central dispatch with another branch.
--========================================================================
local listeners = {}

-- Subscribe fn to an event. Returns fn so callers can keep a handle for ns.Off.
function ns.On(event, fn)
    local bucket = listeners[event]
    if not bucket then bucket = {}; listeners[event] = bucket end
    bucket[#bucket + 1] = fn
    return fn
end

-- Unsubscribe a previously registered fn from an event.
function ns.Off(event, fn)
    local bucket = listeners[event]
    if not bucket then return end
    for i = #bucket, 1, -1 do
        if bucket[i] == fn then table.remove(bucket, i) end
    end
end

-- Fire an event: call every listener with the given args, in registration order.
function ns.Emit(event, ...)
    local bucket = listeners[event]
    if not bucket then return end
    for i = 1, #bucket do bucket[i](...) end
end
