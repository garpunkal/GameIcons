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
$global:Settings = Get-Settings -Path $SettingsPath
$rootPath = if ($global:RepoRoot) { $global:RepoRoot } else { $PSScriptRoot }

# Apply path settings from settings.json (parameters take precedence)
if ($global:Settings.paths) {
    if ($global:Settings.paths.steamInstall -and -not $PSBoundParameters.ContainsKey('SteamInstall')) {
        $SteamInstall = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.steamInstall)
    }
    if ($global:Settings.paths.epicManifests -and -not $PSBoundParameters.ContainsKey('EpicManifests')) {
        $EpicManifests = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.epicManifests)
    }
    if ($global:Settings.paths.ubisoftInstall) {
        $UbisoftInstall = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.ubisoftInstall)
    }
    if ($global:Settings.paths.battleNetInstall) {
        $BattleNetInstall = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.battleNetInstall)
    }
    if ($global:Settings.paths.gogInstall) {
        $GogInstall = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.gogInstall)
    }
    if ($global:Settings.paths.itchInstall) {
        $ItchInstall = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.itchInstall)
    }
    if ($global:Settings.paths.eaAppInstall) {
        $EaAppInstall = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.eaAppInstall)
    }
    if ($global:Settings.paths.rockstarInstall) {
        $RockstarInstall = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.rockstarInstall)
    }
    if ($global:Settings.paths.gamesMenu -and -not $PSBoundParameters.ContainsKey('GamesMenu')) {
        $GamesMenu = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.gamesMenu)
    }
    if ($global:Settings.paths.uwpIconCache -and -not $PSBoundParameters.ContainsKey('UwpIconCache')) {
        $UwpIconCache = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.uwpIconCache)
        # If it's a relative path, make it relative to script root
        if (-not [System.IO.Path]::IsPathRooted($UwpIconCache)) {
            $UwpIconCache = Join-Path $rootPath $UwpIconCache
        }
    }
    if ($global:Settings.paths.steamGridDbCache -and -not $PSBoundParameters.ContainsKey('SteamGridDbCache')) {
        $SteamGridDbCache = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.steamGridDbCache)
        # If it's a relative path, make it relative to script root
        if (-not [System.IO.Path]::IsPathRooted($SteamGridDbCache)) {
            $SteamGridDbCache = Join-Path $rootPath $SteamGridDbCache
        }
    }
    if ($global:Settings.paths.customIconsPath -and -not $PSBoundParameters.ContainsKey('CustomIconsPath')) {
        $CustomIconsPath = [Environment]::ExpandEnvironmentVariables($global:Settings.paths.customIconsPath)
        # If it's a relative path, make it relative to script root
        if (-not [System.IO.Path]::IsPathRooted($CustomIconsPath)) {
            $CustomIconsPath = Join-Path $rootPath $CustomIconsPath
        }
    }
}

# All platform shortcuts always go to the single configured Games folder.
$SteamMenu    = $GamesMenu
$EpicMenu     = $GamesMenu
$XboxMenu     = $GamesMenu
$MsStoreMenu  = $GamesMenu
$UbisoftMenu  = $GamesMenu
$BattleNetMenu = $GamesMenu
$GogMenu      = $GamesMenu
$ItchMenu     = $GamesMenu
$EaAppMenu    = $GamesMenu
$RockstarMenu = $GamesMenu

$global:SteamNonGameIds                    = $global:Settings.steamNonGameIds
$global:UwpServicePackageNames             = $global:Settings.uwpServicePackageNames
$global:MsPublisherPrefixes                = $global:Settings.msPublisherPrefixes
$global:SteamGridDbExcludedIconIdsByAppId  = $global:Settings.SteamGridDbExcludedIconIds
$global:SteamGridDbPreferredIconIdsByAppId = $global:Settings.SteamGridDbPreferredIconIds
