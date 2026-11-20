# v2 - universal API+lokal
# -*- coding: utf-8 -*-
<#
    TOMBOL DARURAT - EarnApp VM Watchdog (SATU FILE untuk API + LOKAL)
    ------------------------------------------------------------------
    Menghentikan watchdog DULU (task + proses), baru service/proses
    EarnApp. Urutan ini penting: kalau EarnApp dimatikan lebih dulu,
    watchdog akan langsung menyalakannya lagi.

    Default: matikan watchdog + EarnApp, dan DISABLE task supaya tidak
    hidup lagi saat logon / reboot.

    Mode dipilih otomatis:
      - task/folder EarnAppWatchdogLocal ada  -> mode LOKAL
      - task/folder EarnAppWatchdog ada       -> mode API
    Bisa dipaksa dengan -Local atau -Api.

    Contoh (PowerShell sebagai Administrator):
      .\stop-emergency.ps1                       # auto-detect, matikan semuanya
      .\stop-emergency.ps1 -Local -Status        # cek mode lokal
      .\stop-emergency.ps1 -Api -Status          # cek mode API
      .\stop-emergency.ps1 -KeepEarnApp          # watchdog saja, EarnApp tetap jalan
      .\stop-emergency.ps1 -KeepTaskEnabled      # jangan disable task
      .\stop-emergency.ps1 -Status               # lihat keadaan tanpa mengubah apa pun
      .\stop-emergency.ps1 -Resume               # pulihkan: enable + start task, start EarnApp
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [string]$TaskName = "",
    [switch]$Local,
    [switch]$Api,
    [switch]$KeepEarnApp,
    [switch]$KeepTaskEnabled,
    [switch]$Status,
    [switch]$Resume
)

$ErrorActionPreference = "Stop"

# --- tentukan mode ------------------------------------------------------------
if ($Local -and $Api) {
    Write-Host "GAGAL: pilih salah satu saja: -Local atau -Api." -ForegroundColor Red
    exit 1
}
if ($Local) {
    $mode = "local"
} elseif ($Api) {
    $mode = "api"
} else {
    $localTask = Get-ScheduledTask -TaskName "EarnAppWatchdogLocal" -ErrorAction SilentlyContinue
    $apiTask   = Get-ScheduledTask -TaskName "EarnAppWatchdog" -ErrorAction SilentlyContinue
    $localDir  = Test-Path "C:\EarnAppWatchdogLocal\config.json"
    $apiDir    = Test-Path "C:\EarnAppWatchdog\config.json"

    if ($localTask -and $apiTask) {
        Write-Host "PERINGATAN: task API dan LOKAL sama-sama ada. Pakai -Api / -Local kalau ragu." -ForegroundColor Yellow
    }
    if ($localTask -and -not $apiTask) { $mode = "local" }
    elseif ($apiTask -and -not $localTask) { $mode = "api" }
    elseif ($localDir -and -not $apiDir) { $mode = "local" }
    elseif ($apiDir -and -not $localDir) { $mode = "api" }
    elseif ($localTask -or $localDir) { $mode = "local" }
    else { $mode = "api" }
}

if ($mode -eq "local") {
    if (-not $InstallDir) { $InstallDir = "C:\EarnAppWatchdogLocal" }
    if (-not $TaskName)   { $TaskName   = "EarnAppWatchdogLocal" }
    $WatchdogScript = "earnapp-watchdog-local.ps1"
    $Prefix = "[darurat-lokal] "
} else {
    if (-not $InstallDir) { $InstallDir = "C:\EarnAppWatchdog" }
    if (-not $TaskName)   { $TaskName   = "EarnAppWatchdog" }
    $WatchdogScript = "earnapp-watchdog.ps1"
    $Prefix = "[darurat-api] "
}

Write-Host ("Mode       : " + $(if ($mode -eq "local") { "LOKAL" } else { "API" }))
Write-Host ("InstallDir : $InstallDir")
Write-Host ("Task       : $TaskName")

function Write-Step {
    param([string]$Text)
    Write-Host ($Prefix + $Text)
    if (Test-Path $InstallDir) {
        try {
            $logDir = Join-Path $InstallDir "logs"
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + " " + $Text
            Add-Content -Path (Join-Path $logDir "emergency.log") -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principalCheck = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "GAGAL: jalankan PowerShell sebagai Administrator." -ForegroundColor Red
    exit 1
}

function Get-Cfg {
    $cfg = [ordered]@{
        process_names = @("earnapp")
        service_match = "earnapp"
        earnapp_exe   = ""
    }
    $path = Join-Path $InstallDir "config.json"
    if (Test-Path $path) {
        try {
            $old = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($old.PSObject.Properties.Name -contains $k) { $cfg[$k] = $old.$k }
            }
        } catch { }
    }
    return $cfg
}

function Get-ProcessPatterns {
    param($Cfg)
    $names = @($Cfg["process_names"])
    if (-not $names -or $names.Count -eq 0) { $names = @("earnapp") }
    return @($names | ForEach-Object { if ([string]$_.Contains('*')) { $_ } else { "$_*" } })
}

function Get-EarnServices {
    param($Cfg)
    $m = [string]$Cfg["service_match"]
    if (-not $m) { $m = "earnapp" }
    try {
        return @(Get-Service | Where-Object {
            $_.Name -like "*$m*" -or $_.DisplayName -like "*$m*"
        })
    } catch { return @() }
}

function Get-EarnProcesses {
    param($Cfg)
    $found = @()
    foreach ($pattern in @(Get-ProcessPatterns $Cfg)) {
        try { $found += @(Get-Process -Name $pattern -ErrorAction SilentlyContinue) }
        catch { }
    }
    return @($found | Sort-Object Id -Unique)
}

function Get-WatchdogProcesses {
    $found = @()
    try {
        $found += @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$WatchdogScript*" } |
            ForEach-Object { [pscustomobject]@{ Kind = "watchdog"; Id = $_.ProcessId } })
        $found += @(Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*run-hidden.vbs*" -and $_.CommandLine -like "*$InstallDir*" } |
            ForEach-Object { [pscustomobject]@{ Kind = "launcher"; Id = $_.ProcessId } })
    } catch { }
    return @($found)
}

function Get-ExePath {
    param($Cfg)
    $p = [string]$Cfg["earnapp_exe"]
    if ($p -and (Test-Path $p)) { return $p }
    foreach ($c in @(
        "C:\Program Files (x86)\EarnApp\earnapp.exe",
        "C:\Program Files\EarnApp\earnapp.exe",
        "$env:LOCALAPPDATA\Programs\EarnApp\earnapp.exe"
    )) {
        if (Test-Path $c) { return $c }
    }
    return ""
}

$cfg = Get-Cfg

# --- STATUS -------------------------------------------------------------------
if ($Status) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Host ("Task      : {0} | State={1} | LastResult={2}" -f $TaskName, $task.State, $info.LastTaskResult)
    } else {
        Write-Host ("Task      : {0} TIDAK ADA" -f $TaskName)
    }
    $wd = @(Get-WatchdogProcesses)
    Write-Host ("Watchdog  : " + $(if ($wd.Count) { ($wd | ForEach-Object { "$($_.Kind)=$($_.Id)" }) -join ", " } else { "tidak jalan" }))
    $procs = @(Get-EarnProcesses $cfg)
    Write-Host ("EarnApp   : " + $(if ($procs.Count) { ($procs | ForEach-Object { "$($_.ProcessName)=$($_.Id)" }) -join ", " } else { "tidak jalan" }))
    foreach ($s in @(Get-EarnServices $cfg)) { Write-Host ("Service   : {0} [{1}]" -f $s.Name, $s.Status) }
    return
}

# --- RESUME --------------------------------------------------------------------
if ($Resume) {
    try {
        Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-Step "Task '$TaskName' di-enable + dinyalakan."
    } catch {
        Write-Step "Gagal menyalakan task: $($_.Exception.Message)"
    }
    foreach ($s in @(Get-EarnServices $cfg)) {
        if ($s.Status -ne "Running") {
            try { Start-Service -Name $s.Name -ErrorAction Stop; Write-Step "Service dinyalakan: $($s.Name)" }
            catch { Write-Step "Gagal start service $($s.Name): $($_.Exception.Message)" }
        }
    }
    $exe = Get-ExePath $cfg
    if ($exe -and @(Get-EarnProcesses $cfg).Count -eq 0) {
        try { Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) | Out-Null; Write-Step "EarnApp dinyalakan: $exe" }
        catch { Write-Step "Gagal start EarnApp: $($_.Exception.Message)" }
    }
    Write-Step "Pemulihan selesai."
    return
}

# --- STOP ----------------------------------------------------------------------
# 1. Task dulu, supaya tidak menyalakan lagi EarnApp di tengah jalan.
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Step "Task '$TaskName' dihentikan."
} catch {
    Write-Step "Task '$TaskName' tidak ada / sudah berhenti."
}

if (-not $KeepTaskEnabled) {
    try {
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Step "Task '$TaskName' DI-DISABLE (tidak hidup saat logon/reboot)."
    } catch {
        Write-Step "Gagal disable task: $($_.Exception.Message)"
    }
} else {
    Write-Step "Task sengaja dibiarkan aktif (-KeepTaskEnabled)."
}

# 2. Proses watchdog + launcher yang masih berjalan.
foreach ($p in @(Get-WatchdogProcesses)) {
    try {
        Stop-Process -Id $p.Id -Force -ErrorAction Stop
        Write-Step "Proses $($p.Kind) dihentikan (PID $($p.Id))."
    } catch { }
}

# 3. Service + proses EarnApp.
if ($KeepEarnApp) {
    Write-Step "EarnApp sengaja dibiarkan jalan (-KeepEarnApp)."
} else {
    foreach ($s in @(Get-EarnServices $cfg)) {
        if ($s.Status -eq "Running") {
            try {
                Stop-Service -Name $s.Name -Force -ErrorAction Stop
                Write-Step "Service dihentikan: $($s.Name)"
            } catch {
                Write-Step "Gagal stop service $($s.Name): $($_.Exception.Message)"
            }
        }
    }
    foreach ($p in @(Get-EarnProcesses $cfg)) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Write-Step "Proses dihentikan: $($p.ProcessName) (PID $($p.Id))"
        } catch { }
    }
}

Write-Step "SELESAI. Cek: .\stop-emergency.ps1 -Status | Pulihkan: .\stop-emergency.ps1 -Resume"
