# COD Orders: design & plan

Status: Phases 1 and 2 built. Phases 3 to 4 not started. Working design doc, expected to span
more than one session.

## 1. Problem

Sellers keep their shop open while doing other things and get whispers asking for a
Cash On Delivery (COD) mail. They want to fulfil those later, when they are back at a
mailbox. Today there is nothing to capture that request:

- If the buyer whispers "from the item" (ctrl+click puts item + price into the whisper),
  the item and price are in the line, but as soon as the buyer starts negotiating or
  asking questions the context scrolls away. The seller has to hunt back up the whisper
  history to recover which item and price it was.
- There is no place to hold a list of pending CODs, so nothing to work through at the
  mailbox.

The fix is to capture the order **structurally at request time**, independent of the chat
conversation, and to keep a per-character to-do list the seller works off at the mailbox.

## 2. Why not keyword-scraping the whisper

An earlier idea was to watch incoming whispers for a configurable keyword plus an item
link and let the seller capture with a modified click. Rejected: the item link alone
carries no sender attribution (`SetItemRef` gives the link, not who whispered it), and the
negotiation problem above still bites. The design below captures the order as data, not as
scraped text.

## 3. Concepts

- **COD order**: one pending fulfilment the seller owes a buyer: buyer + item (+ variant)
  + qty + unit price. Lives in a per-character list.
- **COD request**: a buyer asking, through GFM, for a specific listing to be COD-ed. It is
  an addon-to-addon protocol message, not a human whisper. On arrival it becomes a COD
  order on the seller and triggers a configurable human-readable confirmation whisper back
  to the buyer.
- Two ways an order enters the list:
  1. **Buyer-initiated** via a COD request (the robust path).
  2. **Seller-initiated** manual add (for orders that arrived some other way, e.g. mid
     negotiation in chat).

## 4. Data model

Orders are the seller's own mailbox work, per character, so they live in
`GuildFoundMarketCharDB` (already declared as `SavedVariablesPerCharacter` in the TOC).

```
GuildFoundMarketCharDB.codOrders = {
  {
    buyer  = "Name",       -- whisper target / recipient
    itemID = 13468,
    suffix = 0,            -- random-enchant variant (see vkey usage); 0 = none
    qty    = 5,
    unit   = 15000,        -- unit price in copper
    total  = 75000,        -- qty * unit, stored so display never recomputes wrongly
    source = "request",    -- "request" | "manual"
    added  = 1751500000,   -- epoch seconds (time())
    done   = false,
  },
  ...
}
```

Notes:
- `itemID` + `suffix` fully identify the exact stats of a random-enchant item (see the
  existing `vkey(id, suffix)` keying used across Offers/Wants/Buyers). Store `suffix` so a
  variant order mails the right item.
- Keep the list flat and append-only until marked done. Marking done removes the row (the
  seller does not need a fulfilment history in v1).

## 5. Config additions

`Services/Settings.lua` currently supports boolean and `choice` settings only. We need:

- `codAccept` (boolean, default false): "Accept COD order requests". Seller-side gate. When
  off, other GFM users do not see the "Request COD" affordance on your listings, and any
  stray request is ignored.
- `codReplyText` (**new `text` setting type**, default e.g.
  `"Got your COD order for %item x%qty, I'll mail it (%total) when I'm at a mailbox."`):
  the auto-reply whisper sent to a buyer when a request lands. Support tokens: `%item`,
  `%qty`, `%unit`, `%total`, `%buyer`.

Adding a `text` type means: extend the schema (a `type = "text"` branch), render an edit box
in the Options panel, and store the string verbatim. Small and reusable.

## 6. Components

### A. Buyer-initiated COD request (protocol + auto-reply)

This reuses the existing directed-whisper protocol (`ns.EnqueueWhisper`, the short
`R~`/`WR~`/`C~`/`K~`... message types dispatched in the browse services).

- **Buyer side**: on a seller's listing (Sellers list catalog, and the Category browser
  rows), a modified click (e.g. ctrl-click) sends a COD request to that seller for that
  exact listing. The affordance only shows if the seller advertises `codAccept` (carry a
  capability flag in the catalog/summary payload, or gate optimistically and handle a
  refusal). The request carries item + suffix + qty + unit price as seen in the listing.
- **Wire**: new message type, proposal:
  - Request: `CO~itemID~suffix~qty~unit`  (buyer -> seller)
  - Addon ack: `OA~ok`  or `OA~no~reason`  (seller -> buyer), so the buyer's client can show
    "order received" vs "seller declined / not accepting COD". Distinct from the human
    whisper below.
- **Seller side** on receiving `CO~`:
  1. If `codAccept` is off -> reply `OA~no~closed`, stop.
  2. Optionally validate the item is still in stock / still listed; if not, `OA~no~stock`.
  3. Append a COD order (`source = "request"`).
  4. Send `OA~ok` (addon) and a **human whisper** using `codReplyText` with tokens filled,
     via `SendChatMessage(text, "WHISPER", nil, buyer)`. Human whispers from addons are
     allowed without a hardware event; keep it to one line per order (no spam).
  5. Bump the COD tab badge.

Caveats:
- Seller must be online (addon loaded) to receive and ack. If the buyer gets no `OA~`
  within a short timeout, show "shop looks offline, try a normal whisper".
- One request = one order. No merging in v1.

### B. Seller-initiated manual add

For orders that arrive through negotiation in chat.

- **Entry point**: a modified click on a player name, or a right-click menu entry on the
  name. Two routes, pick per the open question in section 8:
  - Preferred if available: append "Add COD order" to the unit popup menu via
    `Menu.ModifyMenu("MENU_UNIT_...", cb)`.
  - Guaranteed fallback fully under our control: a modified click on the name in chat, or a
    small "+ COD" button on the My Items COD tab.
- **Form** (small popup): buyer name (prefilled if launched from a name), item, unit price,
  qty. Item entry by either the existing item search/browser or shift+click an item link
  from chat into the box (the My Items add-listing box already accepts shift-clicked
  links; reuse that input path). Total is computed.
- Saving appends a COD order with `source = "manual"`.

### C. COD orders tab (My Items view)

- Add a "COD" tab next to the existing WTB tab on the My Items view.
- Show a count badge so a seller returning to town sees "COD (3)".
- Each row: buyer, item (icon + link), qty, unit, total, age. Row actions:
  - **Send** (mailbox assist, section D),
  - **Done** (removes the row),
  - **Remove** (cancel without mailing),
  - **Whisper** the buyer.
- Empty state explains how orders arrive (buyers requesting, or manual add).

### D. Mailbox send-assist

Feasible: Postal does exactly this on Classic Era. Important correction: `SetSendMailCOD()`
does **not** exist on 1.15; COD is set through the send-mail frames.

Trigger: the seller is at a mailbox (`MAIL_SHOW`) on the Send tab and clicks **Send** on a
COD order row. We pre-fill and let the seller press the real Send button (real gold/items,
so a human confirm is deliberate). Steps:

1. Recipient: `SendMailNameEditBox:SetText(buyer)`.
2. Attach the item: locate bag+slot for `itemID`+`suffix` (reuse `Services/BagSearch.lua`),
   then `C_Container.UseContainerItem(bag, slot)` while the Send frame is shown to attach it.
3. COD: turn off the "send money" radio first, then enable COD and set the amount to
   `total`, via the COD button + money input frame (the exact frame names are the open
   question in section 8; Postal is the reference).
4. Subject/body: a short auto subject (e.g. item name) is nice-to-have.

Caveats:
- Only works standing at a mailbox on the Send tab; otherwise the Send action shows "open a
  mailbox first".
- Item must be in bags; if not found, tell the seller.
- Keep it one order per mail. The old "COD applies to first item only with multiple
  attachments" quirk is a vanilla 1.12 limitation; a single-item order avoids it entirely.
- If any of this proves unreliable on Era, the fallback is unchanged: the seller mails by
  hand and hits **Done** to clear the row.

## 7. Protocol summary (new)

| Dir | Message | Meaning |
| --- | --- | --- |
| buyer -> seller | `CQ~itemID~suffix` | how many of this do I already have on order with you? |
| seller -> buyer | `CQR~itemID~suffix~qty~cap` | outstanding qty (0 = none) + cap = max I can still promise (`-1` = uncapped) |
| buyer -> seller | `CO~itemID~suffix~qty~unit` | request a COD (qty 0 = cancel my order for this item) |
| seller -> buyer | `OA~ok~~itemID~suffix` | order accepted and queued (reason field empty) |
| seller -> buyer | `OA~no~reason~itemID~suffix` | declined (`closed` / `stock` / `price`) |
| seller -> buyer | `OA~cancelled~~itemID~suffix` | cancel done: the order was dropped |
| seller -> buyer | `OA~nocancel~~itemID~suffix` | cancel had nothing to drop (no such order) |
| seller -> buyer | human whisper (`codReplyText`) | readable confirmation |

`CQ`/`CQR` back the Alt-click qty popup: the seller's order list is the single source of truth and
can't be mirrored to the buyer, so the buyer reads the current outstanding qty live (via `CQR`) and
the popup prefills it, rather than persisting a buyer-side copy that would drift. Own shop / self-test
resolves the query locally with no wire traffic; an unanswered `CQ` times out (~2s) and the popup
opens as a fresh order.

`OA` keeps uniform field positions (status, reason, itemID, suffix) so the buyer can name the
item in feedback regardless of accept/decline; the reason is empty on accept.

Field order and encoding follow the existing services (each send site encodes its own line,
`~` delimited, no colons in free text). Capability advertising (does the seller accept COD)
piggybacks on the existing seller summary/catalog payload as a small flag.

## 8. Open questions to verify before building

1. **Unit popup menu on 1.15.7**: is `Menu.ModifyMenu` available and which menu tag backs the
   chat-name right-click menu? If uncertain, ship the modified-click fallback first and add
   the menu entry later.
2. **Mail frame names on Classic Era**: confirm `SendMailNameEditBox`, the COD button, the
   COD money input frame, and `C_Container.UseContainerItem` behaviour when the Send frame is
   open. Postal (`wow-vanilla-addons/Postal`) is the blueprint.
3. **Auto-reply throttling**: confirm one whisper per request is comfortably within send
   limits (it is for normal volumes; note it, do not batch).
4. **Capability flag placement**: cheapest place to advertise `codAccept` in the existing
   seller summary without a protocol bump.

## 9. Build order

Phased so each phase is independently useful and shippable.

- **Phase 1 (self-contained core)** [DONE]: data model in CharDB (`Services/CODOrders.lua`),
  the COD tab on My Items (list + "COD (n)" badge), manual add form (buyer autocompleted from the
  guild roster + item autocomplete + qty + unit price), a single "Done" action per row that clears
  it once mailed, and right-click-to-whisper the buyer. No protocol, no mailbox. Headless test at
  `tests/cod_orders.lua`. Sellers can hand-track CODs today.
- **Phase 2 (buyer-initiated)** [DONE]: `CO~`/`OA~` protocol in `Services/CODOrders.lua`,
  `codAccept` gate + configurable `codReplyText` auto-reply (new `text` setting type in the
  options panel), and an Alt-click "request a COD" affordance on the Buy results, the seller
  catalog, and the category Browse. Optimistic (no capability handshake): the seller declines
  with a reason (closed / stock / price) and the buyer's request times out if nobody answers.
  The seller's own listed price is authoritative. Headless test at `tests/cod_protocol.lua`.
- **Phase 3 (mailbox assist)**: the Send action pre-filling the send-mail frame.
- **Phase 4 (polish)**: unit popup menu entry, hover details, nicer empty/loading states.

## 10. Out of scope (v1)

- Auto-sending the mail without a human pressing Send.
- Fulfilment history / analytics.
- Merging multiple orders from the same buyer into one mail.
- Cross-character shared order list (orders are per character by design).

## 11. Touch points in the current code

- `GuildFoundMarket.toc`: a new `Services/CODOrders.lua` (data + protocol) in the load order.
- `Services/Settings.lua`: `codAccept`, `codReplyText`, and the new `text` setting type.
- `Services/Transport.lua` / the browse services: register/dispatch the `CO~` and `OA~`
  message types alongside the existing ones.
- `Services/SellerBrowse.lua`, `Services/CategoryBrowse.lua`: the "Request COD" modified
  click on a listing.
- `Services/BagSearch.lua`: reused to locate the item for mail attach.
- `UI.lua`: the COD tab on My Items, the row actions, the manual-add form, and the
  mailbox Send wiring.

## 12. Progress log and test plan

### Done so far (as of 2026-07-03)

- **Phase 1**: `Services/CODOrders.lua` data service (per-character `codOrders`, stable ids,
  add/remove/list/count); COD sub-tab on My Items with a live "COD (n)" badge; manual add form
  (buyer autocompleted from the guild roster, item autocomplete + shift-clicked links, qty, unit
  price); one "Done" action per row that clears it; right-click the item to whisper the buyer.
  Top row re-packed (pause + filter shifted right, filter narrowed) to fit the third sub-tab.
- **Phase 2**: `CO~`/`OA~` request protocol; `codAccept` seller gate; configurable `codReplyText`
  confirmation whisper (new `text` setting type rendered full-width in Options); Alt-click to
  request a COD on Buy results, seller catalog, and category Browse; seller's listed price is
  authoritative; decline reasons (closed / stock / price); buyer-side timeout when nobody answers.
  Seller logic factored into `sellerDecideCOD`, shared with a self-test path so Alt-clicking your
  own shop simulates the whole round trip locally (no wire, no self-whisper).
- **Config plumbing**: `SetSetting` no longer coerces non-boolean (`text`) settings; `ns.CoinText`
  exposed for plaintext coins in whispers.
- **Tests (headless, all green)**: `tests/cod_orders.lua` (data layer), `tests/cod_protocol.lua`
  (accept/decline paths, price authority, self-test, tokens). Synced to the Classic Era AddOns
  folder after each change.

### To test in-game (tomorrow)

Phase 1:
- [ ] COD sub-tab shows with a correct "COD (n)" badge; the top row (WTS/WTB/COD, pause, filter)
      lays out without overlap, including SELLING mode with the "Whisper" announce destination
      (the whisper box appears on the right).
- [ ] Manual add: buyer field autocompletes guild names; item field autocompletes and accepts a
      shift-clicked link; qty/unit accepted; "Add COD" adds a row; form clears.
- [ ] Row shows item / qty / COD total / buyer; "Done" removes it; right-click the item opens a
      whisper to the buyer.
- [ ] Orders persist per character across `/reload`; badge count survives.

Phase 2:
- [ ] Turn on "Accept COD order requests"; edit the confirmation whisper and confirm tokens
      (`%item %qty %unit %total %buyer`) fill in; the text field saves on Enter / focus-out.
- [ ] Self-test: open your own shop (Sellers), Alt-click a catalog item -> order appears in the
      COD tab, you see the auto-reply preview and the buyer-side confirmation. (Option must be ON,
      else you get the "closed" decline, which is also worth seeing.)
- [ ] Two characters (buyer + seller alt): buyer Alt-clicks on Buy results / seller catalog /
      category Browse -> seller's COD list gains the order + badge; buyer gets "accepted"; the
      seller's confirmation whisper actually lands in the buyer's chat.
- [ ] Decline paths land the right buyer message: option off (closed), item not listed (stock),
      bid-only listing (price).
- [ ] Timeout: Alt-click a seller who is offline or on an addon without this feature -> after ~5s
      the buyer gets "didn't confirm, try a normal whisper".

### Refinements (from first test notes, 2026-07-03) [DONE 2026-07-04]

1. **Courtesy whisper on request - dropped.** Considered a buyer -> seller human whisper on
   Alt-click, but the readable confirmation already flows the other way: the seller's client queues
   the order and whispers back its configured `codReplyText`. No buyer-side whisper is added; the
   Alt-click stays a silent addon request.
2. **Qty input on Alt-click.** Alt-click opens a small qty picker at the cursor and sends
   `RequestCOD(seller, id, suffix, qty, price)` on confirm. Built as a custom frame, NOT a
   StaticPopup: once shown from addon code, a StaticPopup taints `SendChatMessage` and the channel
   scan (`ScanSellers`) is then blocked as a protected call. Custom frames are how the rest of the
   addon does popups. The picker closes on any tab/view switch or when the window closes (a
   generation counter also drops a slow query reply that would otherwise pop onto a stale view).
3. **One order per (buyer, item) - anti-spam, made visible.** `ns.AddCODOrder` dedupes on
   (buyer, itemID, suffix) via `findOpenCOD`: an existing open order is updated in place (newest
   qty/unit authoritative, id + list position kept) instead of stacking a duplicate; a different
   suffix is a separate variant order. To make that visible to the buyer (whose client can't see the
   seller's list), the Alt-click first queries the seller (`CQ`/`CQR`, section 7) for the current
   outstanding qty and prefills the popup with it, labelling the button "Update" and showing
   "You have N on order here — change to update, 0 to cancel". No persistent buyer-side order copy:
   it would drift out of sync the moment the seller marks one done or removes it.
4. **Buyer-side cancel (qty 0).** Clearing the popup to 0 sends `CO~...~0`; the seller drops the
   matching order and acks `OA~cancelled` (or `OA~nocancel` if there was nothing on file). Lets the
   buyer retract an order without the seller having to notice and remove it by hand.
   - **Cancel link in the confirmation whisper.** The accept whisper trails a `{{GFMCOD:seller:itemID:suffix}}`
     marker (same plain-text-marker + local-rewrite trick as the shop link in `ShopLink.lua`, since the
     chat server strips real hyperlinks). The buyer's client rewrites it into a clickable `[Cancel COD]`
     link that sends the `CO~...~0` cancel on click. This is the cancel entry point that survives stock
     reservation (item 5): once a listing is fully reserved it vanishes from search/browse, so the
     whisper link is the only way left to reach it. The self-test echoes a ready-made clickable link so
     the flow is testable solo.
5. **Stock reservation on bag-synced listings.** When a listing follows the seller's bags (`track`),
   its qty is real stock, so open COD orders reserve against it. Two effects, both computed live from
   the order list (nothing is cached, so add / update up or down / done / cancel all reconcile on the
   next read):
   - **Advertised availability** drops by `ns.CODCommitted(item)` (total promised across all buyers).
     `Offers.offerList` — the single gate for search / browse / catalog / shop-link — subtracts it,
     so an item fully spoken-for by CODs stops showing as available until an order is mailed and
     cleared. Manual (untracked) listings are left as-is (soft claim, not inventory). My Items shows
     the seller's real stock with a `(N)` reserved marker and a hover note; the reduced number is
     what everyone else sees.
   - **Per-request cap** `codCap(buyer, item)` = `live qty - orders committed to OTHER buyers` (the
     buyer's own order is being replaced, not added). Reported in `CQR`; the popup caps the input
     there, snapping a too-large entry back to the max. The seller re-clamps on accept (authoritative)
     and the confirmation whisper reports the clamped qty; a fully-committed listing declines new
     buyers with `stock`. `sellerDecideCOD` reads the RAW offer (via `OfferInfo`), not the reduced
     `OfferList`, so a buyer editing their own fully-reserved order still resolves.

   Known transient: between mailing a COD and clicking Done, bag stock has dropped but the order still
   counts, so availability momentarily reads low; clicking Done reconciles it.
4. **Editable COD rows.** Each COD row has an Edit button that loads it back into the add form
   (button relabels to "Update"); `ns.EditCODOrder` mutates the record in place. Add/edit share
   `normalizeOrder` for validation.
