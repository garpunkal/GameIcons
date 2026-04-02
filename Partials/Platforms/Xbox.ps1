# Xbox Game Pass platform operations

function Sync-XboxGamePass {
    param(
        [string]$XboxMenu,
        [string]$CustomIconsPath,
        [string]$SteamGridDbCache,
        [string]$UwpIconCache
    )
    
    Write-Host "`n=== Xbox Game Pass ===" -ForegroundColor Cyan

    $xboxGames = @(Get-UwpGameList -XboxOnly | Sort-Object DisplayName)
    
    if ($xboxGames.Count -eq 0) {
        Write-Host "  [SKIP]    No Xbox Game Pass titles found (requires the Xbox app with installed games)." -ForegroundColor DarkYellow
        return
    }

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
        if (-not $customIco -and $UseSteamGridDb) {
            $sgdbKey = if ($script:SteamGridDbPreferredIconIdsByAppId.ContainsKey($game.DisplayName)) { $game.DisplayName } elseif ($script:SteamGridDbPreferredIconIdsByAppId.ContainsKey($safeName)) { $safeName } else { $null }
            if ($sgdbKey) {
                $customIco = Get-SteamGridDbIcoPath -AppId $sgdbKey -SafeName "xbox.$safeName" -ApiKey $SteamGridDbApiKey -CachePath $SteamGridDbCache -Refresh:$RefreshSteamGridDb
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
    
    # Return installed names for potential Store folder sharing
    return @($installedXboxNames)
}
