# Changelog

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
