local ADDON, ns = ...

--========================================================================
-- COD capture from whispers. In practice buyers don't use the Alt-click affordance; they just
-- whisper "cod", "cod me 3", "cod 20 please". So watch incoming whispers for a COD intent and turn
-- it into an order automatically, at the seller's own listed price (a negotiated price is a one-edit
-- fix on the COD row). The hard part is which item: often it was linked a few messages earlier, so we
-- remember the last item linked per conversation (in whispers either way) and resolve a bare "cod N"
-- to it. No fuzzy word-matching on the 3-letter "cod" (too many false positives); a real item link
-- or recent context, plus the item being one you list, keeps captures honest.
--========================================================================

-- Tolerant parse of a whisper. Returns (isCod, qty, itemID, suffix):
--   isCod  : the message expresses a COD intent (the word "cod" / "c.o.d")
--   qty    : "all" | a number | nil (nil = unspecified, caller treats as 1) - found anywhere, not
--            necessarily next to "cod", and coin amounts (80s, 1g) are not mistaken for a quantity
--   itemID : from an item link in the message, else nil (caller falls back to conversation context)
local ALL_WORDS = { "all", "everything", "max" }
function ns.ParseCODIntent(msg)
    if type(msg) ~= "string" then return false end
    local itemID = tonumber(msg:match("|Hitem:(%d+)"))
    local suffix = itemID and ns.Stock and ns.Stock.LinkSuffix and ns.Stock.LinkSuffix(msg) or 0
    -- clean copy for keyword/qty parsing: drop item links (their ids aren't quantities), colour
    -- codes, and lowercase everything
    local clean = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|H.-|h.-|h", " "):gsub("|r", ""):lower()
    local isCod = clean:find("%f[%a]cod%f[%A]") ~= nil or clean:find("c%.o%.d") ~= nil
    if not isCod then return false, nil, itemID, suffix end
    -- strip coin amounts (80s, 1g, 50c) so a price isn't read as the quantity
    local q = clean:gsub("%d+%s*[gsc]%f[%A]", " ")
    local qty
    for _, w in ipairs(ALL_WORDS) do
        if q:find("%f[%a]" .. w .. "%f[%A]") then qty = "all"; break end
    end
    if not qty then qty = tonumber(q:match("%d+")) end
    return true, qty, itemID, suffix
end

-- Per-conversation memory of the last item linked, so "cod 5 then" (three messages after the link)
-- still resolves. Keyed by the other player; seeded from whispers in both directions.
local ctx = {}
local CTX_WINDOW = 600   -- seconds; a linked item stays "in context" for ten minutes
local function noteContext(other, itemID, suffix)
    if other and itemID then ctx[other] = { id = itemID, suffix = suffix or 0, at = time() } end
end
local function contextItem(other)
    local c = other and ctx[other]
    if c and (time() - (c.at or 0)) <= CTX_WINDOW then return c.id, c.suffix end
end
ns.CODWhisperContext = contextItem   -- exposed for tests

-- Handle one whisper. `incoming` = a whisper TO me (capture); false = one I sent (only seed context).
function ns.HandleCODWhisper(msg, other, incoming)
    -- Our own confirmation whisper says "Got your COD ..." and carries the {{GFMCOD}} cancel marker.
    -- Since you can whisper yourself (Classic Era), that reply would come back as an incoming whisper
    -- containing "cod" and re-capture forever. Skip anything carrying our marker: it's never a human
    -- request. (Also stops a buyer who lists the same item from mis-capturing the reply.)
    if type(msg) == "string" and msg:find("{{GFMCOD", 1, true) then return end
    other = Ambiguate(other or "", "short")
    local isCod, qty, itemID, suffix = ns.ParseCODIntent(msg)
    if itemID then noteContext(other, itemID, suffix) end
    if not incoming then return end                       -- my own whisper: only remembered for context
    if not isCod then return end
    if not (ns.GetSetting("codAccept") and ns.GetSetting("codWhisperCapture")) then return end
    if ns.IsPaused and ns.IsPaused() then return end
    if not itemID then itemID, suffix = contextItem(other) end   -- resolve from the conversation
    if not itemID then return end                         -- nothing to attribute it to: leave it alone
    if ns.CaptureCOD then ns.CaptureCOD(other, itemID, suffix or 0, qty) end
end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_WHISPER")
f:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
f:SetScript("OnEvent", function(_, event, msg, author)
    ns.HandleCODWhisper(msg, author, event == "CHAT_MSG_WHISPER")
end)
