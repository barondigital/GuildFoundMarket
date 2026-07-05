local ADDON, ns = ...

--========================================================================
-- Transport: the only place that puts bytes on the wire. Owns the marketplace channel
-- (join plus keep-joined, with a deferred first join so we do not grab /1) and the
-- throttled outgoing whisper queue. Channel broadcasts (SendChatMessage) stay in the
-- feature code that triggers them, since those must ride a hardware event; this module
-- hands them the channel index via ns.EnsureChannel.
--========================================================================
local PREFIX         = "GFMarket"   -- addon-message prefix for whispered replies (<=16 chars)
local SEND_TICK      = 0.30         -- min seconds between outgoing messages (throttle)
local SEND_QUEUE_MAX = 50           -- under sustained throttling, drop the oldest (stale) reply
                                    -- instead of growing unbounded: a >5s-old answer is useless
ns.PREFIX = PREFIX                  -- the receive side (Core) checks incoming prefix against this

local sendQ = {}
local sendBacklogWarned = false

-- Queue a whispered reply. Channel broadcasts do not go here (they need a hardware event).
function ns.EnqueueWhisper(msg, to)
    if #sendQ >= SEND_QUEUE_MAX then
        table.remove(sendQ, 1)
        if ns.NetStats then ns.NetStats.Bump("dropped") end   -- an answer someone will never get
    end
    sendQ[#sendQ + 1] = { msg = msg, to = to }
    if ns.NetStats then ns.NetStats.NoteBacklog(#sendQ) end
end

-- Live queue depth, for the Network view.
function ns.SendQueueSize() return #sendQ end
ns.SEND_QUEUE_MAX = SEND_QUEUE_MAX

-- Hold off the first join until the default chat channels (General, Trade, LocalDefense...)
-- have settled, so we do not grab a low slot like /1 and push everyone's channels up.
-- Channels are numbered by join order, and the defaults trickle in over the first seconds.
local channelJoinReady = false
local joinScheduled = false

-- Ensure we are joined to the marketplace channel; returns the channel index (or nil).
function ns.EnsureChannel()
    local name = ns.channelName
    if not name then ns.channelIndex = nil; return nil end
    local idx = GetChannelName(name)
    if (not idx or idx == 0) and channelJoinReady then
        JoinTemporaryChannel(name)
        idx = GetChannelName(name)
        ns.Log(("CHANNEL joined %s on slot %s"):format(name, tostring(idx)))
    end
    ns.channelIndex = (idx and idx > 0) and idx or nil
    return ns.channelIndex
end

-- Hold the first join until the channel list settles (unchanged for ~4s), then join, so we
-- land after the default channels instead of grabbing /1. A 20s cap joins anyway. Runs once.
local function waitThenJoin()
    if joinScheduled then return end
    joinScheduled = true
    local last, stable, waited, ticker = -1, 0, 0
    ticker = C_Timer.NewTicker(2, function()
        waited = waited + 2
        local n = select("#", GetChannelList())
        if n == last then stable = stable + 1 else stable, last = 0, n end
        if stable >= 2 or waited >= 20 then
            ticker:Cancel()
            channelJoinReady = true
            ns.EnsureChannel()
        end
    end)
end

-- PLAYER_ENTERING_WORLD: re-join immediately once the list is known, else defer the first join.
function ns.RejoinChannel()
    if channelJoinReady then ns.EnsureChannel() else waitThenJoin() end
end

-- Called once at PLAYER_LOGIN: register the addon prefix and start the send-queue pump.
function ns.StartTransport()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.NewTicker(SEND_TICK, function()
        ns.EnsureChannel()   -- keep the marketplace channel joined (to send/receive queries)
        -- only whispered replies go through the queue; addon whispers are allowed from any
        -- context, unlike the channel broadcast which must ride a hardware event
        local item = sendQ[1]
        if item and item.to then
            local res = C_ChatInfo.SendAddonMessage(PREFIX, item.msg, "WHISPER", item.to)
            local throttled = Enum and Enum.SendAddonMessageResult
                and res == Enum.SendAddonMessageResult.AddonMessageThrottle
            if throttled then
                ns.Log("THROTTLE: addon whisper to " .. item.to .. " throttled by server; will retry")
                if ns.NetStats then ns.NetStats.Bump("throttled") end
            else
                table.remove(sendQ, 1)
                if ns.NetStats then ns.NetStats.Bump("sent"); ns.NetStats.Bump("sentBytes", #item.msg) end
            end
        end
        -- surface a growing backlog (latency / throttling symptom), edge-triggered
        if #sendQ >= 20 and not sendBacklogWarned then
            sendBacklogWarned = true
            ns.Log("SEND backlog: " .. #sendQ .. " replies queued (throttle/latency?)")
        elseif #sendQ == 0 and sendBacklogWarned then
            sendBacklogWarned = false
            ns.Log("SEND backlog cleared")
        end
    end)
end
