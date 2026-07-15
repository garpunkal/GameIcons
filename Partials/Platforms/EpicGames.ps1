# Epic Games platform operations

function Sync-EpicGames {
    [CmdletBinding(SupportsShouldProcess = $true)]
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

    function Resolve-EpicIconSourcePath {
        param(
            [string]$InstallLocation,
            [string]$LaunchExecutable,
            [string]$DisplayName
        )

        $launchPath = Join-Path $InstallLocation $LaunchExecutable
        $launchExt = [System.IO.Path]::GetExtension([string]$LaunchExecutable).ToLowerInvariant()

        if ($launchExt -eq '.exe' -and (Test-Path $launchPath -PathType Leaf)) {
            return $launchPath
        }

        $helperExePattern = '(?i)\\(vc_redist|crashpad_handler\d*|epicgameslauncher|unins\d*|setup|launcher\\dowser)\.exe$'
        $candidates = @()

        if (($launchExt -in @('.bat', '.cmd')) -and (Test-Path $launchPath -PathType Leaf)) {
            $scriptText = Get-Content -LiteralPath $launchPath -Raw -ErrorAction SilentlyContinue
            if ($scriptText) {
                [regex]::Matches($scriptText, '(?im)(?:"([^"\r\n]+\.exe)"|([^\s"\r\n]+\.exe))') | ForEach-Object {
                    $rawExe = if ($_.Groups[1].Value) { $_.Groups[1].Value } else { $_.Groups[2].Value }
                    if (-not $rawExe) { return }

                    $exeRef = $rawExe.Trim().Trim('"').Replace('/', '\\')
                    $exePath = if ([System.IO.Path]::IsPathRooted($exeRef)) {
                        $exeRef
                    } else {
                        Join-Path $InstallLocation $exeRef
                    }

                    if (Test-Path $exePath -PathType Leaf) {
                        $candidates += $exePath
                    }
                }
            }
        }

        if (Test-Path $InstallLocation) {
            $candidates += @(Get-ChildItem -LiteralPath $InstallLocation -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }

        $candidates = @($candidates | Select-Object -Unique | Where-Object { $_ -notmatch $helperExePattern })

        if ($candidates.Count -gt 0) {
            $nameTokens = @([regex]::Matches(([string]$DisplayName).ToLowerInvariant(), '[a-z0-9]+') | ForEach-Object { $_.Value } | Select-Object -Unique)
            $best = $candidates |
                Sort-Object `
                    @{ Expression = {
                        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($_).ToLowerInvariant()
                        $score = 0
                        foreach ($token in $nameTokens) {
                            if ($leaf -like "*$token*") { $score++ }
                        }
                        if ($_ -match '(?i)\\launcher\\') { $score -= 2 }
                        $score
                    }; Descending = $true },
                    @{ Expression = { $_.Length }; Descending = $false } |
                Select-Object -First 1

            if ($best) { return $best }
        }

        $launcherIconCandidates = @(
            'C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe',
            'C:\Program Files\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe'
        )
        $launcherIcon = $launcherIconCandidates | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
        if ($launcherIcon) { return $launcherIcon }

        return $launchPath
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

        # Skip DLCs (no launch target), incomplete installs, and duplicates
        if (-not $m.LaunchExecutable) { return }
        $launchExt = [System.IO.Path]::GetExtension([string]$m.LaunchExecutable).ToLowerInvariant()
        # Some Epic titles launch via wrapper scripts (.bat/.cmd); include those.
        # Keep extension filtering to avoid non-launch payloads.
        if ($launchExt -notin @('.exe', '.bat', '.cmd')) { return }
        # Skip known non-game helper launchers.
        if ([string]$m.LaunchExecutable -match '(?i)showfolder\.(bat|cmd)$') { return }
        if ($m.bIsIncompleteInstall)  { return }
        # Skip DLC/expansion entries that are children of another game
        if ($m.MainGameAppName -and ($m.MainGameAppName -ne $m.AppName)) { return }
        # Skip entries excluded by display name in settings
        if ($global:EpicExcludedDisplayNames -contains [string]$m.DisplayName) { return }
        if ($seen.ContainsKey($m.AppName)) { return }
        $seen[$m.AppName] = $true

        $exePath = Join-Path $m.InstallLocation $m.LaunchExecutable
        $iconSourcePath = Resolve-EpicIconSourcePath -InstallLocation $m.InstallLocation -LaunchExecutable $m.LaunchExecutable -DisplayName $m.DisplayName
        # Build the Epic launcher URL: namespace:catalogItemId:appName
        $launchUrl = "com.epicgames.launcher://apps/$([System.Uri]::EscapeDataString("$($m.CatalogNamespace):$($m.CatalogItemId):$($m.AppName)"))?action=launch&silent=true"

        $games += [PSCustomObject]@{
            DisplayName = $m.DisplayName
            ExePath     = $exePath
            IconSourcePath = $iconSourcePath
            LaunchUrl   = $launchUrl
            WorkingDir  = 'C:\Program Files (x86)\Epic Games'
        }
    }

    $installedEpicNames = $games | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    $installedEpicNamesLegacy = $installedEpicNames | ForEach-Object { $_ -replace ' ', '_' }
    $installedEpicNamesCombined = @($installedEpicNames + $installedEpicNamesLegacy) | Select-Object -Unique

    if (Test-Path $EpicMenu) {
        Get-ChildItem $EpicMenu -Filter '*.url' | ForEach-Object {
            # In shared folders, only clean up Epic-owned .url shortcuts.
            $raw = [System.IO.File]::ReadAllText($_.FullName)
            $isEpicShortcut = $raw -match '(?m)^URL=com\.epicgames\.launcher://apps/'
            if (-not $isEpicShortcut) { return }

            if ($installedEpicNamesCombined -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
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
        $iconFile  = if ($customIco) { $customIco } elseif ($game.IconSourcePath -and (Test-Path $game.IconSourcePath)) { $game.IconSourcePath } else { $game.ExePath }

        if (-not (Test-Path $shortcutPath)) {
            # Create missing shortcut
            if (Test-Path $game.ExePath) {
                Write-Host "  [CREATE]  $($game.DisplayName)" -ForegroundColor Green
                Write-UrlFile -Path $shortcutPath -Url $game.LaunchUrl -IconFile $iconFile -WorkingDir $game.WorkingDir
            }
        } else {
            # Shortcut exists: check icon is still valid
            $currentIcon = Get-ShortcutIconPath -Path $shortcutPath -Type 'url'
            $desiredIcon = if ($customIco) { $customIco } else { $iconFile }
            $needsFix = -not $currentIcon -or
                        -not (Test-Path $currentIcon) -or
                        ($desiredIcon -and ($currentIcon.Trim().ToLowerInvariant() -ne $desiredIcon.Trim().ToLowerInvariant()))
            
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
