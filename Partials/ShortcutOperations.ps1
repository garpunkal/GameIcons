# Shortcut creation and management operations

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

function Test-ShortcutValid {
    # Checks if a .url or .lnk shortcut has a valid icon path.
    # Returns $true if valid, $false if broken.
    param(
        [string]$Path,
        [string]$Type = 'url'  # 'url' or 'lnk'
    )
    
    if ($Type -eq 'lnk') {
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($Path)
        $current = ($s.IconLocation -split ',')[0].Trim()
    } else {
        $raw = [System.IO.File]::ReadAllText($Path)
        $current = if ($raw -match 'IconFile=([^\r\n]+)') { $matches[1].Trim() } else { '' }
    }
    
    return ($current -and (Test-Path $current))
}

function Get-ShortcutIconPath {
    # Extracts the current icon path from a .url or .lnk shortcut.
    param(
        [string]$Path,
        [string]$Type = 'url'  # 'url' or 'lnk'
    )
    
    if ($Type -eq 'lnk') {
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($Path)
        return ($s.IconLocation -split ',')[0].Trim()
    } else {
        $raw = [System.IO.File]::ReadAllText($Path)
        if ($raw -match 'IconFile=([^\r\n]+)') {
            return $matches[1].Trim()
        } else {
            return ''
        }
    }
}

function Remove-ShortcutsForUninstalledGames {
    # Removes shortcuts for games that are no longer installed.
    param(
        [string]$MenuPath,
        [string[]]$InstalledGames,  # Array of safe filenames of installed games
        [string]$Filter = '*.url',
        [switch]$SkipIfShared       # If true, skip removal (caller handles dedup)
    )
    
    if ($SkipIfShared) { return }
    
    Get-ChildItem $MenuPath -Filter $Filter -ErrorAction SilentlyContinue | ForEach-Object {
        if ($InstalledGames -notcontains $_.BaseName) {
            Write-Host "  [REMOVE]  $($_.BaseName)" -ForegroundColor Red
            if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove uninstalled shortcut')) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
    }
}

function Sync-GameShortcut {
    # Unified shortcut sync logic for all platforms.
    # Handles creation, updates, and removal of broken shortcuts.
    param(
        [string]$ShortcutPath,
        [string]$GameName,
        [string]$IconPath,
        [hashtable]$ShortcutParams  # Additional params: LaunchTarget, LaunchUrl, AppId, PackageFamilyName, WorkingDir, Type
    )
    
    $type = $ShortcutParams.Type -or 'url'
    $exists = Test-Path $ShortcutPath
    
    if (-not $exists) {
        # Create missing shortcut
        if ($IconPath) {
            Write-Host "  [CREATE]  $GameName" -ForegroundColor Green
            if ($type -eq 'lnk') {
                Write-LnkShortcut -Path $ShortcutPath `
                    -Target ($ShortcutParams.LaunchTarget -or 'explorer.exe') `
                    -Arguments ($ShortcutParams.LaunchUrl -or '') `
                    -IconFile $IconPath `
                    -Description $GameName
            } else {
                Write-UrlFile -Path $ShortcutPath `
                    -Url ($ShortcutParams.LaunchUrl -or '') `
                    -IconFile $IconPath `
                    -WorkingDir ($ShortcutParams.WorkingDir -or '')
            }
        } else {
            Write-Host "  [SKIP]    $GameName - no icon found" -ForegroundColor DarkYellow
        }
    } else {
        # Shortcut exists: check icon is still valid
        $currentIcon = Get-ShortcutIconPath -Path $ShortcutPath -Type $type
        $isValid = ($currentIcon -and (Test-Path $currentIcon))
        $needsUpdate = -not $isValid -or ($IconPath -and $currentIcon -ne $IconPath)
        
        if (-not $needsUpdate) {
            Write-Host "  [OK]      $GameName" -ForegroundColor DarkGray
        } elseif ($IconPath) {
            Write-Host "  [FIX]     $GameName" -ForegroundColor Yellow
            if ($type -eq 'lnk') {
                Set-LnkIconFile -Path $ShortcutPath -IconFile $IconPath
            } else {
                Set-UrlIconFile -Path $ShortcutPath -IconFile $IconPath
            }
        } else {
            Write-Host "  [REMOVE]  $GameName - broken icon, no source available" -ForegroundColor Red
            if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Remove shortcut with broken icon')) {
                Remove-Item -LiteralPath $ShortcutPath -Force
            }
        }
    }
}
