# Ubisoft platform operations

function Get-UbisoftInstallPath {
    # Find Ubisoft Connect installation path from registry or common defaults
    $registryPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher',
        'HKLM:\SOFTWARE\Ubisoft\Launcher'
    )
    
    foreach ($regPath in $registryPaths) {
        try {
            $installDir = (Get-ItemProperty -Path $regPath -Name InstallDir -ErrorAction SilentlyContinue).InstallDir
            if ($installDir -and (Test-Path $installDir)) {
                return $installDir
            }
        } catch {
            # Continue to next registry path
        }
    }
    
    # Fallback to common default paths
    $defaultPaths = @(
        'C:\Program Files\Ubisoft\Ubisoft Game Launcher',
        'C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher'
    )
    
    foreach ($path in $defaultPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    return $null
}

function Get-UbisoftGameList {
    # Enumerate Ubisoft Connect installed games
    # Games are stored as JSON manifests in %LOCALAPPDATA%\Ubisoft Game Launcher\games
    
    $gamesPath = Join-Path $env:LOCALAPPDATA 'Ubisoft Game Launcher\games'
    
    if (-not (Test-Path $gamesPath)) {
        return @()
    }
    
    $games = @()
    
    try {
        Get-ChildItem $gamesPath -Directory | ForEach-Object {
            $gameDir = $_.FullName
            # Look for game metadata: either game.json or installation.json
            $metadataFiles = @(
                (Join-Path $gameDir 'game.json'),
                (Join-Path $gameDir 'installation.json'),
                (Join-Path $gameDir 'game_identifier.json')
            )
            
            foreach ($metadataFile in $metadataFiles) {
                if (Test-Path $metadataFile) {
                    try {
                        $manifest = Get-Content $metadataFile -Raw | ConvertFrom-Json
                        
                        # Extract game info - JSON structure varies
                        $gameId = $manifest.external_id -or $manifest.game_id -or $manifest.id
                        $displayName = $manifest.game_name -or $manifest.name -or $_.Name
                        $executablePath = $manifest.installed_path -or $null
                        
                        if ($displayName -and $gameId) {
                            $games += [PSCustomObject]@{
                                DisplayName    = $displayName
                                GameId         = $gameId
                                ExecutablePath = $executablePath
                                ManifestPath   = $metadataFile
                                InstallPath    = $gameDir
                            }
                            break
                        }
                    } catch {
                        # Skip malformed manifests
                        continue
                    }
                }
            }
        }
    } catch {
        Write-Host "  [WARN]    Failed to enumerate Ubisoft games: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
    
    return $games
}

function Sync-UbisoftGames {
    param(
        [string]$UbisoftMenu,
        [string]$CustomIconsPath,
        [string]$SteamGridDbCache,
        [string]$UwpIconCache
    )
    
    Write-Host "`n=== Ubisoft Connect ===" -ForegroundColor Cyan

    $ubisoftInstall = Get-UbisoftInstallPath
    if (-not $ubisoftInstall) {
        Write-Host "  [SKIP]    Ubisoft Connect not found (not installed or configured)" -ForegroundColor DarkYellow
        return @()
    }

    $games = @(Get-UbisoftGameList | Sort-Object DisplayName)
    
    if ($games.Count -eq 0) {
        Write-Host "  [SKIP]    No Ubisoft games found" -ForegroundColor DarkYellow
        return @()
    }

    if (-not (Test-Path $UbisoftMenu)) {
        if ($PSCmdlet.ShouldProcess($UbisoftMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $UbisoftMenu | Out-Null
        }
    }

    $installedUbisoftNames = $games | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    
    # Clean up shortcuts for uninstalled games
    if (Test-Path $UbisoftMenu) {
        Get-ChildItem $UbisoftMenu -Filter '*.url' | ForEach-Object {
            # Check if this is a Ubisoft shortcut (contains uplay://)
            $raw = [System.IO.File]::ReadAllText($_.FullName)
            $isUbisoftShortcut = $raw -match '(?m)^URL=uplay://'
            if (-not $isUbisoftShortcut) { return }

            if ($installedUbisoftNames -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    # Process each game
    foreach ($game in $games) {
        $safeName     = Get-SafeFilename -Name $game.DisplayName
        $shortcutPath = Join-Path $UbisoftMenu "$safeName.url"
        # Ubisoft launcher URL: uplay://launch/{game_id}
        $launchUrl    = "uplay://launch/$($game.GameId)"

        # Try to find icon
        $customIco = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        if (-not $customIco -and $UseSteamGridDb) {
            $sgdbKey = if ($script:SteamGridDbPreferredIconIdsByAppId.ContainsKey($game.DisplayName)) { $game.DisplayName } elseif ($script:SteamGridDbPreferredIconIdsByAppId.ContainsKey($safeName)) { $safeName } else { $null }
            if ($sgdbKey) {
                $customIco = Get-SteamGridDbIcoPath -AppId $sgdbKey -SafeName "ubisoft.$safeName" -ApiKey $SteamGridDbApiKey -CachePath $SteamGridDbCache -Refresh:$RefreshSteamGridDb
            }
        }
        
        # Fallback to Ubisoft logo or generic executable icon
        $iconFile = if ($customIco) { $customIco } else { 
            # Try to use Ubisoft launcher icon
            Join-Path $ubisoftInstall 'ubilauncher.exe'
        }

        if (-not (Test-Path $shortcutPath)) {
            # Create missing shortcut
            Write-Host "  [CREATE]  $($game.DisplayName)" -ForegroundColor Green
            Write-UrlFile -Path $shortcutPath -Url $launchUrl -IconFile $iconFile
        } else {
            # Shortcut exists: check icon is still valid
            $currentIcon = Get-ShortcutIconPath -Path $shortcutPath -Type 'url'
            $needsFix = -not $currentIcon -or -not (Test-Path $currentIcon) -or ($customIco -and $currentIcon -ne $customIco)
            
            if (-not $needsFix) {
                Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
            } elseif (Test-Path $iconFile) {
                Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
                Set-UrlIconFile -Path $shortcutPath -IconFile $iconFile
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - no icon available" -ForegroundColor DarkYellow
            }
        }
    }
    
    # Return installed names for potential shared folder deduplication
    return @($installedUbisoftNames)
}
