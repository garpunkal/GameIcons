# GOG platform operations

function Get-GoGRegistryEntryStringValue {
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

function Get-GoGInstallPath {
    # Resolve GOG Galaxy install folder from uninstall registry entries or defaults.
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $uninstallPaths) {
        $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        foreach ($entry in $entries) {
            $displayName = Get-GoGRegistryEntryStringValue -Entry $entry -Name 'DisplayName'
            if (-not $displayName) { continue }
            if ($displayName -notmatch '(?i)gog galaxy') { continue }

            $installLocationRaw = Get-GoGRegistryEntryStringValue -Entry $entry -Name 'InstallLocation'
            $installLocation = [Environment]::ExpandEnvironmentVariables($installLocationRaw)
            if ($installLocation -and (Test-Path $installLocation)) {
                return $installLocation
            }

            $displayIcon = Get-GoGRegistryEntryStringValue -Entry $entry -Name 'DisplayIcon'
            if ($displayIcon) {
                $iconPath = ($displayIcon -split ',')[0].Trim().Trim('"')
                if ($iconPath -and (Test-Path $iconPath)) {
                    return (Split-Path $iconPath -Parent)
                }
            }
        }
    }

    foreach ($defaultPath in @('C:\Program Files (x86)\GOG Galaxy', 'C:\Program Files\GOG Galaxy')) {
        if (Test-Path $defaultPath) {
            return $defaultPath
        }
    }

    return $null
}

function Get-GoGShortcutInfo {
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

function Get-GoGGameList {
    # Enumerate installed GOG games from uninstall entries and resolve launchable exes.
    param([string]$PreferredLibraryRoot = '')

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
            $displayName = Get-GoGRegistryEntryStringValue -Entry $entry -Name 'DisplayName'
            if (-not $displayName) { continue }

            $publisher = Get-GoGRegistryEntryStringValue -Entry $entry -Name 'Publisher'
            $isGoGPublisher = $publisher -match '(?i)gog'
            $installLocationRaw = Get-GoGRegistryEntryStringValue -Entry $entry -Name 'InstallLocation'
            $displayIcon = Get-GoGRegistryEntryStringValue -Entry $entry -Name 'DisplayIcon'
            $hasGoGInstallPath = $installLocationRaw -match '(?i)\\gog galaxy\\games|\\gog games'
            $hasGoGIconPath = $displayIcon -match '(?i)\\gog galaxy\\games|\\gog games'
            if (-not ($isGoGPublisher -or $hasGoGInstallPath -or $hasGoGIconPath)) { continue }

            # Skip launcher/install helper entries.
            if ($displayName -match '(?i)^gog galaxy(\s|$)|gog.com galaxy|redistributable|visual c\+\+|directx') {
                continue
            }

            $safeName = (Get-SafeFilename -Name $displayName).ToLowerInvariant()
            if (-not $safeName -or $seen.ContainsKey($safeName)) { continue }

            $installLocation = [Environment]::ExpandEnvironmentVariables($installLocationRaw)
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
                    (Join-Path $installLocation 'bin'),
                    (Join-Path $installLocation 'x64')
                ) | Select-Object -Unique

                $exeCandidates = @()
                foreach ($root in $searchRoots) {
                    if (Test-Path $root) {
                        $exeCandidates += Get-ChildItem -Path $root -Filter '*.exe' -File -ErrorAction SilentlyContinue
                    }
                }

                $exePath = ($exeCandidates |
                    Where-Object { $_.Name -notmatch '(?i)unins|uninstall|setup|config|crash|launcher|galaxy|support|updater' } |
                    Sort-Object Length -Descending |
                    Select-Object -First 1 -ExpandProperty FullName)
            }

            if ((-not $installLocation) -and $exePath) {
                $installLocation = Split-Path $exePath -Parent
            }

            if (-not $exePath -or -not (Test-Path $exePath)) {
                continue
            }

            if ($PreferredLibraryRoot -and (Test-Path $PreferredLibraryRoot)) {
                $normalizedRoot = [System.IO.Path]::GetFullPath($PreferredLibraryRoot).TrimEnd('\\')
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

function Sync-GoGGames {
    param(
        [string]$GogMenu,
        [string]$GogInstall,
        [string]$CustomIconsPath
    )

    Write-Host "`n=== GOG ===" -ForegroundColor Cyan

    $gogRoot = if ($GogInstall -and (Test-Path $GogInstall)) {
        $GogInstall
    } else {
        Get-GoGInstallPath
    }

    $games = @()
    if ($gogRoot) {
        $games = @(Get-GoGGameList -PreferredLibraryRoot $gogRoot | Sort-Object DisplayName)
    }

    if ($games.Count -eq 0) {
        $games = @(Get-GoGGameList | Sort-Object DisplayName)
    }

    if ($games.Count -eq 0) {
        Write-Host "  [SKIP]    No GOG games found" -ForegroundColor DarkYellow
        return
    }

    if (-not (Test-Path $GogMenu)) {
        New-Item -ItemType Directory -Path $GogMenu | Out-Null
    }

    $gogDescription = 'GOG Game'
    $installedGoGNames = $games | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    $installedGoGNamesLegacy = $installedGoGNames | ForEach-Object { $_ -replace ' ', '_' }
    $installedGoGNamesCombined = @($installedGoGNames + $installedGoGNamesLegacy) | Select-Object -Unique

    if (Test-Path $GogMenu) {
        Get-ChildItem $GogMenu -Filter '*.lnk' | ForEach-Object {
            $shortcutInfo = Get-GoGShortcutInfo -Path $_.FullName
            if ($shortcutInfo.Description -ne $gogDescription) { return }

            if ($installedGoGNamesCombined -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
    }

    foreach ($game in $games) {
        $safeName = Get-SafeFilename -Name $game.DisplayName
        $legacySafeName = $safeName -replace ' ', '_'
        $shortcutPath = Join-Path $GogMenu "$safeName.lnk"
        $legacyShortcutPath = Join-Path $GogMenu "$legacySafeName.lnk"

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
                Write-LnkShortcut -Path $shortcutPath -Target $game.ExePath -Arguments '' -IconFile $iconFile -Description $gogDescription
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - executable not found: $($game.ExePath)" -ForegroundColor DarkYellow
            }
            continue
        }

        $shortcutInfo = Get-GoGShortcutInfo -Path $shortcutPath
        $currentTarget = $shortcutInfo.TargetPath
        $currentIcon = $shortcutInfo.IconPath

        $needsFix = -not $currentTarget -or -not (Test-Path $currentTarget) -or
                    ($currentTarget -ne $game.ExePath) -or
                    -not $currentIcon -or -not (Test-Path $currentIcon) -or
                    ($customIco -and $currentIcon -ne $customIco) -or
                    ($shortcutInfo.Description -ne $gogDescription)

        if (-not $needsFix) {
            Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
        } elseif (Test-Path $game.ExePath) {
            Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
            Write-LnkShortcut -Path $shortcutPath -Target $game.ExePath -Arguments '' -IconFile $iconFile -Description $gogDescription
        } else {
            Write-Host "  [REMOVE]  $($game.DisplayName) - broken shortcut target not found" -ForegroundColor Red
            Remove-Item -LiteralPath $shortcutPath -Force
        }
    }
}
