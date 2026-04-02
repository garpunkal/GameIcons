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

# Load consolidated settings
$script:Settings = Get-Settings -Path $SettingsPath
$script:SteamNonGameIds                   = $script:Settings.steamNonGameIds
$script:UwpServicePackageNames            = $script:Settings.uwpServicePackageNames
$script:MsPublisherPrefixes               = $script:Settings.msPublisherPrefixes
$script:SteamGridDbExcludedIconIdsByAppId = $script:Settings.SteamGridDbExcludedIconIds
$script:SteamGridDbPreferredIconIdsByAppId = $script:Settings.SteamGridDbPreferredIconIds
