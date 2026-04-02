# Shortcut creation and management operations

function Write-UrlFile {
    param(
        [string]$Path,
        [string]$Url,
        [string]$IconFile,
        [string]$WorkingDir = ''
    )
    try {
        $wdLine = if ($WorkingDir) { "`r`nWorkingDirectory=$WorkingDir" } else { '' }
        $iconLine = if ($IconFile) { "`r`nIconFile=$IconFile" } else { '' }
        $body   = "[{000214A0-0000-0000-C000-000000000046}]`r`nProp3=19,0`r`n[InternetShortcut]`r`nIDList=`r`nIconIndex=0$wdLine`r`nURL=$Url$iconLine`r`n"
        if ($PSCmdlet.ShouldProcess($Path, 'Write shortcut')) {
            $dir = Split-Path $Path
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($Path, $body, $utf8NoBom)
        }
    } catch {
        Write-Host "  [ERROR]   Failed to create URL shortcut: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Set-UrlIconFile {
    param([string]$Path, [string]$IconFile)
    $raw = [System.IO.File]::ReadAllText($Path)
    if ($IconFile) {
        if ($raw -match 'IconFile=') {
            $raw = $raw -replace 'IconFile=[^\r\n]+', "IconFile=$IconFile"
        } else {
            $raw = $raw -replace '(\[InternetShortcut\])', "`$1`r`nIconFile=$IconFile"
        }
    } else {
        # Remove IconFile line if present
        $raw = $raw -replace '\r\nIconFile=[^\r\n]+', ''
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
    try {
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
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($s) | Out-Null
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
        }
    } catch {
        Write-Host "  [ERROR]   Failed to create LNK shortcut: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Set-LnkIconFile {
    param([string]$Path, [string]$IconFile)
    if ($PSCmdlet.ShouldProcess($Path, "Set IconLocation to $IconFile")) {
        $ws = $null
        $s = $null
        try {
            $ws = New-Object -ComObject WScript.Shell
            $s  = $ws.CreateShortcut($Path)
            $s.IconLocation = "$IconFile,0"
            $s.Save()
        } finally {
            if ($s) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($s) | Out-Null
            }
            if ($ws) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
            }
        }
    }
}

function Get-ShortcutIconPath {
    # Extracts the current icon path from a .url or .lnk shortcut.
    param(
        [string]$Path,
        [string]$Type = 'url'  # 'url' or 'lnk'
    )
    
    if ($Type -eq 'lnk') {
        $ws = $null
        $s = $null
        try {
            $ws = New-Object -ComObject WScript.Shell
            $s = $ws.CreateShortcut($Path)
            return ($s.IconLocation -split ',')[0].Trim()
        } finally {
            if ($s) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($s) | Out-Null
            }
            if ($ws) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
            }
        }
    } else {
        $raw = [System.IO.File]::ReadAllText($Path)
        if ($raw -match 'IconFile=([^\r\n]+)') {
            return $matches[1].Trim()
        } else {
            return ''
        }
    }
}
