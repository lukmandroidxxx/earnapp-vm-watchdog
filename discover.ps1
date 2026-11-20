# -*- coding: utf-8 -*-
<#
    discover.ps1 - Cari device EarnApp mana yang milik VM ini
    ---------------------------------------------------------
    Menampilkan semua device di akun cookie, status blokir, IP, dan
    kecocokan dengan nama komputer / IP publik VM ini.

    Contoh (PowerShell, tidak perlu Administrator):
      .\discover.ps1 -CookieFile "C:\path\cookie.json"
      .\discover.ps1 -DeviceTitle "sdk-win-20"
      .\discover.ps1 -DeviceTitle "sdk-win-20" -WriteConfig
      .\discover.ps1 -Json

    -WriteConfig  : simpan device_title + device_uuid yang cocok ke config.json
                    (supaya watchdog tidak perlu menebak lagi).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$CookieFile = "",
    [string]$DeviceTitle = "",
    [switch]$Json,
    [switch]$WriteConfig
)

$ErrorActionPreference = "Stop"

$BaseDir = $PSScriptRoot
if (-not $BaseDir) { $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Lib = Join-Path $BaseDir "earnapp-watchdog.ps1"
if (-not (Test-Path $Lib)) {
    Write-Host "GAGAL: earnapp-watchdog.ps1 tidak ada di $BaseDir" -ForegroundColor Red
    exit 1
}

# Muat fungsi saja (tanpa menjalankan loop watchdog).
. $Lib -LibraryOnly

if (-not $ConfigPath) { $ConfigPath = Join-Path $BaseDir "config.json" }
$cfg = Read-WatchdogConfig $ConfigPath
if ($CookieFile) { $cfg["cookie_file"] = $CookieFile }

$cookiePath = Resolve-ConfigPath ([string]$cfg["cookie_file"])
$cookie = Get-CookieHeader $cookiePath
if (-not $cookie) {
    Write-Host "GAGAL: cookie kosong / tidak ada di $cookiePath" -ForegroundColor Red
    Write-Host "Letakkan cookie akun EarnApp (JSON / cookies.txt / string) di file itu," -ForegroundColor Yellow
    Write-Host "atau jalankan: .\discover.ps1 -CookieFile C:\path\cookie.json" -ForegroundColor Yellow
    exit 1
}

$computer = $env:COMPUTERNAME
$publicIp = Get-PublicIp
$hint = $DeviceTitle
if (-not $hint) { $hint = [string]$cfg["device_title"] }

try {
    $devices = Get-EarnAppDevices $cfg $cookie
} catch {
    Write-Host ("GAGAL ambil device: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "Kalau pesannya 401/403, cookie sudah tidak berlaku (export ulang cookie)." -ForegroundColor Yellow
    exit 1
}

if (-not $devices -or @($devices).Count -eq 0) {
    Write-Host "Akun ini tidak punya device." -ForegroundColor Yellow
    exit 1
}

$rows = @()
foreach ($d in @($devices)) {
    $ban = Get-BanInfo $d
    $ips = @($d.ips)
    $match = @()
    if ([string]$d.title -eq $computer) { $match += "COMPUTERNAME" }
    if ($hint -and [string]$d.title -eq $hint) { $match += "judul-device" }
    if ($publicIp -and ($ips -contains $publicIp)) { $match += "IP-publik" }
    $rows += [pscustomobject]@{
        title  = [string]$d.title
        status = $(if ($ban) { "BLOCKED" } else { "hijau" })
        banned = $(if ($ban) { $ban } else { "" })
        ips    = ($ips -join ", ")
        match  = ($match -join ", ")
        uuid   = [string]$d.uuid
    }
}

# Pilih kandidat terbaik
$suggested = $null
if ($hint) {
    $suggested = @($rows | Where-Object { $_.title -eq $hint }) | Select-Object -First 1
}
if (-not $suggested) {
    $suggested = @($rows | Where-Object { $_.title -eq $computer }) | Select-Object -First 1
}
if (-not $suggested -and $publicIp) {
    $ipHits = @($rows | Where-Object { ($_.ips -split ", ") -contains $publicIp })
    if ($ipHits.Count -eq 1) { $suggested = $ipHits[0] }
}

if ($Json) {
    [pscustomobject]@{
        computer   = $computer
        public_ip  = $publicIp
        cookie     = $cookiePath
        total      = @($rows).Count
        suggested  = $(if ($suggested) { $suggested.title } else { "" })
        devices    = $rows
    } | ConvertTo-Json -Depth 6
} else {
    Write-Host ""
    Write-Host ("Komputer : " + $computer)
    Write-Host ("IP publik: " + $(if ($publicIp) { $publicIp } else { "(tidak terdeteksi)" }))
    Write-Host ("Cookie   : " + $cookiePath)
    Write-Host ("Device   : " + @($rows).Count)
    Write-Host ""
    $rows | Format-Table title, status, banned, match, uuid -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host "Daftar IP tiap device:"
    foreach ($r in $rows) { Write-Host ("  {0,-12} {1}" -f $r.title, $r.ips) }
    Write-Host ""
    if ($suggested) {
        Write-Host ("Kandidat untuk VM ini: " + $suggested.title + "  (" + $suggested.status + ")") -ForegroundColor Green
        Write-Host ("  device_title = " + $suggested.title)
        Write-Host ("  device_uuid  = " + $suggested.uuid)
    } else {
        Write-Host "Tidak ada kandidat otomatis. Lihat daftar di atas dan isi device_title manual." -ForegroundColor Yellow
        Write-Host "Contoh: .\discover.ps1 -DeviceTitle sdk-win-20" -ForegroundColor Yellow
    }
}

if ($WriteConfig) {
    if (-not $suggested) {
        Write-Host "Tidak menulis config: kandidat device belum pasti." -ForegroundColor Yellow
        exit 2
    }
    $cfg["device_title"] = $suggested.title
    $cfg["device_uuid"] = $suggested.uuid
    $cfg | ConvertTo-Json -Depth 5 | Out-File -FilePath $ConfigPath -Encoding UTF8 -Force
    Write-Host ("config.json diperbarui: " + $ConfigPath) -ForegroundColor Green
}
