<#
.SYNOPSIS
    Removes AI Usage Node from %LOCALAPPDATA%\AIUsageNode, kills any running
    instance, and removes the autostart entry.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

$AppName    = 'AIUsageNode'
$InstallDir = Join-Path $env:LOCALAPPDATA $AppName
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# Kill any running tray instance (any PowerShell process loaded from our script path).
$scriptPath = Join-Path $InstallDir 'AIUsageNode.ps1'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='wscript.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$AppName*" } |
    ForEach-Object {
        Write-Host "[ai-usage-node] stopping PID $($_.ProcessId)" -ForegroundColor Yellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

# Remove autostart entry
$existing = Get-ItemProperty -Path $RunKey -Name $AppName -ErrorAction SilentlyContinue
if ($existing) {
    Remove-ItemProperty -Path $RunKey -Name $AppName -ErrorAction SilentlyContinue
    Write-Host "[ai-usage-node] removed autostart entry" -ForegroundColor Green
}

# Remove install dir (keep settings.json if user wants by setting -KeepSettings; default removes everything).
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        Write-Warning "Could not fully remove $InstallDir. Some files may be locked (e.g. tray icon still running)."
        Write-Warning "Wait a few seconds for processes to exit, then re-run uninstall.ps1."
    } else {
        Write-Host "[ai-usage-node] removed $InstallDir" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "[ai-usage-node] uninstalled." -ForegroundColor Cyan
