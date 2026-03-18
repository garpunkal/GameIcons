# GameIcons

A PowerShell script that syncs your installed game libraries to Start Menu shortcuts, creating missing shortcuts and fixing broken icon paths.

Supports:
- **Steam** — reads all library folders and installed game manifests
- **Epic Games** — reads the launcher manifest folder
- **Xbox Game Pass** — enumerates installed AppX packages via Xbox Live / `ms-xbl-*` capability detection
- **Microsoft Store** — enumerates installed AppX packages via gaming capability detection, with an opt-in list for games that declare no standard gaming capabilities

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later
- No external modules required

---

## Usage

```powershell
.\Update-GameIcons.ps1
```

You can also run it explicitly with PowerShell 7:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Update-GameIcons.ps1
```

Put all generated shortcuts into a dedicated Games Start Menu folder:

```powershell
.\Update-GameIcons.ps1 -UseGamesFolderForAll
```

This defaults to:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Games
```

Choose a custom final destination folder:

```powershell
.\Update-GameIcons.ps1 -UseGamesFolderForAll -GamesMenu "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\My Games"
```

Legacy mode (puts non-Steam shortcuts in Steam folder):

```powershell
.\Update-GameIcons.ps1 -UseSteamFolderForAll
```

If both switches are provided, `-UseGamesFolderForAll` takes precedence.

Preview changes without writing anything:

```powershell
.\Update-GameIcons.ps1 -WhatIf
```

Use SteamGridDB for Steam icon downloads (falls back to local Steam artwork when needed):

```powershell
.\Update-GameIcons.ps1 -UseSteamGridDb -SteamGridDbApiKey '<your-api-key>'
```

Or set the API key once via environment variable:

```powershell
$env:STEAMGRIDDB_API_KEY = '<your-api-key>'
.\Update-GameIcons.ps1 -UseSteamGridDb
```

To persist it for future terminals and logins (recommended):

```powershell
setx STEAMGRIDDB_API_KEY "<your-api-key>"
```

Then open a new terminal before running the script again.

If a `.env` file exists next to the script with `STEAMGRIDDB_API_KEY=...`,
the script now auto-loads it when no explicit/environment key is already set.

```dotenv
STEAMGRIDDB_API_KEY=<your-api-key>
```

To have the script persist the resolved key to your User environment:

```powershell
.\Update-GameIcons.ps1 -UseSteamGridDb -PersistSteamGridDbApiKey
```

Force refresh of cached SteamGridDB icons:

```powershell
.\Update-GameIcons.ps1 -UseSteamGridDb -RefreshSteamGridDb
```

By default, the script triggers a Windows icon cache refresh and then restarts
Explorer at the end.

Disable both steps if needed:

```powershell
.\Update-GameIcons.ps1 -SkipIconCacheRefresh
```

Disable only the Explorer restart while keeping icon cache refresh:

```powershell
.\Update-GameIcons.ps1 -SkipExplorerRestart
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `SteamInstall` | `C:\Program Files (x86)\Steam` | Path to your Steam installation |
| `SteamMenu` | `%APPDATA%\...\Programs\Steam` | Start Menu folder for Steam shortcuts |
| `UseGamesFolderForAll` | `False` | Routes Steam/Epic/Xbox/Microsoft Store shortcuts into the folder set by `GamesMenu` |
| `GamesMenu` | `%APPDATA%\...\Programs\Games` | Final destination folder used when `UseGamesFolderForAll` is enabled |
| `UseSteamFolderForAll` | `False` | Legacy: routes Epic/Xbox/Microsoft Store shortcuts into the same folder as `SteamMenu` |
| `EpicMenu` | `%APPDATA%\...\Programs\Epic Games` | Start Menu folder for Epic shortcuts |
| `EpicManifests` | `C:\ProgramData\Epic\...\Manifests` | Path to Epic launcher manifests |
| `XboxMenu` | `%APPDATA%\...\Programs\Xbox` | Start Menu folder for Xbox shortcuts |
| `MsStoreMenu` | `%APPDATA%\...\Programs\Microsoft Store` | Start Menu folder for Store game shortcuts |
| `UwpIconCache` | `.\UwpIconCache` | Folder where extracted UWP logos are cached as `.ico` files |
| `IncludeStorePackages` | `@()` | Package name patterns to force-include in the MS Store section (see below) |
| `SettingsPath` | `.\config\settings.json` | JSON file with exclusion lists, publisher prefixes, and other configuration |
| `CustomIconsPath` | `.\CustomIcons` | Folder for custom icon overrides (see below) |
| `UseSteamGridDb` | `False` | Enables Steam icon lookup from SteamGridDB before local Steam fallback |
| `SteamGridDbApiKey` | `$env:STEAMGRIDDB_API_KEY` | SteamGridDB API key (uses environment variable if omitted) |
| `DotEnvPath` | `.\.env` | Optional `.env` file path used to load `STEAMGRIDDB_API_KEY` when needed |
| `PersistSteamGridDbApiKey` | `False` | Saves resolved SteamGridDB API key to User environment for future terminals |
| `SteamGridDbCache` | `.\SteamGridDbCache` | Cache folder for SteamGridDB-downloaded icon assets |
| `RefreshSteamGridDb` | `False` | Re-download SteamGridDB assets instead of using cached files |
| `SkipIconCacheRefresh` | `False` | Skips the final Windows icon cache refresh step |
| `SkipExplorerRestart` | `False` | Skips restarting Explorer after icon cache refresh |

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

To force-include them, add their package `Name` to the `includeStorePackages` array in `config/settings.json`. Wildcards are supported.

```json
{
  "includeStorePackages": [
    "TrivialTechnology.UltimateRummy500",
    "SomePublisher.*"
  ]
}
```

You can also pass them directly via the `-IncludeStorePackages` parameter:

```powershell
.\Update-GameIcons.ps1 -IncludeStorePackages 'TrivialTechnology.UltimateRummy500'
```

To find a package name for an installed Store app:

```powershell
Get-AppxPackage | Where-Object { $_.Name -match 'keyword' } | Select-Object Name, PackageFamilyName
```

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
| `SteamGridDbCache/` | Cached SteamGridDB icon assets. Safe to delete — regenerated when `-UseSteamGridDb` is used. |
| `CustomIcons/` | Your custom icon overrides. Not touched by the script. |
| `config/settings.json` | Consolidated settings: exclusion lists, publisher prefixes, SGDB icon exclusions, and Store package overrides. |

---

## License

[MIT](LICENSE)
