local ADDON, ns = ...

--========================================================================
-- Network health. Session counters for everything the addon puts on (or pulls off) the
-- wire, plus the three saturation signals: server throttling, send-queue drops, and
-- replies landing after a scan's collection window. Shown in a plain-language sidebar
-- (Help > Network) so any player, not just a dev, can see how busy the marketplace is
-- and tune the client-side scan cap in Options. Counters reset on /reload, like the
-- Debug log; the two views share the same spot beside the window, so opening one
-- closes the other.
--========================================================================
ns.NetStats = ns.NetStats or {}

local counts = {
    sent = 0, sentBytes = 0, throttled = 0, dropped = 0,
    recvWhisper = 0, recvChannel = 0, late = 0, peakBacklog = 0,
}
local lastAt    = {}          -- [key] = GetTime() of the most recent bump
local startedAt = GetTime()

function ns.NetStats.Bump(key, n)
    counts[key] = (counts[key] or 0) + (n or 1)
    lastAt[key] = GetTime()
end

function ns.NetStats.NoteBacklog(n)
    if n > counts.peakBacklog then counts.peakBacklog = n end
end

-- Late-reply detection. Every scan registers its query id when it starts; the protocol
-- router reports each incoming reply id back here. A reply for a known id past its
-- collection window counts as late. Note that most handlers still USE such a reply (the
-- active id sticks around until the next scan), so "late" means "slower than the scan
-- waits", not "lost" - it's the early-warning signal that the confederation answers
-- slower than QUERY_SETTLE. Old ids are pruned so the table stays flat.
local scans = {}   -- [qid] = GetTime() deadline (scan start + settle window)

function ns.NetStats.ScanStarted(qid)
    if not qid then return end
    local now = GetTime()
    scans[qid] = now + (ns.QUERY_SETTLE or 5) + 0.5   -- small grace for timer/handler skew
    for id, deadline in pairs(scans) do
        if now > deadline + 300 then scans[id] = nil end
    end
end

function ns.NetStats.NoteReply(qid)
    local deadline = qid and scans[qid]
    if deadline and GetTime() > deadline then ns.NetStats.Bump("late") end
end

--========================================================================
-- The sidebar. Static FontStrings built once (a coloured value line plus a small
-- explanation line per metric), refreshed once a second while shown.
--========================================================================
local panel, ticker
local ui = {}         -- [key] = { line, note }
local content, lastAnchor
local TEXT_W = 300

local function ago(s)
    s = math.max(0, math.floor(s or 0))
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    return ("%dh%02dm"):format(math.floor(s / 3600), math.floor((s % 3600) / 60))
end

local function perMin(n)
    local mins = (GetTime() - startedAt) / 60
    if mins < 1 then mins = 1 end   -- avoid silly rates in the first minute
    return n / mins
end

-- Stack an element under the previous one; everything shares one left edge and width.
local function attach(fs, gap)
    if lastAnchor then fs:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -(gap or 4))
    else fs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -4) end
    fs:SetWidth(TEXT_W); fs:SetJustifyH("LEFT")
    lastAnchor = fs
    return fs
end

local function section(title)
    local h = attach(content:CreateFontString(nil, "OVERLAY", "GameFontNormal"), 14)
    h:SetText(title); h:SetTextColor(1, 0.82, 0)
end

local function row(key)
    local line = attach(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"), 10)
    local note = attach(content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 3)
    ui[key] = { line = line, note = note }
end

local function setRow(key, text, note, r, g, b)
    local w = ui[key]
    w.line:SetText(text); w.line:SetTextColor(r or 1, g or 1, b or 1)
    w.note:SetText(note or "")
end

-- The one-line verdict at the top: worst signal wins.
local function health()
    if counts.dropped > 0 then
        return ("Overloaded earlier: %d of your replies were lost."):format(counts.dropped),
            "More players asked you for data than your send queue could hold. To them it just looked like silence. If this keeps happening, mention it to the confederation.",
            1, 0.35, 0.35
    end
    if counts.throttled > 0 and lastAt.throttled and (GetTime() - lastAt.throttled) < 300 then
        return "Busy: the server recently slowed your sending down.",
            "Nothing is lost (GFM retries), but your answers go out later than normal. Frequent slow-downs mean the marketplace is near the sending limit.",
            1, 0.82, 0.2
    end
    if counts.late >= 10 and counts.late > counts.recvWhisper * 0.05 then
        return "Slow answers: many replies miss the scan window.",
            "Your scans close before some players manage to answer. Their results still trickle in where possible, but the picture during a scan is incomplete.",
            1, 0.82, 0.2
    end
    return "Healthy: traffic is well within limits.",
        "Sending and receiving are keeping up; nothing was lost or slowed down by the server this session.",
        0.4, 1, 0.4
end

local function refresh()
    if not panel or not panel:IsShown() then return end

    local hText, hNote, hr, hg, hb = health()
    ui.health.line:SetText(hText); ui.health.line:SetTextColor(hr, hg, hb)
    ui.health.note:SetText(hNote)

    local green, yellow, red, white = { 0.4, 1, 0.4 }, { 1, 0.82, 0.2 }, { 1, 0.35, 0.35 }, { 1, 1, 1 }
    local function pick(c) return c[1], c[2], c[3] end

    setRow("sent", ("Whispers sent: %d  (%.1f/min, %.1f KB)"):format(counts.sent, perMin(counts.sent), counts.sentBytes / 1024),
        "Replies and requests this character sent to other GFM users: search answers, catalogs, notes, COD messages.")

    local thrText = ("Server slow-downs: %d"):format(counts.throttled)
    if counts.throttled > 0 and lastAt.throttled then thrText = thrText .. ("  (last %s ago)"):format(ago(GetTime() - lastAt.throttled)) end
    local thrRecent = counts.throttled > 0 and lastAt.throttled and (GetTime() - lastAt.throttled) < 300
    setRow("throttled", thrText,
        "Times the server told us to wait before sending more. GFM retries, so nothing is lost, but a steadily growing number means you send more than the server allows.",
        pick(counts.throttled == 0 and green or (thrRecent and red or yellow)))

    setRow("dropped", ("Dropped replies: %d"):format(counts.dropped),
        ("Outgoing replies thrown away because more than %d were already waiting. Should stay at 0: every one is an answer another player never received."):format(ns.SEND_QUEUE_MAX or 50),
        pick(counts.dropped == 0 and green or red))

    local qNow = (ns.SendQueueSize and ns.SendQueueSize()) or 0
    setRow("queue", ("Send queue: %d waiting  (busiest: %d)"):format(qNow, counts.peakBacklog),
        "Messages lined up to go out; one leaves every 0.3 seconds. The queue fills when several players scan or browse you at the same time.",
        pick(qNow >= 20 and yellow or white))

    setRow("chan", ("Channel broadcasts: %d  (%.1f/min)"):format(counts.recvChannel, perMin(counts.recvChannel)),
        "Searches and scans everyone (you included) sends on the marketplace channel. Every GFM user receives all of these; this is the shared load.")

    setRow("whisp", ("Whispers received: %d  (%.1f/min)"):format(counts.recvWhisper, perMin(counts.recvWhisper)),
        "Replies and data sent directly to you: search results, catalogs, COD traffic. Only you carry this part.")

    setRow("late", ("Late replies: %d"):format(counts.late),
        ("Replies that arrived after the %d-second window a scan collects for. A few is normal; a lot means others answer slower than GFM waits, e.g. their send queue was busy."):format(ns.QUERY_SETTLE or 5),
        pick(counts.late == 0 and green or yellow))

    local cap = (ns.ScanCap and ns.ScanCap()) or ns.SELLER_CAP or 150
    local capHit = (ns.sellers and ns.sellers.capped) or (ns.buyers and ns.buyers.capped)
    setRow("cap", ("Scan size cap: %d sellers/buyers%s"):format(cap, capHit and "  (reached!)" or ""),
        capHit and "Your last Sellers or Buyers scan collected the maximum and ignored the rest. Raise the cap in Options (gear icon) to see everyone; a bigger scan just takes a moment longer to fill."
            or "The most sellers or buyers one scan collects. Your recent scans stayed below it, so you're already seeing everyone. Adjustable in Options (gear icon).",
        pick(capHit and yellow or white))

    ui.footer:SetText(("Counting since login, %s ago. Resets on /reload. Anyone can open this view; compare with guildmates to tune the caps."):format(ago(GetTime() - startedAt)))

    -- the notes wrap, so the content height is only known once rendered
    local top, bottom = content:GetTop(), ui.footer:GetBottom()
    if top and bottom then content:SetHeight(top - bottom + 12) end
end

local function createPanel()
    if panel then return panel end
    local main = _G.GuildFoundMarketFrame
    if not main then return nil end

    panel = CreateFrame("Frame", "GuildFoundMarketNetStats", main, "BackdropTemplate")
    panel:SetWidth(360)
    panel:SetPoint("TOPLEFT", main, "TOPRIGHT", 6, 0)
    panel:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", 6, 0)
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    panel:EnableMouse(true)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -16); title:SetText("GFM |cff00ff96Network|r")

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() panel:Hide() end)

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -38); scroll:SetPoint("BOTTOMRIGHT", -34, 14)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(TEXT_W, 1)
    scroll:SetScrollChild(content)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local mx = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.min(mx, math.max(0, self:GetVerticalScroll() - delta * 24)))
    end)

    -- the verdict block, then one row (value + explanation) per metric
    row("health")
    ui.health.line:SetFontObject(GameFontNormal)

    section("Sending")
    row("sent"); row("throttled"); row("dropped"); row("queue")

    section("Receiving")
    row("chan"); row("whisp"); row("late")

    section("Your settings")
    row("cap")

    ui.footer = attach(content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 16)

    panel:SetScript("OnShow", function()
        refresh()
        ticker = C_Timer.NewTicker(1, refresh)
    end)
    panel:SetScript("OnHide", function()
        if ticker then ticker:Cancel(); ticker = nil end
    end)

    panel:Hide()
    return panel
end

function ns.ToggleNetStats()
    createPanel()
    if not panel then return end
    if panel:IsShown() then panel:Hide(); return end
    local dbg = _G.GuildFoundMarketDebug
    if dbg and dbg:IsShown() then dbg:Hide() end   -- shares the sidebar spot beside the window
    panel:Show()
end
