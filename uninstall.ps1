# -*- coding: utf-8 -*-
<#
    Uninstaller EarnApp VM Watchdog
    -------------------------------
    Menghentikan dan menghapus Scheduled Task "EarnAppWatchdog", lalu
    menghapus folder install.

    Contoh (PowerShell sebagai Administrator):
      .\uninstall.ps1
      .\uninstall.ps1 -KeepConfig -KeepLogs
      .\uninstall.ps1 -InstallDir "D:\EarnAppWatchdog"
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "C:\EarnAppWatchdog",
    [switch]$KeepConfig,
    [switch]$KeepLogs
)

$ErrorActionPreference = "Stop"
$TaskName = "EarnAppWatchdog"

function Write-Step {
    param([string]$Text)
    Write-Host ("[uninstall] " + $Text)
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principalCheck = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "GAGAL: jalankan PowerShell sebagai Administrator." -ForegroundColor Red
    exit 1
}

# 1. Hentikan task
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Step "Task dihentikan."
} catch { }

# 2. Hapus task
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-Step "Task '$TaskName' dihapus."
} catch {
    Write-Step "Task '$TaskName' tidak ada / sudah dihapus."
}

# 3. Hentikan proses watchdog yang masih jalan
try {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*earnapp-watchdog.ps1*" })
    foreach ($proc in $running) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Step "Proses dihentikan (PID $($proc.ProcessId))"
    }
} catch { }

# 4. Hapus file
if (Test-Path $InstallDir) {
    foreach ($name in @("earnapp-watchdog.ps1", "discover.ps1", "stop-emergency.ps1", "run-hidden.vbs")) {
        $f = Join-Path $InstallDir $name
        if (Test-Path $f) {
            Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
            Write-Step "Dihapus: $f"
        }
    }
    if (-not $KeepConfig) {
        foreach ($name in @("config.json", "cookie.json")) {
            $f = Join-Path $InstallDir $name
            if (Test-Path $f) {
                Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
                Write-Step "Dihapus: $f"
            }
        }
    } else {
        Write-Step "config.json & cookie.json disimpan (-KeepConfig)."
    }
    if (-not $KeepLogs) {
        $logs = Join-Path $InstallDir "logs"
        if (Test-Path $logs) {
            Remove-Item -Path $logs -Recurse -Force -ErrorAction SilentlyContinue
            Write-Step "Log dihapus."
        }
    } else {
        Write-Step "Folder logs disimpan (-KeepLogs)."
    }

    $left = @(Get-ChildItem -Path $InstallDir -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) {
        Remove-Item -Path $InstallDir -Force -ErrorAction SilentlyContinue
        Write-Step "Folder install dihapus."
    } else {
        Write-Step "Folder install masih berisi file (config/log); tidak dihapus: $InstallDir"
    }
} else {
    Write-Step "Folder install tidak ada: $InstallDir"
}

Write-Host ""
Write-Host "Selesai. EarnApp sendiri TIDAK di-uninstall." -ForegroundColor Green
