<#
.SYNOPSIS
    Syncs Steam, Epic Games, Xbox Game Pass, and Microsoft Store installed
    libraries to Start Menu shortcuts, creating missing shortcuts and fixing
    broken icon paths.

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

.PARAMETER SteamInstall
    Path to the Steam installation directory.
    Default: C:\Program Files (x86)\Steam

.PARAMETER SteamMenu
    Path to the Steam Start Menu programs folder.

.PARAMETER UseGamesFolderForAll
    If set, routes Steam, Epic, Xbox Game Pass, and Microsoft Store shortcuts
    to a single folder defined by -GamesMenu.

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

.PARAMETER UwpIconCache
    Folder where generated .ico files for UWP packages are cached.

.PARAMETER IncludeStorePackages
    Array of package Name patterns (wildcards supported) to force-include in
    the Microsoft Store Games section regardless of declared capabilities.
    Useful for games that only declare 'internetClient' (e.g. Rummy 500).
    Example: -IncludeStorePackages 'TrivialTechnology.UltimateRummy500','AnotherPublisher.*'

.PARAMETER WhatIf
    Preview changes without writing anything.

.EXAMPLE
    .\Update-GameIcons.ps1

.EXAMPLE
    .\Update-GameIcons.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SteamInstall    = 'C:\Program Files (x86)\Steam',
    [string]$SteamMenu       = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Steam",
    [switch]$UseGamesFolderForAll,
    [string]$GamesMenu       = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Games",
    [switch]$UseSteamFolderForAll,
    [string]$EpicMenu        = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Epic Games",
    [string]$EpicManifests   = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests',
    [string]$XboxMenu        = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Xbox",
    [string]$MsStoreMenu     = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Store",
    [string]$UwpIconCache    = (Join-Path $PSScriptRoot 'UwpIconCache'),
    # Package Name patterns (wildcards OK) to force-include in the MS Store section
    # even if the app declares no gaming capabilities. Persisted in IncludeStorePackages.txt.
    [string[]]$IncludeStorePackages = @(),
    # Folder for custom icon overrides. Drop a <GameName>.ico or <GameName>.png
    # here to override the auto-detected icon for any game.
    # Get free icons from: https://www.steamgriddb.com  (Icons tab, choose ICO/PNG)
    [string]$CustomIconsPath = (Join-Path $PSScriptRoot 'CustomIcons')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# New preferred mode: place all shortcuts in an explicit Games folder.
if ($UseGamesFolderForAll) {
    $SteamMenu   = $GamesMenu
    $EpicMenu    = $GamesMenu
    $XboxMenu    = $GamesMenu
    $MsStoreMenu = $GamesMenu
}

# Convenience switch to place all generated shortcuts in the Steam menu folder.
if ($UseSteamFolderForAll -and -not $UseGamesFolderForAll) {
    $EpicMenu    = $SteamMenu
    $XboxMenu    = $SteamMenu
    $MsStoreMenu = $SteamMenu
}

Write-Host "Shortcut destinations:" -ForegroundColor DarkGray
Write-Host "  Steam:          $SteamMenu" -ForegroundColor DarkGray
Write-Host "  Epic Games:     $EpicMenu" -ForegroundColor DarkGray
Write-Host "  Xbox Game Pass: $XboxMenu" -ForegroundColor DarkGray
Write-Host "  Microsoft Store:$MsStoreMenu" -ForegroundColor DarkGray

#region Helpers

function Get-CustomIcoPath {
    # Returns a .ico path from the CustomIcons folder for the given safe name,
    # converting a .png override to .ico on-the-fly if needed.
    # Returns $null if no override exists.
    param([string]$SafeName, [string]$CustomIconsPath)
    if (-not (Test-Path $CustomIconsPath)) { return $null }

    # Direct .ico override
    $icoOverride = Join-Path $CustomIconsPath "$SafeName.ico"
    if (Test-Path $icoOverride) { return $icoOverride }

    # .png override -> auto-convert to .ico alongside the source file
    $pngOverride = Join-Path $CustomIconsPath "$SafeName.png"
    if (Test-Path $pngOverride) {
        if ($PSCmdlet.ShouldProcess($icoOverride, 'Convert PNG to ICO')) {
            ConvertImageToIco -SourcePath $pngOverride -DestPath $icoOverride
        }
        return $icoOverride
    }
    return $null
}

function Get-SafeFilename {
    # Remove characters that Windows does not allow in file names
    param([string]$Name)
    ($Name -replace '[\\/:*?"<>|]', '').Trim()
}

function Write-UrlFile {
    param(
        [string]$Path,
        [string]$Url,
        [string]$IconFile,
        [string]$WorkingDir = ''
    )
    $wdLine = if ($WorkingDir) { "`r`nWorkingDirectory=$WorkingDir" } else { '' }
    $body   = "[{000214A0-0000-0000-C000-000000000046}]`r`nProp3=19,0`r`n[InternetShortcut]`r`nIDList=`r`nIconIndex=0$wdLine`r`nURL=$Url`r`nIconFile=$IconFile`r`n"
    if ($PSCmdlet.ShouldProcess($Path, 'Write shortcut')) {
        $dir = Split-Path $Path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Path, $body, $utf8NoBom)
    }
}

function Set-UrlIconFile {
    param([string]$Path, [string]$IconFile)
    $raw = [System.IO.File]::ReadAllText($Path)
    if ($raw -match 'IconFile=') {
        $raw = $raw -replace 'IconFile=[^\r\n]+', "IconFile=$IconFile"
    } else {
        $raw = $raw -replace '(\[InternetShortcut\])', "`$1`r`nIconFile=$IconFile"
    }
    if ($PSCmdlet.ShouldProcess($Path, "Set IconFile to $IconFile")) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Path, $raw, $utf8NoBom)
    }
}

function ConvertImageToIco {
    param([string]$SourcePath, [string]$DestPath)
    Add-Type -AssemblyName System.Drawing
    $orig      = [System.Drawing.Image]::FromFile($SourcePath)
    $bmp       = New-Object System.Drawing.Bitmap $orig, 256, 256
    $pngStream = New-Object System.IO.MemoryStream
    $bmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytes  = $pngStream.ToArray()
    $orig.Dispose(); $bmp.Dispose(); $pngStream.Dispose()

    $icoStream = New-Object System.IO.MemoryStream
    $writer    = New-Object System.IO.BinaryWriter $icoStream
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
    $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]0); $writer.Write([uint16]32)
    $writer.Write([uint32]$pngBytes.Length)
    $writer.Write([uint32]22)
    $writer.Write($pngBytes)
    $writer.Flush()
    [System.IO.File]::WriteAllBytes($DestPath, $icoStream.ToArray())
    $writer.Dispose(); $icoStream.Dispose()
}

function Get-SteamIcoPath {
    # Returns the path to the .ico for a Steam appid, creating it from
    # the library cache JPG if needed. Returns $null if no source found.
    param([string]$AppId, [string]$SteamInstall)
    $icoDir  = Join-Path $SteamInstall 'steam\games'
    $cacheDir = Join-Path $SteamInstall "appcache\librarycache\$AppId"

    # Prefer the dedicated icon JPG (40-char sha1 filename)
    $iconJpg = Get-ChildItem $cacheDir -Filter '*.jpg' -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match '^[0-9a-f]{40}$' } |
                Select-Object -First 1

    # Fall back to header.jpg
    if (-not $iconJpg) {
        $iconJpg = Get-ChildItem $cacheDir -Filter 'header.jpg' -ErrorAction SilentlyContinue |
                   Select-Object -First 1
    }

    if (-not $iconJpg) { return $null }

    $icoName = "$($iconJpg.BaseName).ico"
    $icoPath = Join-Path $icoDir $icoName

    if (-not (Test-Path $icoPath)) {
        if (-not (Test-Path $icoDir)) { New-Item -ItemType Directory -Path $icoDir | Out-Null }
        ConvertImageToIco -SourcePath $iconJpg.FullName -DestPath $icoPath
    }
    return $icoPath
}

function Get-SteamLibraryPaths {
    param([string]$SteamInstall)
    $vdfPath = Join-Path $SteamInstall 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path $vdfPath)) { return @() }
    $vdf  = Get-Content $vdfPath -Raw
    $libs = @($SteamInstall)
    $libs += [regex]::Matches($vdf, '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
    return $libs | Select-Object -Unique
}

function Write-LnkShortcut {
    param(
        [string]$Path,
        [string]$Target,
        [string]$Arguments,
        [string]$IconFile,
        [string]$Description = ''
    )
    if ($PSCmdlet.ShouldProcess($Path, 'Write shortcut')) {
        $dir = Split-Path $Path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $ws = New-Object -ComObject WScript.Shell
        $s  = $ws.CreateShortcut($Path)
        $s.TargetPath  = $Target
        $s.Arguments   = $Arguments
        if ($IconFile)    { $s.IconLocation = "$IconFile,0" }
        if ($Description) { $s.Description  = $Description }
        $s.Save()
    }
}

function Set-LnkIconFile {
    param([string]$Path, [string]$IconFile)
    if ($PSCmdlet.ShouldProcess($Path, "Set IconLocation to $IconFile")) {
        $ws = New-Object -ComObject WScript.Shell
        $s  = $ws.CreateShortcut($Path)
        $s.IconLocation = "$IconFile,0"
        $s.Save()
    }
}

function Get-UwpLogoPath {
    # Resolves the best available logo file for a UWP package from its assets
    # folder, trying scale variants in descending resolution order.
    param([string]$InstallLocation, [string]$LogoRelPath)
    if (-not $LogoRelPath -or -not (Test-Path $InstallLocation)) { return $null }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($LogoRelPath)
    $ext      = [System.IO.Path]::GetExtension($LogoRelPath)
    $subDir   = [System.IO.Path]::GetDirectoryName($LogoRelPath)
    $assetDir = Join-Path $InstallLocation $subDir
    foreach ($scale in @('scale-400','scale-200','scale-150','scale-125','scale-100')) {
        # Flat naming: Assets\Logo.scale-400.png
        $candidate = Join-Path $assetDir "$baseName.$scale$ext"
        if (Test-Path $candidate) { return $candidate }
        # Subfolder naming: Assets\scale-400\Logo.png
        $candidate = Join-Path $assetDir "$scale\$baseName$ext"
        if (Test-Path $candidate) { return $candidate }
    }
    foreach ($size in @(256, 96, 48)) {
        # Flat naming: Assets\Logo.targetsize-256.png
        $candidate = Join-Path $assetDir "$baseName.targetsize-$size$ext"
        if (Test-Path $candidate) { return $candidate }
        # Subfolder naming: Assets\targetsize-256\Logo.png
        $candidate = Join-Path $assetDir "targetsize-$size\$baseName$ext"
        if (Test-Path $candidate) { return $candidate }
    }
    $plain = Join-Path $assetDir "$baseName$ext"
    if (Test-Path $plain) { return $plain }
    return $null
}

function Get-UwpIcoPath {
    # Returns a cached .ico for a UWP package logo, generating it if needed.
    param(
        [string]$PackageFamilyName,
        [string]$InstallLocation,
        [string]$LogoRelPath,
        [string]$UwpIconCache
    )
    $logoSrc = Get-UwpLogoPath -InstallLocation $InstallLocation -LogoRelPath $LogoRelPath
    if (-not $logoSrc) { return $null }
    $cacheDir = Join-Path $UwpIconCache $PackageFamilyName
    $icoPath  = Join-Path $cacheDir 'icon.ico'
    if (Test-Path $icoPath) { return $icoPath }
    if ($PSCmdlet.ShouldProcess($icoPath, 'Generate ICO from UWP logo')) {
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
        $srcExt = [System.IO.Path]::GetExtension($logoSrc).ToLower()
        if ($srcExt -eq '.ico') {
            Copy-Item -LiteralPath $logoSrc -Destination $icoPath
        } else {
            ConvertImageToIco -SourcePath $logoSrc -DestPath $icoPath
        }
    }
    return $icoPath
}

function Get-UwpGameList {
    # Enumerates installed AppX packages matching gaming capabilities.
    # -XboxOnly  : packages with the xboxLive capability (Xbox Game Pass / Live titles)
    # -StoreOnly : packages with other gaming capabilities but without xboxLive
    param([switch]$XboxOnly, [switch]$StoreOnly)

    # Try all-user packages first (needs elevation); fall back to current-user
    $packages = $null
    try   { $packages = Get-AppxPackage -AllUsers -ErrorAction Stop }
    catch { $packages = Get-AppxPackage -ErrorAction SilentlyContinue }

    # Microsoft publisher prefixes to skip for the Store-only list
    $msPrefixes = @(
        'CN=Microsoft Corporation',
        'CN=Microsoft Windows',
        'E=ntdev@microsoft.com'
    )

    # Xbox/Windows infrastructure packages (not games) that carry xboxLive
    $servicePackageNames = @(
        'Microsoft.GamingApp',
        'Microsoft.GamingServices',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.XboxGameCallableUI',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxGameBar',
        'Microsoft.XboxTCUI',
        'Microsoft.Xbox.TCUI',
        'Microsoft.StorePurchaseApp'
    )

    foreach ($pkg in $packages) {
        if ($pkg.IsFramework)       { continue }
        if ($pkg.IsResourcePackage) { continue }
        if ($pkg.SignatureKind -eq 'System') { continue }
        if ($servicePackageNames -contains $pkg.Name) { continue }

        $manifestPath = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
        if (-not (Test-Path $manifestPath -PathType Leaf)) { continue }

        $raw = Get-Content $manifestPath -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { continue }

        $isXboxLive    = $raw -match 'xboxLive' -or $raw -match 'Protocol Name="ms-xbl-'
        $isOtherGame   = $raw -match 'xboxManageTiles|xboxGameBroadcast|gameInput'

        if ($XboxOnly  -and -not $isXboxLive)               { continue }
        if ($StoreOnly -and $isXboxLive)                    { continue }
        if ($StoreOnly -and -not $isOtherGame)              { continue }

        # Skip Microsoft-published packages from the Store-only list
        if ($StoreOnly) {
            $pub      = $pkg.Publisher
            $isMsPub  = $false
            foreach ($prefix in $msPrefixes) {
                if ($pub -like "$prefix*") { $isMsPub = $true; break }
            }
            if ($isMsPub) { continue }
        }

        # Display name: prefer Properties > VisualElements; skip ms-resource strings
        $displayName = $null
        if ($raw -match '<DisplayName>([^<]+)</DisplayName>') {
            $dn = $matches[1].Trim()
            if ($dn -notmatch '^ms-resource:') { $displayName = $dn }
        }
        if (-not $displayName -and $raw -match 'DisplayName="([^"]+)"') {
            $dn = $matches[1].Trim()
            if ($dn -notmatch '^ms-resource:') { $displayName = $dn }
        }
        if (-not $displayName) { $displayName = $pkg.Name }

        # Application ID from first <Application Id="..."> in manifest
        $appId = if ($raw -match '<Application[^>]+\bId="([^"]+)"') { $matches[1] } else { 'App' }

        # Logo: prefer Square150x150 > StoreLogo > Square44x44
        $logoRelPath = $null
        if      ($raw -match 'Square150x150Logo="([^"]+)"') { $logoRelPath = $matches[1] }
        elseif  ($raw -match 'StoreLogo="([^"]+)"')         { $logoRelPath = $matches[1] }
        elseif  ($raw -match 'Square44x44Logo="([^"]+)"')   { $logoRelPath = $matches[1] }

        [PSCustomObject]@{
            DisplayName       = $displayName
            PackageFamilyName = $pkg.PackageFamilyName
            AppId             = $appId
            LogoRelPath       = $logoRelPath
            InstallLocation   = $pkg.InstallLocation
        }
    }
}

# AppIDs that are tools/redistributables, not games
$script:SteamNonGameIds = @('228980','1070560','1391110','250820','1628350')

function Get-SteamAppManifests {
    param([string[]]$LibraryPaths)
    foreach ($lib in $LibraryPaths) {
        # Skip library paths whose drive does not exist
        $drive = Split-Path $lib -Qualifier
        if (-not (Test-Path $drive)) { continue }
        $appsDir = Join-Path $lib 'steamapps'
        if (-not (Test-Path $appsDir)) { continue }
        Get-ChildItem $appsDir -Filter 'appmanifest_*.acf' | ForEach-Object {
            # Read as UTF-8 so special chars (TM, copyright) survive
            $raw        = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
            $appId      = if ($raw -match '"appid"\s+"(\d+)"') { $matches[1] } else { $null }
            $name       = if ($raw -match '"name"\s+"([^"]+)"') { $matches[1] } else { $null }
            $installDir = if ($raw -match '"installdir"\s+"([^"]+)"') { $matches[1] } else { $null }
            $flags      = if ($raw -match '"StateFlags"\s+"(\d+)"') { [int]$matches[1] } else { 0 }
            if (-not $appId -or -not $name) { return }
            # Skip known non-game / redistributable entries
            if ($script:SteamNonGameIds -contains $appId) { return }
            if ($name -match 'Redistributable|Steamworks Common|SDK|Proton|Steam Linux') { return }
            # StateFlags bit 2 (mask 4) = fully installed; also allow 6 (needs update but playable)
            if (($flags -band 4) -eq 0) { return }
            $fullInstallDir = Join-Path (Join-Path $lib 'steamapps\common') $installDir
            if (-not (Test-Path $fullInstallDir)) { return }
            [PSCustomObject]@{
                AppId   = $appId
                Name    = $name
                Library = $lib
            }
        }
    }
}

#endregion

###############################################################################
# STEAM
###############################################################################
Write-Host "`n=== Steam ===" -ForegroundColor Cyan

if (-not (Test-Path $SteamInstall)) {
    Write-Host "  [SKIP]    Steam not found at: $SteamInstall" -ForegroundColor DarkYellow
} else {
    if (-not (Test-Path $SteamMenu)) {
        if ($PSCmdlet.ShouldProcess($SteamMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $SteamMenu | Out-Null
        }
    }

    $libs  = Get-SteamLibraryPaths -SteamInstall $SteamInstall
    $games = Get-SteamAppManifests -LibraryPaths $libs

    $installedSteamNames = $games | ForEach-Object { Get-SafeFilename -Name $_.Name }
    if (Test-Path $SteamMenu) {
        Get-ChildItem $SteamMenu -Filter '*.url' | ForEach-Object {
            # In shared folders, only clean up Steam-owned .url shortcuts.
            $raw = [System.IO.File]::ReadAllText($_.FullName)
            $isSteamShortcut = $raw -match '(?m)^URL=steam://rungameid/'
            if (-not $isSteamShortcut) { return }

            if ($installedSteamNames -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    foreach ($game in ($games | Sort-Object Name)) {
        $safeName     = Get-SafeFilename -Name $game.Name
        $shortcutPath = Join-Path $SteamMenu "$safeName.url"
        $url          = "steam://rungameid/$($game.AppId)"

        # Custom override takes priority; fall back to Steam library cache icon
        $icoPath = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        if (-not $icoPath) {
            $icoPath = Get-SteamIcoPath -AppId $game.AppId -SteamInstall $SteamInstall
        }

        if (-not (Test-Path $shortcutPath)) {
            # -- Create missing shortcut
            if ($icoPath) {
                Write-Host "  [CREATE]  $($game.Name)" -ForegroundColor Green
                Write-UrlFile -Path $shortcutPath -Url $url -IconFile $icoPath
            } else {
                Write-Host "  [SKIP]    $($game.Name) (AppID $($game.AppId)) - no icon found in library cache" -ForegroundColor DarkYellow
            }
        } else {
            # -- Shortcut exists: check icon is still valid
            $raw     = [System.IO.File]::ReadAllText($shortcutPath)
            $current = if ($raw -match 'IconFile=([^\r\n]+)') { $matches[1].Trim() } else { '' }
            if ($current -and (Test-Path $current)) {
                Write-Host "  [OK]      $($game.Name)" -ForegroundColor DarkGray
            } elseif ($icoPath) {
                Write-Host "  [FIX]     $($game.Name)" -ForegroundColor Yellow
                Set-UrlIconFile -Path $shortcutPath -IconFile $icoPath
            } else {
                Write-Host "  [SKIP]    $($game.Name) (AppID $($game.AppId)) - broken icon, no cache source" -ForegroundColor DarkYellow
            }
        }
    }
}

###############################################################################
# EPIC GAMES
###############################################################################
Write-Host "`n=== Epic Games ===" -ForegroundColor Cyan

if (-not (Test-Path $EpicManifests)) {
    Write-Host "  [SKIP]    Epic manifests not found at: $EpicManifests" -ForegroundColor DarkYellow
} else {
    if (-not (Test-Path $EpicMenu)) {
        if ($PSCmdlet.ShouldProcess($EpicMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $EpicMenu | Out-Null
        }
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

        # Skip DLCs (no launch exe), incomplete installs, and duplicates
        if (-not $m.LaunchExecutable) { return }
        # Skip non-game launchers (e.g. showfolder.bat, content packs)
        if ($m.LaunchExecutable -notmatch '\.exe$') { return }
        if ($m.bIsIncompleteInstall)  { return }
        # Skip DLC/expansion entries that are children of another game
        if ($m.MainGameAppName -and ($m.MainGameAppName -ne $m.AppName)) { return }
        if ($seen.ContainsKey($m.AppName)) { return }
        $seen[$m.AppName] = $true

        $exePath = Join-Path $m.InstallLocation $m.LaunchExecutable
        # Build the Epic launcher URL: namespace:catalogItemId:appName
        $launchUrl = "com.epicgames.launcher://apps/$([System.Uri]::EscapeDataString("$($m.CatalogNamespace):$($m.CatalogItemId):$($m.AppName)"))?action=launch&silent=true"

        $games += [PSCustomObject]@{
            DisplayName = $m.DisplayName
            ExePath     = $exePath
            LaunchUrl   = $launchUrl
            WorkingDir  = 'C:\Program Files (x86)\Epic Games'
        }
    }

    $installedEpicNames = $games | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    if (Test-Path $EpicMenu) {
        Get-ChildItem $EpicMenu -Filter '*.url' | ForEach-Object {
            # In shared folders, only clean up Epic-owned .url shortcuts.
            $raw = [System.IO.File]::ReadAllText($_.FullName)
            $isEpicShortcut = $raw -match '(?m)^URL=com\.epicgames\.launcher://apps/'
            if (-not $isEpicShortcut) { return }

            if ($installedEpicNames -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    foreach ($game in ($games | Sort-Object DisplayName)) {
        $safeName     = Get-SafeFilename -Name $game.DisplayName
        $shortcutPath = Join-Path $EpicMenu "$safeName.url"

        # Custom override takes priority; fall back to the game exe
        $customIco = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        $iconFile  = if ($customIco) { $customIco } else { $game.ExePath }

        if (-not (Test-Path $shortcutPath)) {
            # -- Create missing shortcut
            if (Test-Path $game.ExePath) {
                Write-Host "  [CREATE]  $($game.DisplayName)" -ForegroundColor Green
                Write-UrlFile -Path $shortcutPath -Url $game.LaunchUrl -IconFile $iconFile -WorkingDir $game.WorkingDir
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - exe not found at: $($game.ExePath)" -ForegroundColor DarkYellow
            }
        } else {
            # -- Shortcut exists: check icon is still valid
            $raw     = [System.IO.File]::ReadAllText($shortcutPath)
            $current = if ($raw -match 'IconFile=([^\r\n]+)') { $matches[1].Trim() } else { '' }
            $needsFix = -not $current -or -not (Test-Path $current) -or ($customIco -and $current -ne $customIco)
            if (-not $needsFix) {
                Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
            } elseif (Test-Path $game.ExePath) {
                Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
                Set-UrlIconFile -Path $shortcutPath -IconFile $iconFile
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - broken icon, exe not found: $($game.ExePath)" -ForegroundColor DarkYellow
            }
        }
    }
}

###############################################################################
# XBOX GAME PASS
###############################################################################
Write-Host "`n=== Xbox Game Pass ===" -ForegroundColor Cyan

$xboxGames = @(Get-UwpGameList -XboxOnly | Sort-Object DisplayName)
$installedXboxNames = @()

if ($xboxGames.Count -eq 0) {
    Write-Host "  [SKIP]    No Xbox Game Pass titles found (requires the Xbox app with installed games)." -ForegroundColor DarkYellow
} else {
    if (-not (Test-Path $XboxMenu)) {
        if ($PSCmdlet.ShouldProcess($XboxMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $XboxMenu | Out-Null
        }
    }

    $installedXboxNames = $xboxGames | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    if (Test-Path $XboxMenu) {
        # If Xbox and Store share a folder, removal is handled once in the Store
        # section against a combined installed set to avoid cross-deleting links.
        if ($XboxMenu -ne $MsStoreMenu) {
            Get-ChildItem $XboxMenu -Filter '*.lnk' | ForEach-Object {
                if ($installedXboxNames -notcontains $_.BaseName) {
                    Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                    if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                        Remove-Item -LiteralPath $_.FullName -Force
                    }
                }
            }
        }
    }

    foreach ($game in $xboxGames) {
        $safeName     = Get-SafeFilename -Name $game.DisplayName
        $shortcutPath = Join-Path $XboxMenu "$safeName.lnk"
        $aumId        = "$($game.PackageFamilyName)!$($game.AppId)"

        $customIco = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        $icoPath   = if ($customIco) { $customIco } else {
            Get-UwpIcoPath -PackageFamilyName $game.PackageFamilyName `
                           -InstallLocation   $game.InstallLocation `
                           -LogoRelPath       $game.LogoRelPath `
                           -UwpIconCache      $UwpIconCache
        }

        if (-not (Test-Path $shortcutPath)) {
            if ($icoPath) {
                Write-Host "  [CREATE]  $($game.DisplayName)" -ForegroundColor Green
                Write-LnkShortcut -Path $shortcutPath -Target 'explorer.exe' `
                    -Arguments "shell:AppsFolder\$aumId" `
                    -IconFile $icoPath -Description $game.DisplayName
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - no icon found" -ForegroundColor DarkYellow
            }
        } else {
            $ws      = New-Object -ComObject WScript.Shell
            $s       = $ws.CreateShortcut($shortcutPath)
            $current = ($s.IconLocation -split ',')[0].Trim()
            $needsFix = -not $current -or -not (Test-Path $current) -or ($customIco -and $current -ne $customIco)
            if (-not $needsFix) {
                Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
            } elseif ($icoPath) {
                Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
                Set-LnkIconFile -Path $shortcutPath -IconFile $icoPath
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - broken icon, no source available" -ForegroundColor DarkYellow
            }
        }
    }
}

###############################################################################
# MICROSOFT STORE GAMES
###############################################################################
Write-Host "`n=== Microsoft Store Games ===" -ForegroundColor Cyan

# Merge capability-detected games with any explicitly included packages
$storeGames = [System.Collections.Generic.List[object]]::new()
foreach ($g in @(Get-UwpGameList -StoreOnly)) { $storeGames.Add($g) }

# Load persisted include list from file (one package Name pattern per line)
$includeListFile = Join-Path $PSScriptRoot 'IncludeStorePackages.txt'
if (Test-Path $includeListFile) {
    $fileEntries = Get-Content $includeListFile | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }
    $IncludeStorePackages = @($IncludeStorePackages) + @($fileEntries) | Select-Object -Unique
}

if ($IncludeStorePackages.Count -gt 0) {
    $knownFamilyNames = $storeGames | ForEach-Object { $_.PackageFamilyName }
    $allPkgs = $null
    try   { $allPkgs = Get-AppxPackage -AllUsers -ErrorAction Stop }
    catch { $allPkgs = Get-AppxPackage -ErrorAction SilentlyContinue }
    foreach ($pattern in $IncludeStorePackages) {
        $matched = $allPkgs | Where-Object { $_.Name -like $pattern -and -not $_.IsFramework -and -not $_.IsResourcePackage }
        foreach ($pkg in $matched) {
            if ($knownFamilyNames -contains $pkg.PackageFamilyName) { continue }
            $knownFamilyNames += $pkg.PackageFamilyName
            $manifestPath = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
            $raw = if (Test-Path $manifestPath) { Get-Content $manifestPath -Raw -ErrorAction SilentlyContinue } else { '' }
            $displayName = $null
            if ($raw -match '<DisplayName>([^<]+)</DisplayName>') {
                $dn = $matches[1].Trim()
                if ($dn -notmatch '^ms-resource:') { $displayName = $dn }
            }
            if (-not $displayName -and $raw -match 'DisplayName="([^"]+)"') {
                $dn = $matches[1].Trim()
                if ($dn -notmatch '^ms-resource:') { $displayName = $dn }
            }
            if (-not $displayName) { $displayName = $pkg.Name }
            $appId = if ($raw -match '<Application[^>]+\bId="([^"]+)"') { $matches[1] } else { 'App' }
            $logoRelPath = $null
            if      ($raw -match 'Square150x150Logo="([^"]+)"') { $logoRelPath = $matches[1] }
            elseif  ($raw -match 'StoreLogo="([^"]+)"')         { $logoRelPath = $matches[1] }
            elseif  ($raw -match 'Square44x44Logo="([^"]+)"')   { $logoRelPath = $matches[1] }
            $storeGames.Add([PSCustomObject]@{
                DisplayName       = $displayName
                PackageFamilyName = $pkg.PackageFamilyName
                AppId             = $appId
                LogoRelPath       = $logoRelPath
                InstallLocation   = $pkg.InstallLocation
            })
        }
    }
}

$storeGames = @($storeGames | Sort-Object DisplayName)

if ($storeGames.Count -eq 0) {
    Write-Host "  No Microsoft Store games found." -ForegroundColor DarkGray
} else {
    if (-not (Test-Path $MsStoreMenu)) {
        if ($PSCmdlet.ShouldProcess($MsStoreMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $MsStoreMenu | Out-Null
        }
    }

    $installedStoreNames = $storeGames | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    if (Test-Path $MsStoreMenu) {
        # Shared Xbox+Store folder cleanup: keep anything installed in either list.
        $installedSharedNames = $installedStoreNames
        if ($MsStoreMenu -eq $XboxMenu) {
            $installedSharedNames = @($installedStoreNames + $installedXboxNames) | Select-Object -Unique
        }

        Get-ChildItem $MsStoreMenu -Filter '*.lnk' | ForEach-Object {
            if ($installedSharedNames -notcontains $_.BaseName) {
                Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    foreach ($game in $storeGames) {
        $safeName     = Get-SafeFilename -Name $game.DisplayName
        $shortcutPath = Join-Path $MsStoreMenu "$safeName.lnk"
        $aumId        = "$($game.PackageFamilyName)!$($game.AppId)"

        $customIco = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        $icoPath   = if ($customIco) { $customIco } else {
            Get-UwpIcoPath -PackageFamilyName $game.PackageFamilyName `
                           -InstallLocation   $game.InstallLocation `
                           -LogoRelPath       $game.LogoRelPath `
                           -UwpIconCache      $UwpIconCache
        }

        if (-not (Test-Path $shortcutPath)) {
            if ($icoPath) {
                Write-Host "  [CREATE]  $($game.DisplayName)" -ForegroundColor Green
                Write-LnkShortcut -Path $shortcutPath -Target 'explorer.exe' `
                    -Arguments "shell:AppsFolder\$aumId" `
                    -IconFile $icoPath -Description $game.DisplayName
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - no icon found" -ForegroundColor DarkYellow
            }
        } else {
            $ws      = New-Object -ComObject WScript.Shell
            $s       = $ws.CreateShortcut($shortcutPath)
            $current = ($s.IconLocation -split ',')[0].Trim()
            $needsFix = -not $current -or -not (Test-Path $current) -or ($customIco -and $current -ne $customIco)
            if (-not $needsFix) {
                Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
            } elseif ($icoPath) {
                Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
                Set-LnkIconFile -Path $shortcutPath -IconFile $icoPath
            } else {
                Write-Host "  [SKIP]    $($game.DisplayName) - broken icon, no source available" -ForegroundColor DarkYellow
            }
        }
    }
}

Write-Host "`nDone." -ForegroundColor Cyan