# Battle.net platform operations

function Get-RegistryEntryStringValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Entry.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) {
        return [string]$property.Value
    }

    return ''
}

function Get-BattleNetInstallPath {
    # Find Battle.net launcher installation path from uninstall registry entries
    # or common default install locations.
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $uninstallPaths) {
        $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        foreach ($entry in $entries) {
            $displayName = Get-RegistryEntryStringValue -Entry $entry -Name 'DisplayName'
            if (-not $displayName) { continue }
            if ($displayName -notmatch '(?i)^battle\.net(\s|$)|blizzard battle\.net desktop app') { continue }

            $installLocationRaw = Get-RegistryEntryStringValue -Entry $entry -Name 'InstallLocation'
            $installLocation = [Environment]::ExpandEnvironmentVariables($installLocationRaw)
            if ($installLocation -and (Test-Path $installLocation)) {
                return $installLocation
            }

            $displayIcon = Get-RegistryEntryStringValue -Entry $entry -Name 'DisplayIcon'
            if ($displayIcon) {
                $iconPath = ($displayIcon -split ',')[0].Trim().Trim('"')
                if ($iconPath -and (Test-Path $iconPath)) {
                    return (Split-Path $iconPath -Parent)
                }
            }
        }
    }

    foreach ($defaultPath in @('C:\Program Files (x86)\Battle.net', 'C:\Program Files\Battle.net')) {
        if (Test-Path $defaultPath) {
            return $defaultPath
        }
    }

    return $null
}

function Get-BattleNetShortcutInfo {
    param([string]$Path)

    $ws = $null
    $shortcut = $null
    try {
        $ws = New-Object -ComObject WScript.Shell
        $shortcut = $ws.CreateShortcut($Path)
        $iconPath = if ($shortcut.IconLocation) { ($shortcut.IconLocation -split ',')[0].Trim() } else { '' }

        return [PSCustomObject]@{
            TargetPath  = [string]$shortcut.TargetPath
            Description = [string]$shortcut.Description
            IconPath    = [string]$iconPath
        }
    } finally {
        if ($shortcut) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) | Out-Null
        }
        if ($ws) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
        }
    }
}

function Get-BattleNetGameList {
    # Build a game list from uninstall entries. This avoids relying on
    # undocumented launcher metadata formats.
    param([string]$PreferredLauncherRoot = '')

    $games = @()
    $seen = @{}

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $uninstallPaths) {
        $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        foreach ($entry in $entries) {
            $displayName = Get-RegistryEntryStringValue -Entry $entry -Name 'DisplayName'
            if (-not $displayName) { continue }

            $publisher = Get-RegistryEntryStringValue -Entry $entry -Name 'Publisher'
            $isBlizzardPublisher = $publisher -match '(?i)blizzard|activision'
            $isKnownBattleNetTitle = $displayName -match '(?i)world of warcraft|diablo|overwatch|hearthstone|starcraft|warcraft|heroes of the storm|call of duty'
            if (-not ($isBlizzardPublisher -or $isKnownBattleNetTitle)) { continue }

            # Skip launcher and updater entries.
            if ($displayName -match '(?i)^battle\.net(\s|$)|battle\.net update agent|blizzard battle\.net desktop app') {
                continue
            }

            $safeName = (Get-SafeFilename -Name $displayName).ToLowerInvariant()
            if (-not $safeName -or $seen.ContainsKey($safeName)) { continue }

            $installLocationRaw = Get-RegistryEntryStringValue -Entry $entry -Name 'InstallLocation'
            $installLocation = [Environment]::ExpandEnvironmentVariables($installLocationRaw)
            $displayIcon = Get-RegistryEntryStringValue -Entry $entry -Name 'DisplayIcon'
            $exePath = ''

            if ($displayIcon) {
                $iconPath = ($displayIcon -split ',')[0].Trim().Trim('"')
                if ($iconPath -and $iconPath.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path $iconPath)) {
                    $exePath = $iconPath
                }
            }

            if (-not $exePath -and $installLocation -and (Test-Path $installLocation)) {
                $searchRoots = @(
                    $installLocation,
                    (Join-Path $installLocation '_retail_'),
                    (Join-Path $installLocation '_classic_'),
                    (Join-Path $installLocation 'x64'),
                    (Join-Path $installLocation 'Support64')
                ) | Select-Object -Unique

                $exeCandidates = @()
                foreach ($root in $searchRoots) {
                    if (Test-Path $root) {
                        $exeCandidates += Get-ChildItem -Path $root -Filter '*.exe' -File -ErrorAction SilentlyContinue
                    }
                }

                $exePath = ($exeCandidates |
                    Where-Object { $_.Name -notmatch '(?i)unins|uninstall|launcher|agent|repair|crash|support|setup|updater|battle\.net' } |
                    Sort-Object Length -Descending |
                    Select-Object -First 1 -ExpandProperty FullName)
            }

            # If install path is missing, try to infer it from the discovered exe path.
            if ((-not $installLocation) -and $exePath) {
                $installLocation = Split-Path $exePath -Parent
            }

            if (-not $exePath -or -not (Test-Path $exePath)) {
                continue
            }

            # If a launcher root was provided, prefer entries under that root.
            if ($PreferredLauncherRoot -and (Test-Path $PreferredLauncherRoot)) {
                $normalizedRoot = [System.IO.Path]::GetFullPath($PreferredLauncherRoot).TrimEnd('\\')
                $normalizedExe = [System.IO.Path]::GetFullPath($exePath)
                if ($normalizedExe -notlike "$normalizedRoot\\*") {
                    continue
                }
            }

            $seen[$safeName] = $true
            $games += [PSCustomObject]@{
                DisplayName = $displayName
                ExePath     = $exePath
                InstallPath = $installLocation
            }
        }
    }

    return $games
}

function Sync-BattleNetGames {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$BattleNetMenu,
        [string]$BattleNetInstall,
        [string]$CustomIconsPath
    )

    Write-Host "`n=== Battle.net ===" -ForegroundColor Cyan

    $battleNetRoot = if ($BattleNetInstall -and (Test-Path $BattleNetInstall)) {
        $BattleNetInstall
    } else {
        Get-BattleNetInstallPath
    }

    $games = @()
    if ($battleNetRoot) {
        $games = @(Get-BattleNetGameList -PreferredLauncherRoot $battleNetRoot | Sort-Object DisplayName)
    }

    # Fall back to global lookup if launcher root detection was not possible.
    if ($games.Count -eq 0) {
        $games = @(Get-BattleNetGameList | Sort-Object DisplayName)
    }

    if ($games.Count -eq 0) {
        Write-Host "  [SKIP]    No Battle.net games found" -ForegroundColor DarkYellow
        return
    }

    if (-not (Test-Path $BattleNetMenu)) {
        New-Item -ItemType Directory -Path $BattleNetMenu | Out-Null
    }

    $battleNetDescription = 'Battle.net Game'
    $installedBattleNetNames = $games | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    $installedBattleNetNamesLegacy = $installedBattleNetNames | ForEach-Object { $_ -replace ' ', '_' }
    $installedBattleNetNamesCombined = @($installedBattleNetNames + $installedBattleNetNamesLegacy) | Select-Object -Unique

    if (Test-Path $BattleNetMenu) {
        Get-ChildItem $BattleNetMenu -Filter '*.lnk' | ForEach-Object {
            $shortcutInfo = Get-BattleNetShortcutInfo -Path $_.FullName
            if ($shortcutInfo.Description -ne $battleNetDescription) { return }

            if ($installedBattleNetNamesCombined -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
    }

    foreach ($game in $games) {
        $safeName = Get-SafeFilename -Name $game.DisplayName
        $legacySafeName = $safeName -replace ' ', '_'
        $shortcutPath = Join-Path $BattleNetMenu "$safeName.lnk"
        $legacyShortcutPath = Join-Path $BattleNetMenu "$legacySafeName.lnk"

        if ((-not (Test-Path $shortcutPath)) -and (Test-Path $legacyShortcutPath)) {
            Write-Host "  [MIGRATE] Renaming legacy shortcut $legacySafeName.lnk -> $safeName.lnk" -ForegroundColor Cyan
            Rename-Item -Path $legacyShortcutPath -NewName (Split-Path $shortcutPath -Leaf) -Force
        }

        if ((Test-Path $shortcutPath) -and (Test-Path $legacyShortcutPath) -and ($legacyShortcutPath -ne $shortcutPath)) {
            Write-Host "  [REMOVE] Duplicate legacy shortcut $legacySafeName.lnk" -ForegroundColor Red
            Remove-Item -LiteralPath $legacyShortcutPath -Force
        }

        $customIco = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        $iconFile = if ($customIco) { $customIco } else { $game.ExePath }

        if (-not (Test-Path $shortcutPath)) {
            if (Test-Path $game.ExePath) {
                Write-Host "  [CREATE]  $($game.DisplayName)" -ForegroundColor Green
                Write-LnkShortcut -Path $shortcutPath -Target $game.ExePath -Arguments '' -IconFile $iconFile -Description $battleNetDescription
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - executable not found: $($game.ExePath)" -ForegroundColor DarkYellow
            }
            continue
        }

        $shortcutInfo = Get-BattleNetShortcutInfo -Path $shortcutPath
        $currentTarget = $shortcutInfo.TargetPath
        $currentIcon = $shortcutInfo.IconPath

        $needsFix = -not $currentTarget -or -not (Test-Path $currentTarget) -or
                    ($currentTarget -ne $game.ExePath) -or
                    -not $currentIcon -or -not (Test-Path $currentIcon) -or
                    ($customIco -and $currentIcon -ne $customIco) -or
                    ($shortcutInfo.Description -ne $battleNetDescription)

        if (-not $needsFix) {
            Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
        } elseif (Test-Path $game.ExePath) {
            Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
            Write-LnkShortcut -Path $shortcutPath -Target $game.ExePath -Arguments '' -IconFile $iconFile -Description $battleNetDescription
        } else {
            Write-Host "  [REMOVE]  $($game.DisplayName) - broken shortcut target not found" -ForegroundColor Red
            Remove-Item -LiteralPath $shortcutPath -Force
        }
    }
}
