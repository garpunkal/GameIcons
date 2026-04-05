# Settings initialization and API key resolution

# Resolve API key from broader environment scopes so SteamGridDB can work
# even when the current shell session does not have the process variable.
if (-not $SteamGridDbApiKey) {
    foreach ($scope in @('User', 'Machine')) {
        try {
            $candidate = [Environment]::GetEnvironmentVariable('STEAMGRIDDB_API_KEY', $scope)
            if ($candidate) {
                $SteamGridDbApiKey = $candidate
                Write-Host "SteamGridDB API key loaded from $scope environment scope." -ForegroundColor DarkGray
                break
            }
        } catch {
            # Ignore environment lookup errors and continue probing scopes.
        }
    }
}

# Optionally resolve from a local .env file for convenience.
if (-not $SteamGridDbApiKey -and $DotEnvPath -and (Test-Path $DotEnvPath)) {
    try {
        $dotenvLine = Get-Content -LiteralPath $DotEnvPath -ErrorAction Stop |
                      Where-Object { $_ -match '^\s*STEAMGRIDDB_API_KEY\s*=' } |
                      Select-Object -First 1
        if ($dotenvLine -match '^\s*STEAMGRIDDB_API_KEY\s*=\s*(.+?)\s*$') {
            $candidate = $matches[1].Trim().Trim("'").Trim('"')
            if ($candidate) {
                $SteamGridDbApiKey = $candidate
                Write-Host "SteamGridDB API key loaded from .env file." -ForegroundColor DarkGray
            }
        }
    } catch {
        # Ignore .env read/parse errors and continue without failing the run.
    }
}

# Keep the current process variable in sync once a key is resolved.
if ($SteamGridDbApiKey -and -not $env:STEAMGRIDDB_API_KEY) {
    $env:STEAMGRIDDB_API_KEY = $SteamGridDbApiKey
}

# Optional one-time persistence for future shells.
if ($PersistSteamGridDbApiKey) {
    if ($SteamGridDbApiKey) {
        if ($PSCmdlet.ShouldProcess('User environment STEAMGRIDDB_API_KEY', 'Persist SteamGridDB API key')) {
            [Environment]::SetEnvironmentVariable('STEAMGRIDDB_API_KEY', $SteamGridDbApiKey, 'User')
            Write-Host "SteamGridDB API key saved to User environment scope." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [SKIP]    PersistSteamGridDbApiKey was set but no SteamGridDB API key was resolved." -ForegroundColor DarkYellow
    }
}

# Load consolidated settings
$script:Settings = Get-Settings -Path $SettingsPath

# Apply path settings from settings.json (parameters take precedence)
if ($script:Settings.paths) {
    if ($script:Settings.paths.steamInstall -and -not $PSBoundParameters.ContainsKey('SteamInstall')) {
        $SteamInstall = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.steamInstall)
    }
    if ($script:Settings.paths.steamMenu -and -not $PSBoundParameters.ContainsKey('SteamMenu')) {
        $SteamMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.steamMenu)
    }
    if ($script:Settings.paths.epicMenu -and -not $PSBoundParameters.ContainsKey('EpicMenu')) {
        $EpicMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.epicMenu)
    }
    if ($script:Settings.paths.epicManifests -and -not $PSBoundParameters.ContainsKey('EpicManifests')) {
        $EpicManifests = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.epicManifests)
    }
    if ($script:Settings.paths.xboxMenu -and -not $PSBoundParameters.ContainsKey('XboxMenu')) {
        $XboxMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.xboxMenu)
    }
    if ($script:Settings.paths.msStoreMenu -and -not $PSBoundParameters.ContainsKey('MsStoreMenu')) {
        $MsStoreMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.msStoreMenu)
    }
    if ($script:Settings.paths.ubisoftMenu -and -not $PSBoundParameters.ContainsKey('UbisoftMenu')) {
        $UbisoftMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.ubisoftMenu)
    }
    if ($script:Settings.paths.gamesMenu -and -not $PSBoundParameters.ContainsKey('GamesMenu')) {
        $GamesMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.gamesMenu)
    }
    if ($script:Settings.paths.uwpIconCache -and -not $PSBoundParameters.ContainsKey('UwpIconCache')) {
        $UwpIconCache = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.uwpIconCache)
        # If it's a relative path, make it relative to script root
        if (-not [System.IO.Path]::IsPathRooted($UwpIconCache)) {
            $UwpIconCache = Join-Path $PSScriptRoot $UwpIconCache
        }
    }
    if ($script:Settings.paths.steamGridDbCache -and -not $PSBoundParameters.ContainsKey('SteamGridDbCache')) {
        $SteamGridDbCache = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.steamGridDbCache)
        # If it's a relative path, make it relative to script root
        if (-not [System.IO.Path]::IsPathRooted($SteamGridDbCache)) {
            $SteamGridDbCache = Join-Path $PSScriptRoot $SteamGridDbCache
        }
    }
    if ($script:Settings.paths.customIconsPath -and -not $PSBoundParameters.ContainsKey('CustomIconsPath')) {
        $CustomIconsPath = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.customIconsPath)
        # If it's a relative path, make it relative to script root
        if (-not [System.IO.Path]::IsPathRooted($CustomIconsPath)) {
            $CustomIconsPath = Join-Path $PSScriptRoot $CustomIconsPath
        }
    }
}

# New preferred mode: place all shortcuts in an explicit Games folder.
if ($UseGamesFolderForAll) {
    $SteamMenu    = $GamesMenu
    $EpicMenu     = $GamesMenu
    $XboxMenu     = $GamesMenu
    $MsStoreMenu  = $GamesMenu
    $UbisoftMenu  = $GamesMenu
}

# Convenience switch to place all generated shortcuts in the Steam menu folder.
if ($UseSteamFolderForAll -and -not $UseGamesFolderForAll) {
    $EpicMenu     = $SteamMenu
    $XboxMenu     = $SteamMenu
    $MsStoreMenu  = $SteamMenu
    $UbisoftMenu  = $SteamMenu
}

Write-Host "Shortcut destinations:" -ForegroundColor DarkGray
Write-Host "  Steam:           $SteamMenu" -ForegroundColor DarkGray
Write-Host "  Epic Games:      $EpicMenu" -ForegroundColor DarkGray
Write-Host "  Xbox Game Pass:  $XboxMenu" -ForegroundColor DarkGray
Write-Host "  Microsoft Store: $MsStoreMenu" -ForegroundColor DarkGray
Write-Host "  Ubisoft Connect: $UbisoftMenu" -ForegroundColor DarkGray

# Apply path settings from settings.json (parameters take precedence)
if ($script:Settings.paths) {
    if ($script:Settings.paths.steamInstall -and -not $PSBoundParameters.ContainsKey('SteamInstall')) {
        $SteamInstall = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.steamInstall)
    }
    if ($script:Settings.paths.steamMenu -and -not $PSBoundParameters.ContainsKey('SteamMenu')) {
        $SteamMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.steamMenu)
    }
    if ($script:Settings.paths.epicMenu -and -not $PSBoundParameters.ContainsKey('EpicMenu')) {
        $EpicMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.epicMenu)
    }
    if ($script:Settings.paths.epicManifests -and -not $PSBoundParameters.ContainsKey('EpicManifests')) {
        $EpicManifests = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.epicManifests)
    }
    if ($script:Settings.paths.xboxMenu -and -not $PSBoundParameters.ContainsKey('XboxMenu')) {
        $XboxMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.xboxMenu)
    }
    if ($script:Settings.paths.msStoreMenu -and -not $PSBoundParameters.ContainsKey('MsStoreMenu')) {
        $MsStoreMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.msStoreMenu)
    }
    if ($script:Settings.paths.ubisoftMenu -and -not $PSBoundParameters.ContainsKey('UbisoftMenu')) {
        $UbisoftMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.ubisoftMenu)
    }
    if ($script:Settings.paths.gamesMenu -and -not $PSBoundParameters.ContainsKey('GamesMenu')) {
        $GamesMenu = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.gamesMenu)
    }
    if ($script:Settings.paths.uwpIconCache -and -not $PSBoundParameters.ContainsKey('UwpIconCache')) {
        $UwpIconCache = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.uwpIconCache)
        # If it's a relative path, make it relative to script root
        if (-not [System.IO.Path]::IsPathRooted($UwpIconCache)) {
            $UwpIconCache = Join-Path $PSScriptRoot $UwpIconCache
        }
    }
    if ($script:Settings.paths.steamGridDbCache -and -not $PSBoundParameters.ContainsKey('SteamGridDbCache')) {
        $SteamGridDbCache = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.steamGridDbCache)
        # If it's a relative path, make it relative to script root
        if (-not [System.IO.Path]::IsPathRooted($SteamGridDbCache)) {
            $SteamGridDbCache = Join-Path $PSScriptRoot $SteamGridDbCache
        }
    }
    if ($script:Settings.paths.customIconsPath -and -not $PSBoundParameters.ContainsKey('CustomIconsPath')) {
        $CustomIconsPath = [Environment]::ExpandEnvironmentVariables($script:Settings.paths.customIconsPath)
        # If it's a relative path, make it relative to script root
        if (-not [System.IO.Path]::IsPathRooted($CustomIconsPath)) {
            $CustomIconsPath = Join-Path $PSScriptRoot $CustomIconsPath
        }
    }
}

$script:SteamNonGameIds                   = $script:Settings.steamNonGameIds
$script:UwpServicePackageNames            = $script:Settings.uwpServicePackageNames
$script:MsPublisherPrefixes               = $script:Settings.msPublisherPrefixes
$script:SteamGridDbExcludedIconIdsByAppId = $script:Settings.SteamGridDbExcludedIconIds
$script:SteamGridDbPreferredIconIdsByAppId = $script:Settings.SteamGridDbPreferredIconIds
