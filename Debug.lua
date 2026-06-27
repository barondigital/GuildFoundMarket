local ADDON, ns = ...

--========================================================================
-- Debug log + copyable sidebar. The log always collects (a small ring buffer,
-- negligible cost) so any guild member can open it and copy a bug/latency report
-- to send. The sidebar is toggled by a button on the main window.
--========================================================================
local LOG_MAX = 400
ns.debugLog = ns.debugLog or {}
local log = ns.debugLog
local panel, editBox, scroll, statusFS, titleFS

-- Title reflects dev mode so it's obvious when the extra dev output is flowing in.
function ns.UpdateDebugTitle()
    if titleFS then
        titleFS:SetText(ns.dev and "GFM |cff00ff96Debug|r  |cffffd100dev mode|r" or "GFM |cff00ff96Debug|r")
    end
end

-- Append a timestamped line. Safe to call from anywhere, any time.
function ns.Log(msg)
    if type(msg) ~= "string" then msg = tostring(msg) end
    log[#log + 1] = date("%H:%M:%S") .. "  " .. msg
    while #log > LOG_MAX do table.remove(log, 1) end
    if ns.RefreshDebug then ns.RefreshDebug() end
end

local function setStatus(text, r, g, b)
    if statusFS then statusFS:SetText(text); statusFS:SetTextColor(r, g, b) end
end

function ns.RefreshDebug()
    if not panel or not panel:IsShown() then return end
    ns.UpdateDebugTitle()
    -- While the box has focus (you're selecting/copying) we don't rewrite the text,
    -- or it would wipe your selection, so the view "freezes". Tell the user how to resume.
    if editBox:HasFocus() then
        setStatus("PAUSED: press Esc or click the panel to resume", 1, 0.7, 0.2)
        return
    end
    -- Newest line on top, so the latest is always visible without scrolling.
    local lines = {}
    for i = #log, 1, -1 do lines[#lines + 1] = log[i] end
    editBox:SetText(table.concat(lines, "\n"))
    scroll:SetVerticalScroll(0)
    setStatus("live · newest on top", 0.4, 1, 0.4)
end

local function createSidebar()
    if panel then return panel end
    local main = _G.GuildFoundMarketFrame
    if not main then return nil end

    panel = CreateFrame("Frame", "GuildFoundMarketDebug", main, "BackdropTemplate")
    panel:SetWidth(340)
    panel:SetPoint("TOPLEFT", main, "TOPRIGHT", 6, 0)
    panel:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", 6, 0)
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    -- clicking anywhere on the panel (outside the text box) drops the edit focus and
    -- resumes the live view (an EditBox won't release focus on its own otherwise)
    panel:EnableMouse(true)
    panel:SetScript("OnMouseDown", function() if editBox then editBox:ClearFocus() end end)

    titleFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("TOP", 0, -16); ns.UpdateDebugTitle()

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() panel:Hide() end)

    statusFS = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusFS:SetPoint("TOPLEFT", 16, -62); statusFS:SetJustifyH("LEFT"); statusFS:SetText("")

    local selectBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    selectBtn:SetSize(80, 20); selectBtn:SetPoint("TOPLEFT", 16, -38); selectBtn:SetText("Select all")
    selectBtn:SetScript("OnClick", function() editBox:SetFocus(); editBox:HighlightText() end)
    local clearBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearBtn:SetSize(56, 20); clearBtn:SetPoint("LEFT", selectBtn, "RIGHT", 6, 0); clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function() wipe(log); if editBox then editBox:SetText("") end end)
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", clearBtn, "RIGHT", 8, 0); hint:SetText("then Ctrl+C")

    scroll = CreateFrame("ScrollFrame", "GuildFoundMarketDebugScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -78); scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true); editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontSmall)
    editBox:SetWidth(290)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editBox:SetScript("OnEditFocusGained", function() setStatus("PAUSED: press Esc or click the panel to resume", 1, 0.7, 0.2) end)
    editBox:SetScript("OnEditFocusLost", function() ns.RefreshDebug() end)
    scroll:SetScrollChild(editBox)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local mx = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.min(mx, math.max(0, self:GetVerticalScroll() - delta * 24)))
    end)

    panel:Hide()
    return panel
end

function ns.ToggleDebug()
    createSidebar()
    if not panel then return end
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show(); ns.RefreshDebug()
    end
end
