# Steam platform operations

function Sync-SteamGames {
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
    if (Test-Path $SteamMenu) {
        Get-ChildItem $SteamMenu -Filter '*.url' | ForEach-Object {
            # In shared folders, only clean up Steam-owned .url shortcuts.
            $raw = [System.IO.File]::ReadAllText($_.FullName)
            $isSteamShortcut = $raw -match '(?m)^URL=steam://rungameid/'
            if (-not $isSteamShortcut) { return }

            if ($installedSteamNames -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    foreach ($game in ($games | Sort-Object Name)) {
        $safeName     = Get-SafeFilename -Name $game.Name
        $steamIconCacheKey = "steam.$($game.AppId)"
        $shortcutPath = Join-Path $SteamMenu "$safeName.url"
        $url          = "steam://rungameid/$($game.AppId)"

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

        if (-not (Test-Path $shortcutPath)) {
            # Create missing shortcut
            if ($icoPath) {
                Write-Host "  [CREATE]  $($game.Name)" -ForegroundColor Green
                Write-UrlFile -Path $shortcutPath -Url $url -IconFile $icoPath
            } else {
                Write-Host "  [SKIP]    $($game.Name) (AppID $($game.AppId)) - no icon found in SteamGridDB, caches, or Steam local assets" -ForegroundColor DarkYellow
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
}
