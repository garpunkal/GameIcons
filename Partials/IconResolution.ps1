function Invoke-SteamGridDbApiCall {
    # Wrapper for SteamGridDB API calls with retry logic and better error handling
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop -TimeoutSec 30
            return $response
        } catch {
            $isLastAttempt = $attempt -eq $MaxRetries
            $errorMessage = $_.Exception.Message

            if ($errorMessage -match '429|Too Many Requests') {
                # Rate limited - wait longer
                $waitTime = $RetryDelaySeconds * 2
                Write-Host "  [WARN]    Rate limited by SteamGridDB. Waiting ${waitTime}s before retry..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $waitTime
            } elseif ($errorMessage -match '5\d\d|timeout|network') {
                # Server error or network issue - retry with backoff
                if (-not $isLastAttempt) {
                    $waitTime = $RetryDelaySeconds * $attempt
                    Write-Host "  [WARN]    Network/server error, retrying in ${waitTime}s (attempt $attempt/$MaxRetries)..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds $waitTime
                    continue
                }
            } else {
                # Client error or other issue - don't retry
                throw
            }

            if ($isLastAttempt) {
                throw
            }
        }
    }
}

function Get-SteamGridDbIcoPath {
    # Returns cached/generated SGDB icon for a Steam appid when available.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$AppId,
        [string]$SafeName,
        [string]$ApiKey,
        [string]$CachePath,
        [switch]$Refresh,
        # Comma-separated SteamGridDB style filter (e.g. 'official' or 'official,custom').
        [string]$Styles = 'official,custom',
        [string]$GameName = $null,
        # Suppress the [SKIP] message on failure (use for intermediate fallback calls).
        [switch]$Quiet
    )

    $excludedIds = @()
    if ($global:SteamGridDbExcludedIconIdsByAppId -and $global:SteamGridDbExcludedIconIdsByAppId.ContainsKey($AppId)) {
        $excludedIds = @($global:SteamGridDbExcludedIconIdsByAppId[$AppId] | ForEach-Object { [string]$_ })
    }

    $preferredId = ''
    if ($global:SteamGridDbPreferredIconIdsByAppId -and $global:SteamGridDbPreferredIconIdsByAppId.ContainsKey($AppId)) {
        $preferredId = [string]$global:SteamGridDbPreferredIconIdsByAppId[$AppId]
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
            $prefResp = Invoke-SteamGridDbApiCall -Uri $prefUrl -Headers $headers
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
            $resp = Invoke-SteamGridDbApiCall -Uri $apiUrl -Headers $headers
        } catch {
            # Compatibility fallback for clients expecting raw API key without Bearer.
            try {
                $headers = @{ Authorization = $ApiKey }
                $resp = Invoke-SteamGridDbApiCall -Uri $apiUrl -Headers $headers
            } catch {
                if (-not $Quiet) {
                    $gameInfo = if ($GameName) { "$GameName (AppID $AppId)" } else { "AppID $AppId" }
                    Write-Host "  [SKIP]    SteamGridDB lookup failed for $gameInfo" -ForegroundColor DarkYellow
                }
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
    $iconJpg = Get-ChildItem $cacheDir -File -Include '*.jpg','*.png' -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match '^[0-9a-f]{40}$' } |
                Select-Object -First 1

    # Fall back to header.<ext>
    if (-not $iconJpg) {
        $iconJpg = Get-ChildItem $cacheDir -File -Include 'header.jpg','header.png' -ErrorAction SilentlyContinue |
                   Select-Object -First 1
    }

    # Next fall back to any single image in the library cache folder
    if (-not $iconJpg) {
        $iconJpg = Get-ChildItem $cacheDir -File -Include '*.jpg','*.png' -ErrorAction SilentlyContinue |
                   Sort-Object @{ Expression = { $_.BaseName -match 'logo|cover|header|client|icon' }; Descending = $true }, @{ Expression = { $_.Length }; Descending = $true } |
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

function Get-SteamCdnIcoPath {
    # Downloads Steam CDN artwork for the app and converts it to ICO.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$AppId,
        [string]$SafeName,
        [string]$CachePath,
        [switch]$Refresh
    )

    if (-not $AppId -or -not $SafeName -or -not $CachePath) {
        return $null
    }

    if (-not (Test-Path $CachePath)) {
        if ($PSCmdlet.ShouldProcess($CachePath, 'Create Steam icon cache directory')) {
            New-Item -ItemType Directory -Path $CachePath | Out-Null
        }
    }

    $icoPath = Join-Path $CachePath "$SafeName.steamcdn.ico"
    if ((-not $Refresh) -and (Test-Path $icoPath)) {
        return $icoPath
    }

    $tmpPath = Join-Path $CachePath "$SafeName.steamcdn.download.jpg"
    $candidateUrls = @(
        "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId/library_600x900_2x.jpg",
        "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId/library_600x900.jpg",
        "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId/library_capsule.jpg",
        "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId/header.jpg",
        "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId/capsule_231x87.jpg"
    )

    foreach ($url in $candidateUrls) {
        try {
            if ($PSCmdlet.ShouldProcess($tmpPath, 'Download Steam CDN artwork')) {
                Invoke-WebRequest -Uri $url -OutFile $tmpPath -UseBasicParsing -ErrorAction Stop
            }

            if (Test-Path $tmpPath) {
                if ($PSCmdlet.ShouldProcess($icoPath, 'Convert Steam CDN artwork to ICO')) {
                    ConvertImageToIco -SourcePath $tmpPath -DestPath $icoPath
                }
                if (Test-Path $icoPath) {
                    return $icoPath
                }
            }
        } catch {
            # Try next candidate URL.
        } finally {
            if (Test-Path $tmpPath) {
                if ($PSCmdlet.ShouldProcess($tmpPath, 'Remove temporary Steam CDN asset')) {
                    Remove-Item -LiteralPath $tmpPath -Force
                }
            }
        }
    }

    # Some demos/apps do not expose legacy CDN paths, but appdetails still
    # provides valid store_item_assets image URLs.
    try {
        $appDetails = Invoke-RestMethod -Uri "https://store.steampowered.com/api/appdetails?appids=$AppId&l=english" -ErrorAction Stop
        $entry = $appDetails.$AppId
        if ($entry -and $entry.success -and $entry.data) {
            $storeUrls = @(
                $entry.data.header_image,
                $entry.data.capsule_image,
                $entry.data.capsule_imagev5
            ) | Where-Object { $_ } | Select-Object -Unique

            foreach ($storeUrl in $storeUrls) {
                try {
                    if ($PSCmdlet.ShouldProcess($tmpPath, 'Download Steam Store artwork')) {
                        Invoke-WebRequest -Uri $storeUrl -OutFile $tmpPath -UseBasicParsing -ErrorAction Stop
                    }

                    if (Test-Path $tmpPath) {
                        if ($PSCmdlet.ShouldProcess($icoPath, 'Convert Steam Store artwork to ICO')) {
                            ConvertImageToIco -SourcePath $tmpPath -DestPath $icoPath
                        }
                        if (Test-Path $icoPath) {
                            return $icoPath
                        }
                    }
                } catch {
                    # Try next store-provided URL.
                } finally {
                    if (Test-Path $tmpPath) {
                        if ($PSCmdlet.ShouldProcess($tmpPath, 'Remove temporary Steam Store asset')) {
                            Remove-Item -LiteralPath $tmpPath -Force
                        }
                    }
                }
            }
        }
    } catch {
        # Ignore store metadata errors and continue to later fallbacks.
    }

    return $null
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
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$PackageFamilyName,
        [string]$InstallLocation,
        [string]$LogoRelPath,
        [string]$UwpIconCache
    )

    $logoSrc = Get-UwpLogoPath -InstallLocation $InstallLocation -LogoRelPath $LogoRelPath

    # Fallback: search for a name containing a known icon keyword when manifest-specified logo path is missing.
    if (-not $logoSrc -and $InstallLocation -and (Test-Path $InstallLocation)) {
        try {
            $logoCandidates = Get-ChildItem -Path $InstallLocation -Recurse -Include '*logo*.ico','*logo*.png','*logo*.jpg' -File -ErrorAction SilentlyContinue
            if ($logoCandidates) {
                $logoSrc = $logoCandidates |
                    Sort-Object @{Expression = { $_.Name -match 'Square150x150|StoreLogo|Square44x44|Logo' }; Descending = $true }, @{Expression = { $_.Name.Length }; Descending = $true } |
                    Select-Object -First 1
                if ($logoSrc) { $logoSrc = $logoSrc.FullName }
            }
        } catch {
            # Ignore file scan failures and continue gracefully.
            $logoSrc = $null
        }
    }

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
