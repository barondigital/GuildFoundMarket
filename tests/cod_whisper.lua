-- Unit test for COD whisper capture (Services/CODWhisper.lua).
--
-- Not loaded by the addon (absent from the .toc) and excluded from the package. Run with:
--   lua tests/cod_whisper.lua
--
-- Loads the REAL Services/CODWhisper.lua against stubs and asserts:
--   * ns.ParseCODIntent handles many phrasings, coin amounts, item links, and non-COD chatter;
--   * ns.HandleCODWhisper seeds item context (both directions), resolves a bare "cod N" to it,
--     honours the settings + pause gate, and only captures for an incoming whisper.

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
local fakeNow = 1000
function time() return fakeNow end
function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end

local settings = { codAccept = true, codWhisperCapture = true, codCreateLink = true }
local paused = false
local captured = {}   -- { buyer, id, suffix, qty }
local listed = { [100] = 15000 }   -- itemID -> listed price (0/absent = not listed)
local ns = {
    Stock = { LinkSuffix = function(link)
        local str = link and link:match("item:[%-%d:]+"); if not str then return 0 end
        local p = { strsplit(":", str) }; return tonumber(p[8]) or 0
    end },
    GetSetting = function(k) return settings[k] end,
    IsPaused = function() return paused end,
    CaptureCOD = function(buyer, id, suffix, qty) captured[#captured + 1] = { buyer = buyer, id = id, suffix = suffix, qty = qty } end,
    OfferInfo = function(id) local p = listed[id]; if not p then return nil end; return 1, false, p end,
    CODMakeLink = function(buyer, id, suffix) return ("[MKCOD:%s:%d:%d]"):format(buyer, id, suffix or 0) end,
}
assert(loadfile("Services/CODWhisper.lua"))("GuildFoundMarket", ns)

-- a fake item link: itemID 8117, suffix (field 8) 0 unless given
local function link(id, suffix) return ("|cffffffff|Hitem:%d:0:0:0:0:0:%d:0|h[Thing]|h|r"):format(id or 8117, suffix or 0) end

--========================================================================
-- 1. ParseCODIntent: phrasing permutations
--========================================================================
local function parse(msg) return ns.ParseCODIntent(msg) end
local function isCod(msg) local c = parse(msg); return c end
local function qtyOf(msg) local _, q = parse(msg); return q end

check("bare cod -> intent, no qty", isCod("cod") == true and qtyOf("cod") == nil)
check("cod 5", qtyOf("cod 5") == 5)
check("cod me 5", qtyOf("cod me 5") == 5)
check("cod me 5 please", qtyOf("cod me 5 please") == 5)
check("5 cod (number first)", qtyOf("5 cod") == 5)
check("words between: can you cod 20 of these?", qtyOf("can you cod 20 of these?") == 20)
check("cod x3", qtyOf("cod x3") == 3)
check("uppercase COD 5", qtyOf("COD 5") == 5)
check("c.o.d 5", isCod("c.o.d 5") == true and qtyOf("c.o.d 5") == 5)
check("glued cod5", qtyOf("cod5") == 5)
check("cod all -> all", qtyOf("cod all") == "all")
check("cod me all -> all", qtyOf("cod me all") == "all")
check("cod everything -> all", qtyOf("cod everything") == "all")
check("coin amount not a qty: cod for 80s", isCod("cod for 80s") == true and qtyOf("cod for 80s") == nil)
check("qty kept, price stripped: cod 2 of them for 5g", qtyOf("cod 2 of them for 5g") == 2)

-- non-COD chatter is ignored
check("price question is not COD", isCod("80s?") == false)
check("sure is not COD", isCod("sure") == false)
check("codex is not COD", isCod("codex please") == false)
check("plain talk is not COD", isCod("that's a good deal") == false)
check("bare number is not COD", isCod("5") == false)

-- item link is extracted (and its id is not read as a quantity)
do
    local c, q, id, sfx = parse(link(8117, 0) .. " cod 3")
    check("link + cod 3: intent + qty", c == true and q == 3)
    check("link + cod 3: itemID from link", id == 8117 and sfx == 0)
end
do
    local _, q, id, sfx = parse(link(8117, 1234) .. "@1g cod me all")
    check("link@price cod all: qty all, price ignored", q == "all")
    check("link carries the variant suffix", id == 8117 and sfx == 1234)
end

--========================================================================
-- 2. HandleCODWhisper: context seeding + resolution + gating
--========================================================================
local function reset() for i = #captured, 1, -1 do captured[i] = nil end end
local function last() return captured[#captured] end

-- a link with no cod: seeds context, captures nothing
reset()
ns.HandleCODWhisper(link(8117), "Buyer", true)
check("link only: no capture", #captured == 0)
check("link only: context seeded", select(1, ns.CODWhisperContext("Buyer")) == 8117)

-- a later bare "cod 5" resolves to the remembered item
ns.HandleCODWhisper("cod 5 then", "Buyer", true)
check("later cod 5 resolves via context", last() and last().id == 8117 and last().qty == 5 and last().buyer == "Buyer")

-- item link in the same message needs no context
reset()
ns.HandleCODWhisper(link(555) .. " cod 3", "Other", true)
check("inline link + cod 3 captures", last() and last().id == 555 and last().qty == 3)

-- the exact direct-whisper shape a right-click compose produces: "[Item]@1g cod 3"
reset()
ns.HandleCODWhisper(link(8117) .. "@1g cod 3", "Direct", true)
check("direct '[Item]@1g cod 3' captures id + qty 3", last() and last().id == 8117 and last().qty == 3)

-- no context, bare cod: nothing to attribute
reset()
ns.HandleCODWhisper("cod 5", "Stranger", true)
check("bare cod with no context: no capture", #captured == 0)

-- context can be seeded by MY outgoing whisper (I linked the item to them)
reset()
ns.HandleCODWhisper(link(700), "Buyer3", false)   -- outgoing: seed only
check("outgoing link: no capture", #captured == 0)
ns.HandleCODWhisper("cod me all", "Buyer3", true)
check("cod all after my link: captures with qty all", last() and last().id == 700 and last().qty == "all")

-- gating: capture off
reset()
settings.codWhisperCapture = false
ns.HandleCODWhisper(link(800) .. " cod 2", "Buyer4", true)
check("capture disabled: nothing", #captured == 0)
settings.codWhisperCapture = true

-- gating: accept off
reset()
settings.codAccept = false
ns.HandleCODWhisper(link(800) .. " cod 2", "Buyer4", true)
check("accept disabled: nothing", #captured == 0)
settings.codAccept = true

-- gating: paused
reset()
paused = true
ns.HandleCODWhisper(link(800) .. " cod 2", "Buyer4", true)
check("paused: nothing", #captured == 0)
paused = false

-- outgoing whisper never captures, even with cod text
reset()
ns.HandleCODWhisper(link(900) .. " cod 4", "Buyer5", false)
check("outgoing cod text: no capture", #captured == 0)

-- our own confirmation whisper (contains "cod" + the {{GFMCOD}} marker) must never re-capture,
-- even when it arrives as an incoming self-whisper with the item in context (would loop otherwise)
reset()
ns.HandleCODWhisper(link(950), "Me", true)   -- seed context for the item
ns.HandleCODWhisper("Got your COD for Thing x2 (40000c) {{GFMCOD:Me:950:0}}", "Me", true)
check("confirmation whisper is not re-captured", #captured == 0)

-- context expires after the window
reset()
fakeNow = 5000
ns.HandleCODWhisper(link(8117), "Timed", true)   -- seeded at t=5000
fakeNow = 5000 + 601                              -- just past the 600s window
ns.HandleCODWhisper("cod 2", "Timed", true)
check("expired context: no capture", #captured == 0)

--========================================================================
-- 3. AppendCreateCODLink: append [Create COD] to whispers linking a listed item
--========================================================================
local function itemLink(id, suffix) return ("|Hitem:%d:0:0:0:0:0:%d:0|h[Thing]|h"):format(id, suffix or 0) end

-- a listed item link -> the message gets the make-COD link appended (for that buyer + item)
local out = ns.AppendCreateCODLink(itemLink(100) .. " still in stock?", "Citra")
check("create link: appended for a listed item", out ~= nil and out:find("[MKCOD:Citra:100:0]", 1, true) ~= nil)
check("create link: original text kept", out and out:find("still in stock?", 1, true) ~= nil)

-- an item you don't list -> nothing appended
check("create link: unlisted item gets nothing", ns.AppendCreateCODLink(itemLink(999) .. " hi", "Citra") == nil)

-- no item link -> nothing
check("create link: no item link gets nothing", ns.AppendCreateCODLink("hey are you there", "Citra") == nil)

-- option off -> nothing
settings.codCreateLink = false
check("create link: disabled gets nothing", ns.AppendCreateCODLink(itemLink(100) .. " ?", "Citra") == nil)
settings.codCreateLink = true

-- our own confirmation whisper (carries the marker) never gets a Create link
check("create link: skips our confirmation marker",
    ns.AppendCreateCODLink(itemLink(100) .. " {{GFMCOD:Me:100:0}}", "Citra") == nil)

io.write(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
