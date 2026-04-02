<#
.SYNOPSIS
    Syncs Steam, Epic Games, Xbox Game Pass, Microsoft Store, and Ubisoft Connect
    installed libraries to Start Menu shortcuts, creating missing shortcuts and
    fixing broken icon paths.

.DESCRIPTION
    Steam:
      - Reads all library folders from libraryfolders.vdf
      - Scans appmanifest_*.acf for every installed game
      - Creates a .url shortcut if one is missing
      - Converts the library-cache icon JPG to .ico if needed
      - Fixes any shortcut whose IconFile path is broken

    Epic Games:
      - Reads all *.item manifests from the Epic launcher data folder
      - Skips DLC entries (no LaunchExecutable) and incomplete installs
      - Deduplicates by AppName
      - Creates a .url shortcut if one is missing
      - Fixes any shortcut whose IconFile path is broken

    Xbox Game Pass:
      - Enumerates installed AppX packages with the xboxLive capability
        or ms-xbl-* protocol registrations (e.g. Minecraft for Windows)
      - Resolves the highest-resolution logo from the package assets
      - Creates a .lnk shortcut launching via shell:AppsFolder if missing
      - Fixes any shortcut whose IconLocation path is broken

    Microsoft Store Games:
      - Enumerates installed AppX packages that declare xboxManageTiles,
        xboxGameBroadcast, or gameInput capabilities (but not xboxLive, to
        avoid duplication with the Xbox section)
      - Excludes framework, resource, system, and Microsoft-published packages
      - Creates a .lnk shortcut launching via shell:AppsFolder if missing
      - Fixes any shortcut whose IconLocation path is broken

    Ubisoft Connect:
      - Reads Ubisoft Connect game manifests from %LOCALAPPDATA%\Ubisoft Game Launcher\games
      - Parses game.json/installation.json files for game metadata
      - Creates uplay://launch/{game_id} .url shortcuts if missing
      - Fixes any shortcut whose IconFile path is broken

.PARAMETER SteamInstall
    Path to the Steam installation directory.
    Default: C:\Program Files (x86)\Steam

.PARAMETER SteamMenu
    Path to the Steam Start Menu programs folder.

.PARAMETER UseGamesFolderForAll
    If set, routes Steam, Epic, Xbox Game Pass, Microsoft Store, and Ubisoft Connect
    shortcuts to a single folder defined by -GamesMenu.

.PARAMETER GamesMenu
    Start Menu folder used when -UseGamesFolderForAll is set.
    Default: %APPDATA%\Microsoft\Windows\Start Menu\Programs\Games

.PARAMETER UseSteamFolderForAll
    If set, routes Epic, Xbox Game Pass, and Microsoft Store shortcuts to the
    same Start Menu folder as Steam (-SteamMenu). Kept for backward
    compatibility; prefer -UseGamesFolderForAll for new setups.

.PARAMETER EpicMenu
    Path to the Epic Games Start Menu programs folder.

.PARAMETER EpicManifests
    Path to the Epic Games launcher manifests folder.

.PARAMETER XboxMenu
    Path to the Xbox Game Pass Start Menu programs folder.

.PARAMETER MsStoreMenu
    Path to the Microsoft Store Games Start Menu programs folder.

.PARAMETER UbisoftMenu
    Path to the Ubisoft Connect Start Menu programs folder.

.PARAMETER UwpIconCache
    Folder where generated .ico files for UWP packages are cached.

.PARAMETER IncludeStorePackages
    Array of package Name patterns (wildcards supported) to force-include in
    the Microsoft Store Games section regardless of declared capabilities.
    Useful for games that only declare 'internetClient' (e.g. Rummy 500).
    Example: -IncludeStorePackages 'TrivialTechnology.UltimateRummy500','AnotherPublisher.*'

.PARAMETER SettingsPath
    Path to the JSON settings file containing exclusion lists, publisher
    prefixes, and other configuration. Default: config\settings.json next
    to the script.

.PARAMETER WhatIf
    Preview changes without writing anything.

.PARAMETER UseSteamGridDb
    If set, attempts to fetch Steam game icons from SteamGridDB.
    Resolution order:
      1. SteamGridDB official icons (original Steam assets hosted on SGDB)
      2. SteamGridDB all styles sorted by score (community icons)
            3. Cached icons from SteamGridDbCache or UwpIconCache
            4. Local Steam assets (clienticon / library cache artwork)

.PARAMETER SteamGridDbApiKey
    SteamGridDB API key. If omitted, uses environment variable
    STEAMGRIDDB_API_KEY.

.PARAMETER DotEnvPath
    Optional path to a .env file used to load STEAMGRIDDB_API_KEY when no
    explicit key or environment key is available.

.PARAMETER PersistSteamGridDbApiKey
    If set and a SteamGridDB API key is resolved, saves it to the current
    user's environment (STEAMGRIDDB_API_KEY) for future terminals.

.PARAMETER SteamGridDbCache
    Cache folder for SteamGridDB-downloaded icon assets.

.PARAMETER RefreshSteamGridDb
    If set with -UseSteamGridDb, forces re-download of cached SteamGridDB
    assets.

.PARAMETER SkipIconCacheRefresh
    If set, skips the final Windows shell icon cache refresh step.

.PARAMETER SkipExplorerRestart
    If set, does not restart Explorer after icon cache refresh.

.EXAMPLE
    .\Sync-GameShortcuts.ps1

.EXAMPLE
    .\Sync-GameShortcuts.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SteamInstall    = 'C:\Program Files (x86)\Steam',
    [string]$SteamMenu       = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Steam",
    [switch]$UseGamesFolderForAll = $true,
    [string]$GamesMenu       = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Games",
    [switch]$UseSteamFolderForAll,
    [string]$EpicMenu        = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Epic Games",
    [string]$EpicManifests   = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests',
    [string]$XboxMenu        = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Xbox",
    [string]$MsStoreMenu     = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Store",
    [string]$UbisoftMenu     = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Games",
    [string]$UwpIconCache    = (Join-Path $PSScriptRoot 'UwpIconCache'),
    # Package Name patterns (wildcards OK) to force-include in the MS Store section
    # even if the app declares no gaming capabilities. Persisted in settings.json.
    [string[]]$IncludeStorePackages = @(),
    [string]$SettingsPath = (Join-Path $PSScriptRoot 'settings.json'),
    # Folder for custom icon overrides. Drop a <GameName>.ico or <GameName>.png
    # here to override the auto-detected icon for any game.
    # Get free icons from: https://www.steamgriddb.com  (Icons tab, choose ICO/PNG)
    [string]$CustomIconsPath = (Join-Path $PSScriptRoot 'CustomIcons'),
    [switch]$UseSteamGridDb = $true,
    [string]$SteamGridDbApiKey = $env:STEAMGRIDDB_API_KEY,
    [string]$DotEnvPath = (Join-Path $PSScriptRoot '.env'),
    [switch]$PersistSteamGridDbApiKey,
    [string]$SteamGridDbCache  = (Join-Path $PSScriptRoot 'SteamGridDbCache'),
    [switch]$RefreshSteamGridDb = $true,
    [switch]$SkipIconCacheRefresh,
    [switch]$SkipExplorerRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

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
    'Platforms\Ubisoft.ps1'
)

foreach ($file in $partialFiles) {
    $partialPath = Join-Path $partialsPath $file
    if (Test-Path $partialPath) {
        . $partialPath
    } else {
        Write-Host "  [WARN]    Partial not found: $partialPath" -ForegroundColor DarkYellow
    }
}

###############################################################################
# ORCHESTRATION: Run platform sync functions
###############################################################################

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
Sync-MicrosoftStoreGames -MsStoreMenu $MsStoreMenu `
    -CustomIconsPath $CustomIconsPath -SteamGridDbCache $SteamGridDbCache -UwpIconCache $UwpIconCache `
    -InstalledXboxNames $installedXboxNames

# Sync Ubisoft Connect Games
$installedUbisoftNames = @(Sync-UbisoftGames -UbisoftMenu $UbisoftMenu `
    -CustomIconsPath $CustomIconsPath -SteamGridDbCache $SteamGridDbCache -UwpIconCache $UwpIconCache)

if (-not $SkipIconCacheRefresh) {
    try {
        Write-Host "`n=== Refresh Icon Cache ===" -ForegroundColor Cyan

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