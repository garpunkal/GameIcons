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

Preview changes without writing anything:

```powershell
.\Update-GameIcons.ps1 -WhatIf
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `SteamInstall` | `C:\Program Files (x86)\Steam` | Path to your Steam installation |
| `SteamMenu` | `%APPDATA%\...\Programs\Steam` | Start Menu folder for Steam shortcuts |
| `EpicMenu` | `%APPDATA%\...\Programs\Epic Games` | Start Menu folder for Epic shortcuts |
| `EpicManifests` | `C:\ProgramData\Epic\...\Manifests` | Path to Epic launcher manifests |
| `XboxMenu` | `%APPDATA%\...\Programs\Xbox` | Start Menu folder for Xbox shortcuts |
| `MsStoreMenu` | `%APPDATA%\...\Programs\Microsoft Store` | Start Menu folder for Store game shortcuts |
| `UwpIconCache` | `.\UwpIconCache` | Folder where extracted UWP logos are cached as `.ico` files |
| `IncludeStorePackages` | `@()` | Package name patterns to force-include in the MS Store section (see below) |
| `CustomIconsPath` | `.\CustomIcons` | Folder for custom icon overrides (see below) |

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

---

## Including Store Games Without Gaming Capabilities

Some Microsoft Store games don't declare any gaming capabilities in their manifest (e.g. games built with certain Unity or web-based frameworks). These won't be auto-detected by the Store section.

To force-include them, add their package `Name` (one per line) to `IncludeStorePackages.txt` next to the script. Wildcards are supported.

```
# IncludeStorePackages.txt
TrivialTechnology.UltimateRummy500
SomePublisher.*
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
| `[SKIP]` | Could not create/fix — no icon source or executable found |

---

## Generated Files

| Path | Purpose |
|---|---|
| `UwpIconCache/` | Cached `.ico` files extracted from UWP package assets. Safe to delete — regenerated on next run. |
| `CustomIcons/` | Your custom icon overrides. Not touched by the script. |
| `IncludeStorePackages.txt` | Opt-in list for Store games without gaming capabilities. |

---

## License

[MIT](LICENSE)
