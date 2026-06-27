# Changelog

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
