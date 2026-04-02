# Microsoft Store Games platform operations

function Sync-MicrosoftStoreGames {
    param(
        [string]$MsStoreMenu,
        [string]$CustomIconsPath,
        [string]$SteamGridDbCache,
        [string]$UwpIconCache,
        [string[]]$InstalledXboxNames = @()
    )
    
    Write-Host "`n=== Microsoft Store Games ===" -ForegroundColor Cyan

    # Merge capability-detected games with any explicitly included packages
    $storeGames = [System.Collections.Generic.List[object]]::new()
    foreach ($g in @(Get-UwpGameList -StoreOnly)) { $storeGames.Add($g) }

    # Merge persisted include list from settings.json
    if ($script:Settings.includeStorePackages.Count -gt 0) {
        $IncludeStorePackages = @($IncludeStorePackages) + @($script:Settings.includeStorePackages) | Select-Object -Unique
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
        return
    }

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
            $installedSharedNames = @($installedStoreNames + $InstalledXboxNames) | Select-Object -Unique
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
        if (-not $customIco -and $UseSteamGridDb) {
            $sgdbKey = if ($script:SteamGridDbPreferredIconIdsByAppId.ContainsKey($game.DisplayName)) { $game.DisplayName } elseif ($script:SteamGridDbPreferredIconIdsByAppId.ContainsKey($safeName)) { $safeName } else { $null }
            if ($sgdbKey) {
                $customIco = Get-SteamGridDbIcoPath -AppId $sgdbKey -SafeName "msstore.$safeName" -ApiKey $SteamGridDbApiKey -CachePath $SteamGridDbCache -Refresh:$RefreshSteamGridDb
            }
        }
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
            $currentIcon = Get-ShortcutIconPath -Path $shortcutPath -Type 'lnk'
            $needsFix = -not $currentIcon -or -not (Test-Path $currentIcon) -or ($customIco -and $currentIcon -ne $customIco)
            
            if (-not $needsFix) {
                Write-Host "  [OK]      $($game.DisplayName)" -ForegroundColor DarkGray
            } elseif ($icoPath) {
                Write-Host "  [FIX]     $($game.DisplayName)" -ForegroundColor Yellow
                Set-LnkIconFile -Path $shortcutPath -IconFile $icoPath
            } else {
                Write-Host "  [REMOVE]  $($game.DisplayName) - broken icon, no source available" -ForegroundColor Red
                if ($PSCmdlet.ShouldProcess($shortcutPath, 'Remove shortcut with broken icon')) {
                    Remove-Item -LiteralPath $shortcutPath -Force
                }
            }
        }
    }
}
