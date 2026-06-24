# Changelog

## 0.4.1

- **Find a seller by name.** The Sellers filter now also runs as a network query:
  type at least three letters and press Enter, and only sellers whose name matches
  answer — so you can locate someone even in a large confederation. Typing still
  narrows the already-listed sellers instantly client-side.
- **Scales to busy markets.** Incoming replies are coalesced so the list re-sorts
  at most a few times per second instead of once per message; a seller scan now
  collects up to 150 sellers and sellers spread their replies over a couple of
  seconds, so a crowded confederation no longer floods the client.
- **Mouse-wheel scrolling** in every list (Buy, Sellers, a seller's items, My Items).

## 0.4.0

- **Sellers tab — browse who's online.** Scan your confederation for sellers who
  are online right now (name + item count + location), then open one to see their
  full list. Catalogs are fetched on demand and chunked, so large lists are fine.
  Includes a client-side name filter.
- **Online / Offline toggle (My Items).** Pause your listings while you raid or do
  PvP without clearing anything — your client stops answering searches and seller
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
- **My Items tab:** list your offers (price optional — empty means you take bids). Your
  client answers others' searches automatically; sellers are never notified.
- Pull/search architecture (query on a hidden channel, point-to-point answers) so it scales
  to large confederations without broadcast lag.
- Self-building item database (learned + optional one-time background "Build full DB" scan),
  auto-localized.
- Minimap button; `/gfm` and `/market` slash commands.
