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
    # Try multiple detection methods: directory scanning, registry, existing shortcuts, and installation directory
    param([string]$PreferredLibraryRoot = '')

    function Test-UbisoftInstalledPath {
        param([string]$Path)
        return ($Path -and (Test-Path -LiteralPath $Path))
    }
    
    $games = @()
    
    # Method 1: Check for existing Ubisoft shortcuts and extract game info
    $startMenuPaths = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:PROGRAMDATA\Microsoft\Windows\Start Menu\Programs"
    )
    
    $defaultUbisoftInstallDirs = @(
        'S:\ubisoft',
        'C:\Program Files (x86)\Ubisoft',
        'C:\Program Files\Ubisoft',
        (Join-Path $env:PROGRAMFILES 'Ubisoft'),
        (Join-Path ${env:ProgramFiles(x86)} 'Ubisoft')
    )
    $ubisoftInstallDirs = @($PreferredLibraryRoot) + $defaultUbisoftInstallDirs | Where-Object { $_ } | Select-Object -Unique

    foreach ($startMenuPath in $startMenuPaths) {
        if (Test-Path $startMenuPath) {
            Get-ChildItem $startMenuPath -Recurse -Include "*.url" -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $content = Get-Content $_.FullName -Raw
                    if ($content -match '(?m)^URL=uplay://launch/(\d+)(?:/|\b)') {
                        $gameId = $matches[1]
                        $displayName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                        
                        # Try to find install path from known locations
                        $installPath = $null
                        foreach ($installDir in $ubisoftInstallDirs) {
                            if (Test-Path $installDir) {
                                # Try exact match first
                                $gameDir = Get-ChildItem $installDir -Directory | Where-Object { $_.Name -eq $displayName } | Select-Object -First 1
                                if (-not $gameDir) {
                                    # Try fuzzy match (remove special characters and spaces)
                                    $cleanDisplayName = $displayName -replace '[^a-zA-Z0-9]', ''
                                    $gameDir = Get-ChildItem $installDir -Directory | Where-Object { ($_.Name -replace '[^a-zA-Z0-9]', '') -eq $cleanDisplayName } | Select-Object -First 1
                                }
                                if ($gameDir) {
                                    $installPath = $gameDir.FullName
                                    break
                                }
                            }
                        }
                        
                        # Check if we already have this game
                        if ($installPath -and -not ($games | Where-Object { $_.GameId -eq $gameId })) {
                            $games += [PSCustomObject]@{
                                DisplayName    = $displayName
                                GameId         = $gameId
                                ExecutablePath = $installPath
                                ManifestPath   = $_.FullName
                                InstallPath    = $installPath
                            }
                        }
                    }
                } catch {
                    # Skip invalid shortcuts
                }
            }
        }
    }
    
    # Method 2: Check directory-based storage (original method)
    $possiblePaths = @(
        (Join-Path $env:LOCALAPPDATA 'Ubisoft Game Launcher\games'),
        (Join-Path $env:LOCALAPPDATA 'Ubisoft Game Launcher\data\games'),
        (Join-Path $env:APPDATA 'Ubisoft Game Launcher\games'),
        (Join-Path $env:PROGRAMDATA 'Ubisoft Game Launcher\games')
    )
    
    foreach ($gamesPath in $possiblePaths) {
        if (Test-Path $gamesPath) {
            Get-ChildItem $gamesPath -Directory | ForEach-Object {
                $gameDir = $_.FullName
                # Look for game metadata: various possible filenames
                $metadataFiles = @(
                    (Join-Path $gameDir 'game.json'),
                    (Join-Path $gameDir 'installation.json'),
                    (Join-Path $gameDir 'metadata.json'),
                    (Join-Path $gameDir 'game_identifier.json'),
                    (Join-Path $gameDir 'config.json')
                )
                
                foreach ($metadataFile in $metadataFiles) {
                    if (Test-Path $metadataFile) {
                        try {
                            $manifest = Get-Content $metadataFile -Raw | ConvertFrom-Json
                            
                            # Extract game info - JSON structure varies by Ubisoft Connect version
                            $gameId = $manifest.external_id -or $manifest.game_id -or $manifest.id -or $manifest.uplay_id -or $_.Name
                            $displayName = $manifest.game_name -or $manifest.name -or $manifest.display_name -or $_.Name
                            $executablePath = $manifest.installed_path -or $manifest.install_path -or $manifest.executable -or $null
                            $installPathCandidate = $manifest.installed_path -or $manifest.install_path -or $null

                            if (-not (Test-UbisoftInstalledPath -Path $installPathCandidate) -and $executablePath) {
                                if (Test-Path -LiteralPath $executablePath) {
                                    $installPathCandidate = Split-Path -Parent $executablePath
                                }
                            }
                            
                            if ($displayName -and $gameId -and (Test-UbisoftInstalledPath -Path $installPathCandidate)) {
                                # Check if we already have this game
                                if (-not ($games | Where-Object { $_.GameId -eq $gameId })) {
                                    $games += [PSCustomObject]@{
                                        DisplayName    = $displayName
                                        GameId         = $gameId
                                        ExecutablePath = $executablePath
                                        ManifestPath   = $metadataFile
                                        InstallPath    = $installPathCandidate
                                    }
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
        }
    }
    
    # Method 3: Check Ubisoft installation directory for installed games
    foreach ($installDir in $ubisoftInstallDirs) {
        if (Test-Path $installDir) {
            $ubisoftDataFolders = @('cache', 'crashes', 'data', 'license', 'locales', 'logs', 'savegames', 'shareplay', 'Ubisoft Game Launcher')
            Get-ChildItem $installDir -Directory | Where-Object { $ubisoftDataFolders -notcontains $_.Name -and $_.Name -notmatch 'Ubisoft Game Launcher' } | ForEach-Object {
                $gameDir = $_.FullName
                $displayName = $_.Name
                
                # Skip if we already have this game (by name)
                if ($games | Where-Object { $_.DisplayName -eq $displayName }) {
                    continue
                }
                
                # Strict mode: skip inferred titles without a launchable Ubisoft game id.
                if ($displayName -and -not ($games | Where-Object { $_.DisplayName -eq $displayName })) {
                    $games += [PSCustomObject]@{
                        DisplayName    = $displayName
                        GameId         = $null
                        ExecutablePath = $gameDir
                        ManifestPath   = $null
                        InstallPath    = $gameDir
                    }
                }
            }
        }
    }
    
    # Method 4: Check registry (if other methods fail)
    if ($games.Count -eq 0) {
        try {
            $installedGames = Get-ItemProperty 'HKCU:\Software\Ubisoft\Launcher\Games\*' -ErrorAction SilentlyContinue
            if ($installedGames) {
                foreach ($game in $installedGames.PSObject.Properties) {
                    $gameData = $game.Value
                    if ($gameData -and $gameData.DisplayName -and (Test-UbisoftInstalledPath -Path $gameData.InstallPath)) {
                        $games += [PSCustomObject]@{
                            DisplayName    = $gameData.DisplayName
                            GameId         = $game.Name
                            ExecutablePath = $gameData.InstallPath
                            ManifestPath   = $null
                            InstallPath    = $gameData.InstallPath
                        }
                    }
                }
            }
        } catch {
            # Continue without registry data
        }
    }
    
    return $games
}

function Sync-UbisoftGames {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$UbisoftMenu,
        [string]$UbisoftInstall,
        [string]$CustomIconsPath
    )
    
    Write-Host "`n=== Ubisoft Connect ===" -ForegroundColor Cyan

    $ubisoftInstall = if ($UbisoftInstall -and (Test-Path $UbisoftInstall)) {
        $UbisoftInstall
    } else {
        Get-UbisoftInstallPath
    }
    if (-not $ubisoftInstall) {
        Write-Host "  [SKIP]    Ubisoft Connect not found (not installed or configured)" -ForegroundColor DarkYellow
        return
    }

    $games = @(Get-UbisoftGameList -PreferredLibraryRoot $ubisoftInstall | Sort-Object DisplayName)
    
    if ($games.Count -eq 0) {
        Write-Host "  [SKIP]    No Ubisoft games found" -ForegroundColor DarkYellow
        return
    }

    if (-not (Test-Path $UbisoftMenu)) {
        if ($PSCmdlet.ShouldProcess($UbisoftMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $UbisoftMenu | Out-Null
        }
    }

    $installedUbisoftNames = $games | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    $installedUbisoftNamesLegacy = $installedUbisoftNames | ForEach-Object { $_ -replace ' ', '_' }
    $installedUbisoftNamesCombined = @($installedUbisoftNames + $installedUbisoftNamesLegacy) | Select-Object -Unique
    
    # Clean up shortcuts for uninstalled games
    if (Test-Path $UbisoftMenu) {
        Get-ChildItem $UbisoftMenu -Filter '*.url' | ForEach-Object {
            # Check if this is a Ubisoft shortcut (contains uplay://)
            $raw = [System.IO.File]::ReadAllText($_.FullName)
            $isUbisoftShortcut = $raw -match '(?m)^URL=uplay://'
            if (-not $isUbisoftShortcut) { return }

            if ($installedUbisoftNamesCombined -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    # Process each game
    foreach ($game in $games) {
        if (-not $game.GameId) {
            continue
        }

        $safeName      = Get-SafeFilename -Name $game.DisplayName
        $legacySafeName = $safeName -replace ' ', '_'
        $shortcutPath  = Join-Path $UbisoftMenu "$safeName.url"
        $legacyShortcutPath = Join-Path $UbisoftMenu "$legacySafeName.url"
        # Ubisoft launcher URL: uplay://launch/{game_id}

        if ((-not (Test-Path $shortcutPath)) -and (Test-Path $legacyShortcutPath)) {
            Write-Host "  [MIGRATE] Renaming legacy shortcut $legacySafeName.url -> $safeName.url" -ForegroundColor Cyan
            if ($PSCmdlet.ShouldProcess($legacyShortcutPath, 'Rename legacy shortcut')) {
                Rename-Item -Path $legacyShortcutPath -NewName (Split-Path $shortcutPath -Leaf) -Force
            }
        }

        if ((Test-Path $shortcutPath) -and (Test-Path $legacyShortcutPath) -and ($legacyShortcutPath -ne $shortcutPath)) {
            Write-Host "  [REMOVE] Duplicate legacy shortcut $legacySafeName.url" -ForegroundColor Red
            if ($PSCmdlet.ShouldProcess($legacyShortcutPath, 'Remove duplicate shortcut')) {
                Remove-Item -LiteralPath $legacyShortcutPath -Force
            }
        }
        $launchUrl    = "uplay://launch/$($game.GameId)"

        # Try to find icon
        $customIco = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        
        # Fallback to game executable or Ubisoft launcher icon
        $iconFile = if ($customIco) { $customIco } elseif ($game.InstallPath -and (Test-Path $game.InstallPath)) {
            # Search common executable locations first to avoid deep recursive scans.
            $exeCandidates = @()
            $searchDirs = @(
                $game.InstallPath,
                (Join-Path $game.InstallPath 'bin'),
                (Join-Path $game.InstallPath 'bin_plus'),
                (Join-Path $game.InstallPath 'Binaries'),
                (Join-Path $game.InstallPath 'Binaries\Win64'),
                (Join-Path $game.InstallPath 'Binaries\Win32')
            ) | Select-Object -Unique

            foreach ($dir in $searchDirs) {
                if (Test-Path $dir) {
                    $exeCandidates += Get-ChildItem -Path $dir -Filter '*.exe' -File -ErrorAction SilentlyContinue
                }
            }

            $gameExe = $exeCandidates |
                      Where-Object { $_.Name -notmatch "uninstall|eac|crash|service|splash" } |
                      Sort-Object { 
                          # Prioritize executables that match the game name or are in bin/bin_plus directories
                          $priority = 0
                          if ($_.Name -match "^$($game.DisplayName -replace '[^a-zA-Z0-9]', '').*\.exe$") { $priority -= 10 }
                          if ($_.DirectoryName -match '\\bin[^\\]*$') { $priority -= 5 }
                          if ($_.Name -match "launcher|setup|config") { $priority += 5 }
                          $priority
                      } | 
                      Select-Object -First 1
            if ($gameExe) { $gameExe.FullName } else { $null }
        }

        # Never persist a missing icon path in the shortcut.
        $resolvedIconFile = if ($iconFile -and (Test-Path -LiteralPath $iconFile)) { $iconFile } else { $null }

        if (-not (Test-Path $shortcutPath)) {
            # Create missing shortcut
            Write-Host "  [CREATE]  $($game.DisplayName)" -ForegroundColor Green
            Write-UrlFile -Path $shortcutPath -Url $launchUrl -IconFile $resolvedIconFile
        } else {
            # Shortcut exists: check icon is still valid
            $currentIcon = Get-ShortcutIconPath -Path $shortcutPath -Type 'url'
            $needsFix = ($currentIcon -and (-not (Test-Path $currentIcon))) -or ($customIco -and $currentIcon -ne $customIco)
            
            if (-not $needsFix) {
                Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
            } elseif ($resolvedIconFile) {
                Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
                Set-UrlIconFile -Path $shortcutPath -IconFile $resolvedIconFile
            } else {
                # No valid icon available. Remove stale icon references.
                if ($currentIcon) {
                    Write-Host "  [FIX]     $($game.DisplayName) - removing missing icon" -ForegroundColor Yellow
                    Set-UrlIconFile -Path $shortcutPath -IconFile ''
                } else {
                    Write-Host "  [SKIP]    $($game.DisplayName) - no icon available" -ForegroundColor DarkYellow
                }
            }
        }
    }
    
    return
}
