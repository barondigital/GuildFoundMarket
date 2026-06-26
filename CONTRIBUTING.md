# Contributing to Guild Found Market

Thanks for your interest in improving Guild Found Market. Contributions are welcome.

## How contributions work

This project accepts changes **only through pull requests** using the standard
fork-and-pull model. Nobody is added as a collaborator with direct push access to this
repository, so you do not need to be "let in" first: anyone with a GitHub account can
contribute by forking.

1. **Fork** this repository to your own GitHub account.
2. **Clone** your fork and create a branch for your change:
   ```
   git checkout -b my-change
   ```
3. **Make your change** and commit it (see the guidelines below).
4. **Push** the branch to your fork.
5. **Open a pull request** against the `main` branch of this repository.

A maintainer will review your PR and merge it when it is ready. The first time you
contribute, GitHub Actions will run only after a maintainer approves them.

## Local development

This is a World of Warcraft Classic Era addon written in Lua 5.1. There is no compiler
or package step for local work: you edit the `.lua` files and load them in the game.

- Install the addon by placing (or symlinking) the project folder as
  `World of Warcraft\_classic_era_\Interface\AddOns\GuildFoundMarket`.
- The folder must be named exactly `GuildFoundMarket`.
- Reload in-game with `/reload` after changing files. Use `/gfm` (or `/market`) to open
  the window.

### Syntax check before you push

Please verify that every Lua file still parses before opening a PR. WoW uses Lua 5.1:

```
luac5.1 -p Core.lua UI.lua ItemDB.lua SoDItems.lua Debug.lua
```

This only checks syntax, not behaviour, but it catches the most common breakages.

## Project layout

| File                 | Role                                                              |
|----------------------|-------------------------------------------------------------------|
| `GuildFoundMarket.toc` | Addon manifest: interface version, load order, saved variables. |
| `Core.lua`           | Core logic: channel handling, search and answer messaging.        |
| `UI.lua`             | The window and all interface elements.                            |
| `ItemDB.lua`         | Item database and the resumable background scan.                  |
| `SoDItems.lua`       | Generated Season of Discovery item-ID list (see README credits).  |
| `Debug.lua`          | Debug helpers.                                                     |
| `Libs/`              | Bundled third-party libraries. Do not edit these by hand.         |

Please do not hand-edit `SoDItems.lua` or anything under `Libs/`: the first is generated
and the second is vendored from upstream projects.

## Coding guidelines

- Match the style of the surrounding code: early returns, low nesting, clear names.
- Keep changes focused. One logical change per pull request makes review much easier.
- Avoid breaking the public slash commands (`/gfm`, `/market`) and saved-variable names
  (`GuildFoundMarketDB`, `GuildFoundMarketCharDB`) unless that is the point of the change.
- If your change affects user-facing behaviour, add a short note to `CHANGELOG.md` under
  an "Unreleased" heading. Leave version bumps and tagging to the maintainer.

## Commit messages

Write clear, imperative commit subjects that describe what the commit does, for example:

```
Sellers tab: sort the index by name or item count
```

## Reporting bugs and ideas

If you are not ready to send code, open an issue describing the problem or suggestion.
Include your game client (Classic Era / Season of Discovery), the addon version from the
`.toc`, and steps to reproduce where relevant.

## License

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE).
