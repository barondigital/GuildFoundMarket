-- Unit test for the Guild Found verification flag (Services/Verified.lua) and its ride
-- on the wire (Search R, seller/buyer summaries C/WC, buyer-find WR).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package. Run from
-- the addon root with:  lua tests/verified.lua
--
-- Loads the REAL Protocol/Verified/Search/SellerBrowse/BuyerBrowse against stubs and asserts:
--   * a replier appends its FreshSoD status ("1"/"0", empty without the addon) as the LAST
--     field of R/C/WC/WR, leaving every pre-existing field in its old position;
--   * a receiver caches the flag by name and still parses the reply itself unchanged;
--   * an old-style message (no flag, or no guild either) parses fine and leaves the
--     player's status unknown (nil), which the UI shows as unverified;
--   * ValidOf/VerifiedEnabled/CODSendBlocked gate on both the setting and FreshSoD's
--     presence, and read the OWN player's status live from FreshSoD.

local failures = 0
local function check(name, cond)
    io.write(cond and ("  ok   " .. name .. "\n") or ("  FAIL " .. name .. "\n"))
    if not cond then failures = failures + 1 end
end

--========================================================================
-- Minimal WoW API + addon-namespace stubs
--========================================================================
local unpack = table.unpack or unpack

function strsplit(sep, s)
    local res, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then res[#res + 1] = s:sub(start); break end
        res[#res + 1] = s:sub(start, i - 1)
        start = i + #sep
    end
    return unpack(res)
end

function Ambiguate(name) return (name:gsub("%-.*", "")) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function GetTime() return 0 end
function GetItemInfo() return nil end
math.random = function() return 0 end          -- kill the reply jitter
C_Timer = { After = function(_, fn) fn() end }  -- run deferred work (the jittered replies) inline

local sentWhispers = {}
function SendChatMessage() end                  -- the scan broadcasts; not under test

local settings = { verifiedCheck = true }
local ns = {
    playerName  = "Me",
    channelName = "GFM",
    version     = "0.20.0",
    CHAT_TAG    = "GFMqp1:",
    QUERY_SETTLE = 3,
    SCAN_JITTER  = 0,
    search  = { results = {} },
    sellers = { results = {} },
    buyers  = { results = {}, find = { results = {} }, allWants = {}, allScan = {} },
    GetSetting = function(k) return settings[k] end,
    EnsureChannel = function() return 1 end,
    Feedback = function() end,
    Log = function() end,
    IsPaused = function() return false end,
    NotePeerVersion = function() end,
    NoteGuild = function() end,
    ScanCap = function() return 150 end,
    GetShopNote = function() return "" end,
    MyGuild = function() return "F R E S H IV" end,
    LiveLoc = function() return "Bank, Orgrimmar" end,
    EnqueueWhisper = function(msg, to) sentWhispers[#sentWhispers + 1] = { msg = msg, to = to } end,
    ItemDB = { Learn = function() end },
    vkey = function(id, suffix) return id .. "#" .. (suffix or 0) end,
}
ns.OfferList = function() return { { id = 100, qty = 2, price = 5000, suffix = 1531 } } end
ns.WantList  = function() return { { id = 100, qty = 3, price = 4000, suffix = 0, cod = true } } end

local function loadModule(path)
    local chunk = assert(loadfile(path))
    return chunk("GuildFoundMarket", ns)
end
loadModule("Services/Protocol.lua")
loadModule("Services/Verified.lua")
loadModule("Services/Search.lua")
loadModule("Services/SellerBrowse.lua")
loadModule("Services/BuyerBrowse.lua")

local function reset() sentWhispers = {} end

--========================================================================
-- 1. Replier side: the flag rides LAST on R / C / WC / WR, old fields unshifted
--========================================================================
do
    _G.FreshSoD_AmIVerified = function() return true end

    reset()
    ns.DispatchMessage("Q~q1~100~0.19.0", "Buyer-Realm")
    local cmd, qid, id, qty, price, loc, suffix, guild, valid = strsplit("~", sentWhispers[1].msg)
    check("R: suffix still at field 6 (0.6.0 contract)", cmd == "R" and suffix == "1531")
    check("R: qty/price/loc unshifted", qty == "2" and price == "5000" and loc == "Bank, Orgrimmar")
    check("R: guild still at field 7", guild == "F R E S H IV")
    check("R: valid flag appended last (verified -> 1)", valid == "1")

    reset()
    ns.DispatchMessage("S~s1~~0.19.0", "Buyer-Realm")
    local _, sid, count, loc2, hasNote, guild2, valid2 = strsplit("~", sentWhispers[1].msg)
    check("C: sid/count/loc/hasNote unshifted", sid == "s1" and count == "1" and loc2 == "Bank, Orgrimmar" and hasNote == "")
    check("C: guild still at field 5, valid appended last", guild2 == "F R E S H IV" and valid2 == "1")

    reset()
    ns.DispatchMessage("W~w1~~0.19.0", "Buyer-Realm")
    local _, wsid, wcount, _, _, wguild, wvalid = strsplit("~", sentWhispers[1].msg)
    check("WC: sid/count unshifted, valid appended last", wsid == "w1" and wcount == "1" and wguild == "F R E S H IV" and wvalid == "1")

    reset()
    ns.DispatchMessage("WQ~wq1~100~0.19.0", "Seller-Realm")
    local _, wqid, wid, wqty, wprice, wloc, sfxcod, wrguild, wrvalid = strsplit("~", sentWhispers[1].msg)
    check("WR: suffix:cod still packed at field 6", wqid == "wq1" and sfxcod == "0:1")
    check("WR: id/qty/price/loc unshifted", wid == "100" and wqty == "3" and wprice == "4000" and wloc == "Bank, Orgrimmar")
    check("WR: guild at field 7, valid appended last", wrguild == "F R E S H IV" and wrvalid == "1")

    _G.FreshSoD_AmIVerified = function() return false end
    reset()
    ns.DispatchMessage("Q~q2~100~0.19.0", "Buyer-Realm")
    check("R: tampering recorded -> valid=0", select(9, strsplit("~", sentWhispers[1].msg)) == "0")

    _G.FreshSoD_AmIVerified = nil
    reset()
    ns.DispatchMessage("Q~q3~100~0.19.0", "Buyer-Realm")
    check("R: no FreshSoD -> valid field empty (never guessed)", select(9, strsplit("~", sentWhispers[1].msg)) == "")
end

--========================================================================
-- 2. Receiver side: new-style replies fill the cache, old-style replies parse and leave nil
--========================================================================
do
    ns.Search(100)   -- activeQid becomes Me#1
    ns.DispatchMessage("R~Me#1~100~2~5000~Bank, Orgrimmar~1531~F R E S H IV~1", "Newguy-Realm")
    ns.DispatchMessage("R~Me#1~100~1~6000~Bank, Orgrimmar~0~Old Guild", "Midguy-Realm")   -- 0.19: guild, no flag
    ns.DispatchMessage("R~Me#1~100~1~7000~Bank, Orgrimmar~0", "Oldguy-Realm")             -- 0.9: no guild either
    local a, b, c = ns.search.results["Newguy#1531"], ns.search.results["Midguy#0"], ns.search.results["Oldguy#0"]
    check("new-style R parsed (qty/price intact)", a and a.qty == 2 and a.price == 5000)
    check("0.19-style R (no flag) still parsed", b and b.price == 6000)
    check("0.9-style R (no guild, no flag) still parsed", c and c.price == 7000)
    check("flag cached: sender verified", ns.ValidOf("Newguy") == true)
    check("no flag: status stays unknown -> shown unverified", ns.ValidOf("Midguy") == nil and ns.ValidOf("Oldguy") == nil)

    ns.ScanSellers("")   -- activeSid becomes Me#S1
    ns.DispatchMessage("C~Me#S1~4~Bank, Orgrimmar~~Their Guild~0", "Baddie-Realm")
    check("C: summary parsed with the flag appended", ns.sellers.results["Baddie"] and ns.sellers.results["Baddie"].count == 4)
    check("C: valid=0 cached as tampering recorded", ns.ValidOf("Baddie") == false)

    ns.ScanBuyers("")    -- activeWSid becomes Me#WS1
    ns.DispatchMessage("WC~Me#WS1~2~Bank, Orgrimmar~1~Their Guild~1", "Wantguy-Realm")
    check("WC: summary parsed with the flag appended", ns.buyers.results["Wantguy"] and ns.buyers.results["Wantguy"].hasNote == true)
    check("WC: valid=1 cached as verified", ns.ValidOf("Wantguy") == true)

    ns.FindBuyersForItem(100)   -- activeWQid becomes Me#WQ2 (the module's seq is shared with the WS scan)
    ns.DispatchMessage("WR~Me#WQ2~100~3~4000~Bank, Orgrimmar~0:1~G~1", "Codguy-Realm")
    local w = ns.buyers.find.results["Codguy#0"]
    check("WR: want parsed (cod bit intact) with the flag appended", w and w.cod == true and w.price == 4000)
    check("WR: valid cached for the buyer", ns.ValidOf("Codguy") == true)
end

--========================================================================
-- 3. Gating: setting AND FreshSoD present; own status read live
--========================================================================
do
    _G.FreshSoD_AmIVerified = function() return true end
    settings.verifiedCheck = true
    check("check active with setting on + FreshSoD present", ns.VerifiedEnabled() == true)
    check("own status read live from FreshSoD", ns.ValidOf("Me") == true)
    check("COD to a verified buyer allowed", ns.CODSendBlocked("Codguy") == nil)
    check("COD to a tampered buyer blocked", type(ns.CODSendBlocked("Baddie")) == "string")
    check("COD to an unknown buyer blocked (unknown counts as unverified)", type(ns.CODSendBlocked("Oldguy")) == "string")

    settings.verifiedCheck = false
    check("setting off: check inactive, nothing blocked", ns.VerifiedEnabled() == false and ns.CODSendBlocked("Baddie") == nil)

    settings.verifiedCheck = true
    _G.FreshSoD_AmIVerified = nil
    check("no FreshSoD: check locked off even with the setting on",
        ns.VerifiedEnabled() == false and ns.CODSendBlocked("Baddie") == nil)
    check("no FreshSoD: no tooltip line either", ns.ValidLine("Baddie") == nil)
end

io.write(failures == 0 and "\nAll Guild Found verification checks passed.\n"
                        or ("\n" .. failures .. " check(s) FAILED.\n"))
os.exit(failures == 0 and 0 or 1)
