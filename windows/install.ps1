<#
.SYNOPSIS
    Installs AI Usage Node (Windows tray app) into %LOCALAPPDATA%\AIUsageNode
    and registers an autostart entry so it launches at login.

.PARAMETER NoAutostart
    Skip the HKCU Run registry entry. The app can still be launched manually
    from the install dir.

.PARAMETER Start
    Start the tray app immediately after installing.

.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -Start
.EXAMPLE
    .\install.ps1 -NoAutostart
#>
[CmdletBinding()]
param(
    [switch]$NoAutostart,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

$AppName   = 'AIUsageNode'
$InstallDir = Join-Path $env:LOCALAPPDATA $AppName
$SrcDir    = $PSScriptRoot
$RunKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# Sanity checks
$credsPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
if (-not (Test-Path $credsPath)) {
    Write-Warning "Claude credentials not found at $credsPath."
    Write-Warning "Install Claude Code and run 'claude' once to log in: https://docs.claude.com/claude-code"
    Write-Warning "The tray icon will still install, but it'll show 'No credentials' until you log in."
}

# Copy files
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$files = @(
    'AIUsageNode.ps1'
    'start-aiusagenode.vbs'
    'uninstall.ps1'
)
foreach ($f in $files) {
    $src = Join-Path $SrcDir $f
    if (-not (Test-Path $src)) {
        throw "Source file missing: $src"
    }
    Copy-Item -Path $src -Destination (Join-Path $InstallDir $f) -Force
}
Write-Host "[ai-usage-node] installed to $InstallDir" -ForegroundColor Green

# Autostart entry
if (-not $NoAutostart) {
    $vbs = Join-Path $InstallDir 'start-aiusagenode.vbs'
    $cmd = "wscript.exe `"$vbs`""
    New-ItemProperty -Path $RunKey -Name $AppName -Value $cmd -PropertyType String -Force | Out-Null
    Write-Host "[ai-usage-node] autostart registered at HKCU\...\Run\$AppName" -ForegroundColor Green
} else {
    Write-Host "[ai-usage-node] autostart skipped (--NoAutostart)" -ForegroundColor Yellow
}

# Launch now
if ($Start) {
    $vbs = Join-Path $InstallDir 'start-aiusagenode.vbs'
    Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`""
    Write-Host "[ai-usage-node] launched. Look for the sparkle icon in your system tray." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Done. To start now without rebooting:" -ForegroundColor Cyan
    Write-Host "  wscript.exe `"$(Join-Path $InstallDir 'start-aiusagenode.vbs')`"" -ForegroundColor White
    Write-Host ""
    Write-Host "It will also launch automatically at your next login." -ForegroundColor Cyan
}
