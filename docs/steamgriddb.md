# SteamGridDB Integration

The script can fetch higher-quality icons from [SteamGridDB](https://www.steamgriddb.com/) for Steam games and cache them locally.

## API Key Setup

Get a free API key from [steamgriddb.com/profile/preferences/api](https://www.steamgriddb.com/profile/preferences/api).

**Option 1 — `.env` file** (recommended, persists across runs):

Create a `.env` file in the repository root:

```
STEAMGRIDDB_API_KEY=your_api_key_here
```

**Option 2 — Environment variable** (session only):

```powershell
$env:STEAMGRIDDB_API_KEY = "your_api_key_here"
.\Sync.ps1
```

## Icon Caching

Fetched icons are saved to `SteamGridDbCache/` and reused on subsequent runs. The cache is refreshed automatically when a newer image is available upstream.

## Pinning a Specific Icon

If the automatically chosen icon for a game looks wrong, you can pin a specific SteamGridDB icon ID. Use the Steam AppID or the game's display name as the key:

```json
{
  "steamGridDbPreferredIconIds": {
    "1091500": "86095",
    "Cyberpunk 2077": "86095"
  }
}
```

Find the icon ID in the SteamGridDB URL when browsing icons for a game, e.g. `steamgriddb.com/icon/86095`.

## Excluding a Specific Icon

If a particular icon keeps being selected but looks bad (e.g. white/blank), add its ID to the exclusion list:

```json
{
  "steamGridDbExcludedIconIds": {
    "1091500": ["99999", "12345"]
  }
}
```

> Prefer excluding bad IDs over pinning a preferred one, since pinned IDs can go stale if the asset is later removed from SteamGridDB.
