# itch.io platform operations

function Get-ItchIoInstallPath {
    param([string]$ConfiguredPath = '')

    if ($ConfiguredPath) {
        $expandedConfigured = [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
        if (Test-Path $expandedConfigured) {
            return $expandedConfigured
        }
    }

    $defaultPaths = @(
        (Join-Path $env:APPDATA 'itch\apps'),
        (Join-Path $env:LOCALAPPDATA 'itch\apps')
    )

    foreach ($path in $defaultPaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

function Get-ItchIoGameList {
    param([string]$PreferredLibraryRoot)

    if (-not $PreferredLibraryRoot -or -not (Test-Path $PreferredLibraryRoot)) {
        return @()
    }

    $games = @()
    $seen = @{}


    # Recursively scan all subfolders under the library root for .exe files, grouping by top-level folder
    Get-ChildItem -Path $PreferredLibraryRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $gameFolder = $_
        $displayName = $gameFolder.Name -replace '_', ' '
        $safeName = (Get-SafeFilename -Name $displayName).ToLowerInvariant()
        if (-not $safeName -or $seen.ContainsKey($safeName)) {
            return
        }


        # Find all .exe files under this game folder (any depth)
        $exeCandidates = Get-ChildItem -Path $gameFolder.FullName -Recurse -Filter '*.exe' -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch '(?i)\\.itch\\' -and
                $_.Name -notmatch '(?i)unins|uninstall|setup|crash|updater|itch|butler|prereq|redist'
            }


        $exePath = ($exeCandidates |
            Sort-Object Length -Descending |
            Select-Object -First 1 -ExpandProperty FullName)

        if (-not $exePath -or -not (Test-Path $exePath)) {
            return
        }

        $seen[$safeName] = $true
        $games += [PSCustomObject]@{
            DisplayName = $displayName
            ExePath     = $exePath
            InstallPath = $gameFolder.FullName
        }
    }

    return $games
}

function Get-ItchIoShortcutInfo {
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

function Sync-ItchIoGames {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ItchMenu,
        [string]$ItchInstall,
        [string]$CustomIconsPath
    )

    Write-Host "`n=== itch.io ===" -ForegroundColor Cyan

    $itchRoot = Get-ItchIoInstallPath -ConfiguredPath $ItchInstall
    if (-not $itchRoot) {
        Write-Host "  [SKIP]    itch.io apps folder not found (set paths.itchInstall in settings.json)" -ForegroundColor DarkYellow
        return
    }

    $games = @(Get-ItchIoGameList -PreferredLibraryRoot $itchRoot | Sort-Object DisplayName)
    if ($games.Count -eq 0) {
        Write-Host "  [SKIP]    No itch.io games found" -ForegroundColor DarkYellow
        return
    }

    if (-not (Test-Path $ItchMenu)) {
        if ($PSCmdlet.ShouldProcess($ItchMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $ItchMenu | Out-Null
        }
    }

    $itchDescription = 'itch.io Game'
    $installedItchNames = $games | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    $installedItchNamesLegacy = $installedItchNames | ForEach-Object { $_ -replace ' ', '_' }
    $installedItchNamesCombined = @($installedItchNames + $installedItchNamesLegacy) | Select-Object -Unique

    if (Test-Path $ItchMenu) {
        Get-ChildItem $ItchMenu -Filter '*.lnk' | ForEach-Object {
            $shortcutInfo = Get-ItchIoShortcutInfo -Path $_.FullName
            if ($shortcutInfo.Description -ne $itchDescription) { return }

            if ($installedItchNamesCombined -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    foreach ($game in $games) {
        $safeName = Get-SafeFilename -Name $game.DisplayName
        $shortcutPath = Join-Path $ItchMenu "$safeName.lnk"
        $customIco = if ($CustomIconsPath) { Join-Path $CustomIconsPath "$safeName.ico" } else { '' }
        $iconFile = if ($customIco -and (Test-Path $customIco)) { $customIco } else { $game.ExePath }

        $shortcutInfo = Get-ItchIoShortcutInfo -Path $shortcutPath
        $currentTarget = $shortcutInfo.TargetPath
        $currentIcon = $shortcutInfo.IconPath

        $needsFix = -not $currentTarget -or -not (Test-Path $currentTarget) -or
                    ($currentTarget -ne $game.ExePath) -or
                    -not $currentIcon -or -not (Test-Path $currentIcon) -or
                    ($customIco -and $currentIcon -ne $customIco) -or
                    ($shortcutInfo.Description -ne $itchDescription)

        if (-not $needsFix) {
            Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
        } elseif (Test-Path $game.ExePath) {
            Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
            Write-LnkShortcut -Path $shortcutPath -Target $game.ExePath -Arguments '' -IconFile $iconFile -Description $itchDescription
        } else {
            Write-Host "  [REMOVE]  $($game.DisplayName) - broken shortcut target not found" -ForegroundColor Red
            if ($PSCmdlet.ShouldProcess($shortcutPath, 'Remove shortcut with broken target')) {
                Remove-Item -LiteralPath $shortcutPath -Force
            }
        }
    }
}
