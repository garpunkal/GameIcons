# Utility functions for file operations, conversions, and data handling

function Write-ProgressIndicator {
    # Display progress for long-running operations
    param(
        [int]$Current,
        [int]$Total,
        [string]$Activity = "Processing",
        [string]$Status = ""
    )

    if ($Total -le 0) { return }

    $percent = [math]::Min(100, [math]::Round(($Current / $Total) * 100))
    $progressParams = @{
        Activity = $Activity
        Status = $Status
        PercentComplete = $percent
    }

    Write-Progress @progressParams
}

function Get-CustomIcoPath {
    # Returns a .ico path from the CustomIcons folder for the given safe name,
    # converting a .png override to .ico on-the-fly if needed.
    # Returns $null if no override exists.
    param([string]$SafeName, [string]$CustomIconsPath)
    if (-not (Test-Path $CustomIconsPath)) { return $null }

    $candidateNames = @($SafeName)
    $legacyName = $SafeName -replace ' ', '_'
    if ($legacyName -ne $SafeName) { $candidateNames += $legacyName }

    foreach ($name in $candidateNames | Select-Object -Unique) {
        $icoOverride = Join-Path $CustomIconsPath "$name.ico"
        if (Test-Path $icoOverride) { return $icoOverride }

        $pngOverride = Join-Path $CustomIconsPath "$name.png"
        if (Test-Path $pngOverride) {
            if ($PSCmdlet.ShouldProcess($icoOverride, 'Convert PNG to ICO')) {
                ConvertImageToIco -SourcePath $pngOverride -DestPath $icoOverride
            }
            return $icoOverride
        }
    }
    return $null
}

function ConvertFrom-XmlEntity {
    # Decode common XML/HTML entities that appear verbatim in AppxManifest.xml files
    # when read with Get-Content -Raw (plain text, not parsed XML).
    param([string]$Text)
    if (-not $Text) { return $Text }
    $Text -replace '&amp;',  '&' `
          -replace '&lt;',   '<' `
          -replace '&gt;',   '>' `
          -replace '&quot;', '"' `
          -replace '&apos;', "'"
}

function Get-SafeFilename {
    # Remove characters that Windows does not allow in file names, but preserve spaces for human-readable Start Menu labels.
    param([string]$Name)
    if (-not $Name) { return '' }
    $clean = $Name -replace '[\\/:*?"<>|]', ''
    return $clean.Trim()
}

function Get-Settings {
    # Reads the consolidated JSON settings file.
    param([string]$Path)
    $defaults = @{
        steamNonGameIds             = @()
        uwpServicePackageNames      = @()
        msPublisherPrefixes         = @()
        steamGridDbExcludedIconIds  = @{}
        steamGridDbPreferredIconIds = @{}
        battleNetProductCodes       = [ordered]@{}
        includeStorePackages        = @()
        paths                       = $null
    }
    if (-not $Path -or -not (Test-Path $Path)) {
        return $defaults
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Host "  [WARN]    Failed to parse settings file: $Path ($($_.Exception.Message))" -ForegroundColor DarkYellow
        Write-Host "  [WARN]    Using default settings" -ForegroundColor DarkYellow
        return $defaults
    }
    # Simple arrays
    foreach ($key in @('steamNonGameIds','uwpServicePackageNames','msPublisherPrefixes','includeStorePackages')) {
        if ($json.PSObject.Properties[$key]) {
            $defaults[$key] = @($json.$key)
        }
    }
    # Paths object
    if ($json.PSObject.Properties['paths']) {
        $defaults['paths'] = $json.paths
    }
    # Map: steamGridDbExcludedIconIds -> hashtable of appId -> string[] iconIds
    if ($json.PSObject.Properties['steamGridDbExcludedIconIds']) {
        $map = @{}
        $obj = $json.steamGridDbExcludedIconIds
        foreach ($prop in $obj.PSObject.Properties) {
            $map[$prop.Name] = @($prop.Value | ForEach-Object { [string]$_ })
        }
        $defaults['steamGridDbExcludedIconIds'] = $map
    }
    # Map: battleNetProductCodes -> hashtable of displayName (lowercase) -> string productCode
    if ($json.PSObject.Properties['battleNetProductCodes']) {
        $map = [ordered]@{}
        $obj = $json.battleNetProductCodes
        foreach ($prop in $obj.PSObject.Properties) {
            if ($prop.Name -eq '_comment') { continue }
            $map[$prop.Name] = [string]$prop.Value
        }
        $defaults['battleNetProductCodes'] = $map
    }
    # Map: steamGridDbPreferredIconIds -> hashtable of appId -> string iconId
    if ($json.PSObject.Properties['steamGridDbPreferredIconIds']) {
        $map = @{}
        $obj = $json.steamGridDbPreferredIconIds
        foreach ($prop in $obj.PSObject.Properties) {
            $map[$prop.Name] = [string]$prop.Value
        }
        $defaults['steamGridDbPreferredIconIds'] = $map
    }
    return $defaults
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

function Get-SteamLibraryPaths {
    param([string]$SteamInstall)
    $vdfPath = Join-Path $SteamInstall 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path $vdfPath)) { return @() }
    $vdf  = Get-Content $vdfPath -Raw
    $libs = @($SteamInstall)
    $libs += [regex]::Matches($vdf, '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
    return $libs | Select-Object -Unique
}

function Get-UwpGameList {
    # Enumerates installed AppX packages matching gaming capabilities.
    # -XboxOnly  : packages with the xboxLive capability (Xbox Game Pass / Live titles)
    # -StoreOnly : packages with other gaming capabilities but without xboxLive
    param([switch]$XboxOnly, [switch]$StoreOnly)

    # Merge all-users and current-user views so per-user installs are included
    # even when -AllUsers succeeds but omits some user-scoped packages.
    $packages = @()
    try {
        $packages += @(Get-AppxPackage -AllUsers -ErrorAction Stop)
    } catch {
        # Ignore and continue with current-user inventory.
    }
    $packages += @(Get-AppxPackage -ErrorAction SilentlyContinue)
    $packages = $packages |
        Group-Object PackageFamilyName |
        ForEach-Object { $_.Group | Select-Object -First 1 }

    foreach ($pkg in $packages) {
        if ($pkg.IsFramework)       { continue }
        if ($pkg.IsResourcePackage) { continue }
        if ($pkg.SignatureKind -eq 'System') { continue }
        $pkgName = if ($pkg.Name) { [string]$pkg.Name } else { '' }
        $pkgFamilyBase = ''
        if ($pkg.PackageFamilyName) {
            $pkgFamilyBase = ([string]$pkg.PackageFamilyName -split '_')[0]
        }
        if (($global:UwpServicePackageNames -contains $pkgName) -or
            ($pkgFamilyBase -and ($global:UwpServicePackageNames -contains $pkgFamilyBase))) {
            continue
        }

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
            foreach ($prefix in $global:MsPublisherPrefixes) {
                if ($pub -like "$prefix*") { $isMsPub = $true; break }
            }
            if ($isMsPub) { continue }
        }

        # Display name: prefer Properties > VisualElements; skip ms-resource strings
        $displayName = $null
        if ($raw -match '<DisplayName>([^<]+)</DisplayName>') {
            $dn = ConvertFrom-XmlEntity $matches[1].Trim()
            if ($dn -notmatch '^ms-resource:') { $displayName = $dn }
        }
        if (-not $displayName -and $raw -match 'DisplayName="([^"]+)"') {
            $dn = ConvertFrom-XmlEntity $matches[1].Trim()
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
            $clientIcon = if ($raw -match '"clienticon"\s+"([^"]+)"') { $matches[1] } else { $null }
            $installDir = if ($raw -match '"installdir"\s+"([^"]+)"') { $matches[1] } else { $null }
            $flags      = if ($raw -match '"StateFlags"\s+"(\d+)"') { [int]$matches[1] } else { 0 }
            if (-not $appId -or -not $name) { return }
            # Skip known non-game / redistributable entries
            if ($global:SteamNonGameIds -contains $appId) { return }
            if ($name -match 'Redistributable|Steamworks Common|SDK|Proton|Steam Linux') { return }
            # StateFlags bit 2 (mask 4) = fully installed; also allow 6 (needs update but playable)
            if (($flags -band 4) -eq 0) { return }
            $fullInstallDir = Join-Path (Join-Path $lib 'steamapps\common') $installDir
            if (-not (Test-Path $fullInstallDir)) { return }
            [PSCustomObject]@{
                AppId          = $appId
                Name           = $name
                ClientIconHash = $clientIcon
                InstallPath    = $fullInstallDir
                Library        = $lib
            }
        }
    }
}
