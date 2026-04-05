# GameIcons

A PowerShell script that builds and maintains a single **Games** folder in your Windows Start Menu, pulling from every game launcher you have installed.

It detects installed games, creates shortcuts with proper icons, repairs broken icon links, and removes stale shortcuts when games are uninstalled — all in one place.

## Screenshots

| Script Output | Start Menu Icons |
|---|---|
| ![Script output](Screenshots/output.png) | ![Start Menu icons](Screenshots/icons.png) |

## Quick Start

1. Clone or download this repository.
2. Open PowerShell in the repository root.
3. Preview what will happen (no changes written):

```powershell
.\Sync.ps1 -WhatIf
```

4. Run it for real:

```powershell
.\Sync.ps1
```

Shortcuts are written to:

```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Games
```

That's it. On the next Start Menu search, your games will appear as a unified list.

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or newer
- No external modules required

## Supported Platforms

| Platform | How Games Are Detected | Shortcut Type |
|---|---|---|
| Steam | Library manifests across all Steam library folders | `.url` |
| Epic Games | Launcher `.item` manifests | `.url` |
| Xbox Game Pass | Installed AppX packages with Xbox Live indicators | `.lnk` |
| Microsoft Store | AppX packages with game capabilities + include list | `.lnk` |
| Ubisoft Connect | Launcher metadata, shortcuts, install folders, registry | `.url` |
| Battle.net | Windows uninstall registry entries | `.lnk` |
| GOG | Windows uninstall registry entries | `.lnk` |
| itch.io | itch apps library scan for launchable executables | `.lnk` |
| EA App | Windows uninstall registry entries | `.lnk` |
| Rockstar | Windows uninstall registry entries | `.lnk` |

## Script Parameters

| Parameter | Default | Description |
|---|---|---|
| `-GamesMenu` | `%APPDATA%\...\Programs\Games` | Destination folder for all generated shortcuts |
| `-SkipIconCacheRefresh` | `$false` | Skip the Windows shell icon cache refresh at the end |
| `-SkipExplorerRestart` | `$false` | Skip restarting Explorer after the cache refresh |
| `-WhatIf` | — | Preview all changes without writing anything |

```powershell
# Use a custom folder name
.\Sync.ps1 -GamesMenu "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\My Games"

# Run without restarting Explorer
.\Sync.ps1 -SkipIconCacheRefresh -SkipExplorerRestart
```

## Configuration

All paths, exclusions, and icon preferences are set in `settings.json` at the repository root.

### Launcher Paths

If your launchers are installed in non-default locations, update the `paths` block:

```json
{
  "paths": {
    "steamInstall":    "C:\\Program Files (x86)\\Steam",
    "epicManifests":   "C:\\ProgramData\\Epic\\EpicGamesLauncher\\Data\\Manifests",
    "ubisoftInstall":  "C:\\Program Files (x86)\\Ubisoft",
    "battleNetInstall": "",
    "gogInstall":      "",
    "itchInstall":     "%APPDATA%\\itch\\apps",
    "eaAppInstall":    "",
    "rockstarInstall": "",
    "gamesMenu":       "%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Games",
    "uwpIconCache":    "UwpIconCache",
    "steamGridDbCache": "SteamGridDbCache",
    "customIconsPath": "CustomIcons"
  }
}
```

> **Notes:**
> - Environment variables (e.g. `%APPDATA%`) are expanded automatically.
> - Relative paths for cache and icon folders are resolved from the repository root.
> - The `-GamesMenu` script parameter overrides `paths.gamesMenu` in settings.

### Custom Icons

Place `.ico` files in the `CustomIcons/` folder. Name each file exactly after the game title used in the shortcut.

```
CustomIcons/
  Cyberpunk 2077.ico
  Hades II.ico
```

Custom icons always take priority over any automatically resolved icon.

### SteamGridDB Integration

The script can fetch higher-quality icons from [SteamGridDB](https://www.steamgriddb.com/) for Steam games.

**API key setup:**

Create a `.env` file in the repository root:

```
STEAMGRIDDB_API_KEY=your_api_key_here
```

Or set it as an environment variable before running:

```powershell
$env:STEAMGRIDDB_API_KEY = "your_api_key_here"
.\Sync.ps1
```

Get a free API key at [steamgriddb.com/profile/preferences/api](https://www.steamgriddb.com/profile/preferences/api).

**Pinning or excluding specific icon IDs:**

If the automatically chosen icon for a game is wrong, you can override it in `settings.json` using the Steam AppID or game name as a key:

```json
{
  "steamGridDbPreferredIconIds": {
    "1091500": "86095"
  },
  "steamGridDbExcludedIconIds": {
    "1091500": ["99999"]
  }
}
```

Icons are cached locally in `SteamGridDbCache/` and reused on subsequent runs.

### Filtering Steam Non-Games

Steam ships several non-game AppIDs (redistributables, tools). Add their IDs to exclude them:

```json
{
  "steamNonGameIds": ["228980", "1070560", "1391110"]
}
```

### Microsoft Store / Xbox Filtering

AppX packages that don't declare standard gaming capabilities won't be detected automatically. Use `includeStorePackages` to force-include them by package family name (wildcards supported):

```json
{
  "includeStorePackages": [
    "TrivialTechnology.UltimateRummy500",
    "SomePublisher.*"
  ]
}
```

Use `uwpServicePackageNames` and `msPublisherPrefixes` to exclude Microsoft system packages from appearing as games (sensible defaults are already set).

### Battle.net Product Codes

Battle.net shortcuts require a `--productcode=` argument. The `battleNetProductCodes` map in `settings.json` maps display names (lowercase) to their codes. Common Blizzard titles are pre-populated — add any missing ones:

```json
{
  "battleNetProductCodes": {
    "diablo iv": "Fen",
    "world of warcraft": "WoW"
  }
}
```

## Known Limitations

- Detection depends on each launcher's local metadata and the Windows uninstall registry. Portable installs may not appear.
- Microsoft Store and Xbox detection relies on AppX manifest capabilities, which are inconsistent across titles.
- Ubisoft can detect installs that lack a valid launch ID; those are skipped automatically.
- Some launchers change executable paths after updates — re-running the script will repair those shortcuts.
- Icon changes may not be visible immediately due to Windows shell icon caching; a restart or cache refresh resolves this.

Keys can be app IDs or game names.

Example:

```json
{
  "steamGridDbPreferredIconIds": {
    "1091500": "86095",
    "Cyberpunk 2077": "86095"
  },
  "steamGridDbExcludedIconIds": {
    "1091500": ["11111", "22222"]
  }
}
```

## SteamGridDB API Key Setup

SteamGridDB is enabled by default, but a key is optional.

Resolution order used by the script:

1. Current process environment variable STEAMGRIDDB_API_KEY.
2. User environment scope.
3. Machine environment scope.
4. Local .env file in repo root.

Set for the current terminal session:

```powershell
$env:STEAMGRIDDB_API_KEY = "your-api-key"
.\Sync.ps1
```

Persist for future terminals:

```powershell
setx STEAMGRIDDB_API_KEY "your-api-key"
```

Or use a local .env file:

```dotenv
STEAMGRIDDB_API_KEY=your-api-key
```

Security notes:

- Keep .env local and never commit real keys.
- .env.example is intended for placeholders only.
- .gitignore already excludes .env.

## Icon Resolution Priority

### Steam

Priority chain:

1. CustomIcons override.
2. SteamGridDB official style.
3. SteamGridDB official and custom styles.
4. Previously cached icon assets.
5. Local Steam client icon or library cache artwork.
6. Steam CDN artwork fallback.
7. Native game executable icon fallback.

### Epic, Xbox, Microsoft Store

1. CustomIcons override.
2. SteamGridDB preferred entry when configured by game name.
3. Platform-native icon source.

### Ubisoft, Battle.net, GOG, itch.io, EA App, Rockstar

1. CustomIcons override.
2. Game executable icon.

## Custom Icon Overrides

Place .ico or .png files in CustomIcons with a filename matching the sanitized game name.

Examples:

```text
CustomIcons/
  Halo The Master Chief Collection.ico
  Balatro.png
```

When a matching PNG exists, it is converted to ICO automatically.

## Output Statuses

The script reports one of these states per game:

| Status | Meaning |
|---|---|
| [CREATE] | Shortcut did not exist and was created |
| [OK] | Shortcut and icon are valid |
| [FIX] | Shortcut existed but target/icon/details were repaired |
| [REMOVE] | Shortcut removed because game is missing or unrecoverable |
| [SKIP] | Game could not be processed (missing source, icon, or executable) |
| [MIGRATE] | Legacy shortcut naming moved to current naming |
| [WARN] | Non-fatal warning |

## Generated Caches

| Path | Purpose |
|---|---|
| UwpIconCache | Cached ICO files from UWP package assets |
| SteamGridDbCache | Cached SteamGridDB and Steam CDN icon assets |

Both are safe to delete and will be regenerated as needed.

## Project Layout

| Path | Role |
|---|---|
| Sync.ps1 | Entry point and orchestration |
| Setup-GitHooks.ps1 | One-command setup for repo hooks and gitleaks validation |
| settings.json | Main configuration |
| Partials/Helpers.ps1 | Shared helpers and settings parsing |
| Partials/IconResolution.ps1 | SteamGridDB, image conversion, cache helpers |
| Partials/ShortcutOperations.ps1 | URL and LNK read/write helpers |
| Partials/Settings.ps1 | Runtime settings initialization and path resolution |
| Partials/Platforms | Per-platform detection and sync logic |
| CustomIcons | Optional manual icon overrides |

## Troubleshooting

### No games found for a launcher

- Verify the launcher is installed and has at least one installed game.
- Check corresponding paths in settings.json.
- For Store titles with unusual manifests, add package names to includeStorePackages.

### Icons look stale after run

- Run without SkipIconCacheRefresh so shell cache refresh executes.
- If needed, allow Explorer restart by omitting SkipExplorerRestart.

### SteamGridDB lookups fail

- Confirm STEAMGRIDDB_API_KEY is set correctly.
- Confirm network access to steamgriddb.com.
- Retry later if rate limited.

### Wrong game icon selected

- Add a custom icon in CustomIcons.
- Or pin a specific SteamGridDB ID in steamGridDbPreferredIconIds.

## Safe Operations and Secrets

- Keep secrets in environment variables or local .env only.
- Do not store real API keys in settings.json.
- Before pushing, review staged files with git diff --staged.

### Optional Pre-Commit Secret Scan (Recommended)

This repository includes a gitleaks config and sample git hook under .githooks.

Fast path (recommended):

```powershell
.\Setup-GitHooks.ps1
```

This script sets core.hooksPath and runs a staged gitleaks scan when available.

1. Install gitleaks.

```powershell
winget install Gitleaks.Gitleaks
```

2. Enable repo hooks.

```powershell
git config core.hooksPath .githooks
```

3. Test the scanner manually.

```powershell
gitleaks protect --staged --config .gitleaks.toml --redact
```

If a secret is detected, commit is blocked until the issue is fixed or intentionally allowlisted.

## License

This project is licensed under the MIT License. See LICENSE for details.