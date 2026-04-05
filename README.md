# GameIcons

A PowerShell script that builds and maintains a single **Games** folder in your Windows Start Menu, pulling from every game launcher you have installed.

It detects installed games, creates shortcuts with proper icons, repairs broken icon links, and removes stale shortcuts when games are uninstalled — all in one place.

## Screenshots

### Script Output

![GameIcons script output](Screenshots/output.png)

### Start Menu Icons

![GameIcons Start Menu icons](Screenshots/icons.png)

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

- **[Configuration reference](docs/configuration.md)** — launcher paths, custom icons, store filtering, Battle.net product codes
- **[SteamGridDB integration](docs/steamgriddb.md)** — API key setup, icon caching, pinning and excluding specific icons

## Known Limitations

- Detection depends on each launcher's local metadata and the Windows uninstall registry. Portable installs may not appear.
- Microsoft Store and Xbox detection relies on AppX manifest capabilities, which are inconsistent across titles.
- Ubisoft can detect installs that lack a valid launch ID; those are skipped automatically.
- Some launchers change executable paths after updates — re-running the script will repair those shortcuts.
- Icon changes may not be visible immediately due to Windows shell icon caching; a restart or cache refresh resolves this.

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