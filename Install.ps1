<#
.SYNOPSIS
    Installer for Thetis Custom VU Meter.

.DESCRIPTION
    Downloads the latest ThetisLevelMeter.ps1 from GitHub, unblocks it, and
    creates a Desktop shortcut that launches it with PowerShell 7. Also offers
    to install PowerShell 7 via winget if it isn't already present.

    Deliberately written to run on the Windows PowerShell 5.1 that ships with
    Windows by default -- so it works as a one-liner even before PowerShell 7
    is installed:

        irm https://raw.githubusercontent.com/Chris-W4ORS/Thetis-Custom-VU-Meter/main/Install.ps1 | iex

    Re-run this any time to update to the latest version of the script --
    your saved config (device choice, TCI host/port) is untouched, since that
    lives separately in %APPDATA%\ThetisQSORecorder\.
#>

param(
    [string]$InstallDir = "$env:LOCALAPPDATA\ThetisVUMeter"
)

$ErrorActionPreference = "Stop"
$RepoRawUrl = "https://raw.githubusercontent.com/Chris-W4ORS/Thetis-Custom-VU-Meter/main/ThetisLevelMeter.ps1"

Write-Host ""
Write-Host "=== Thetis Custom VU Meter -- Installer ===" -ForegroundColor Cyan
Write-Host ""

# ── 1. PowerShell 7+ check ────────────────────────────────────────────────────
# The meter itself needs PS7 (WebSocket support, etc.); this installer does not.
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshCmd) {
    Write-Host "PowerShell 7 is required to run the meter (you're currently running this installer on Windows PowerShell, which is fine just for installing)." -ForegroundColor Yellow
    $resp = Read-Host "Install PowerShell 7 now via winget? [Y/n]"
    if ($resp -notmatch '^(n|no)$') {
        try {
            winget install --id Microsoft.PowerShell -e --source winget --accept-package-agreements --accept-source-agreements
            Write-Host "PowerShell 7 installed." -ForegroundColor Green
        } catch {
            Write-Warning "winget install failed ($($_.Exception.Message)). Install manually from https://aka.ms/powershell-release?tag=stable"
        }
    } else {
        Write-Warning "Skipping. Install PowerShell 7 manually before launching the meter: https://aka.ms/powershell-release?tag=stable"
    }
    # Re-check -- winget may have just installed it into this same session's PATH scope
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
} else {
    Write-Host "PowerShell 7 found: $($pwshCmd.Source)" -ForegroundColor Green
}

$pwshPath = if ($pwshCmd) { $pwshCmd.Source }
            elseif (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") { "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
            else { $null }

# ── 2. Download the script ────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$scriptPath = Join-Path $InstallDir "ThetisLevelMeter.ps1"
Write-Host ""
Write-Host "Downloading ThetisLevelMeter.ps1 to $scriptPath ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $RepoRawUrl -OutFile $scriptPath -UseBasicParsing
Unblock-File -Path $scriptPath
Write-Host "Done." -ForegroundColor Green

# ── 3. Desktop shortcut ────────────────────────────────────────────────────────
$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "Thetis VU Meter.lnk"
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = if ($pwshPath) { $pwshPath } else { "pwsh.exe" }  # resolves via PATH once PS7 is installed
$shortcut.Arguments  = "-NoExit -File `"$scriptPath`""
$shortcut.WorkingDirectory = $InstallDir
if ($pwshPath) { $shortcut.IconLocation = "$pwshPath,0" }
$shortcut.Description = "Thetis Custom VU Meter"
$shortcut.Save()
Write-Host "Desktop shortcut created: $shortcutPath" -ForegroundColor Green

Write-Host ""
Write-Host "=== Install complete ===" -ForegroundColor Cyan
Write-Host "Double-click 'Thetis VU Meter' on your Desktop to launch it."
Write-Host "First launch walks you through a short one-time setup: pick your mic/TX capture"
Write-Host "device, confirm Thetis's TCI connection. Re-run that setup any time with:"
Write-Host "  pwsh `"$scriptPath`" -Reconfigure" -ForegroundColor Gray
Write-Host ""
