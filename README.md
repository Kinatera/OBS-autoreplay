# AutoReplay

![version](https://img.shields.io/badge/version-0.1.0-1abc9c)
[![license](https://img.shields.io/badge/license-GPL%20v3%20or%20later-0078d7)](LICENSE)
![platform](https://img.shields.io/badge/platform-Windows-0078d7)
![OBS](https://img.shields.io/badge/OBS-28.x%2B-3a3a3a)

An OBS script that detects the game you're playing and sorts Replay Buffer clips into per-game folders.

## Features

- Follows the focused window: games use Game Capture or Window Capture, everything else falls back to screen capture.
- Matches games by executable name against a database of about 11,000 games, plus your own custom entries.
- Also detects Steam and Epic Games Store games from where they're installed, and Minecraft, with Prism Launcher and MultiMC instances named separately (e.g. `Minecraft (Fabulously Optimized)`).
- Moves saved replays into a folder named after the game, keeping your filename formatting.
- Optionally hard links every saved replay into a second folder, e.g. Medal.
- Downloads and keeps the game database up to date automatically.

## Installation

1. Download `auto-replay.lua` and `games_database.json` into the same folder.
2. In OBS, open **Tools → Scripts**, click **+** and pick `auto-replay.lua`.

`games_database.json` is optional: if it's missing, the script downloads it.

## Recommended Setup

1. Create a new scene just for the script, e.g. **AutoReplay**.
2. Add a **Game Capture**, a **Window Capture** and a **Display Capture** source to it. The script manages their visibility and targets, so don't use them elsewhere.
3. In the script settings, pick the **AutoReplay** scene and the three sources.
4. Add the **AutoReplay** scene as a source in your other scenes (e.g. under a webcam or overlay), or record from it directly.
5. Start the Replay Buffer and play.

## Settings

| Setting | Description |
|---|---|
| Only while the replay buffer is running | Pauses switching while the Replay Buffer is off. |
| Game database | Leave empty to use `games_database.json` next to the script. |
| Auto-update database | Checks for a newer database on load and every 6 hours. Only applies to the default database. |
| Custom games | Adds games, or overrides database entries. See [Custom games](#custom-games). |
| Never treat as a game | Ignores these executables even if they're detected as games, so they always show the screen. Useful for apps the database lists that aren't games (e.g. After Effects). |
| Keep current capture when focused | Apps that don't switch away from the game, like OBS itself. Comes pre-filled with Windows shell UI (Start, search, notification center, emoji panel, Snipping Tool, Game Bar, ...) and `windhawk-mod.exe`. The Run dialog and taskbar are always kept. |
| Move saved replays into game folders | Sorts saved replays by game. |
| Also hard link saved replays into folder | Links each saved replay into the chosen folder. Must be on the same drive. |

## Custom games

One entry per line, in the form `exe = name = capture`:

```
VALORANT-Win64-Shipping.exe = VALORANT = Game
RobloxPlayerBeta.exe = Roblox = Window
```

- `capture` is `Game` or `Window`. Use `Window` for games that block Game Capture.
- The name and capture are optional. Anything left out comes from the database, or defaults to the exe name and `Game`.
- `RobloxPlayerBeta.exe = = Window` keeps the database name and only changes the capture type.

## Game database

Each entry maps a lowercase executable name, without `.exe`, to a display name and a capture type:

```json
"robloxplayerbeta": {"name": "Roblox", "capture": "Window"}
```

`capture` is `Game` or `Window`.

When several games share an exe name (`hl2.exe`, `game.exe`, `nw.exe`, ...), the key also includes the folders the exe is in, up to five, separated by `/`. The most specific match wins:

```json
"garrysmod/hl2": {"name": "Garry's Mod", "capture": "Game"}
```

## Detection outside the database

Games the database doesn't list are still detected:

- **Steam:** exes under `steamapps\common\<game>\` take the game's name from its Steam manifest. The script asks the Steam store once per game whether it's a game or software (like Wallpaper Engine), and caches the answer in `steam_app_types.json` next to the script.
- **Epic Games Store:** exes inside an Epic game's install folder take its name from the Epic launcher's install manifests. Unreal Engine and other non-game installs are skipped.
- **Minecraft:** `java.exe`/`javaw.exe` counts as Minecraft only when it's actually running Minecraft. Prism Launcher and MultiMC instances get their instance name, e.g. `Minecraft (Fabulously Optimized)`, so each instance gets its own replay folder.

Launchers, config tools, installers and crash reporters inside store game folders are ignored.

## Contributing

If you have a game that isn't detected, or one that only works with another capture type.. please open a PR or an issue with the custom game entry you've found works for it so it works for others too!!

As an example, this is the custom game entry for Onimusha: Way of the Sword:

```
OnimushaWotS.exe = Onimusha: Way of the Sword = Game
```

**For a PR**, turn it into a line in `games_database.json` (lowercase exe, no `.exe`, alphabetical order please):

```json
"onimushawots": {"name": "Onimusha: Way of the Sword", "capture": "Game"}
```

**For an issue**, just paste the custom game entry, or list:

- the game's exe (e.g. `OnimushaWotS.exe`)
- the game's name
- the capture type that works (`Game` or `Window`)

Thank you!

## Notes

- Hard links take no extra disk space. To delete a hard linked replay, delete it from both the hard link folder and the sorted folder.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

`games_database.json` was originally sourced from [SlonickLab/Smart-Replay-Mover](https://github.com/SlonickLab/Smart-Replay-Mover/blob/main/games_database.json) (GPL-3.0).

### AI usage disclosure

This project was developed with the help of AI, though every change was reviewed and tested before being committed. (WE LOVE CONVENIENCEEE!!!)
