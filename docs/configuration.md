# Configuration

All behavior is controlled by `settings.json` in the repository root.

## Launcher Paths

If your launchers are installed in non-default locations, update the `paths` block. Leave any value empty (`""`) to skip detection for that platform.

```json
{
  "paths": {
    "steamInstall":     "C:\\Program Files (x86)\\Steam",
    "epicManifests":    "C:\\ProgramData\\Epic\\EpicGamesLauncher\\Data\\Manifests",
    "ubisoftInstall":   "C:\\Program Files (x86)\\Ubisoft",
    "battleNetInstall": "",
    "gogInstall":       "",
    "itchInstall":      "%APPDATA%\\itch\\apps",
    "eaAppInstall":     "",
    "rockstarInstall":  "",
    "gamesMenu":        "%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Games",
    "uwpIconCache":     "UwpIconCache",
    "steamGridDbCache": "SteamGridDbCache",
    "customIconsPath":  "CustomIcons"
  }
}
```

> - Environment variables (e.g. `%APPDATA%`) are expanded automatically.
> - Relative paths for cache and icon folders are resolved from the repository root.
> - The `-GamesMenu` script parameter overrides `paths.gamesMenu`.

## Custom Icons

Place `.ico` files in the `CustomIcons/` folder named exactly after the game title as it appears in the shortcut.

```
CustomIcons/
  Cyberpunk 2077.ico
  Hades II.ico
```

Custom icons always take priority over any automatically resolved icon.

## Filtering Steam Non-Games

Steam ships several non-game AppIDs (redistributables, tools). Add their numeric IDs to exclude them:

```json
{
  "steamNonGameIds": ["228980", "1070560", "1391110"]
}
```

## Microsoft Store / Xbox Filtering

AppX packages that don't declare standard gaming capabilities won't be detected automatically. Use `includeStorePackages` to force-include them by package family name prefix (wildcards supported):

```json
{
  "includeStorePackages": [
    "TrivialTechnology.UltimateRummy500",
    "SomePublisher.*"
  ]
}
```

`uwpServicePackageNames` and `msPublisherPrefixes` control which Microsoft system packages are excluded from game detection. Sensible defaults are already set — only edit these if something unexpected appears in your Games folder.

## Battle.net Product Codes

Battle.net shortcuts require a `--productcode=` argument. The `battleNetProductCodes` map matches display names (lowercase) to their codes. Common Blizzard titles are pre-populated — add any missing ones using the same format:

```json
{
  "battleNetProductCodes": {
    "diablo iv":         "Fen",
    "world of warcraft": "WoW",
    "starcraft ii":      "S2"
  }
}
```
