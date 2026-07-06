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

-- Find every bag stack of itemID with the matching random-enchant suffix (0 = plain), largest
-- first so a multi-stack order uses as few attachment slots (and splits) as possible. Reuses
-- ns.Stock.LinkSuffix so a variant order pulls the right item, not a look-alike.
local function findStacks(itemID, suffix)
    suffix = suffix or 0
    local stacks = {}
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and (ns.Stock.LinkSuffix(info.hyperlink) or 0) == suffix then
                stacks[#stacks + 1] = { bag = bag, slot = slot, n = info.stackCount or 1 }
            end
        end
    end
    table.sort(stacks, function(a, b) return a.n > b.n end)
    return stacks
end

-- Find an empty bag slot to split into. Returns bag, slot or nil.
local function findEmptySlot()
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if not C_Container.GetContainerItemInfo(bag, slot) then return bag, slot end
        end
    end
end

-- Split `qty` off the stack at (bag, slot) into an empty bag slot, then attach that new stack
-- whole once the server confirms it landed. Splitting straight onto the cursor and clicking a
-- mail attachment slot attaches the WHOLE source stack instead of the split amount on this
-- client, so the split must land in a bag slot first and be attached from there, not off the
-- cursor. Returns true once the attach is queued (it may complete a moment later).
local function splitAndAttach(bag, slot, qty, itemID, suffix)
    local eb, es = findEmptySlot()
    if not eb then return false end   -- no empty bag slot to split into; attach short
    local split = (C_Container and C_Container.SplitContainerItem) or SplitContainerItem
    local pickup = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
    local useItem = (C_Container and C_Container.UseContainerItem) or UseContainerItem
    local after = (C_Timer and C_Timer.After) or function(_, fn) fn() end
    split(bag, slot, qty)          -- qty now rides the cursor
    pickup(eb, es)                 -- drop the split stack into the empty bag slot
    local tries = 0
    local function confirm()
        tries = tries + 1
        local info = C_Container.GetContainerItemInfo(eb, es)
        if info and info.itemID == itemID and (ns.Stock.LinkSuffix(info.hyperlink) or 0) == suffix
            and info.stackCount == qty then
            useItem(eb, es)
        elseif tries < 10 then
            after(0.2, confirm)     -- new stack not confirmed by the server yet
        end
    end
    confirm()
    return true
end

-- Attach `need` of the item to the open Send-Mail frame, pulling from `stacks` (largest first)
-- until it's covered: whole stacks attach as-is, and at most one final stack is split down to
-- the leftover. Never over-attaches: the buyer pays COD for `need` and must receive exactly that.
-- Returns how many were attached, short of `need` if bag stock or an empty bag slot runs out.
local function attach(stacks, need, itemID, suffix)
    local useItem = (C_Container and C_Container.UseContainerItem) or UseContainerItem
    local remaining = need
    for _, st in ipairs(stacks) do
        if remaining <= 0 then break end
        if st.n <= remaining then
            useItem(st.bag, st.slot)
            remaining = remaining - st.n
        elseif splitAndAttach(st.bag, st.slot, remaining, itemID, suffix) then
            remaining = 0
        end
    end
    return need - remaining
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
    local stacks = findStacks(itemID, suffix)
    local have = 0
    for _, st in ipairs(stacks) do have = have + st.n end
    if have < qty then
        ns.Feedback(("Couldn't find %d x %s in your bags. Mail it by hand, then press Done."):format(qty, name), true)
        return
    end
    if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end   -- Send tab
    if ClearSendMail then ClearSendMail() end                       -- clear leftover attachments/money
    SendMailNameEditBox:SetText(rec.buyer or "")
    SendMailSubjectEditBox:SetText(name)
    if attach(stacks, qty, itemID, suffix) < qty then
        ns.Feedback("Couldn't attach the full amount (no free bag slot to split into?). Attach the rest by hand.", true)
        return
    end
    if SendMailRadioButton_OnClick then SendMailRadioButton_OnClick(2) end   -- COD mode
    MoneyInputFrame_SetCopper(SendMailMoney, total)
    if SendMailFrame_Update then SendMailFrame_Update() end
    if SendMailFrame_CanSend then SendMailFrame_CanSend() end       -- enables the Send button
    ns.Feedback(("COD mail to %s ready: %s x%d, collect %s. Review it and press Send."):format(
        rec.buyer or "?", name, qty, GetCoinTextureString(total)), false)
    ns.Log(("COD send-assist: %s x%d -> %s, COD %s (%d stack(s))"):format(name, qty, rec.buyer or "?", total .. "c", #stacks))
end
