# Rockstar platform operations

function Get-RockstarRegistryEntryStringValue {
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

function Get-RockstarInstallPath {
    param([string]$ConfiguredPath = '')

    if ($ConfiguredPath) {
        $expandedConfigured = [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
        if (Test-Path $expandedConfigured) {
            return $expandedConfigured
        }
    }

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $uninstallPaths) {
        $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        foreach ($entry in $entries) {
            $displayName = Get-RockstarRegistryEntryStringValue -Entry $entry -Name 'DisplayName'
            if (-not $displayName) { continue }
            if ($displayName -notmatch '(?i)^rockstar games launcher(\s|$)') { continue }

            $installLocationRaw = Get-RockstarRegistryEntryStringValue -Entry $entry -Name 'InstallLocation'
            $installLocation = [Environment]::ExpandEnvironmentVariables($installLocationRaw)
            if ($installLocation -and (Test-Path $installLocation)) {
                return $installLocation
            }

            $displayIcon = Get-RockstarRegistryEntryStringValue -Entry $entry -Name 'DisplayIcon'
            if ($displayIcon) {
                $iconPath = ($displayIcon -split ',')[0].Trim().Trim('"')
                if ($iconPath -and (Test-Path $iconPath)) {
                    return (Split-Path $iconPath -Parent)
                }
            }
        }
    }

    foreach ($defaultPath in @('C:\Program Files\Rockstar Games\Launcher', 'C:\Program Files (x86)\Rockstar Games\Launcher')) {
        if (Test-Path $defaultPath) {
            return $defaultPath
        }
    }

    return $null
}

function Get-RockstarShortcutInfo {
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

function Get-RockstarGameList {
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
            $displayName = Get-RockstarRegistryEntryStringValue -Entry $entry -Name 'DisplayName'
            if (-not $displayName) { continue }

            $publisher = Get-RockstarRegistryEntryStringValue -Entry $entry -Name 'Publisher'
            $installLocationRaw = Get-RockstarRegistryEntryStringValue -Entry $entry -Name 'InstallLocation'
            $displayIcon = Get-RockstarRegistryEntryStringValue -Entry $entry -Name 'DisplayIcon'

            $isRockstarPublisher = $publisher -match '(?i)rockstar games'
            $hasRockstarInstallPath = $installLocationRaw -match '(?i)\\rockstar games\\'
            $hasRockstarIconPath = $displayIcon -match '(?i)\\rockstar games\\'
            if (-not ($isRockstarPublisher -or $hasRockstarInstallPath -or $hasRockstarIconPath)) { continue }

            if ($displayName -match '(?i)^rockstar games launcher(\s|$)|social club|redistributable|prerequisite|launcher service') {
                continue
            }

            $safeName = (Get-SafeFilename -Name $displayName).ToLowerInvariant()
            if (-not $safeName -or $seen.ContainsKey($safeName)) { continue }

            $installLocation = [Environment]::ExpandEnvironmentVariables($installLocationRaw)
            $exePath = ''

            if ($displayIcon) {
                $iconPath = ($displayIcon -split ',')[0].Trim().Trim('"')
                if ($iconPath -and $iconPath.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path $iconPath) -and $iconPath -notmatch '(?i)launcher') {
                    $exePath = $iconPath
                }
            }

            if (-not $exePath -and $installLocation -and (Test-Path $installLocation)) {
                $searchRoots = @(
                    $installLocation,
                    (Join-Path $installLocation 'Bin'),
                    (Join-Path $installLocation 'x64')
                ) | Select-Object -Unique

                $exeCandidates = @()
                foreach ($root in $searchRoots) {
                    if (Test-Path $root) {
                        $exeCandidates += Get-ChildItem -Path $root -Filter '*.exe' -File -ErrorAction SilentlyContinue
                    }
                }

                $exePath = ($exeCandidates |
                    Where-Object { $_.Name -notmatch '(?i)unins|uninstall|setup|config|crash|launcher|socialclub|updater' } |
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

function Sync-RockstarGames {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$RockstarMenu,
        [string]$RockstarInstall,
        [string]$CustomIconsPath
    )

    Write-Host "`n=== Rockstar ===" -ForegroundColor Cyan

    $rockstarRoot = if ($RockstarInstall -and (Test-Path $RockstarInstall)) {
        $RockstarInstall
    } else {
        Get-RockstarInstallPath
    }

    $games = @()
    if ($rockstarRoot) {
        $games = @(Get-RockstarGameList -PreferredLibraryRoot $rockstarRoot | Sort-Object DisplayName)
    }

    if ($games.Count -eq 0) {
        $games = @(Get-RockstarGameList | Sort-Object DisplayName)
    }

    if ($games.Count -eq 0) {
        Write-Host "  [SKIP]    No Rockstar games found" -ForegroundColor DarkYellow
        return
    }

    if (-not (Test-Path $RockstarMenu)) {
        if ($PSCmdlet.ShouldProcess($RockstarMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $RockstarMenu | Out-Null
        }
    }

    $rockstarDescription = 'Rockstar Game'
    $installedRockstarNames = $games | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    $installedRockstarNamesLegacy = $installedRockstarNames | ForEach-Object { $_ -replace ' ', '_' }
    $installedRockstarNamesCombined = @($installedRockstarNames + $installedRockstarNamesLegacy) | Select-Object -Unique

    if (Test-Path $RockstarMenu) {
        Get-ChildItem $RockstarMenu -Filter '*.lnk' | ForEach-Object {
            $shortcutInfo = Get-RockstarShortcutInfo -Path $_.FullName
            if ($shortcutInfo.Description -ne $rockstarDescription) { return }

            if ($installedRockstarNamesCombined -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    foreach ($game in $games) {
        $safeName = Get-SafeFilename -Name $game.DisplayName
        $legacySafeName = $safeName -replace ' ', '_'
        $shortcutPath = Join-Path $RockstarMenu "$safeName.lnk"
        $legacyShortcutPath = Join-Path $RockstarMenu "$legacySafeName.lnk"

        if ((-not (Test-Path $shortcutPath)) -and (Test-Path $legacyShortcutPath)) {
            Write-Host "  [MIGRATE] Renaming legacy shortcut $legacySafeName.lnk -> $safeName.lnk" -ForegroundColor Cyan
            if ($PSCmdlet.ShouldProcess($legacyShortcutPath, 'Rename legacy shortcut')) {
                Rename-Item -Path $legacyShortcutPath -NewName (Split-Path $shortcutPath -Leaf) -Force
            }
        }

        if ((Test-Path $shortcutPath) -and (Test-Path $legacyShortcutPath) -and ($legacyShortcutPath -ne $shortcutPath)) {
            Write-Host "  [REMOVE] Duplicate legacy shortcut $legacySafeName.lnk" -ForegroundColor Red
            if ($PSCmdlet.ShouldProcess($legacyShortcutPath, 'Remove duplicate shortcut')) {
                Remove-Item -LiteralPath $legacyShortcutPath -Force
            }
        }

        $customIco = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        $iconFile = if ($customIco) { $customIco } else { $game.ExePath }

        if (-not (Test-Path $shortcutPath)) {
            if (Test-Path $game.ExePath) {
                Write-Host "  [CREATE]  $($game.DisplayName)" -ForegroundColor Green
                Write-LnkShortcut -Path $shortcutPath -Target $game.ExePath -Arguments '' -IconFile $iconFile -Description $rockstarDescription
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - executable not found: $($game.ExePath)" -ForegroundColor DarkYellow
            }
            continue
        }

        $shortcutInfo = Get-RockstarShortcutInfo -Path $shortcutPath
        $currentTarget = $shortcutInfo.TargetPath
        $currentIcon = $shortcutInfo.IconPath

        $needsFix = -not $currentTarget -or -not (Test-Path $currentTarget) -or
                    ($currentTarget -ne $game.ExePath) -or
                    -not $currentIcon -or -not (Test-Path $currentIcon) -or
                    ($customIco -and $currentIcon -ne $customIco) -or
                    ($shortcutInfo.Description -ne $rockstarDescription)

        if (-not $needsFix) {
            Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
        } elseif (Test-Path $game.ExePath) {
            Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
            Write-LnkShortcut -Path $shortcutPath -Target $game.ExePath -Arguments '' -IconFile $iconFile -Description $rockstarDescription
        } else {
            Write-Host "  [REMOVE]  $($game.DisplayName) - broken shortcut target not found" -ForegroundColor Red
            if ($PSCmdlet.ShouldProcess($shortcutPath, 'Remove shortcut with broken target')) {
                Remove-Item -LiteralPath $shortcutPath -Force
            }
        }
    }
}
