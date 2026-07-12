-- Backward-compatibility regression test for the tilde wire protocol.
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package
-- (.pkgmeta ignore). Run from the addon root with:  lua tests/protocol_compat.lua
--
-- It loads the REAL Services/Protocol.lua and Services/CategoryBrowse.lua against a
-- stubbed WoW API, then asserts the contract that lets 0.9.0 and newer clients keep
-- interoperating after the per-slot category browse was added:
--   * QC carries the optional `slot` appended LAST, so old sellers read class/sub/ver
--     unchanged and just ignore the extra field (replying with the whole subclass).
--   * a new seller honours `slot` when present and ignores it when absent or empty.
--   * the QR reply wire format (id:qty:price:suffix) is unchanged in both directions.
--   * the dispatcher's unlimited split never lets a trailing field shift earlier ones.
--   * the Guild Found valid flag rides QR appended LAST (after guild + loc), so 0.19
--     and older clients read every earlier field unchanged; without FreshSoD the field
--     is empty and a missing/empty flag never poisons the receiver's cache.

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
math.random = function() return 0 end          -- kill the reply jitter
C_Timer = { After = function(_, fn) fn() end }  -- run deferred work inline

-- itemID -> {name, class, sub, equipLoc}
local ITEMS = {
    [100] = { "Cloth Hat",  4, 1, "INVTYPE_HEAD" },
    [101] = { "Cloth Vest", 4, 1, "INVTYPE_CHEST" },
    [102] = { "Cloth Robe", 4, 1, "INVTYPE_ROBE" },   -- folds into CHEST
    [300] = { "Potion",     0, 1, "" },               -- consumable, no equip slot
}
-- GetItemInfo: classID at position 12, subclassID at 13 (matches the real signature)
function GetItemInfo(id)
    local it = ITEMS[id]; if not it then return nil end
    local r = {}; for i = 1, 11 do r[i] = false end
    r[12], r[13] = it[2], it[3]
    return unpack(r, 1, 13)
end
-- GetItemInfoInstant: itemEquipLoc at position 4
function GetItemInfoInstant(id)
    local it = ITEMS[id]; if not it then return nil end
    return id, "", "", it[4]
end

local sentBroadcasts, sentWhispers = {}, {}
function SendChatMessage(msg) sentBroadcasts[#sentBroadcasts + 1] = msg end

local ns = {
    playerName  = "Me",
    channelName = "GFM",
    version     = "0.10.0",
    CHAT_TAG    = "GFMqp1:",
    QUERY_SETTLE = 3,
    SCAN_JITTER  = 0,
    browseResults = {},
    EnsureChannel = function() return 1 end,
    Feedback = function() end,
    Log = function() end,
    IsPaused = function() return false end,
    NotePeerVersion = function() end,
    NoteGuild = function() end,
    MyGuild = function() return "F R E S H IV" end,
    LiveLoc = function() return "Bank, Orgrimmar" end,
    RefreshBrowse = function() end,
    RefreshBrowseSoon = function() end,
    EnqueueWhisper = function(msg, to) sentWhispers[#sentWhispers + 1] = { msg = msg, to = to } end,
    ItemDB = { Learn = function() end },
}
-- the responding seller's own in-stock offers
ns.OfferList = function()
    return {
        { id = 100, qty = 2, price = 5000, suffix = 0 },
        { id = 101, qty = 1, price = 8000, suffix = 0 },
        { id = 102, qty = 1, price = 9000, suffix = 0 },
        { id = 300, qty = 5, price = 100,  suffix = 0 },
    }
end

--========================================================================
-- Load the real protocol + feature against the stubs
--========================================================================
local function loadModule(path)
    local chunk = assert(loadfile(path))
    return chunk("GuildFoundMarket", ns)
end
loadModule("Services/Protocol.lua")
loadModule("Services/Verified.lua")   -- real MyValidFlag/NoteValid: CategoryBrowse appends the flag
loadModule("Services/CategoryBrowse.lua")

-- ids present in the whisper replies the seller queued, parsed from QR rows
local function repliedIDs()
    local ids = {}
    for _, w in ipairs(sentWhispers) do
        local _, _, _, rows = strsplit("~", w.msg)     -- QR~qid~more~rows
        for chunk in (rows or ""):gmatch("[^;]+") do
            local id = strsplit(":", chunk)
            ids[tonumber(id)] = true
        end
    end
    return ids
end
local function reset() sentWhispers = {} end

--========================================================================
-- 1. Dispatcher invariant: a..f positional, sender stays 7th, 7th wire field delivered 8th
--========================================================================
do
    local got
    ns.OnMessage("ZZ", function(...) got = { ... } end)
    ns.DispatchMessage("ZZ~A~B~C~D~E~F~G~H", "Sender-Realm")
    check("dispatch maps a..f positionally", got[1] == "A" and got[6] == "F")
    check("dispatch keeps sender in the 7th slot", got[7] == "Sender-Realm")
    check("dispatch delivers the 7th wire field (G) as the 8th arg", got[8] == "G")
    check("dispatch delivers the 8th wire field (H) as the 9th arg", got[9] == "H")
    ns.DispatchMessage("ZZ~A", "S")
    check("dispatch leaves missing fields nil", got[2] == nil and got[8] == nil and got[9] == nil)
end

--========================================================================
-- 2. New buyer -> new seller: slot is honoured
--========================================================================
do
    reset()
    ns.DispatchMessage("QC~q1~4~1~0.10.0~INVTYPE_HEAD", "Buyer-Realm")
    local ids = repliedIDs()
    check("new seller honours slot (head only)", ids[100] and not ids[101] and not ids[102])
end

--========================================================================
-- 3. Old buyer -> new seller: no slot field -> whole subclass (backward compat IN)
--========================================================================
do
    reset()
    ns.DispatchMessage("QC~q1~4~1~0.9.0", "Buyer-Realm")
    local ids = repliedIDs()
    check("old buyer (no slot) gets whole subclass", ids[100] and ids[101] and ids[102])
end

--========================================================================
-- 4. Empty slot field is treated as no slot (non-armor query)
--========================================================================
do
    reset()
    ns.DispatchMessage("QC~q1~0~1~0.10.0~", "Buyer-Realm")
    local ids = repliedIDs()
    check("empty slot field == no slot (consumable matches)", ids[300])
end

--========================================================================
-- 5. Robe folds into Chest on the seller side
--========================================================================
do
    reset()
    ns.DispatchMessage("QC~q1~4~1~0.10.0~INVTYPE_CHEST", "Buyer-Realm")
    local ids = repliedIDs()
    check("robe folds into chest slot", ids[101] and ids[102] and not ids[100])
end

--========================================================================
-- 6. QR reply wire format unchanged (backward compat OUT)
--========================================================================
do
    reset()
    ns.DispatchMessage("QC~q1~4~1~0.10.0~INVTYPE_HEAD", "Buyer-Realm")
    local w = sentWhispers[1]
    local cmd, qid, more, rows, guild, loc, valid = strsplit("~", w.msg)
    check("reply command is QR", cmd == "QR")
    check("reply echoes the query id", qid == "q1")
    check("reply carries the more flag", more == "0")
    check("reply row is id:qty:price:suffix", rows == "100:2:5000:0")
    check("reply carries the responder's guild", guild == "F R E S H IV")
    check("reply keeps the responder's location at field 5", loc == "Bank, Orgrimmar")
    check("no FreshSoD: the appended valid flag is empty", valid == "")
end

--========================================================================
-- 6b. Guild Found valid flag: appended last on QR, harmless to old clients in both directions
--========================================================================
do
    reset()
    _G.FreshSoD_AmIVerified = function() return true end   -- the seller runs SoD Guild Found, clean
    ns.DispatchMessage("QC~q1~4~1~0.10.0~INVTYPE_HEAD", "Buyer-Realm")
    local _, _, _, rows, guild, loc, valid = strsplit("~", sentWhispers[1].msg)
    check("valid flag appended after guild + loc (old fields unshifted)",
        rows == "100:2:5000:0" and guild == "F R E S H IV" and loc == "Bank, Orgrimmar")
    check("verified seller appends valid=1", valid == "1")
    _G.FreshSoD_AmIVerified = function() return false end   -- tampering recorded
    reset()
    ns.DispatchMessage("QC~q1~4~1~0.10.0~INVTYPE_HEAD", "Buyer-Realm")
    valid = select(7, strsplit("~", sentWhispers[1].msg))
    check("tampered seller appends valid=0", valid == "0")
    _G.FreshSoD_AmIVerified = nil

    -- receiving side: a new-style flag fills the cache; an old-style one (absent) leaves it alone
    ns.NoteValid("Clean-Realm", "1")
    ns.NoteValid("Naughty-Realm", "0")
    ns.NoteValid("Old-Realm", nil)     -- old client: field absent
    ns.NoteValid("Old2-Realm", "")     -- new client without FreshSoD: field empty
    check("valid=1 cached as true", ns.ValidOf("Clean") == true)
    check("valid=0 cached as false", ns.ValidOf("Naughty") == false)
    check("missing/empty flag stays unknown (shown unverified)",
        ns.ValidOf("Old") == nil and ns.ValidOf("Old2") == nil)
end

--========================================================================
-- 7. New buyer's QC broadcast keeps ver at field 4, slot appended last
--========================================================================
do
    sentBroadcasts = {}
    ns.BrowseCategory(4, 1, "INVTYPE_HEAD")
    local wire = sentBroadcasts[1]:gsub("^" .. ns.CHAT_TAG, "")
    local cmd, _, class, sub, ver, slot = strsplit("~", wire)
    check("QC keeps class/sub before ver (old clients read these)", cmd == "QC" and class == "4" and sub == "1")
    check("QC keeps ver at field 4", ver == "0.10.0")
    check("QC appends slot last", slot == "INVTYPE_HEAD")
end

io.write(failures == 0 and "\nAll protocol compat checks passed.\n"
                        or ("\n" .. failures .. " check(s) FAILED.\n"))
os.exit(failures == 0 and 0 or 1)
