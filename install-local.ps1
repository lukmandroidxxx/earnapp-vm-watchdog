# -*- coding: utf-8 -*-
<#
    Installer EarnApp VM Watchdog - MODE LOKAL
    ------------------------------------------
    Untuk Windows 10 32-bit / 64-bit, PowerShell 5.1 (bawaan Windows).
    Tidak butuh Python, tidak butuh install apa pun, TIDAK butuh cookie.

    Yang dilakukan:
      1. Menyalin earnapp-watchdog-local.ps1 ke folder install
         (default C:\EarnAppWatchdogLocal).
      2. Membuat config.json (tanpa cookie).
      3. Mendaftarkan Scheduled Task "EarnAppWatchdogLocal" yang jalan saat
         user logon, tersembunyi, dengan hak Administrator (Highest).
      4. (Opsional) langsung menyalakan task.

    Contoh pakai (PowerShell sebagai Administrator):
      .\install-local.ps1
      .\install-local.ps1 -TelegramChatId 5563427435 -TelegramToken 123:ABC
      .\install-local.ps1 -EarnAppExe "C:\Program Files (x86)\EarnApp\earnapp.exe" -NoStart

    PENTING: jangan pasang ini bersamaan dengan watchdog API
    (install.ps1 / task "EarnAppWatchdog"). Pilih salah satu.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "C:\EarnAppWatchdogLocal",
    [string]$EarnAppExe = "",
    [int]$OffSeconds = 60,
    [int]$SettleSeconds = 60,
    [int]$CheckIntervalSeconds = 60,
    [int]$MaxRestartsPerHour = 30,
    [int]$StaleLogSeconds = 1800,
    [string]$TelegramToken = "",
    [string]$TelegramChatId = "",
    [switch]$NoStart,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$TaskName = "EarnAppWatchdogLocal"
$ApiTaskName = "EarnAppWatchdog"

function Write-Step {
    param([string]$Text)
    Write-Host ("[install-local] " + $Text)
}

# --- 1. Harus Administrator ------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principalCheck = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "GAGAL: jalankan PowerShell sebagai Administrator (klik kanan > Run as administrator)." -ForegroundColor Red
    exit 1
}

# --- 2. Sumber file --------------------------------------------------------
$SourceDir = $PSScriptRoot
if (-not $SourceDir) { $SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$MainScript = Join-Path $SourceDir "earnapp-watchdog-local.ps1"
if (-not (Test-Path $MainScript)) {
    Write-Host "GAGAL: earnapp-watchdog-local.ps1 tidak ada di $SourceDir" -ForegroundColor Red
    exit 1
}

# --- 3. Peringatan kalau watchdog API juga terpasang ----------------------
try {
    $apiTask = Get-ScheduledTask -TaskName $ApiTaskName -ErrorAction SilentlyContinue
    if ($apiTask) {
        Write-Host "PERINGATAN: task '$ApiTaskName' (watchdog API) masih terdaftar." -ForegroundColor Yellow
        Write-Host "            Dua watchdog akan saling mematikan EarnApp." -ForegroundColor Yellow
        Write-Host "            Nonaktifkan dulu: Stop-ScheduledTask -TaskName $ApiTaskName; Disable-ScheduledTask -TaskName $ApiTaskName" -ForegroundColor Yellow
    }
} catch { }

# --- 4. Siapkan folder install --------------------------------------------
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Step "Folder dibuat: $InstallDir"
}

$SameFolder = $false
try {
    $SameFolder = ((Resolve-Path $SourceDir).Path.TrimEnd('\') -eq (Resolve-Path $InstallDir).Path.TrimEnd('\'))
} catch { }

if (-not $SameFolder) {
    Copy-Item -Path $MainScript -Destination $InstallDir -Force
    $Emergency = Join-Path $SourceDir "stop-emergency-local.ps1"
    if (Test-Path $Emergency) { Copy-Item -Path $Emergency -Destination $InstallDir -Force }
    Write-Step "Script disalin ke $InstallDir"
} else {
    Write-Step "Install di folder yang sama dengan sumber; tidak perlu menyalin."
}

$TargetScript = Join-Path $InstallDir "earnapp-watchdog-local.ps1"
$ConfigPath = Join-Path $InstallDir "config.json"

# --- 5. Config -------------------------------------------------------------
$defaults = [ordered]@{
    earnapp_exe            = ""
    process_names          = @("earnapp")
    off_seconds            = 60
    settle_seconds         = 60
    check_interval_seconds = 60
    max_restarts_per_hour  = 30
    manage_service         = $true
    service_match          = "earnapp"
    stale_log_seconds      = 1800
    restart_when_paused    = $false
    restart_when_unknown   = $false
    restart_when_hang      = $true
    window_probe_seconds   = 12
    blocked_texts          = @()
    paused_texts           = @()
    telegram_token         = ""
    telegram_chat_id       = ""
}

$cfg = [ordered]@{}
foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }

if ((Test-Path $ConfigPath) -and (-not $Force)) {
    try {
        $old = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            if ($old.PSObject.Properties.Name -contains $k) { $cfg[$k] = $old.$k }
        }
        Write-Step "config.json lama dipakai sebagai dasar."
    } catch {
        Write-Step "config.json lama tidak terbaca; mulai dari default."
    }
}

if ($EarnAppExe) { $cfg["earnapp_exe"] = $EarnAppExe }
if ($OffSeconds -gt 0) { $cfg["off_seconds"] = $OffSeconds }
if ($SettleSeconds -gt 0) { $cfg["settle_seconds"] = $SettleSeconds }
if ($CheckIntervalSeconds -gt 0) { $cfg["check_interval_seconds"] = $CheckIntervalSeconds }
if ($MaxRestartsPerHour -gt 0) { $cfg["max_restarts_per_hour"] = $MaxRestartsPerHour }
if ($StaleLogSeconds -ge 0) { $cfg["stale_log_seconds"] = $StaleLogSeconds }
if ($TelegramToken) { $cfg["telegram_token"] = $TelegramToken }
if ($TelegramChatId) { $cfg["telegram_chat_id"] = $TelegramChatId }

$cfg | ConvertTo-Json -Depth 5 | Out-File -FilePath $ConfigPath -Encoding UTF8 -Force
Write-Step "Config ditulis: $ConfigPath (tanpa cookie)"

# --- 6. Launcher tanpa jendela --------------------------------------------
$VbsPath = Join-Path $InstallDir "run-hidden.vbs"
$vbsDir = $InstallDir.Replace('"', '""')
$vbs = @(
    "' Jalankan EarnApp Watchdog LOKAL tanpa jendela (dibuat oleh install-local.ps1)",
    "Set sh = CreateObject(""WScript.Shell"")",
    "sh.Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$vbsDir\earnapp-watchdog-local.ps1"""""", 0, False"
) -join "`r`n"
$vbs | Out-File -FilePath $VbsPath -Encoding ASCII -Force
Write-Step "Launcher tanpa jendela: $VbsPath"

# --- 7. Hentikan instance lama --------------------------------------------
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
} catch { }

try {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*earnapp-watchdog-local.ps1*" })
    foreach ($proc in $running) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Step "Instance lama dihentikan (PID $($proc.ProcessId))"
    }
} catch { }

# --- 8. Daftarkan Scheduled Task -----------------------------------------
$userId = $identity.Name
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument ("//B `"$VbsPath`"")
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "Mode lokal (tanpa cookie): baca jendela EarnApp; kalau ada tanda blocked, matikan 1 menit lalu nyalakan lagi." `
    -Force | Out-Null

try {
    $task = Get-ScheduledTask -TaskName $TaskName
    $task.Settings.Hidden = $true
    Set-ScheduledTask -TaskName $TaskName -Settings $task.Settings | Out-Null
} catch {
    Write-Step "Peringatan: tidak bisa set Hidden pada task ($($_.Exception.Message))"
}

Write-Step "Scheduled Task '$TaskName' terdaftar (user: $userId, at logon, Highest)."

# --- 9. Nyalakan sekarang --------------------------------------------------
if (-not $NoStart) {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Step ("Task dinyalakan. LastRunTime={0} LastTaskResult={1}" -f $info.LastRunTime, $info.LastTaskResult)
} else {
    Write-Step "Task TIDAK dinyalakan (-NoStart). Nyalakan nanti: Start-ScheduledTask -TaskName $TaskName"
}

Write-Host ""
Write-Host "Selesai. Cek status lokal kapan saja dengan:" -ForegroundColor Green
Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"$TargetScript`" -CheckOnly") -ForegroundColor Green
Write-Host ("Log: " + (Join-Path $InstallDir "logs\watchdog-local.log")) -ForegroundColor Green
Write-Host ""
Write-Host "Catatan: task jalan saat user logon. Pastikan VM auto-login supaya watchdog hidup setelah reboot." -ForegroundColor Yellow
Write-Host "Mode ini TIDAK tahu alasan ban / IP publik; itu hanya dari API akun (watchdog API)." -ForegroundColor Yellow
