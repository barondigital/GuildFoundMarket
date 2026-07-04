-- Unit test for peer-to-peer changelog sharing (Services/Changelog.lua).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package. Run with:
--   lua tests/changelog.lua
--
-- Loads the REAL Protocol/Version/Changelog against stubs and asserts:
--   * a requester whispers CLQ and reassembles chunked CLR into ns.newerChangelog (newlines intact);
--   * a requester rejects a CLR that isn't newer than itself;
--   * an announcer replies with chunked CLR only when opted in, up to date, and genuinely newer;
--   * the wire never carries a raw "~" from the changelog text.

local failures = 0
local function check(name, cond)
    io.write(cond and ("  ok   " .. name .. "\n") or ("  FAIL " .. name .. "\n"))
    if not cond then failures = failures + 1 end
end

local unpack = table.unpack or unpack
function strsplit(sep, s)
    local res, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then res[#res + 1] = s:sub(start); break end
        res[#res + 1] = s:sub(start, i - 1); start = i + #sep
    end
    return unpack(res)
end
function Ambiguate(name) return name end

local wire = {}      -- captured EnqueueWhisper { msg, to }
local settings = { announceChangelog = true }
local ready = 0
local ns = {
    version = "0.17.0",
    latestVersion = "0.17.0",
    channelName = "chan",
    Log = function() end,
    Feedback = function() end,   -- the version nag calls this
    GetSetting = function(k) return settings[k] end,
    EnqueueWhisper = function(msg, to) wire[#wire + 1] = { msg = msg, to = to } end,
    OnChangelogReady = function() ready = ready + 1 end,
}

local function loadModule(path) return assert(loadfile(path))("GuildFoundMarket", ns) end
loadModule("Services/Protocol.lua")    -- OnMessage / DispatchMessage
loadModule("Services/Version.lua")     -- ns.VerNewer
loadModule("Services/Changelog.lua")   -- CLQ/CLR + RequestChangelog + ns.CHANGELOG

local function reset() for i = #wire, 1, -1 do wire[i] = nil end; ready = 0 end
local function lastWire() return wire[#wire] end

--========================================================================
-- 1. Requester: RequestChangelog whispers CLQ with our own version
--========================================================================
reset()
ns.RequestChangelog("Newbie", "0.18.0")
check("request: CLQ on the wire to the peer", lastWire() and lastWire().msg == "CLQ~0.17.0" and lastWire().to == "Newbie")

--========================================================================
-- 2. Requester: chunked CLR reassembles into ns.newerChangelog, newlines intact
--========================================================================
reset()
ns.latestVersion = "0.18.0"
ns._clRequested = nil; ns.newerChangelog = nil
local sample = "What's new in 0.18.0\n" .. ("x"):rep(400) .. "\nEnjoy!"   -- > 180 chars: several chunks
-- hand-encode + chunk exactly as the announcer would, then feed the chunks in
local enc = sample:gsub("~", "-"):gsub("\n", "<NL>")
local pos, n = 1, #enc
while pos <= n do
    local piece = enc:sub(pos, pos + 179); pos = pos + 180
    ns.DispatchMessage(("CLR~0.18.0~%d~%s"):format((pos <= n) and 1 or 0, piece), "Newbie")
end
check("reassemble: cached for the right version", ns.newerChangelog and ns.newerChangelog.version == "0.18.0")
check("reassemble: text is byte-exact incl. newlines", ns.newerChangelog and ns.newerChangelog.text == sample)
check("reassemble: OnChangelogReady fired once", ready == 1)

--========================================================================
-- 3. Requester: reject a CLR that isn't newer than us
--========================================================================
reset()
ns.newerChangelog = nil
ns.DispatchMessage("CLR~0.16.0~0~old notes", "Someone")
check("reject: an older changelog is ignored", ns.newerChangelog == nil and ready == 0)

--========================================================================
-- 4. Announcer: opted in, up to date, newer than the requester -> chunked CLR reply
--========================================================================
reset()
ns.version = "0.18.0"; ns.updateAvailable = nil
ns.CHANGELOG = "Header line\n" .. ("y"):rep(300) .. "\nFooter"   -- forces >1 chunk
settings.announceChangelog = true
ns.DispatchMessage("CLQ~0.17.0", "Behind")
check("announce: replied with at least two chunks", #wire >= 2)
check("announce: all chunks go to the requester", wire[1] and wire[1].to == "Behind")
-- reassemble the sent chunks and confirm they decode back to our changelog
local buf = ""
for _, w in ipairs(wire) do
    local _, ver, more, chunk = strsplit("~", w.msg)
    check("announce: chunk carries our version", ver == "0.18.0")
    buf = buf .. (chunk or "")
end
check("announce: last chunk marks the end (more=0)", select(3, strsplit("~", wire[#wire].msg)) == "0")
check("announce: no raw '~' in any chunk", not wire[1].msg:sub(#"CLR~0.18.0~1~" + 1):find("~", 1, true))
check("announce: reassembles to our changelog", (buf:gsub("<NL>", "\n")) == ns.CHANGELOG)

--========================================================================
-- 5. Announcer: refuses when opted out / out of date / not newer
--========================================================================
reset(); settings.announceChangelog = false
ns.DispatchMessage("CLQ~0.17.0", "Behind")
check("announce: silent when opted out", #wire == 0)

reset(); settings.announceChangelog = true; ns.updateAvailable = "0.19.0"
ns.DispatchMessage("CLQ~0.17.0", "Behind")
check("announce: silent when I'm behind myself", #wire == 0)

reset(); ns.updateAvailable = nil
ns.DispatchMessage("CLQ~0.18.0", "Peer")   -- requester is on my version, nothing newer to give
check("announce: silent when the requester isn't behind me", #wire == 0)

--========================================================================
-- 6. Overlay trigger end-to-end: newer peer -> auto CLQ -> CLR fills notes -> overlay should show
--========================================================================
reset()
ns.version = "0.17.0"; ns.latestVersion = "0.17.0"; ns.updateAvailable = nil
ns.newerChangelog = nil; ns._clRequested = nil; ns._updateNotified = nil
ns.NotePeerVersion("0.18.0", "Helper")   -- we see a peer running a newer version
check("trigger: update flagged", ns.updateAvailable == "0.18.0")
check("trigger: CLQ auto-sent to that peer", lastWire() and lastWire().msg == "CLQ~0.17.0" and lastWire().to == "Helper")
check("trigger: overlay not ready yet (no notes)", not ns.ShouldShowChangelog())
-- the peer answers with the changelog
local notes = "Big news in 0.18.0\nLots to see\nEnjoy"
ns.DispatchMessage(("CLR~0.18.0~0~%s"):format(notes:gsub("~", "-"):gsub("\n", "<NL>")), "Helper")
check("trigger: notes cached + OnChangelogReady fired", ns.newerChangelog and ns.newerChangelog.version == "0.18.0" and ready == 1)
check("trigger: notes decode back to text", ns.newerChangelog.text == notes)
check("trigger: overlay should now show", ns.ShouldShowChangelog())
-- after you actually update, it stops
ns.updateAvailable = nil
check("trigger: no overlay when up to date", not ns.ShouldShowChangelog())
-- an even newer version we don't have notes for yet: don't show stale notes
ns.updateAvailable = "0.19.0"
check("trigger: no overlay for a version we lack notes for", not ns.ShouldShowChangelog())

io.write(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
