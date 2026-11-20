# -*- coding: utf-8 -*-
<#
    Installer EarnApp VM Watchdog
    -----------------------------
    Untuk Windows 10 32-bit / 64-bit, PowerShell 5.1 (bawaan Windows).
    Tidak butuh Python, tidak butuh install apa pun.

    Yang dilakukan:
      1. Menyalin script ke folder install (default C:\EarnAppWatchdog).
      2. Membuat config.json.
      3. Mendaftarkan Scheduled Task "EarnAppWatchdog" yang jalan saat user
         logon, tersembunyi, dengan hak Administrator (Highest).
      4. (Opsional) langsung menyalakan task.

    Contoh pakai (PowerShell sebagai Administrator):
      .\install.ps1 -CookieFile "C:\path\cookie.json" -DeviceTitle "sdk-win-20"
      .\install.ps1 -CookieFile "C:\path\cookie.json" -DeviceTitle "sdk-win-20" -TelegramChatId 5563427435 -TelegramToken 123:ABC

    Parameter lain: -OffSeconds 60 -SettleSeconds 60 -CheckIntervalSeconds 60
                    -EarnAppExe "C:\Program Files (x86)\EarnApp\earnapp.exe"
                    -InstallDir "C:\EarnAppWatchdog" -NoStart -Force
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "C:\EarnAppWatchdog",
    [string]$CookieFile = "",
    [string]$DeviceTitle = "",
    [string]$DeviceUuid = "",
    [string]$EarnAppExe = "",
    [int]$OffSeconds = 60,
    [int]$SettleSeconds = 60,
    [int]$CheckIntervalSeconds = 60,
    [int]$MaxRestartsPerHour = 30,
    [string]$TelegramToken = "",
    [string]$TelegramChatId = "",
    [switch]$NoStart,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$TaskName = "EarnAppWatchdog"

function Write-Step {
    param([string]$Text)
    Write-Host ("[install] " + $Text)
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
$MainScript = Join-Path $SourceDir "earnapp-watchdog.ps1"
if (-not (Test-Path $MainScript)) {
    Write-Host "GAGAL: earnapp-watchdog.ps1 tidak ada di $SourceDir" -ForegroundColor Red
    exit 1
}

# --- 3. Siapkan folder install --------------------------------------------
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
    foreach ($extra in @("discover.ps1", "stop-emergency.ps1")) {
        $srcExtra = Join-Path $SourceDir $extra
        if (Test-Path $srcExtra) { Copy-Item -Path $srcExtra -Destination $InstallDir -Force }
    }
    Write-Step "Script disalin ke $InstallDir"
} else {
    Write-Step "Install di folder yang sama dengan sumber; tidak perlu menyalin."
}

$TargetScript = Join-Path $InstallDir "earnapp-watchdog.ps1"
$ConfigPath = Join-Path $InstallDir "config.json"

# --- 4. Cookie -------------------------------------------------------------
$TargetCookie = Join-Path $InstallDir "cookie.json"
if ($CookieFile) {
    if (-not (Test-Path $CookieFile)) {
        Write-Host "GAGAL: cookie tidak ditemukan: $CookieFile" -ForegroundColor Red
        exit 1
    }
    Copy-Item -Path $CookieFile -Destination $TargetCookie -Force
    Write-Step "Cookie disalin ke $TargetCookie"
} elseif (Test-Path $TargetCookie) {
    Write-Step "Cookie lama dipakai: $TargetCookie"
} else {
    Write-Host "PERINGATAN: cookie.json belum ada. Letakkan cookie akun EarnApp pemilik VM ini di:" -ForegroundColor Yellow
    Write-Host "           $TargetCookie" -ForegroundColor Yellow
    Write-Host "           (format bebas: JSON Cookie-Editor/Playwright, cookies.txt, atau string 'a=b; c=d')" -ForegroundColor Yellow
}

# --- 5. Config -------------------------------------------------------------
$defaults = [ordered]@{
    cookie_file            = "cookie.json"
    device_uuid            = ""
    device_title           = ""
    earnapp_exe            = ""
    off_seconds            = 300
    settle_seconds         = 180
    check_interval_seconds = 120
    max_restarts_per_hour  = 6
    clear_cache_on_restart = $true
    manage_service         = $true
    service_match          = "earnapp"
    api_timeout_seconds    = 30
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

if ($DeviceTitle) { $cfg["device_title"] = $DeviceTitle }
elseif (-not $cfg["device_title"]) { $cfg["device_title"] = $env:COMPUTERNAME }
if ($DeviceUuid) { $cfg["device_uuid"] = $DeviceUuid }
if ($EarnAppExe) { $cfg["earnapp_exe"] = $EarnAppExe }
if ($OffSeconds -gt 0) { $cfg["off_seconds"] = $OffSeconds }
if ($SettleSeconds -gt 0) { $cfg["settle_seconds"] = $SettleSeconds }
if ($CheckIntervalSeconds -gt 0) { $cfg["check_interval_seconds"] = $CheckIntervalSeconds }
if ($MaxRestartsPerHour -gt 0) { $cfg["max_restarts_per_hour"] = $MaxRestartsPerHour }
if ($TelegramToken) { $cfg["telegram_token"] = $TelegramToken }
if ($TelegramChatId) { $cfg["telegram_chat_id"] = $TelegramChatId }

$cfg | ConvertTo-Json -Depth 5 | Out-File -FilePath $ConfigPath -Encoding UTF8 -Force
Write-Step "Config ditulis: $ConfigPath (device_title='$($cfg['device_title'])')"

# --- 6. Launcher tanpa jendela --------------------------------------------
$VbsPath = Join-Path $InstallDir "run-hidden.vbs"
$vbsDir = $InstallDir.Replace('"', '""')
$vbs = @(
    "' Jalankan EarnApp Watchdog tanpa jendela (dibuat oleh install.ps1)",
    "Set sh = CreateObject(""WScript.Shell"")",
    "sh.Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$vbsDir\earnapp-watchdog.ps1"""""", 0, False"
) -join "`r`n"
$vbs | Out-File -FilePath $VbsPath -Encoding ASCII -Force
Write-Step "Launcher tanpa jendela: $VbsPath"

# --- 7. Hentikan instance lama --------------------------------------------
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
} catch { }

try {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*earnapp-watchdog.ps1*" })
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
    -Description "Memantau EarnApp; kalau device diblokir, matikan 1 menit lalu nyalakan lagi sampai hijau." `
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
Write-Host "Selesai. Cek status device kapan saja dengan:" -ForegroundColor Green
Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"$TargetScript`" -CheckOnly") -ForegroundColor Green
Write-Host ("Log: " + (Join-Path $InstallDir "logs\watchdog.log")) -ForegroundColor Green
Write-Host ""
Write-Host "Catatan: task jalan saat user logon. Pastikan VM auto-login supaya watchdog hidup setelah reboot." -ForegroundColor Yellow
