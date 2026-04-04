[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipScan,
    [switch]$SkipInstallHint
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

$hookPath = '.githooks'
$configPath = '.gitleaks.toml'

if (-not (Test-Path $hookPath)) {
    throw "Required hook path not found: $hookPath"
}

if (-not (Test-Path $configPath)) {
    throw "Required gitleaks config not found: $configPath"
}

if ($PSCmdlet.ShouldProcess('git config', 'Set core.hooksPath to .githooks')) {
    git config core.hooksPath .githooks
}

$gitleaksCmd = Get-Command gitleaks -ErrorAction SilentlyContinue
if (-not $gitleaksCmd) {
    if (-not $SkipInstallHint) {
        Write-Warning 'gitleaks is not installed or not on PATH.'
        Write-Host 'Install with: winget install Gitleaks.Gitleaks' -ForegroundColor Yellow
    }

    Write-Host 'Git hooks path configured. Install gitleaks and rerun this script to validate.' -ForegroundColor Cyan
    exit 0
}

if (-not $SkipScan) {
    if ($PSCmdlet.ShouldProcess('staged changes', 'Run gitleaks protect scan')) {
        gitleaks protect --staged --config .gitleaks.toml --redact
    }
}

Write-Host 'Done. Git hooks are configured and secret scanning is ready.' -ForegroundColor Green
