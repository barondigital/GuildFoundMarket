# Guild Found Market

A private, cross-guild marketplace for guild-locked communities. Find live offers from people in your own guild confederation and trade face-to-face — no Auction House, no spam, no third-party services.

## Why

The Auction House can't be restricted to your own guilds, and guild-locked / self-found communities (Hardcore, Season of Discovery, ironman alliances, and similar) need a way to trade *within* their group. Guild Found Market keeps the whole marketplace inside a confederation you define in your guild information. The actual handover happens through the normal trade window.

## How it works

- **Search for an item** — start typing and pick it from the autocomplete. Only online sellers in your confederation answer your search.
- **See live offers** — who is selling, how many, the price (or "Bid" if they take offers), and the seller's current location, sorted cheapest first. Click a seller to whisper them.
- **List what you sell** — add your items in the My Items tab. Your client answers other people's searches automatically; you are never interrupted by pop-ups.

Searches are sent over a hidden channel and answers come straight back to the searcher, so it stays fast and quiet even in large communities.

This is a live, peer-to-peer marketplace — offers come straight from sellers who are online right now, with no central server storing listings. It shines once a good number of people in your confederation run it: the more active members online, the more offers you see.

## Features

- Item search with a self-building, multilingual autocomplete (arrow-key navigation, quality colors, shift-click an item link to search it).
- Live offers from online sellers, sorted by price. Set a fixed price, or leave it empty to take bids.
- A private "My Items" list that auto-answers searches — no notifications, no spam to sellers.
- Minimap button and `/gfm` (or `/market`) slash command.
- No dependency on any other addon. Not tied to any specific game mode or community.

## Setup for guild officers

Access is controlled by a small config block in your Guild Information text (Guild window, Information tab). Add a shared-secret line and one line per guild:

    GFMc:MyCommunity:somesharedsecret
    GFMp:My Main Guild:MG
    GFMp:My Second Guild:MG2

- GFMc:name:secret — only members who can read this (members of the listed guilds) can join the marketplace. Pick any secret string.
- GFMp:exact guild name:short tag — one line per guild in your confederation.

The block must be identical across all guilds in the confederation. If you already run GreenWall, its GWc/GWp config is used automatically and you don't need to add anything.

## Getting started

1. Open the window with /gfm, /market, or the minimap button.
2. In the Buy tab, type an item name and press Enter (arrow keys to navigate the suggestions). You can also shift-click an item from your bags, character sheet, a chat link, or AtlasLoot into the search box.
3. **First run — build the item database.** Autocomplete turns the item name you type into the ID used to search, and it is built locally. On a fresh install it only knows the items in your bags, so to search for things you *don't* own you need to run the one-time "Build full DB" scan first (or have aux installed, which seeds it instantly). It is a safe background scan that resumes if you stop and is only needed once. (Already own the item, or have a chat link / AtlasLoot? You can also shift-click it straight into the search box, no database needed.)
4. In the My Items tab, add the items you want to sell. That is all — your client answers other people's searches on its own.

## Good to know

- Only online sellers show up, since you trade face-to-face anyway.
- Guild Found Market helps you *find* sellers. It never trades for you and respects the game's rules.

Source and license: open source under the MIT license.
