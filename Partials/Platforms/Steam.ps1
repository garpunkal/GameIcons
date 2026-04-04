# Steam platform operations

function Get-SteamNativeExeIconSource {
    param([string]$InstallPath)

    if (-not $InstallPath -or -not (Test-Path $InstallPath)) {
        return $null
    }

    $searchRoots = @(
        $InstallPath,
        (Join-Path $InstallPath 'Binaries'),
        (Join-Path $InstallPath 'Bin'),
        (Join-Path $InstallPath 'x64'),
        (Join-Path $InstallPath 'Win64')
    ) | Select-Object -Unique

    $exeCandidates = @()
    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            $exeCandidates += Get-ChildItem -Path $root -Filter '*.exe' -File -ErrorAction SilentlyContinue
        }
    }

    # Some titles keep their launch exe deeper than one level.
    if (-not $exeCandidates -or $exeCandidates.Count -eq 0) {
        $exeCandidates = @(Get-ChildItem -Path $InstallPath -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue)
    }

    $best = $exeCandidates |
        Where-Object { $_.Name -notmatch '(?i)unins|uninstall|setup|config|crash|launcher|updater|redist|prereq' } |
        Sort-Object Length -Descending |
        Select-Object -First 1 -ExpandProperty FullName

    if ($best -and (Test-Path $best)) {
        return $best
    }

    return $null
}

function Sync-SteamGames {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$SteamInstall,
        [string]$SteamMenu,
        [string]$CustomIconsPath,
        [string]$SteamGridDbCache,
        [string]$UwpIconCache
    )
    
    Write-Host "`n=== Steam ===" -ForegroundColor Cyan

    if ($UseSteamGridDb -and -not $SteamGridDbApiKey) {
        Write-Host "  [SKIP]    SteamGridDB enabled but no API key provided (set -SteamGridDbApiKey or STEAMGRIDDB_API_KEY)." -ForegroundColor DarkYellow
    }

    if (-not (Test-Path $SteamInstall)) {
        Write-Host "  [SKIP]    Steam not found at: $SteamInstall" -ForegroundColor DarkYellow
        return
    }

    if (-not (Test-Path $SteamMenu)) {
        if ($PSCmdlet.ShouldProcess($SteamMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $SteamMenu | Out-Null
        }
    }

    $libs  = Get-SteamLibraryPaths -SteamInstall $SteamInstall
    $games = Get-SteamAppManifests -LibraryPaths $libs

    $installedSteamNames = $games | ForEach-Object { Get-SafeFilename -Name $_.Name }
    $installedSteamNamesLegacy = $installedSteamNames | ForEach-Object { $_ -replace ' ', '_' }
    $installedSteamNamesCombined = @($installedSteamNames + $installedSteamNamesLegacy) | Select-Object -Unique

    if (Test-Path $SteamMenu) {
        Get-ChildItem $SteamMenu -Filter '*.url' | ForEach-Object {
            # In shared folders, only clean up Steam-owned .url shortcuts.
            $raw = [System.IO.File]::ReadAllText($_.FullName)
            $isSteamShortcut = $raw -match '(?m)^URL=steam://rungameid/'
            if (-not $isSteamShortcut) { return }

            if ($installedSteamNamesCombined -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    foreach ($game in ($games | Sort-Object Name)) {
        $index = [array]::IndexOf($games, $game) + 1
        Write-ProgressIndicator -Current $index -Total $games.Count -Activity "Processing Steam Games" -Status $game.Name
        $safeName     = Get-SafeFilename -Name $game.Name
        $legacySafeName = $safeName -replace ' ', '_'
        $steamIconCacheKey = "steam.$($game.AppId)"
        $shortcutPath = Join-Path $SteamMenu "$safeName.url"
        $legacyShortcutPath = Join-Path $SteamMenu "$legacySafeName.url"
        $url          = "steam://rungameid/$($game.AppId)"

        # Migrate legacy underscore shortcut names to preferred spaced names
        if ((-not (Test-Path $shortcutPath)) -and (Test-Path $legacyShortcutPath)) {
            Write-Host "  [MIGRATE] Renaming legacy shortcut $legacySafeName.url -> $safeName.url" -ForegroundColor Cyan
            if ($PSCmdlet.ShouldProcess($legacyShortcutPath, 'Rename legacy shortcut')) {
                Rename-Item -Path $legacyShortcutPath -NewName (Split-Path $shortcutPath -Leaf) -Force
            }
        }

        # Clean up duplicate legacy shortcut if both exist
        if ((Test-Path $shortcutPath) -and (Test-Path $legacyShortcutPath) -and ($legacyShortcutPath -ne $shortcutPath)) {
            Write-Host "  [REMOVE] Duplicate legacy shortcut $legacySafeName.url" -ForegroundColor Red
            if ($PSCmdlet.ShouldProcess($legacyShortcutPath, 'Remove duplicate shortcut')) {
                Remove-Item -LiteralPath $legacyShortcutPath -Force
            }
        }

        # Icon resolution with priority chain
        $icoPath = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        
        if (-not $icoPath -and $UseSteamGridDb) {
            # 1. SteamGridDB official icons (original Steam assets hosted on SGDB)
            $icoPath = Get-SteamGridDbIcoPath -AppId $game.AppId -SafeName $steamIconCacheKey `
                       -ApiKey $SteamGridDbApiKey -CachePath $SteamGridDbCache `
                       -Refresh:$RefreshSteamGridDb -Styles 'official' -GameName $game.Name
            # 2. SteamGridDB all styles sorted by score (community icons)
            if (-not $icoPath) {
                $icoPath = Get-SteamGridDbIcoPath -AppId $game.AppId -SafeName $steamIconCacheKey `
                           -ApiKey $SteamGridDbApiKey -CachePath $SteamGridDbCache `
                           -Refresh:$RefreshSteamGridDb -Styles 'official,custom' -GameName $game.Name
            }
        }

        # 3. Cached icons from SteamGridDbCache or UwpIconCache
        if (-not $icoPath) {
            $icoPath = Get-CachedIcoPath -SafeName $steamIconCacheKey -SteamGridDbCache $SteamGridDbCache -UwpIconCache $UwpIconCache
        }

        # 4. Local Steam assets (clienticon / library cache)
        if (-not $icoPath) {
            $icoPath = Get-SteamIcoPath -AppId $game.AppId -SteamInstall $SteamInstall -ClientIconHash $game.ClientIconHash
        }

        # 5. Official Steam CDN artwork (no API key required)
        if (-not $icoPath) {
            $icoPath = Get-SteamCdnIcoPath -AppId $game.AppId -SafeName $steamIconCacheKey -CachePath $SteamGridDbCache -Refresh:$RefreshSteamGridDb
        }

        # 6. Native game executable icon (final fallback)
        if (-not $icoPath) {
            $icoPath = Get-SteamNativeExeIconSource -InstallPath $game.InstallPath
        }

        if (-not (Test-Path $shortcutPath)) {
            # Create missing shortcut
            if ($icoPath) {
                Write-Host "  [CREATE]  $($game.Name)" -ForegroundColor Green
                Write-UrlFile -Path $shortcutPath -Url $url -IconFile $icoPath
            } else {
                Write-Host "  [SKIP]    $($game.Name) (AppID $($game.AppId)) - no icon found in SteamGridDB, caches, Steam local assets, Steam CDN, or native executable" -ForegroundColor DarkYellow
            }
        } else {
            # Shortcut exists: check icon is still valid
            $currentIcon = Get-ShortcutIconPath -Path $shortcutPath -Type 'url'
            $needsFix = -not $currentIcon -or -not (Test-Path $currentIcon) -or ($icoPath -and $currentIcon -ne $icoPath)
            
            if (-not $needsFix) {
                Write-Host "  [OK]      $($game.Name)" -ForegroundColor DarkGray
            } elseif ($icoPath) {
                Write-Host "  [FIX]     $($game.Name)" -ForegroundColor Yellow
                Set-UrlIconFile -Path $shortcutPath -IconFile $icoPath
            } else {
                Write-Host "  [REMOVE]  $($game.Name) (AppID $($game.AppId)) - broken icon, no source available" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($shortcutPath, 'Remove shortcut with broken icon')) {
                    Remove-Item -LiteralPath $shortcutPath -Force
                }
            }
        }
    }

    # Clear progress bar
    Write-Progress -Activity "Processing Steam Games" -Completed
}
