# Icon resolution strategy - find icons from various sources

function Get-SteamGridDbIcoPath {
    # Returns cached/generated SGDB icon for a Steam appid when available.
    param(
        [string]$AppId,
        [string]$SafeName,
        [string]$ApiKey,
        [string]$CachePath,
        [switch]$Refresh,
        # Comma-separated SteamGridDB style filter (e.g. 'official' or 'official,custom').
        [string]$Styles = 'official,custom',
        [string]$GameName = $null
    )

    $excludedIds = @()
    if ($script:SteamGridDbExcludedIconIdsByAppId -and $script:SteamGridDbExcludedIconIdsByAppId.ContainsKey($AppId)) {
        $excludedIds = @($script:SteamGridDbExcludedIconIdsByAppId[$AppId] | ForEach-Object { [string]$_ })
    }

    $preferredId = ''
    if ($script:SteamGridDbPreferredIconIdsByAppId -and $script:SteamGridDbPreferredIconIdsByAppId.ContainsKey($AppId)) {
        $preferredId = [string]$script:SteamGridDbPreferredIconIdsByAppId[$AppId]
    }

    $cachedCandidates = Get-ChildItem $CachePath -Filter "$SafeName.sgdb*.ico" -ErrorAction SilentlyContinue
    if ($preferredId) {
        $cachedCandidates = $cachedCandidates | Where-Object { $_.BaseName -match "\.sgdb\.$preferredId$" }
    } elseif ($excludedIds.Count -gt 0) {
        $cachedCandidates = $cachedCandidates | Where-Object {
            if ($_.BaseName -match '\.sgdb\.(\d+)$') {
                return ($excludedIds -notcontains $matches[1])
            }
            return $true
        }
    }
    $existingCached = $cachedCandidates |
                      Sort-Object LastWriteTime -Descending |
                      Select-Object -First 1
    # Reuse cached SGDB asset whenever possible. If no API key is present,
    # prefer the cached icon instead of downgrading back to Steam local art.
    if ($existingCached -and ((-not $Refresh) -or (-not $ApiKey))) {
        return $existingCached.FullName
    }

    if (-not $ApiKey) { return $null }
    if (-not (Test-Path $CachePath)) {
        if ($PSCmdlet.ShouldProcess($CachePath, 'Create SteamGridDB cache directory')) {
            New-Item -ItemType Directory -Path $CachePath | Out-Null
        }
    }

    $headers = @{ Authorization = "Bearer $ApiKey" }

    $resp = $null

    if ($preferredId) {
        $prefUrl = "https://www.steamgriddb.com/api/v2/icons/${preferredId}"
        try {
            $prefResp = Invoke-RestMethod -Method Get -Uri $prefUrl -Headers $headers -ErrorAction Stop
            if ($prefResp -and $prefResp.success -and $prefResp.data) {
                $resp = [PSCustomObject]@{ success = $true; data = @($prefResp.data) }
            }
        } catch {
            $gameInfo = if ($GameName) { "$GameName (AppID $AppId)" } else { "AppID $AppId" }
            Write-Host "  [WARN]    SteamGridDB lookup failed for preferred icon $preferredId ($gameInfo). Falling back." -ForegroundColor DarkYellow
        }
    }

    if (-not $resp) {
        $apiUrl = "https://www.steamgriddb.com/api/v2/icons/steam/${AppId}?styles=${Styles}&types=static&mimes=image/vnd.microsoft.icon,image/png&sort=score&order=desc&limit=20"
        try {
            $resp = Invoke-RestMethod -Method Get -Uri $apiUrl -Headers $headers -ErrorAction Stop
        } catch {
            # Compatibility fallback for clients expecting raw API key without Bearer.
            try {
                $headers = @{ Authorization = $ApiKey }
                $resp = Invoke-RestMethod -Method Get -Uri $apiUrl -Headers $headers -ErrorAction Stop
            } catch {
                $gameInfo = if ($GameName) { "$GameName (AppID $AppId)" } else { "AppID $AppId" }
                Write-Host "  [SKIP]    SteamGridDB lookup failed for $gameInfo" -ForegroundColor DarkYellow
                return $null
            }
        }
    }

    if (-not $resp -or -not $resp.success -or -not $resp.data -or $resp.data.Count -eq 0) {
        return $null
    }

    $candidates = @($resp.data)
    if ($excludedIds.Count -gt 0) {
        $candidates = $candidates | Where-Object {
            $id = if ($_.id) { [string]$_.id } else { '' }
            return ($excludedIds -notcontains $id)
        }
    }
    if (-not $candidates -or $candidates.Count -eq 0) {
        $gameInfo = if ($GameName) { "$GameName (AppID $AppId)" } else { "AppID $AppId" }
        Write-Host "  [SKIP]    SteamGridDB has no acceptable icon candidates for $gameInfo" -ForegroundColor DarkYellow
        return $null
    }

    # Prefer explicitly preferred art when available, then official art, then highest score/upvotes.
    $candidate = $candidates |
                 Sort-Object @{ Expression = { $id = if ($_.id) { [string]$_.id } else { '' }; if ($preferredId -and $id -eq $preferredId) { 0 } else { 1 } } },
                             @{ Expression = { if ($_.style -eq 'official') { 0 } else { 1 } } },
                             @{ Expression = { if ($_.score) { [double]$_.score } else { 0 } }; Descending = $true },
                             @{ Expression = { if ($_.upvotes) { [int]$_.upvotes } else { 0 } }; Descending = $true } |
                 Select-Object -First 1
    $assetUrl = $candidate.url
    if (-not $assetUrl) { return $null }

    $tmpExt = '.png'
    if ($candidate.mime -eq 'image/vnd.microsoft.icon') { $tmpExt = '.ico' }
    $tmpPath = Join-Path $CachePath "$SafeName.sgdb.download$tmpExt"
    $candidateId = if ($candidate.id) { [string]$candidate.id } else { 'picked' }
    $candidateIcoPath = Join-Path $CachePath "$SafeName.sgdb.$candidateId.ico"

    try {
        if ($PSCmdlet.ShouldProcess($tmpPath, 'Download SteamGridDB icon')) {
            Invoke-WebRequest -Uri $assetUrl -OutFile $tmpPath -UseBasicParsing -ErrorAction Stop
        }

        if ($tmpExt -eq '.ico') {
            if ($PSCmdlet.ShouldProcess($candidateIcoPath, 'Store SteamGridDB ICO')) {
                Copy-Item -LiteralPath $tmpPath -Destination $candidateIcoPath -Force
            }
        } else {
            if ($PSCmdlet.ShouldProcess($candidateIcoPath, 'Convert SteamGridDB PNG to ICO')) {
                ConvertImageToIco -SourcePath $tmpPath -DestPath $candidateIcoPath
            }
        }

        if (Test-Path $candidateIcoPath) {
            return $candidateIcoPath
        }
        return $null
    } catch {
        Write-Host "  [SKIP]    SteamGridDB download failed for AppID $AppId" -ForegroundColor DarkYellow
        return $null
    } finally {
        if (Test-Path $tmpPath) {
            if ($PSCmdlet.ShouldProcess($tmpPath, 'Remove temporary SteamGridDB asset')) {
                Remove-Item -LiteralPath $tmpPath -Force
            }
        }
    }
}

function Get-SteamIcoPath {
    # Returns the path to the .ico for a Steam appid.
    # Prefers Steam's original clienticon asset when available, then falls
    # back to converting Steam library cache JPGs.
    param(
        [string]$AppId,
        [string]$SteamInstall,
        [string]$ClientIconHash
    )
    $icoDir  = Join-Path $SteamInstall 'steam\games'
    $cacheDir = Join-Path $SteamInstall "appcache\librarycache\$AppId"

    # Prefer Steam's native client icon from appmanifest "clienticon" hash.
    if ($ClientIconHash) {
        $clientIconPath = Join-Path $icoDir "$ClientIconHash.ico"
        if (Test-Path $clientIconPath) { return $clientIconPath }
    }

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

function Get-CachedIcoPath {
    # Looks for a previously generated/downloaded icon in cache folders.
    # SteamGridDbCache is checked first, then UwpIconCache.
    param(
        [string]$SafeName,
        [string]$SteamGridDbCache,
        [string]$UwpIconCache
    )

    if ($SteamGridDbCache -and (Test-Path $SteamGridDbCache)) {
        $sgdbCandidate = Get-ChildItem -LiteralPath $SteamGridDbCache -Filter "$SafeName.sgdb*.ico" -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending |
                         Select-Object -First 1
        if ($sgdbCandidate) { return $sgdbCandidate.FullName }

        $genericCandidate = Get-ChildItem -LiteralPath $SteamGridDbCache -Filter "$SafeName*.ico" -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending |
                            Select-Object -First 1
        if ($genericCandidate) { return $genericCandidate.FullName }
    }

    if ($UwpIconCache -and (Test-Path $UwpIconCache)) {
        $namedCandidate = Join-Path $UwpIconCache "$SafeName.ico"
        if (Test-Path $namedCandidate) { return $namedCandidate }

        $folderCandidate = Join-Path (Join-Path $UwpIconCache $SafeName) 'icon.ico'
        if (Test-Path $folderCandidate) { return $folderCandidate }
    }

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

function Find-GameIcon {
    # Unified icon resolution strategy with priority chain.
    # Priority: Custom > SteamGridDB official > SteamGridDB community > Cache > Local assets
    param(
        [string]$GameName,
        [string]$AppId,
        [string]$PlatformPrefix,  # 'steam', 'epic', 'xbox', 'msstore', etc.
        [hashtable]$IconSources   # Custom callbacks for platform-specific logic
    )
    
    # 1. Custom override (highest priority)
    if ($IconSources.ContainsKey('Custom')) {
        $ico = & $IconSources['Custom']
        if ($ico) { return $ico }
    }
    
    # 2. SteamGridDB official
    if ($IconSources.ContainsKey('SteamGridDbOfficial')) {
        $ico = & $IconSources['SteamGridDbOfficial']
        if ($ico) { return $ico }
    }
    
    # 3. SteamGridDB all styles
    if ($IconSources.ContainsKey('SteamGridDbCommunity')) {
        $ico = & $IconSources['SteamGridDbCommunity']
        if ($ico) { return $ico }
    }
    
    # 4. Cache
    if ($IconSources.ContainsKey('Cached')) {
        $ico = & $IconSources['Cached']
        if ($ico) { return $ico }
    }
    
    # 5. Local assets
    if ($IconSources.ContainsKey('LocalAssets')) {
        $ico = & $IconSources['LocalAssets']
        if ($ico) { return $ico }
    }
    
    return $null
}
