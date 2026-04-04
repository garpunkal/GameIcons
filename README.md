# GameIcons

A robust PowerShell script that automatically syncs your installed game libraries across multiple launchers to Start Menu shortcuts. Features intelligent icon resolution, progress tracking, and comprehensive error handling.
- **Steam** — reads all library folders and installed game manifests
- **Epic Games** — reads the launcher manifest folder
- **Xbox Game Pass** — enumerates installed AppX packages via Xbox Live / `ms-xbl-*` capability detection
- **Microsoft Store** — enumerates installed AppX packages via gaming capability detection, with an opt-in list for games that declare no standard gaming capabilities
- **Ubisoft Connect** — reads game manifests from the Ubisoft Game Launcher data folder
- **Battle.net** — discovers installed Blizzard titles from uninstall registry entries
- **GOG** — discovers installed GOG games from uninstall registry entries
- **itch.io** — scans the itch apps library for launchable executables
- **EA App** — discovers installed EA titles from uninstall registry entries
- **Rockstar** — discovers installed Rockstar titles from uninstall registry entries

## ✨ Features

- **Multi-Platform Support**: Syncs games from Steam, Epic Games, Xbox Game Pass, Microsoft Store, Ubisoft Connect, Battle.net, GOG, itch.io, EA App, and Rockstar
- **Intelligent Icon Resolution**: Priority-based icon lookup (Custom → SteamGridDB → Local assets → Fallback)
- **Progress Tracking**: Visual progress bars for long-running operations
- **Robust Error Handling**: Retry logic for network operations, graceful failure recovery
- **WhatIf Support**: Preview changes before execution
- **Custom Icon Overrides**: Drop custom icons to override auto-detected ones

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later
- No external modules required

## � Quick Start

1. Download `Sync.ps1` and place it in a folder
2. **Optional**: Edit `settings.json` to customize paths for game installations and Start Menu folders
3. Open PowerShell as Administrator
4. Navigate to the script folder
5. Run: `.\Sync.ps1 -WhatIf` (preview mode)
6. Run: `.\Sync.ps1` (to create shortcuts)

For Steam icons, get an API key from [SteamGridDB](https://www.steamgriddb.com) and set it in your environment:
```powershell
$env:STEAMGRIDDB_API_KEY = 'your-api-key-here'
.\Sync.ps1
```

### Configuration

The script can be configured via `settings.json`:

- **Game Paths**: Set custom paths for game installations (e.g., `"ubisoftInstall": "S:\\ubisoft"`)
- **Menu Path**: Set a single destination folder via `gamesMenu`
- **Cache Paths**: Configure where icons and cache files are stored
- **Exclusions**: Define games to skip or custom icon preferences

Example `settings.json`:
```json
{
  "paths": {
    "steamInstall": "C:\\Program Files (x86)\\Steam",
    "ubisoftInstall": "S:\\ubisoft",
    "battleNetInstall": "C:\\Program Files (x86)\\Battle.net",
    "gogInstall": "D:\\GOG Galaxy\\Games",
    "itchInstall": "%APPDATA%\\itch\\apps",
    "eaAppInstall": "C:\\Program Files\\EA Games",
    "rockstarInstall": "C:\\Program Files\\Rockstar Games",
    "gamesMenu": "%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Games"
  }
}
```

## 🏗️ Architecture

The script uses a modular architecture with separate files for different concerns:

- `Sync.ps1` - Main orchestrator script
- `Partials/Helpers.ps1` - Utility functions for parsing, names, and discovery
- `Partials/IconResolution.ps1` - Icon downloading and caching logic
- `Partials/ShortcutOperations.ps1` - Shortcut creation and management
- `Partials/Settings.ps1` - Configuration loading and menu path setup
- `Partials/Platforms/` - Platform-specific game detection logic

---

## Usage

```powershell
.\Sync.ps1
```

You can also run it explicitly with PowerShell 7:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Sync.ps1
```

All generated shortcuts are written to a dedicated Games Start Menu folder:

```powershell
.\Sync.ps1
```

This defaults to:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Games
```

Choose a custom final destination folder:

```powershell
.\Sync.ps1 -GamesMenu "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\My Games"
```

Preview changes without writing anything:

```powershell
.\Sync.ps1 -WhatIf
```

SteamGridDB support is enabled by default. Set the API key once via environment variable:

```powershell
$env:STEAMGRIDDB_API_KEY = '<your-api-key>'
.\Sync.ps1
```

To persist it for future terminals and logins (recommended):

```powershell
setx STEAMGRIDDB_API_KEY "<your-api-key>"
```

Then open a new terminal before running the script again.

If a `.env` file exists next to the script with `STEAMGRIDDB_API_KEY=...`,
the script auto-loads it when no environment key is set.

```dotenv
STEAMGRIDDB_API_KEY=<your-api-key>
```

Advanced SteamGridDB/cache behavior can be controlled through `settings.json`.

By default, the script triggers a Windows icon cache refresh and then restarts
Explorer at the end.

Disable both steps if needed:

```powershell
.\Sync.ps1 -SkipIconCacheRefresh
```

Disable only the Explorer restart while keeping icon cache refresh:

```powershell
.\Sync.ps1 -SkipExplorerRestart
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `GamesMenu` | `%APPDATA%\...\Programs\Games` | Single destination folder for all generated shortcuts |
| `SkipIconCacheRefresh` | `False` | Skips the final Windows icon cache refresh step |
| `SkipExplorerRestart` | `False` | Skips restarting Explorer after icon cache refresh |

Most advanced behavior (launcher paths, include lists, cache paths, icon settings) is configured in `settings.json`.

---

## Custom Icon Overrides

Drop a `<GameName>.ico` or `<GameName>.png` into the `CustomIcons/` folder to override the auto-detected icon for any game.

The filename must match the game's name with invalid filename characters removed (the same sanitisation the script uses for shortcut filenames). For example:

```
CustomIcons/
  Halo The Master Chief Collection.ico
  Balatro.png
```

Free high-quality icons can be downloaded from [SteamGridDB](https://www.steamgriddb.com) (use the **Icons** tab and choose ICO or PNG format).

When both a custom icon and SteamGridDB are available, `CustomIcons` takes priority.

---

## Including Store Games Without Gaming Capabilities

Some Microsoft Store games don't declare any gaming capabilities in their manifest (e.g. games built with certain Unity or web-based frameworks). These won't be auto-detected by the Store section.

To force-include them, add their package `Name` to the `includeStorePackages` array in `settings.json`. Wildcards are supported.

```json
{
  "includeStorePackages": [
    "TrivialTechnology.UltimateRummy500",
    "SomePublisher.*"
  ]
}
```

To find a package name for an installed Store app:

```powershell
Get-AppxPackage | Where-Object { $_.Name -match 'keyword' } | Select-Object Name, PackageFamilyName
```

---

## Ubisoft Connect Support

The script automatically detects Ubisoft Connect installations and reads game manifests from:

```text
%LOCALAPPDATA%\Ubisoft Game Launcher\games
```

It parses `game.json` and `installation.json` files to extract game metadata and creates `uplay://launch/{game_id}` URL shortcuts.

Ubisoft Connect games use the following icon resolution priority:
1. Custom icons from `CustomIcons/` folder
2. Ubisoft game executable icon as fallback

Ubisoft shortcuts are created only for entries that have a valid Ubisoft game id.

## Battle.net Support

Battle.net games are detected from Windows uninstall registry entries for Blizzard and Activision titles.

Battle.net shortcuts are created as `.lnk` files pointing to each game's local executable, with icon resolution priority:
1. Custom icons from `CustomIcons/` folder
2. Game executable icon as fallback

If your games are installed in a non-default location, set `paths.battleNetInstall` in `settings.json`.

## GOG Support

GOG games are detected from Windows uninstall registry entries and filtered to game entries (excluding Galaxy launcher/update components).

GOG shortcuts are created as `.lnk` files pointing to each game's local executable, with icon resolution priority:
1. Custom icons from `CustomIcons/` folder
2. Game executable icon as fallback

If your games are installed in a non-default location, set `paths.gogInstall` in `settings.json`.

## itch.io Support

itch.io games are discovered by scanning the itch apps folder (default: `%APPDATA%\itch\apps`) for launchable `.exe` files.

itch.io shortcuts are created as `.lnk` files with icon resolution priority:
1. Custom icons from `CustomIcons/` folder
2. Game executable icon as fallback

If your itch library is in a custom location, set `paths.itchInstall` in `settings.json`.

## EA App Support

EA App games are detected from Windows uninstall registry entries and filtered to game entries (excluding launcher/installer components).

EA App shortcuts are created as `.lnk` files with icon resolution priority:
1. Custom icons from `CustomIcons/` folder
2. Game executable icon as fallback

If your EA library is in a custom location, set `paths.eaAppInstall` in `settings.json`.

## Rockstar Support

Rockstar games are detected from Windows uninstall registry entries and filtered to game entries (excluding launcher/Social Club components).

Rockstar shortcuts are created as `.lnk` files with icon resolution priority:
1. Custom icons from `CustomIcons/` folder
2. Game executable icon as fallback

If your Rockstar library is in a custom location, set `paths.rockstarInstall` in `settings.json`.

---

## Output

Each game is reported with one of these statuses:

| Status | Meaning |
|---|---|
| `[CREATE]` | Shortcut did not exist — created |
| `[OK]` | Shortcut exists with a valid icon |
| `[FIX]` | Shortcut existed but had a broken or outdated icon path — fixed |
| `[REMOVE]` | Shortcut exists for a game no longer installed — removed |
| `[SKIP]` | Could not create/fix — no icon source or executable found |

---

## Generated Files

| Path | Purpose |
|---|---|
| `UwpIconCache/` | Cached `.ico` files extracted from UWP package assets. Safe to delete — regenerated on next run. |
| `SteamGridDbCache/` | Cached SteamGridDB icon assets. Safe to delete — regenerated on next run. |
| `CustomIcons/` | Your custom icon overrides. Not touched by the script. |
| `settings.json` | Consolidated settings: exclusion lists, publisher prefixes, SGDB icon exclusions, and Store package overrides. |

## 🐛 Troubleshooting

### Common Issues

**"Access denied" or permission errors:**
- Run PowerShell as Administrator
- Ensure the script directory is writable

**Steam games not detected:**
- Verify `paths.steamInstall` in `settings.json`
- Check that Steam is installed and has games

**Icons not downloading:**
- Verify SteamGridDB API key is correct
- Check internet connection
- Clear `SteamGridDbCache/` to force a re-download

**Script runs slowly:**
- First run downloads icons and may take time
- Subsequent runs are faster due to caching

**Ubisoft Connect not detected:**
- Ensure Ubisoft Connect is installed
- Check that games are installed through Ubisoft Connect

**Battle.net games not detected:**
- Ensure games are installed through Battle.net and appear in Apps & Features
- Set `paths.battleNetInstall` if your Blizzard games are on a custom drive

**GOG games not detected:**
- Ensure games are installed and visible in Apps & Features
- Set `paths.gogInstall` if your GOG library is on a custom drive

**itch.io games not detected:**
- Ensure games are installed through the itch desktop app
- Set `paths.itchInstall` if your itch apps library is on a custom drive

**EA App games not detected:**
- Ensure games are installed and visible in Apps & Features
- Set `paths.eaAppInstall` if your EA library is on a custom drive

**Rockstar games not detected:**
- Ensure games are installed and visible in Apps & Features
- Set `paths.rockstarInstall` if your Rockstar library is on a custom drive

### Getting Help

- Use `-WhatIf` to preview changes without making them
- Check the output for `[ERROR]`, `[WARN]`, or `[SKIP]` messages
- Review `settings.json` for configuration issues

---

## License

[MIT](LICENSE)
