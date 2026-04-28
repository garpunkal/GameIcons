<#
.SYNOPSIS
        Sync installed games into a single Start Menu Games folder.

.DESCRIPTION
        Detects installed games from Steam, Epic Games, Xbox Game Pass,
    Microsoft Store, Ubisoft Connect, Battle.net, GOG, itch.io, EA App, and Rockstar. Creates or repairs shortcuts and
        icons in one destination folder. Advanced behavior is configured via
        settings.json.

.PARAMETER GamesMenu
        Destination folder for all generated shortcuts.
        Default: %APPDATA%\Microsoft\Windows\Start Menu\Programs\Games.

.PARAMETER WhatIf
    Preview changes without writing anything.

.PARAMETER SkipIconCacheRefresh
    If set, skips the final Windows shell icon cache refresh step.

.PARAMETER SkipExplorerRestart
    If set, does not restart Explorer after icon cache refresh.

.EXAMPLE
    .\Sync.ps1

.EXAMPLE
    .\Sync.ps1 -WhatIf
#>
param(
    [string]$GamesMenu       = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Games",
    [switch]$SkipIconCacheRefresh,
    [switch]$SkipExplorerRestart
)

# Advanced configuration is intentionally handled via settings.json and local
# defaults to keep the command-line interface minimal.
$SteamInstall            = 'C:\Program Files (x86)\Steam'
$EpicManifests           = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
$UbisoftInstall          = ''
$BattleNetInstall        = ''
$GogInstall              = ''
$ItchInstall             = ''
$EaAppInstall            = ''
$RockstarInstall         = ''
$UwpIconCache            = (Join-Path $PSScriptRoot 'UwpIconCache')
$IncludeStorePackages    = @()
$SettingsPath            = (Join-Path $PSScriptRoot 'settings.json')
$CustomIconsPath         = (Join-Path $PSScriptRoot 'CustomIcons')
$UseSteamGridDb          = $true
$SteamGridDbApiKey       = $env:STEAMGRIDDB_API_KEY
$DotEnvPath              = (Join-Path $PSScriptRoot '.env')
$PersistSteamGridDbApiKey = $false
$SteamGridDbCache        = (Join-Path $PSScriptRoot 'SteamGridDbCache')
$RefreshSteamGridDb      = $true

# Per-platform shortcut destinations — default to the single GamesMenu folder.
# Override individually via settings.json paths.
$SteamMenu               = $GamesMenu
$EpicMenu                = $GamesMenu
$XboxMenu                = $GamesMenu
$MsStoreMenu             = $GamesMenu
$UbisoftMenu             = $GamesMenu
$BattleNetMenu           = $GamesMenu
$GogMenu                 = $GamesMenu
$ItchMenu                = $GamesMenu
$EaAppMenu               = $GamesMenu
$RockstarMenu            = $GamesMenu
$UseGamesFolderForAll    = $false
$UseSteamFolderForAll    = $false


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Canonical project root for dot-sourced partials.
$global:RepoRoot = $PSScriptRoot

# Dot-source all partial modules
$partialsPath = Join-Path $PSScriptRoot 'Partials'
$partialFiles = @(
    'Helpers.ps1',
    'IconResolution.ps1',
    'ShortcutOperations.ps1',
    'Settings.ps1',
    'Platforms\Steam.ps1',
    'Platforms\EpicGames.ps1',
    'Platforms\Xbox.ps1',
    'Platforms\MicrosoftStore.ps1',
    'Platforms\Ubisoft.ps1',
    'Platforms\BattleNet.ps1',
    'Platforms\GoG.ps1',
    'Platforms\ItchIo.ps1',
    'Platforms\EaApp.ps1',
    'Platforms\Rockstar.ps1'
)

# Add CustomApps as a platform
$partialFiles += 'Platforms\CustomApps.ps1'


foreach ($file in $partialFiles) {
    $partialPath = Join-Path $partialsPath $file
    if (Test-Path $partialPath) {
        . $partialPath
    } else {
        Write-Host "  [WARN]    Partial not found: $partialPath" -ForegroundColor DarkYellow
    }
}



###############################################################################

###############################################################################
# ORCHESTRATION: Run platform sync functions
###############################################################################


# Sync Custom Apps as a platform
Sync-CustomApps -CustomAppsMenu $GamesMenu -CustomIconsPath $CustomIconsPath -SettingsPath $SettingsPath

# Sync Steam games
Sync-SteamGames -SteamInstall $SteamInstall -SteamMenu $SteamMenu `
    -CustomIconsPath $CustomIconsPath -SteamGridDbCache $SteamGridDbCache -UwpIconCache $UwpIconCache

# Sync Epic Games
Sync-EpicGames -EpicManifests $EpicManifests -EpicMenu $EpicMenu `
    -CustomIconsPath $CustomIconsPath -SteamGridDbCache $SteamGridDbCache -UwpIconCache $UwpIconCache

# Sync Xbox Game Pass (capture installed names for potential shared Store folder)
$installedXboxNames = @(Sync-XboxGamePass -XboxMenu $XboxMenu `
    -CustomIconsPath $CustomIconsPath -SteamGridDbCache $SteamGridDbCache -UwpIconCache $UwpIconCache)

# Sync Microsoft Store Games (with shared Xbox folder deduplication)
$mergedIncludeStorePackages = @($IncludeStorePackages + $global:Settings.includeStorePackages) | Select-Object -Unique
Sync-MicrosoftStoreGames -MsStoreMenu $MsStoreMenu `
    -CustomIconsPath $CustomIconsPath -SteamGridDbCache $SteamGridDbCache -UwpIconCache $UwpIconCache `
    -InstalledXboxNames $installedXboxNames -IncludeStorePackages $mergedIncludeStorePackages

# Sync Ubisoft Connect Games
Sync-UbisoftGames -UbisoftMenu $UbisoftMenu `
    -UbisoftInstall $UbisoftInstall -CustomIconsPath $CustomIconsPath

# Sync Battle.net Games
Sync-BattleNetGames -BattleNetMenu $BattleNetMenu `
    -BattleNetInstall $BattleNetInstall -CustomIconsPath $CustomIconsPath

# Sync GOG Games
Sync-GoGGames -GogMenu $GogMenu `
    -GogInstall $GogInstall -CustomIconsPath $CustomIconsPath

# Sync itch.io Games
Sync-ItchIoGames -ItchMenu $ItchMenu `
    -ItchInstall $ItchInstall -CustomIconsPath $CustomIconsPath

# Sync EA App Games
Sync-EaAppGames -EaAppMenu $EaAppMenu `
    -EaAppInstall $EaAppInstall -CustomIconsPath $CustomIconsPath

# Sync Rockstar Games
Sync-RockstarGames -RockstarMenu $RockstarMenu `
    -RockstarInstall $RockstarInstall -CustomIconsPath $CustomIconsPath

if (-not $SkipIconCacheRefresh) {
    try {
        Write-Host "`n=== Refresh Icon Cache ===" -ForegroundColor Blue

        if ($PSCmdlet.ShouldProcess('Windows shell icon cache', 'Refresh icon cache')) {
            $ie4uinitPath = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
            if (Test-Path $ie4uinitPath) {
                & $ie4uinitPath -show
                Write-Host "  Icon cache refresh triggered." -ForegroundColor DarkGray
            } else {
                Write-Host "  [SKIP]    Icon cache refresh tool not found: $ie4uinitPath" -ForegroundColor DarkYellow
            }
        }

        if (-not $SkipExplorerRestart) {
            if ($PSCmdlet.ShouldProcess('Explorer shell', 'Restart Explorer')) {
                Stop-Process -Name explorer -Force -ErrorAction Stop
                Write-Host "  Explorer restart triggered (Windows will relaunch the shell)." -ForegroundColor DarkGray
            }
        }
    } catch {
        Write-Host "  [SKIP]    Shell refresh/restart failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

Write-Host "`nDone." -ForegroundColor Cyan