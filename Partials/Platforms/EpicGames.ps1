# Epic Games platform operations

function Sync-EpicGames {
    param(
        [string]$EpicManifests,
        [string]$EpicMenu,
        [string]$CustomIconsPath,
        [string]$SteamGridDbCache,
        [string]$UwpIconCache
    )
    
    Write-Host "`n=== Epic Games ===" -ForegroundColor Cyan

    if (-not (Test-Path $EpicManifests)) {
        Write-Host "  [SKIP]    Epic manifests not found at: $EpicManifests" -ForegroundColor DarkYellow
        return
    }

    if (-not (Test-Path $EpicMenu)) {
        if ($PSCmdlet.ShouldProcess($EpicMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $EpicMenu | Out-Null
        }
    }

    # Build deduplicated game list from manifests
    $seen   = @{}
    $games  = @()
    Get-ChildItem $EpicManifests -Filter '*.item' | ForEach-Object {
        try {
            $m = Get-Content $_.FullName | ConvertFrom-Json
        } catch {
            Write-Host "  [SKIP]    Could not parse manifest: $($_.Name)" -ForegroundColor DarkYellow
            return
        }

        # Skip DLCs (no launch exe), incomplete installs, and duplicates
        if (-not $m.LaunchExecutable) { return }
        # Skip non-game launchers (e.g. showfolder.bat, content packs)
        if ($m.LaunchExecutable -notmatch '\.exe$') { return }
        if ($m.bIsIncompleteInstall)  { return }
        # Skip DLC/expansion entries that are children of another game
        if ($m.MainGameAppName -and ($m.MainGameAppName -ne $m.AppName)) { return }
        if ($seen.ContainsKey($m.AppName)) { return }
        $seen[$m.AppName] = $true

        $exePath = Join-Path $m.InstallLocation $m.LaunchExecutable
        # Build the Epic launcher URL: namespace:catalogItemId:appName
        $launchUrl = "com.epicgames.launcher://apps/$([System.Uri]::EscapeDataString("$($m.CatalogNamespace):$($m.CatalogItemId):$($m.AppName)"))?action=launch&silent=true"

        $games += [PSCustomObject]@{
            DisplayName = $m.DisplayName
            ExePath     = $exePath
            LaunchUrl   = $launchUrl
            WorkingDir  = 'C:\Program Files (x86)\Epic Games'
        }
    }

    $installedEpicNames = $games | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    $installedEpicNamesLegacy = $installedEpicNames | ForEach-Object { $_ -replace ' ', '_' }
    $installedEpicNamesCombined = @($installedEpicNames + $installedEpicNamesLegacy) | Select-Object -Unique

    if (Test-Path $EpicMenu) {
        # If Epic and Store share a folder, removal is handled once in the Store
        # section against a combined installed set to avoid cross-deleting links.
        if ($EpicMenu -ne $MsStoreMenu) {
            Get-ChildItem $EpicMenu -Filter '*.url' | ForEach-Object {
                if ($installedEpicNamesCombined -notcontains $_.BaseName) {
                    Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                    if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                        Remove-Item -LiteralPath $_.FullName -Force
                    }
                }
            }
        }
    }

    foreach ($game in ($games | Sort-Object DisplayName)) {
        $safeName      = Get-SafeFilename -Name $game.DisplayName
        $legacySafeName = $safeName -replace ' ', '_'
        $shortcutPath  = Join-Path $EpicMenu "$safeName.url"
        $legacyShortcutPath = Join-Path $EpicMenu "$legacySafeName.url"

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

        # Custom override takes priority; fall back to the game exe
        $customIco = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        if (-not $customIco -and $UseSteamGridDb) {
            $sgdbKey = if ($global:SteamGridDbPreferredIconIdsByAppId.ContainsKey($game.DisplayName)) { $game.DisplayName } elseif ($global:SteamGridDbPreferredIconIdsByAppId.ContainsKey($safeName)) { $safeName } else { $null }
            if ($sgdbKey) {
                $customIco = Get-SteamGridDbIcoPath -AppId $sgdbKey -SafeName "epic.$safeName" -ApiKey $SteamGridDbApiKey -CachePath $SteamGridDbCache -Refresh:$RefreshSteamGridDb -GameName $game.DisplayName
            }
        }
        $iconFile  = if ($customIco) { $customIco } else { $game.ExePath }

        if (-not (Test-Path $shortcutPath)) {
            # Create missing shortcut
            if (Test-Path $game.ExePath) {
                Write-Host "  [CREATE]  $($game.DisplayName)" -ForegroundColor Green
                Write-UrlFile -Path $shortcutPath -Url $game.LaunchUrl -IconFile $iconFile -WorkingDir $game.WorkingDir
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - exe not found at: $($game.ExePath)" -ForegroundColor DarkYellow
            }
        } else {
            # Shortcut exists: check icon is still valid
            $currentIcon = Get-ShortcutIconPath -Path $shortcutPath -Type 'url'
            $needsFix = -not $currentIcon -or -not (Test-Path $currentIcon) -or ($customIco -and $currentIcon -ne $customIco)
            
            if (-not $needsFix) {
                Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
            } elseif (Test-Path $game.ExePath) {
                Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
                Set-UrlIconFile -Path $shortcutPath -IconFile $iconFile
            } else {
                Write-Host "  [REMOVE]  $($game.DisplayName) - broken icon, exe not found: $($game.ExePath)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($shortcutPath, 'Remove shortcut with broken icon')) {
                    Remove-Item -LiteralPath $shortcutPath -Force
                }
            }
        }
    }
}
