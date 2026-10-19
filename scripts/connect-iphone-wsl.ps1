<#
.SYNOPSIS
    Connects a physical iPhone over USB from Windows into WSL2 Ubuntu for xtool (`xtool devices`, `xtool install`, `xtool launch`).

.DESCRIPTION
    Supports two connection modes:
    1. Relay (Default): Uses the Windows Apple Mobile Device Service (AMDS, listening on 127.0.0.1:27015)
       and bridges it into WSL2 `/var/run/usbmuxd` via `socat` + WSL2 interop stdio (`amds-stdio-bridge.js`).
       This completely bypasses Windows Defender Firewall on `vEthernet (WSL)` and requires zero Admin privileges.
    2. Usbipd: Attaches the Apple Mobile Device USB Composite Device directly to WSL2 via `usbipd-win`
       and starts `usbmuxd` inside WSL2.

.PARAMETER Mode
    Connection mode: 'Auto' (default, prefers Relay if Apple Mobile Device Service is running), 'Relay', or 'Usbipd'.

.PARAMETER WslDistro
    WSL2 distribution name (default: 'Ubuntu').
#>
param(
    [ValidateSet('Auto', 'Relay', 'Usbipd')]
    [string]$Mode = 'Auto',

    [string]$WslDistro = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'

Write-Host "=== SmartShopper iPhone -> WSL2 USB Connector ===" -ForegroundColor Cyan

$amds = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
$usbipdCmd = Get-Command usbipd -ErrorAction SilentlyContinue

if ($Mode -eq 'Auto') {
    if ($amds -and $amds.Status -eq 'Running') {
        $Mode = 'Relay'
        Write-Host "[Auto] Detected running 'Apple Mobile Device Service' on Windows -> using 'Relay' mode." -ForegroundColor Green
    } elseif ($usbipdCmd) {
        $Mode = 'Usbipd'
        Write-Host "[Auto] Detected 'usbipd' -> using 'Usbipd' mode." -ForegroundColor Green
    } else {
        Write-Error "Neither 'Apple Mobile Device Service' nor 'usbipd-win' was found. Install Apple Devices / iTunes or run: winget install --exact dorssel.usbipd-win"
    }
}

if ($Mode -eq 'Relay') {
    if (-not $amds) {
        Write-Error "'Apple Mobile Device Service' is not installed. Install Apple Devices or iTunes on Windows, or use -Mode Usbipd."
    }
    if ($amds.Status -ne 'Running') {
        Write-Host "Starting Apple Mobile Device Service..." -ForegroundColor Yellow
        Start-Service -Name 'Apple Mobile Device Service'
    }

    $listening = Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue
    if (-not $listening) {
        Write-Error "Apple Mobile Device Service is running, but nothing is listening on TCP port 27015."
    }
    Write-Host "Windows Apple Mobile Device Service is listening on 127.0.0.1:27015." -ForegroundColor Green

    wsl -d $WslDistro -u root -- sed -i 's/\r$//' /mnt/c/Users/chadj/OneDrive/Desktop/the/HermesEdge-iOS/scripts/start-wsl-usbmuxd-bridge.sh
    wsl -d $WslDistro -u root -- bash /mnt/c/Users/chadj/OneDrive/Desktop/the/HermesEdge-iOS/scripts/start-wsl-usbmuxd-bridge.sh
}
elseif ($Mode -eq 'Usbipd') {
    if (-not $usbipdCmd) {
        Write-Error "usbipd-win is not installed. Run: winget install --interactive --exact dorssel.usbipd-win"
    }
    $usbList = usbipd list
    Write-Host $usbList
    $appleLine = $usbList -split "`r?`n" | Where-Object { $_ -match '05ac:' -or $_ -match 'Apple Mobile Device' } | Select-Object -First 1
    if (-not $appleLine) {
        Write-Error "No Apple Mobile Device (VID 05ac) found in 'usbipd list'. Make sure your iPhone is plugged in via USB and unlocked."
    }
    $busId = ($appleLine -split '\s+')[0]
    Write-Host "Found Apple device on BUSID: $busId" -ForegroundColor Green
    usbipd attach --wsl --busid $busId
    wsl -d $WslDistro -u root -- sh -c "pkill -f 'socat.*usbmuxd' 2>/dev/null || true; pkill -x usbmuxd 2>/dev/null || true; rm -f /var/run/usbmuxd; usbmuxd"
    Start-Sleep -Seconds 1
    wsl -d $WslDistro -- sh -c 'export PATH="$HOME/.local/bin:$PATH"; idevice_id -l || true; xtool devices || true'
}
