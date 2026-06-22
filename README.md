# Guild Found Market

A private, cross-guild marketplace for **guild-locked communities** in World of Warcraft
(Classic Era / Season of Discovery, e.g. Hardcore guild-locked or self-found confederations).

The real Auction House can't restrict who you buy from or sell to. Guild Found Market
keeps everything inside your **confederation** — a set of guilds you define in your guild
information — and lets you find live offers from other members. The actual handover happens
face-to-face through the normal trade window.

## How it works

- **Search (Buy tab):** type an item, pick it from the autocomplete, and online sellers in
  your confederation answer privately. You see who is selling, the quantity, the price (or
  "Bid"), and their current location — sorted cheapest first. Click a name to whisper them.
- **My Items tab:** list what you offer (item + quantity + price; leave the price empty to
  take bids). This is private to you and is what your client uses to answer other people's
  searches automatically — you are never spammed with notifications.
- **No central catalog, no spam:** searches go out over a hidden channel, and answers come
  straight back to the searcher only. This scales to large confederations without the lag
  that broadcast-everything addons cause.

It does **not** depend on any other addon and is not tied to any specific game mode or
community — any group of guilds can use it.

## Setup (guild officers)

Access is controlled by a small config block in the **Guild Information** text
(`Guild` window → `J` → Information tab). Add a common channel line and one line per guild:

```
GFMc:MyCommunity:somesharedsecret
GFMp:My Main Guild:MG
GFMp:My Second Guild:MG2
```

- `GFMc:<name>:<secret>` — the shared secret. Only members who can read this (i.e. members of
  the listed guilds) can join the marketplace. Pick any secret string.
- `GFMp:<exact guild name>:<short tag>` — one per guild in your confederation.

The block must be **identical** across all guilds in the confederation.
GreenWall's `GWc`/`GWp` config is also supported automatically, so if you already run
GreenWall you don't need to add anything.

## Usage

- `/gfm` (or `/market`) — open the window. Also available via the minimap button.
- **Search:** start typing, use the arrow keys to navigate the dropdown, Enter to pick.
  You can also shift-click an item (bags, character sheet, chat link, AtlasLoot, …) into the
  focused search box.
- **Build full item database:** the first time, the autocomplete only knows items it has
  seen. Use the *Build full DB* button (Buy tab) once to scan in every item name in your
  language. It runs in the background and is resumable.

## Installation

1. Download from CurseForge (or extract the zip into
   `World of Warcraft\_classic_era_\Interface\AddOns\`).
2. Make sure the folder is named `GuildFoundMarket`.
3. Enable it on the character-select AddOns screen.

## License

MIT — see [LICENSE](LICENSE).
