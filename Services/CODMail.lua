local ADDON, ns = ...

--========================================================================
-- COD mailbox send-assist (Phase 3). Standing at a mailbox, "Send" on a COD row pre-fills the
-- Blizzard Send-Mail frame: recipient, the items gathered from your bags (across multiple stacks,
-- splitting one stack for the remainder when the order doesn't line up with whole stacks), COD set
-- to the amount owed, and a subject. It stops there and leaves the real Send button for you to press, because real gold
-- and items move and the confirmation should stay a deliberate human act.
--
-- Verified against the Classic Era (1.15) Blizzard MailFrame source: we never call SendMail() or
-- SetSendMailCOD() ourselves. We drive exactly the frames the default UI drives (the COD radio via
-- SendMailRadioButton_OnClick(2) and the SendMailMoney input) and let the seller's Send press do the
-- rest. Attaching runs from the row button's click (a hardware event), which UseContainerItem needs.
-- A split remainder can't attach in that same click (the client would mail the whole source stack,
-- see CODSendAssist), so it is parked in a free bag slot and attached from a short timer poll using
-- cursor operations only, which carry no hardware-event requirement.
--========================================================================

local atMailbox = false
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("MAIL_SHOW")
    f:RegisterEvent("MAIL_CLOSED")
    f:SetScript("OnEvent", function(_, event) atMailbox = (event == "MAIL_SHOW") end)
end

-- Every bag stack of itemID with the matching random-enchant suffix (0 = plain), smallest first,
-- plus the total on hand. Reuses ns.Stock.LinkSuffix so a variant order pulls the right item, not
-- a look-alike. Smallest-first makes the gather plan consume fractured stacks before breaking
-- into full ones.
local function stacksInBags(itemID, suffix)
    suffix = suffix or 0
    local stacks, total = {}, 0
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and (ns.Stock.LinkSuffix(info.hyperlink) or 0) == suffix then
                local n = info.stackCount or 1
                stacks[#stacks + 1] = { bag = bag, slot = slot, n = n }
                total = total + n
            end
        end
    end
    table.sort(stacks, function(a, b) return a.n < b.n end)
    return stacks, total
end

-- Take whole stacks in the given order, with at most one split (always the last entry) for the
-- remainder. Callers guarantee the stacks hold at least `need` in total.
local function planFrom(stacks, need)
    local plan, remaining = {}, need
    for _, s in ipairs(stacks) do
        if remaining <= 0 then break end
        local take = math.min(s.n, remaining)
        plan[#plan + 1] = { bag = s.bag, slot = s.slot, n = s.n, take = take }
        remaining = remaining - take
    end
    return plan
end

-- Which stacks to mail for an order of `need`: a single exact-size stack when one exists (attach
-- whole, no split), else whole stacks smallest-first with at most one split for the remainder.
-- Each plan entry costs one of the mail's attachment slots; when tidy-bags-first needs too many,
-- re-plan largest-first, which provably uses the fewest stacks possible.
-- Returns { { bag, slot, n, take }, ... } (take < n only on the last entry, the split), or
-- nil + the total on hand when the bags can't cover the order, plus the slots needed when the
-- order simply doesn't fit one mail.
local function gatherPlan(itemID, suffix, need)
    local stacks, total = stacksInBags(itemID, suffix)
    if total < need then return nil, total end
    for _, s in ipairs(stacks) do
        if s.n == need then return { { bag = s.bag, slot = s.slot, n = s.n, take = need } } end
    end
    local maxSlots = ATTACHMENTS_MAX_SEND or 12
    local plan = planFrom(stacks, need)
    if #plan <= maxSlots then return plan end
    local desc = {}
    for i = 1, #stacks do desc[i] = stacks[#stacks + 1 - i] end
    plan = planFrom(desc, need)
    if #plan <= maxSlots then return plan end
    return nil, total, #plan   -- enough on hand, but not within one mail's slots
end

-- The first empty bag slot, used to park a split remainder before attaching it.
local function emptyBagSlot()
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if not C_Container.GetContainerItemInfo(bag, slot) then return bag, slot end
        end
    end
end

-- Guards the park-and-attach poll: a newer Send press invalidates the previous one's timer.
local parkToken = 0

-- Pre-fill the Send-Mail frame for a COD order. Call from the row's Send button (hardware event).
function ns.CODSendAssist(rec)
    if not rec then return end
    -- Guild Found check: every Send path funnels through here, so an unverified recipient is
    -- refused even when a caller forgot to grey its own button.
    local blocked = ns.CODSendBlocked and ns.CODSendBlocked(rec.buyer)
    if blocked then ns.Feedback(blocked, true); return end
    if not (atMailbox and MailFrame and MailFrame:IsShown()) then
        ns.Feedback("Open a mailbox first, then press Send on the order.", true); return
    end
    local itemID, suffix, qty = rec.itemID, rec.suffix or 0, math.max(1, rec.qty or 1)
    local name = GetItemInfo(itemID) or ("item:" .. tostring(itemID))
    local total = rec.total or ((rec.unit or 0) * qty)
    local plan, have, slotsNeeded = gatherPlan(itemID, suffix, qty)
    if not plan then
        if slotsNeeded then
            ns.Feedback(("%d x %s needs %d attachments and a mail holds %d. Combine part-stacks, or mail it in parts by hand and press Done after the last mail."):format(
                qty, name, slotsNeeded, ATTACHMENTS_MAX_SEND or 12), true)
        else
            ns.Feedback(("Your bags hold %d of the %d x %s ordered. Mail it by hand, then press Done."):format(have or 0, qty, name), true)
        end
        return
    end
    -- a split needs a free bag slot to park the remainder in; check before touching the frame
    local last = plan[#plan]
    local splitEntry = last.take < last.n and last or nil
    local parkBag, parkSlot
    if splitEntry then
        parkBag, parkSlot = emptyBagSlot()
        if not parkBag then
            ns.Feedback(("Splitting %d x %s off a stack needs one free bag slot. Free one up, or mail it by hand and press Done."):format(
                splitEntry.take, name), true)
            return
        end
    end
    if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end   -- Send tab
    if ClearSendMail then ClearSendMail() end                       -- clear leftover attachments/money
    SendMailNameEditBox:SetText(rec.buyer or "")
    SendMailSubjectEditBox:SetText(name)
    -- whole stacks attach via UseContainerItem, exactly like a player right-clicking them onto
    -- an open mail
    local useItem = (C_Container and C_Container.UseContainerItem) or UseContainerItem
    for i = 1, #plan - (splitEntry and 1 or 0) do useItem(plan[i].bag, plan[i].slot) end

    -- COD mode, money, feedback: shared by the whole-stacks-only path and the parked-split path.
    local function finish()
        if SendMailRadioButton_OnClick then SendMailRadioButton_OnClick(2) end   -- COD mode
        MoneyInputFrame_SetCopper(SendMailMoney, total)
        if SendMailFrame_Update then SendMailFrame_Update() end
        if SendMailFrame_CanSend then SendMailFrame_CanSend() end   -- enables the Send button
        ns.Feedback(("COD mail to %s ready: %s x%d, collect %s. Review it and press Send."):format(
            rec.buyer or "?", name, qty, GetCoinTextureString(total)), false)
        local parts = {}
        for _, p in ipairs(plan) do
            parts[#parts + 1] = ("bag %d slot %d x%d%s"):format(p.bag, p.slot, p.take, p.take < p.n and (" (split of %d)"):format(p.n) or "")
        end
        ns.Log(("COD send-assist: %s x%d -> %s, COD %s (%s)"):format(name, qty, rec.buyer or "?", total .. "c", table.concat(parts, ", ")))
    end
    if not splitEntry then finish(); return end

    -- Splitting straight onto the mail over-attaches: with the split still in flight to the
    -- server, the client attaches the WHOLE source stack (observed in-game on 1.15). So park the
    -- remainder in a free bag slot first, wait for the server to materialize it, then attach the
    -- parked stack whole - by then the stack IS exactly the remainder, so nothing can over-attach.
    ClearCursor()                                              -- a stray cursor item would corrupt the split
    local split = (C_Container and C_Container.SplitContainerItem) or SplitContainerItem
    local pickup = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
    split(splitEntry.bag, splitEntry.slot, splitEntry.take)    -- the remainder rides the cursor...
    pickup(parkBag, parkSlot)                                  -- ...and lands in the parked slot
    parkToken = parkToken + 1
    local token, tries = parkToken, 0
    local function tick()
        if token ~= parkToken then return end                  -- superseded by a newer Send press
        if not (atMailbox and MailFrame and MailFrame:IsShown()) then ClearCursor(); return end
        local info = C_Container.GetContainerItemInfo(parkBag, parkSlot)
        if info and info.itemID == itemID and (ns.Stock.LinkSuffix(info.hyperlink) or 0) == suffix
            and (info.stackCount or 0) == splitEntry.take and not info.isLocked then
            pickup(parkBag, parkSlot)                          -- cursor ops only: safe from a timer
            for i = 1, (ATTACHMENTS_MAX_SEND or 12) do
                if not HasSendMailItem(i) then ClickSendMailItemButton(i); finish(); return end
            end
            ClearCursor()
            ns.Feedback("Couldn't attach the items (mail attachment slots full?). Attach them by hand.", true)
            return
        end
        tries = tries + 1
        if tries >= 20 then                                    -- ~2s and the split never landed
            ns.Feedback(("The remaining %d x %s didn't split in time. Drag it onto the mail yourself, then press Send."):format(
                splitEntry.take, name), true)
            return
        end
        C_Timer.After(0.1, tick)
    end
    C_Timer.After(0.1, tick)
end
