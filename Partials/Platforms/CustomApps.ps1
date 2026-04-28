function Sync-CustomApps {
    param(
        [string]$CustomAppsMenu,
        [string]$CustomIconsPath,
        [string]$SettingsPath
    )
    $settings = Get-Content $SettingsPath | ConvertFrom-Json
    if ($settings.customApps) {
        Write-Host "`n=== Custom Apps ===" -ForegroundColor Cyan
        foreach ($app in $settings.customApps) {
            $shortcutName = $app.name
            $shortcutPath = Join-Path $CustomAppsMenu ("$shortcutName.lnk")
            $iconPath = if ($app.icon) {
                Join-Path $CustomIconsPath $app.icon
            } else {
                Get-CustomIcoPath -SafeName $shortcutName -CustomIconsPath $CustomIconsPath
            }
            $status = $null
            try {
                if ($app.type -eq 'lnk') {
                    Write-LnkShortcut -Path $shortcutPath -Target $app.target -Arguments '' -IconFile $iconPath -Description $shortcutName
                    $status = '[OK]'
                } elseif ($app.type -eq 'url') {
                    Write-UrlFile -Path $shortcutPath -Url $app.target -IconFile $iconPath
                    $status = '[OK]'
                } else {
                    $status = '[SKIP] Unknown type'
                }
            } catch {
                $status = '[ERROR] ' + $_.Exception.Message
            }
            $iconMsg = if ($iconPath) { "(icon)" } else { "" }
            if ($status -eq '[OK]') {
                $color = 'DarkGray'
            } elseif ($status -like '[ERROR]*') {
                $color = 'Red'
            } else {
                $color = 'Yellow'
            }
            Write-Host ("  $status $shortcutName $iconMsg") -ForegroundColor $color
        }
    }
}
