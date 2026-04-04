# Microsoft Store Games platform operations

function Sync-MicrosoftStoreGames {
    param(
        [string]$MsStoreMenu,
        [string]$LegacyMsStoreMenu = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Store",
        [string]$CustomIconsPath,
        [string]$SteamGridDbCache,
        [string]$UwpIconCache,
        [string[]]$InstalledXboxNames = @(),
        [string[]]$IncludeStorePackages = @()
    )
    
    Write-Host "`n=== Microsoft Store Games ===" -ForegroundColor Cyan

    if (-not (Test-Path $MsStoreMenu)) {
        if ($PSCmdlet.ShouldProcess($MsStoreMenu, 'Create directory')) {
            New-Item -ItemType Directory -Path $MsStoreMenu | Out-Null
        }
    }

    # Migrate legacy Store shortcuts into the unified Games folder.
    if ($LegacyMsStoreMenu -and ($LegacyMsStoreMenu -ne $MsStoreMenu) -and (Test-Path $LegacyMsStoreMenu)) {
        Get-ChildItem -LiteralPath $LegacyMsStoreMenu -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
            $destinationPath = Join-Path $MsStoreMenu $_.Name
            if (-not (Test-Path $destinationPath)) {
                Write-Host "  [MIGRATE] $($_.Name) from legacy Microsoft Store folder" -ForegroundColor Cyan
                if ($PSCmdlet.ShouldProcess($_.FullName, "Move shortcut to $MsStoreMenu")) {
                    Move-Item -LiteralPath $_.FullName -Destination $destinationPath -Force
                }
            } else {
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove duplicate legacy shortcut')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }
        }
    }

    # Merge capability-detected games with any explicitly included packages
    $storeGames = [System.Collections.Generic.List[object]]::new()
    foreach ($g in @(Get-UwpGameList -StoreOnly)) { $storeGames.Add($g) }

    if ($IncludeStorePackages.Count -gt 0) {
        $knownFamilyNames = $storeGames | ForEach-Object { $_.PackageFamilyName }
        $allPkgs = @()
        try {
            $allPkgs += @(Get-AppxPackage -AllUsers -ErrorAction Stop)
        } catch {
            # Ignore and continue with current-user inventory.
        }
        $allPkgs += @(Get-AppxPackage -ErrorAction SilentlyContinue)
        $allPkgs = $allPkgs |
            Group-Object PackageFamilyName |
            ForEach-Object { $_.Group | Select-Object -First 1 }
        foreach ($pattern in $IncludeStorePackages) {
            $matched = $allPkgs | Where-Object { $_.Name -like $pattern -and -not $_.IsFramework -and -not $_.IsResourcePackage }
            foreach ($pkg in $matched) {
                if ($knownFamilyNames -contains $pkg.PackageFamilyName) { continue }
                $knownFamilyNames += $pkg.PackageFamilyName
                $manifestPath = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
                $raw = if (Test-Path $manifestPath) { Get-Content $manifestPath -Raw -ErrorAction SilentlyContinue } else { '' }
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

    $installedStoreNames = $storeGames | ForEach-Object { Get-SafeFilename -Name $_.DisplayName }
    $installedStoreNamesLegacy = $installedStoreNames | ForEach-Object { $_ -replace ' ', '_' }
    $installedStoreNamesCombined = @($installedStoreNames + $installedStoreNamesLegacy) | Select-Object -Unique

    if (Test-Path $MsStoreMenu) {
        # Pre-compute shortcut paths the game loop will create so the cleanup
        # loop never removes a file that is about to be recreated under the same path.
        $plannedStoreLnkPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($g in $storeGames) {
            $sn = Get-SafeFilename -Name $g.DisplayName
            $plannedStoreLnkPaths.Add((Join-Path $MsStoreMenu "$sn.lnk")) | Out-Null
        }

        # When Xbox and Store share a folder, path-based protection prevents
        # create->remove churn even when name matching differs.
        $plannedXboxLnkPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        # Shared Xbox+Store folder cleanup: keep anything installed in either list.
        $installedSharedNames = $installedStoreNamesCombined
        if ($MsStoreMenu -eq $XboxMenu) {
            # Recompute Xbox names from source of truth to avoid any stale/partial
            # handoff arrays causing false removals in the shared folder.
            $xboxSafeNames = @(Get-UwpGameList -XboxOnly | ForEach-Object { Get-SafeFilename -Name $_.DisplayName })
            $xboxSafeNamesLegacy = $xboxSafeNames | ForEach-Object { $_ -replace ' ', '_' }
            foreach ($sn in ($xboxSafeNames + $xboxSafeNamesLegacy | Select-Object -Unique)) {
                $plannedXboxLnkPaths.Add((Join-Path $MsStoreMenu "$sn.lnk")) | Out-Null
            }
            $installedSharedNames = @(
                $installedStoreNamesCombined +
                $InstalledXboxNames +
                $xboxSafeNames +
                $xboxSafeNamesLegacy
            ) | Select-Object -Unique
        }

        Get-ChildItem $MsStoreMenu -Filter '*.lnk' | ForEach-Object {
            # Only clean up UWP/AppX shortcuts owned by Store/Xbox sync.
            # This avoids removing launcher-native shortcuts (Battle.net, GOG, etc.)
            # that may live in the same unified Games folder.
            $ws = $null
            $shortcut = $null
            $isAppsFolderShortcut = $false
            try {
                $ws = New-Object -ComObject WScript.Shell
                $shortcut = $ws.CreateShortcut($_.FullName)
                $targetPath = [string]$shortcut.TargetPath
                $arguments = [string]$shortcut.Arguments
                $isAppsFolderShortcut =
                    $targetPath -match '(?i)\\explorer.exe$' -and
                    $arguments -match '^(?i)shell:AppsFolder\\'
            } finally {
                if ($shortcut) {
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) | Out-Null
                }
                if ($ws) {
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
                }
            }

            if (-not $isAppsFolderShortcut) { return }

            if ($installedSharedNames -notcontains $_.BaseName) {
                if (-not $plannedStoreLnkPaths.Contains($_.FullName) -and
                    -not $plannedXboxLnkPaths.Contains($_.FullName)) {
                    Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
                    if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                        Remove-Item -LiteralPath $_.FullName -Force
                    }
                }
            }
        }
    }

    foreach ($game in $storeGames) {
        $safeName      = Get-SafeFilename -Name $game.DisplayName
        $legacySafeName = $safeName -replace ' ', '_'
        $shortcutPath  = Join-Path $MsStoreMenu "$safeName.lnk"
        $legacyShortcutPath = Join-Path $MsStoreMenu "$legacySafeName.lnk"
        $aumId         = "$($game.PackageFamilyName)!$($game.AppId)"

        if ((-not (Test-Path $shortcutPath)) -and (Test-Path $legacyShortcutPath)) {
            Write-Host "  [MIGRATE] Renaming legacy shortcut $legacySafeName.lnk -> $safeName.lnk" -ForegroundColor Cyan
            if ($PSCmdlet.ShouldProcess($legacyShortcutPath, 'Rename legacy shortcut')) {
                Rename-Item -Path $legacyShortcutPath -NewName (Split-Path $shortcutPath -Leaf) -Force
            }
        }

        if ((Test-Path $shortcutPath) -and (Test-Path $legacyShortcutPath) -and ($legacyShortcutPath -ne $shortcutPath)) {
            if ($PSCmdlet.ShouldProcess($legacyShortcutPath, 'Remove duplicate shortcut')) {
                Remove-Item -LiteralPath $legacyShortcutPath -Force
            }
        }

        $customIco = Get-CustomIcoPath -SafeName $safeName -CustomIconsPath $CustomIconsPath
        if (-not $customIco -and $UseSteamGridDb) {
            $sgdbKey = if ($global:SteamGridDbPreferredIconIdsByAppId.ContainsKey($game.DisplayName)) { $game.DisplayName } elseif ($global:SteamGridDbPreferredIconIdsByAppId.ContainsKey($safeName)) { $safeName } else { $null }
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
