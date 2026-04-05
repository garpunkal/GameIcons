# Troubleshooting

## No games found for a launcher

- Verify the launcher is installed and has at least one installed game.
- Check the corresponding path in `settings.json`.
- For Store titles with unusual manifests, add the package name to `includeStorePackages`.

## Icons look stale after a run

- Run without `-SkipIconCacheRefresh` so the shell cache refresh executes.
- If needed, allow Explorer to restart by omitting `-SkipExplorerRestart`.

## SteamGridDB lookups fail

- Confirm `STEAMGRIDDB_API_KEY` is set correctly.
- Confirm network access to steamgriddb.com.
- Retry later if rate limited.

## Wrong game icon selected

- Add a custom `.ico` in `CustomIcons/` named after the game title.
- Or pin a specific SteamGridDB ID in `steamGridDbPreferredIconIds` — see [SteamGridDB integration](steamgriddb.md).

---

# Safe Operations and Secrets

- Keep secrets in environment variables or a local `.env` file only.
- Do not store real API keys in `settings.json`.
- Before pushing, review staged files with `git diff --staged`.

## Optional Pre-Commit Secret Scan (Recommended)

This repository includes a gitleaks config and a sample git hook under `.githooks`.

**Fast path (recommended):**

```powershell
.\Setup-GitHooks.ps1
```

This sets `core.hooksPath` and runs a staged gitleaks scan when available.

**Manual setup:**

1. Install gitleaks:

```powershell
winget install Gitleaks.Gitleaks
```

2. Enable repo hooks:

```powershell
git config core.hooksPath .githooks
```

3. Test the scanner:

```powershell
gitleaks protect --staged --config .gitleaks.toml --redact
```

If a secret is detected, the commit is blocked until the issue is fixed or intentionally allowlisted.
