local ADDON, ns = ...

--========================================================================
-- Config: parse the marketplace settings out of the guild information text and derive the
-- private channel from them. A single channel line, GFMc (preferred) or GreenWall's GWc as
-- fallback. The marketplace is gated purely by who can read that secret, so peer-guild
-- lines (GFMp/GWp) are not needed and are ignored. The channel name is a hash of
-- channel:password, so everyone with the same secret lands on the same channel.
--========================================================================
local function simpleHash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 0x7FFFFFFF end
    return h
end

local function parseGuildConfig()
    local text = GetGuildInfoText()
    if not text or text == "" then return nil end
    local vars, picked, tradeChannel = {}, {}, nil
    local function applyVars(s) return (s:gsub("%$(.)", function(n) return vars[n] or ("$" .. n) end)) end
    for line in text:gmatch("[^\r\n]+") do
        -- shop-announce trade channel: GFMtc:Name or GFMtc:Name:password (matched before the
        -- single-letter operators below, since "tc" is two letters they would not catch)
        local tcName, tcPass = line:match("^GFMtc:([^:]+):?(.*)$")
        if tcName then tradeChannel = { name = tcName, password = (tcPass ~= "" and tcPass) or nil } end
        local src, op, args
        op, args = line:match("^GFM(%a):(.*)$"); if op then src = "GFM" end
        if not op then op, args = line:match("^GW(%a):(.*)$");  if op then src = "GW" end end
        if not op then op, args = line:match("^GW:(%a):(.*)$"); if op then src = "GW" end end
        if op then
            if op == "s" then
                local value, name = strsplit(":", args)
                if name and name ~= "" then vars[name] = value end
            elseif op == "c" then
                local chan, pass = strsplit(":", args)
                picked[src] = { channel = applyVars(chan or ""), password = pass or "" }
            end
            -- "p" (peer-guild) lines belong to GreenWall's chat bridge; GFM gates on the
            -- channel secret alone, so they are intentionally not parsed.
        end
    end
    local chosen = picked.GFM or picked.GW
    if not chosen or not chosen.channel or chosen.channel == "" then return nil end
    return { channel = chosen.channel, password = chosen.password, source = picked.GFM and "GFM" or "GW",
             tradeChannel = tradeChannel }
end

-- Re-read the guild info and (re)derive the channel. Announces a connect/disconnect and
-- refreshes the Buy view when the channel changes. Called from the bootstrap and guild events.
function ns.RefreshConfig()
    local cfg = parseGuildConfig()
    if cfg and ns._testTradeChannel and not cfg.tradeChannel then cfg.tradeChannel = ns._testTradeChannel end   -- /gfm tradechannel test override
    ns.config = cfg
    local newName = cfg and ("GFM" .. string.format("%x", simpleHash(cfg.channel .. ":" .. (cfg.password or "")))) or nil
    if newName ~= ns.channelName then
        if ns.channelName then LeaveChannelByName(ns.channelName) end
        ns.channelName  = newName
        ns.channelIndex = nil
        if newName then
            ns.Feedback(("Connected to your marketplace channel (using %s config)."):format(
                cfg.source == "GFM" and "GuildFoundMarket" or "GreenWall"), false)
            if ns.Log then ns.Log(("CONFIG connected: %s channel (%s)"):format(cfg.source == "GFM" and "GuildFoundMarket" or "GreenWall", newName)) end
        elseif ns.Log then
            ns.Log("CONFIG disconnected: no marketplace config in guild info")
        end
        if ns.RefreshBuy then ns.RefreshBuy() end
    end
end
