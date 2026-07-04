# Changelog

## 0.17.1

- **See what's new, even before you update.** When a GFM user near you runs a newer version, your
  client fetches that version's changelog from them and shows it in an overlay each time you open
  GFM, so you know what you're missing without leaving the game. Sharing is controlled by a new
  option, "Share changelog with out-of-date players" (on by default): while you're on the newest
  version you answer behind players with your bundled notes. Type `/gfm changelog` to read the notes
  at any time.
- **Never miss a COD order.** An incoming Cash On Delivery request now flashes a line on screen and
  prints one to chat, so you notice it even with the GFM window closed. Orders you add by hand don't
  notify.
- **"Accept COD order requests" is now on by default.**
- **The Options tab is reorganised.** Settings are grouped into General, Selling, Cash On Delivery,
  Shop link visibility, and Updates, and the panel now scrolls so it has room to grow.

## 0.17.0

- **Cash On Delivery orders.** A new COD tab on My Items keeps a per-character to-do list of the
  Cash On Delivery mails you owe buyers, so you can keep your shop open while you're out and send the
  mails at a mailbox later. Buyers request a COD straight from one of your listings (Alt-click a row
  on the Buy results, your shop catalogue, or the category Browse); the order lands on your list and
  the buyer gets your confirmation whisper. You can also add one by hand (buyer, item, quantity, unit
  price) when a deal happens in chat. Turn it on with "Accept COD order requests" in Options, where
  you can also edit the confirmation whisper (with a Reset to default button that restores the example
  with every placeholder).
- **The request popup knows what you already have on order.** Alt-clicking shows a small quantity box
  right away; it fills in how many of that item you already have on order with that seller, so
  changing the number updates the one order instead of stacking duplicates. On a listing that follows
  your bags it won't let a buyer order more than you actually have free, and an item fully spoken for
  by CODs drops out of search and your shop until an order is mailed or cleared.
- **Cancel from the confirmation whisper.** The seller's confirmation whisper carries a clickable
  Cancel COD link, so a buyer can drop the whole order from chat even after the item has sold out of
  the listings. Setting the quantity to 0 in the popup cancels too.
- **Mailbox send-assist.** Standing at a mailbox, the Send button on a COD row pre-fills the mail:
  recipient, the item pulled from your bags, the COD amount to collect, and a subject. You review it
  and press Send yourself, so real gold and items only move on your own click.

## 0.16.3

- **Opening a shop from an item jumps straight to that item.** When you open a seller from a Buy
  result or a Browse row, their shop now opens pre-filtered to the item you were looking at, instead
  of showing their whole catalogue. The same happens on the Buyers side: opening a buyer from a "who
  wants this?" hit filters their want list to that item. Clear the filter box to see everything, and
  opening a seller/buyer from the plain index still shows their full list. This replaces the idea of
  scrolling-and-highlighting, which was awkward while a catalogue is still loading in.
- **A one-click reset on every search and filter box.** Each search, find, and filter field now
  shows a small clear button once you've typed in it. Clicking it empties the field and resets what
  it was showing, the same as pressing Escape in the box.

## 0.16.2

- **Announce your shop note.** A new option (off by default) makes the Announce button post your
  shop note instead of the plain "Shop is open!" line. When it's on and you have a note set, the
  composed line reads `<your note> @[Name's shop]`, with the clickable shop link trailing exactly
  as before. With the option off, or no note set, the default line is unchanged. Nothing is sent
  automatically: the line still lands in your chat box for you to send yourself.

## 0.16.1

- **A player's guild shows on hover.** Hover a name wherever it appears, the Buy results, the
  Sellers and Buyers lists, "who wants this", the Browse results, and the header of an opened seller
  or buyer, and the tooltip's title reads `Name <Guild>`. It stays a hover so it never costs list
  space and needs no setting. A guild fills in once that player has answered one of your searches or
  scans this session, and only for players on this version or newer.
- **The Browse hover shows location too.** The narrow Browse seller column now reveals the seller's
  location under the name on hover, like the other lists, falling back to a location already learned
  in a Sellers scan when an older client sends none.
- **Protocol (backward compatible).** The replies whose sender we show, search (`R`), category
  browse (`QR`), the seller/buyer summaries (`C`/`WC`) and the buyer-find reply (`WR`), now append
  the responder's guild, and `QR` also appends the seller's location. The fields are append-only, so
  0.16.0 and older clients read the existing fields unchanged and keep interoperating.

## 0.16.0

- **Shop links no longer flash a Hearthstone tooltip.** The clickable "browse my shop" link used to
  carry a real Hearthstone item as a safe placeholder, which could leave its tooltip on screen (on
  hover, or if opening the shop hit an error before it was hidden). The link now uses a proper
  `addon:` hyperlink type that shows no item tooltip at all and clicks through a taint-safe
  EventRegistry callback, so the stray tooltip is gone by construction. The visible link text is
  shorter too: `[Name's shop]`.
- **Hovering a shop link previews the shop.** Hover a "browse X's shop" link in chat and GFM shows
  the seller's name and, when known, their shop note, pulling the note on demand the same way the
  Sellers list does, so you no longer have to click first.
- **Shop notes can list items, with a preview.** Shift-click an item into the Shop note field to add
  its link (within the note's length limit), and use the new Preview button to see your note exactly
  as buyers read it. Notes are shown as written.
- **A player's note loads on hover.** The chat-bubble note in the Sellers and Buyers lists now
  fetches on hover instead of needing a click; if a fetch fails (player offline) it says so, and a
  click retries.
- **WTS / WTB tabs on a player.** Opening a seller or buyer now has WTS/WTB sub-tabs (like My Items),
  so you can toggle the same player between what they sell and what they want to buy. "< Back"
  returns to wherever you started. My Items' "Selling" tab is renamed "WTS", and every WTS/WTB tab
  carries a tooltip explaining the terms.

## 0.15.2

- **Channel monitor (`/gfm channelscan`).** A diagnostic that watches your marketplace channel for
  traffic that isn't GFM's own protocol, to catch another addon (or a person) riding the same
  channel. Toggle it on to see each non-GFM line live in the Debug view; toggle it off for a
  summary (GFM vs foreign message counts, plus the busiest foreign senders and prefixes). It is
  read-only (never sends anything), matches the real hashed channel you actually join (not the
  config token or the trade-announce channel), and resets on reload.

## 0.15.1

- **Bag sync now counts your bank and mailbox too.** A Bag-sync listing's quantity is the total of
  your bags (live) plus the last-seen contents of this character's bank and mailbox, so stock you
  keep in the bank no longer parks a listing the moment you walk away. GFM snapshots the bank and
  mail whenever you open them, and never overwrites a snapshot while the source is closed, so
  walking away can't wipe it. The Bag-sync tooltip shows when each snapshot was last seen and warns
  you to open your mailbox when unread mail is waiting (it can't read mail it hasn't opened).
  Random-enchant variants and multi-item mails (one "package" with several attachments) are counted
  correctly. Stock on another character still isn't counted; leave Bag sync off for those listings.

## 0.15.0

- **Park a listing instead of removing it.** Set a listing's quantity to 0 (edit it, or let Bag
  sync empty it) to *park* it: the listing stays on your My Items tab but is hidden from everyone
  else (it stops answering searches, seller browses and shop links, and no longer counts towards a
  shop announce). Set a quantity above 0 to bring it back. Parked rows show an orange `0` and a
  footer note. Local only; no protocol change.
- **Optional per-listing "Bag sync".** Each listing has a Bag-sync toggle (a column on My Items and
  a checkbox in the compose panel): when on, GFM keeps that listing's quantity equal to how many
  you carry, falling as you sell or use them and rising as you restock; at 0 it parks, never
  deleted. Off is a manual claim, the right choice for stock kept on a bank alt, so one character
  can mix tracked and manual listings. A new Option sets the default for new listings (off by
  default). Random-enchant variants are counted separately. Reads only on settled bag updates and
  skips while the cursor holds an item or right after a loading screen, so a transient 0 can never
  wipe a listing.

## 0.14.0

- **Recent prices on item tooltips.** GFM keeps a small local snapshot of what it last saw for an
  item (from your searches, browses and seller views) and shows it on the item tooltip: seller
  count and price range, plus how long ago it was seen. Prices use a compact coloured
  gold/silver/copper notation (e.g. `1.3.34`). Items with no data yet show "alt click to scan".
  Toggle the whole thing in Options (on by default). No protocol change; data is keyed by itemID.
- **Alt-click an item to search is now on by default.** Alt + left-click an item in your bags to
  search it (and feed the price snapshot). Turn it off in Options if it clashes with a bag addon.

## 0.13.1

- **Shop note on the Buyers side.** A player's note now shows on the Buyers tab too: a chat-bubble
  in the Buyers index (click to load, hover to read) and an outlined "Note" block under an opened
  buyer's want list, mirroring the Sellers side. The note is fetched on demand and bundled with a
  buyer's want-list reply.

## 0.13.0

- **WTB (Want To Buy) / Buyers.** The buy-side counterpart to selling. My Items now has two
  sub-tabs: **Selling** (your listings) and **WTB** (items you're looking for, added via the
  search picker with qty, an optional price, and a COD checkbox). A new **Buyers** tab opens on
  **Search by item** ("who wants this?") and toggles to **Find buyer** (browse all buyers, open
  one for their full wanted list); whisper buyers straight from the list. Each Selling row gets a
  coin button that jumps to the buyers for that item. Same sort, filter and full-row-hover QoL as
  the Sellers side. Compatible with 0.12.x: the buyer queries are new messages older clients just
  don't answer, and the shared pause toggle hides both your selling and buying.
- **Find buyers/sellers beyond the live cap.** Reminder surfaced in the UI: typing in a name
  field filters the received list locally; pressing Enter (or Refresh) runs a network search that
  reaches names not in the capped first scan.
- **Compose tweaks.** Item pickers drop down with arrow-key navigation; Tab moves between fields
  (Item → Qty → Price on WTB, Qty ↔ Price on Selling).
- **Price format setting** is now a *fill* format only: you can always type either notation
  (`2g3s44c` or `3.50`) in any price field; the setting just chooses how a price is filled back in
  for you on edit.

## 0.12.0

- **Sort the item lists.** Click a column header to sort Buy search, Buy browse, the seller
  view and My Items. Qty, Price and Lvl (where shown) toggle ascending/descending; the Item
  header cycles quality descending, quality ascending, then alphabetical ascending and
  descending. Lists open alphabetically.
- **Find an item in a list.** My Items and the seller view get a "Find item:" box that filters
  the loaded items by name as you type.
- **Full-row hover highlight.** Hovering anywhere on a row now highlights the whole row, not
  just the item name.
- **Shop note.** Sellers can set a one-line note in My Items that buyers see. In the Sellers
  list a chat-bubble marks sellers who have one; click it to load the note, then hover to
  read it. Opening a seller shows the note in an outlined block at the bottom of their view.
  Compatible with 0.11.x: the scan reply carries only a tiny "has note" flag and the note
  text travels in new messages older clients ignore.

## 0.11.0

- **Browse armor by equip slot.** Armor subclasses in the Browse sidebar now expand to a
  third level by equip slot (Head, Shoulder, Chest, and so on; Neck, Finger, Trinket and
  Held In Off-hand for accessories), so you can search a single slot instead of the whole
  subclass. Robes group under Chest, and Back appears under Cloth. Subclasses without a
  useful slot split (shields, relics) still query the whole subclass. Compatible with
  0.10.x: older clients reply with the whole subclass and your client filters to the slot,
  so mixed guilds keep working.

## 0.10.0

- **Announce to more than guild chat.** The Announce button now has a destination picker:
  guild, party, whisper (with a name field that autocompletes guild members), or your
  guild's trade channel. Your last choice is remembered per character.
- **Trade channel (optional, guild setup).** Officers can name a shared trade channel in the
  guild info with `GFMtc:Name` or `GFMtc:Name:password`. Members get it as an announce
  destination and can join it in one click from the picker.
- **Hide shop-link spam.** New Options toggles to hide incoming shop-link lines per surface
  (guild, party, whispers, channels). Local to you; it changes nothing for anyone else.
- **Help tab reorganised** into Usage and Guild Setup sections.

## 0.9.2

- **Fix: shop links no longer interfere with Blizzard menus.** Making the "browse shop"
  links clickable overrode a Blizzard function, which could block protected actions like
  "Copy Name" from a right-click menu (a taint error). GFM now hooks safely instead.
- **Fix: shop links work alongside NovaWorldBuffs and Questie.** The link is now built as a
  normal item link, so those addons no longer throw an "Unknown link type" error on click.

## 0.9.1

- **Choose how you type prices.** A new "Price input format" option (in Options) lets you
  enter prices as coins (3g50s) or as decimal gold (3.50, where the two decimals are silver,
  so 3.05 = 3g5s). Search results still show the usual coin icons either way.
- **Quicker listing edits.** Editing a listing now jumps straight to the price field, and
  pressing Enter in the quantity or price box places or updates the offer (no button click).
- **Shorter minimap tooltip:** it no longer repeats your online/offline status, since the
  icon already dims while you are offline.
- **Internal cleanup:** a large maintainability refactor (the code is now split into
  focused service files). No change to how the addon behaves, and fully compatible with
  0.9.0, so mixed 0.9.0 / 0.9.1 guilds keep working together.

## 0.9.0

- **Alt-click an item to search it.** Alt + left-click any item in your bags or
  bank opens Guild Found Market and searches it instantly. Works with the default
  bags and with bag addons (Baganator, Bagnon, Combuctor, AdiBags, BetterBags).
  Turn it on in the new Options tab; disable it if it clashes with another addon.
- **New Options tab.** A gear next to Help opens Options, where you can toggle
  features on or off (the minimap button, alt-click search, and importing item
  names from aux), each with a short description on mouseover. Settings are saved
  per account.
- **Edit your listings in place.** Each item on the My Items tab has an Edit
  button that loads it into the panel below; change the quantity or price and
  click Update. No bank trip or relisting needed, since editing does not require
  the item in your bags.
- **Ctrl-click your own listings to search.** Ctrl-click an item on My Items to
  jump to the Buy tab and see who else is selling it, the same as in the Sellers
  and Browse lists.

## 0.8.2

- **Minimap right-click toggles your listings online/offline**, the same as the
  My Items pause button. The icon greys out while you are offline, and the
  tooltip shows both actions (left-click to open, right-click to toggle).
- **The marketplace channel no longer grabs channel /1.** It now joins after the
  default chat channels (General, Trade, ...) have settled, so it lands on a
  higher slot and stops shifting everyone's channel numbers.

## 0.8.1

- **Browse is now the default view** on the Buy tab. Use the toggle in the top
  right to switch to item search.
- **Fix: ctrl-click an item always opens the search.** Ctrl-clicking an item in a
  seller's list or the category browse now jumps straight to the item search
  instead of leaving you in the Browse view.

## 0.8.0

- **Browse by category.** A new Browse toggle on the Buy tab, with a Category to
  Subclass sidebar in Auction House order, lets you see every offer in a
  subcategory at once (for example Weapons then Daggers) instead of only
  searching one item by name. Results show the item (quality coloured), required
  level, quantity, price and the seller, sortable by quality, level or price,
  with a level-range and text filter. Click a seller to open their full list.
- **Version display and update notice.** Your installed version shows in the top
  right. When someone in your confederation runs a newer version, the addon tells
  you to update.
- **Fix: prices and locations no longer garble across versions.** 0.7.0 added the
  random-enchant variant by inserting a field in the middle of the search and
  catalog replies, which shifted the price and location columns for anyone still
  on 0.6.0 (prices showed "1c", locations showed a number). The field is now
  appended at the end, so 0.6.0 and 0.8.0 read each other correctly again.
- **Players on 0.7.0 must update to 0.8.0.** The 0.7.0 wire format is not
  compatible with 0.6.0 or 0.8.0; updating to 0.8.0 resolves it.

## 0.7.0

- **Random-enchant items show what you're actually buying.** A listing now
  captures the specific variant ("Scouting Tunic of the Eagle" instead of a
  generic "random enchantment"), so Buy results, seller catalogs and My Items
  show the real name and the exact stats on hover. You can list several variants
  of the same base item separately, and a search shows each seller's variant
  tagged with its suffix. Plain items are unchanged.
- **Soulbound items can't be listed.** Offering an item is blocked when every
  copy in your bags is bound (soulbound or quest-bound), since it could never be
  traded. Stock kept on a bank alt is unaffected.
- **See your own offer while searching.** When you search an item you also sell,
  your offer now appears among the results in the cheapest-first sort, marked
  "(you)", so you can see your price rank and adjust to compete. It shows even
  while your listings are paused.
- **Sortable Sellers list.** Click the Seller or Items column header to sort, and
  again to reverse; the active column shows an arrow. Defaults to most items
  first, and the name filter still works alongside the chosen sort.
- **Fix: listings no longer vanish after a loading screen.** Offers were checked
  against your inventory, and a momentary empty reading during a zone or city
  change (or while splitting a stack) could permanently delete a listing or
  shrink its quantity. A listing is now treated as your claim and is never
  auto-edited; what you actually have is settled face-to-face in the whisper. As
  a bonus you can keep stock on a bank alt and list it from your main.
- **Fix: shop links work for everyone, and search stays reliable.** Clicking a
  shop link did nothing for players also running NovaWorldBuffs or Questie, and
  an earlier click handler could taint the chat frames and intermittently block
  the addon's channel broadcasts (breaking search and the seller scan). Reworked
  to a taint-free path: links open reliably with no error, and search and the
  scan are unaffected.
- **Fix: switching tabs no longer errors** when stale rows from the previous tab
  were briefly reused during the scroll reset.

## 0.6.0

- **Announce your shop.** A new Announce button on the My Items tab drops a
  "Shop is open!" line, with a clickable shop link, into your guild chat box.
  Nothing is sent automatically (that is your call, and it keeps things spam
  free); you can add items or extra text before pressing Enter. Guild members
  running GFM see the link as a clickable button, everyone else just sees plain
  text.
- **Safe by design.** Clicking a shop link never opens the listing straight from
  the link. It runs a name filtered seller scan over your private marketplace
  channel and opens the shop only once that seller actually answers, so a shop
  can never be shown to someone outside your confederation.
- **Debug button moved.** The Debug log button now lives on the Help tab, top
  right, instead of next to the close button.

## 0.5.0

- **Season of Discovery items are now searchable.** The "Build full DB" scan fetches a
  bundled list of real SoD item IDs (derived from the Questie addon's database) instead of
  brute-forcing the 200000-250000 range, which was almost all non-existent IDs: slow and
  prone to disconnecting you. Classic items are still covered, and skipped instantly when
  the aux addon has already seeded them. Questie is not required at runtime.
- **Faster, safer database scan:** two phases (classic range + SoD list), a gentler request
  throttle, and a fix so the scan can no longer stall on stale outstanding requests.
- **Debug log + sidebar.** A copyable debug panel (the new Debug button) logs searches,
  seller browsing, offers, config, the database scan, and server throttling, so guild members
  can send a bug/latency report. Newest line on top, with a live/paused indicator.
- **Sellers tab at scale:** debounced list refresh, a scan cap with jittered replies, and a
  name-substring query to find a seller in a large confederation.
- **Item tooltips on hover** in Buy results, a seller's item list, and My Items.
- **Mouse-wheel scrolling** in every list.
- The Help tab now notes the benefit of the aux addon (instant classic item names).

## 0.4.3

- **Simpler setup.** The marketplace now needs only a single channel line, `GFMc`
  (preferred) or GreenWall's `GWc` as a fallback, with `GFMc` taking precedence. The
  peer-guild lines (`GFMp`/`GWp`) are no longer parsed or required; access is gated purely
  by who can read the channel secret. On login GFM prints which config it picked up.
- **Sister guilds.** You can now include guilds outside your GreenWall confederation simply
  by sharing the same `GFMc` line with them; no need to expose your GreenWall `GWc` secret.
- **Help tab: Configuration section.** The Help tab is now scrollable and explains the
  channel config, how to add sister guilds, and the trust consequences of sharing the secret.

## 0.4.2

- Hover any item to see its full in-game tooltip: in Buy results, a seller's item
  list, and My Items. The click hint now shows as a small line beneath it.

## 0.4.1

- **Find a seller by name.** The Sellers filter now also runs as a network query:
  type at least three letters and press Enter, and only sellers whose name matches
  answer, so you can locate someone even in a large confederation. Typing still
  narrows the already-listed sellers instantly client-side.
- **Scales to busy markets.** Incoming replies are coalesced so the list re-sorts
  at most a few times per second instead of once per message; a seller scan now
  collects up to 150 sellers and sellers spread their replies over a couple of
  seconds, so a crowded confederation no longer floods the client.
- **Mouse-wheel scrolling** in every list (Buy, Sellers, a seller's items, My Items).

## 0.4.0

- **Sellers tab: browse who's online.** Scan your confederation for sellers who
  are online right now (name + item count + location), then open one to see their
  full list. Catalogs are fetched on demand and chunked, so large lists are fine.
  Includes a client-side name filter.
- **Online / Offline toggle (My Items).** Pause your listings while you raid or do
  PvP without clearing anything; your client stops answering searches and seller
  scans, then resumes when you go back online.
- **Richer row actions.** In Buy, left-click a seller to open their item list and
  right-click to whisper. On a seller's item, right-click opens a whisper pre-filled
  with the item link and price (`[Item]@1g2s45c `), and Ctrl-click searches that
  item to find who else is selling it.
- **Help tab** documenting the first-run "Build full DB" step, the click actions,
  and the slash commands (`/gfm`, `/market`, `/gfm minimap`).

## 0.3.1

- **Fix: cross-guild search never returned offers.** GFM broadcast its queries as
  addon messages over a custom channel, but Blizzard disabled addon messages on
  custom channels in Classic patch 1.13.3, so they were silently dropped. Queries
  now ride the chat layer (a hidden, filtered chat message sent from the search
  action itself, the only context Blizzard permits), while replies stay as addon
  whispers. Both members of a confederation must run 0.3.1+ for search to work.
- Added dev-mode logging of outgoing/incoming channel traffic (`/gfm dev`).

## 0.3.0

- Minimap button is now a standard LibDBIcon launcher, so minimap-button managers
  (Leatrix Plus, etc.) can collect and hide it like any other addon icon.
- Added `/gfm minimap` to hide/show the button. The old custom-button position is
  migrated to the new icon automatically.
- Bundled the required libraries (LibStub, CallbackHandler-1.0, LibDataBroker-1.1,
  LibDBIcon-1.0) under `Libs/`.

## 0.2.0

Initial public release.

- Confederation-gated marketplace driven by a config block in the guild information
  (`GFMc`/`GFMp`, with GreenWall `GWc`/`GWp` also supported). No dependency on other addons.
- **Buy tab:** item search with multilingual, self-building autocomplete (arrow-key nav,
  quality colors, shift-click an item link to search). Live offers from online sellers,
  sorted cheapest first, showing seller, quantity, price (or "Bid") and current location.
- **My Items tab:** list your offers (price optional; empty means you take bids). Your
  client answers others' searches automatically; sellers are never notified.
- Pull/search architecture (query on a hidden channel, point-to-point answers) so it scales
  to large confederations without broadcast lag.
- Self-building item database (learned + optional one-time background "Build full DB" scan),
  auto-localized.
- Minimap button; `/gfm` and `/market` slash commands.
