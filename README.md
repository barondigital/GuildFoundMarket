# Guild Found Market

A private, cross-guild marketplace for **guild-locked communities** in World of Warcraft
(Classic Era / Season of Discovery, e.g. Hardcore guild-locked or self-found confederations).

The real Auction House can't restrict who you buy from or sell to. Guild Found Market
keeps everything inside your **confederation**, a set of guilds you define in your guild
information, and lets you find live offers from other members. The actual handover happens
face-to-face through the normal trade window.

## How it works

- **Search (Buy tab):** type an item, pick it from the autocomplete, and online sellers in
  your confederation answer privately. You see who is selling, the quantity, the price (or
  "Bid"), and their current location, sorted cheapest first. Click a name to whisper them.
- **My Items tab:** list what you offer (item + quantity + price; leave the price empty to
  take bids). This is private to you and is what your client uses to answer other people's
  searches automatically; you are never spammed with notifications.
- **No central catalog, no spam:** searches go out over a hidden channel, and answers come
  straight back to the searcher only. This scales to large confederations without the lag
  that broadcast-everything addons cause.

It does **not** depend on any other addon and is not tied to any specific game mode or
community: any group of guilds can use it.

## Setup (guild officers)

Access is controlled by a **single line** in the **Guild Information** text
(`Guild` window → `J` → Information tab):

```
GFMc:MyMarket:somesharedsecret
```

`GFMc:<name>:<secret>` defines the private marketplace channel. GFM derives a hidden
broadcast channel from this line, and everyone whose guild information contains the
**identical** line joins the same marketplace. Pick any secret string.

The trust boundary is simply *who can read it*: only a guild's own members can read that
guild's information, so only the guilds you paste the line into take part. Put the same
`GFMc` line in **every** guild that should trade together, including **sister guilds**
outside your GreenWall confederation. Nothing else is needed; peer-guild lines (`GFMp`/`GWp`)
are not used by GFM.

**Already running GreenWall?** GFM reuses GreenWall's `GWc` channel automatically, so a
confederation works with no extra setup. When both are present, **`GFMc` takes precedence
over `GWc`**, so keep `GWc` for the GreenWall chat bridge (confederation only) and add a
shared `GFMc` line wherever you want the marketplace, sister guilds included. On login GFM
prints which config it picked up.

## Usage

- `/gfm` (or `/market`): open the window. Also available via the minimap button.
- `/gfm minimap`: hide or show the minimap button. (The button is a standard
  LibDBIcon launcher, so addons like Leatrix Plus can also collect/hide it.)
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

## Credits

The bundled Season of Discovery item-ID list (`SoDItems.lua`) is derived from the SoD item
database of the [Questie](https://github.com/Questie/Questie) addon (`sodBaseItems.lua`).
The list is generated once and shipped with this addon; **Questie is not required at runtime.**
The IDs let the database scan fetch only real SoD items instead of brute-forcing tens of
thousands of non-existent IDs. Item names still resolve in your client's language via
`GetItemInfo`, so the database stays multilingual.

## License

MIT: see [LICENSE](LICENSE).
