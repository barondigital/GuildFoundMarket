local ADDON, ns = ...

--========================================================================
-- COD mailbox send-assist (Phase 3). Standing at a mailbox, "Send" on a COD row pre-fills the
-- Blizzard Send-Mail frame: recipient, the item pulled from your bags, COD set to the amount owed,
-- and a subject. It stops there and leaves the real Send button for you to press, because real gold
-- and items move and the confirmation should stay a deliberate human act.
--
-- Verified against the Classic Era (1.15) Blizzard MailFrame source: we never call SendMail() or
-- SetSendMailCOD() ourselves. We drive exactly the frames the default UI drives (the COD radio via
-- SendMailRadioButton_OnClick(2) and the SendMailMoney input) and let the seller's Send press do the
-- rest. Attaching runs from the row button's click (a hardware event), which UseContainerItem needs.
--========================================================================

local atMailbox = false
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("MAIL_SHOW")
    f:RegisterEvent("MAIL_CLOSED")
    f:SetScript("OnEvent", function(_, event) atMailbox = (event == "MAIL_SHOW") end)
end

-- Find a single bag stack of itemID with the matching random-enchant suffix (0 = plain) that holds
-- at least `need`. Prefers an exact-size stack (attaches whole, no split). Returns bag, slot, count
-- or nil. Reuses ns.Stock.LinkSuffix so a variant order pulls the right item, not a look-alike.
local function findInBags(itemID, suffix, need)
    suffix, need = suffix or 0, math.max(1, need or 1)
    local more
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and (ns.Stock.LinkSuffix(info.hyperlink) or 0) == suffix then
                local n = info.stackCount or 1
                if n == need then return bag, slot, n end        -- exact: best case, no split
                if n > need and not more then more = { bag, slot, n } end
            end
        end
    end
    if more then return more[1], more[2], more[3] end
end

-- Attach `qty` of the item at (bag, slot, count) to the open Send-Mail frame. If the stack is
-- exactly qty we attach it whole; if it is larger we split qty onto the cursor and drop it into the
-- first free mail slot. Returns true on success. Never over-attaches: the buyer pays COD for qty and
-- must receive exactly qty.
local function attach(bag, slot, count, qty)
    local useItem = (C_Container and C_Container.UseContainerItem) or UseContainerItem
    if count == qty then useItem(bag, slot); return true end
    local split = (C_Container and C_Container.SplitContainerItem) or SplitContainerItem
    split(bag, slot, qty)                                  -- qty now rides the cursor
    for i = 1, (ATTACHMENTS_MAX_SEND or 12) do
        if not HasSendMailItem(i) then ClickSendMailItemButton(i); return true end
    end
    ClearCursor()                                          -- no free slot: put the split back
end

-- Pre-fill the Send-Mail frame for a COD order. Call from the row's Send button (hardware event).
function ns.CODSendAssist(rec)
    if not rec then return end
    if not (atMailbox and MailFrame and MailFrame:IsShown()) then
        ns.Feedback("Open a mailbox first, then press Send on the order.", true); return
    end
    local itemID, suffix, qty = rec.itemID, rec.suffix or 0, math.max(1, rec.qty or 1)
    local name = GetItemInfo(itemID) or ("item:" .. tostring(itemID))
    local total = rec.total or ((rec.unit or 0) * qty)
    local bag, slot, count = findInBags(itemID, suffix, qty)
    if not bag then
        ns.Feedback(("Couldn't find %d x %s in one bag stack. Mail it by hand, then press Done."):format(qty, name), true)
        return
    end
    if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end   -- Send tab
    if ClearSendMail then ClearSendMail() end                       -- clear leftover attachments/money
    SendMailNameEditBox:SetText(rec.buyer or "")
    SendMailSubjectEditBox:SetText(name)
    if not attach(bag, slot, count, qty) then
        ns.Feedback("Couldn't attach the item (mail attachment slots full?). Attach it by hand.", true)
        return
    end
    if SendMailRadioButton_OnClick then SendMailRadioButton_OnClick(2) end   -- COD mode
    MoneyInputFrame_SetCopper(SendMailMoney, total)
    if SendMailFrame_Update then SendMailFrame_Update() end
    if SendMailFrame_CanSend then SendMailFrame_CanSend() end       -- enables the Send button
    ns.Feedback(("COD mail to %s ready: %s x%d, collect %s. Review it and press Send."):format(
        rec.buyer or "?", name, qty, GetCoinTextureString(total)), false)
    ns.Log(("COD send-assist: %s x%d -> %s, COD %s (bag %d slot %d)"):format(name, qty, rec.buyer or "?", total .. "c", bag, slot))
end
