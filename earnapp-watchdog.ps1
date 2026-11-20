# -*- coding: utf-8 -*-
<#
    EarnApp VM Watchdog
    -------------------
    Berjalan di Windows 10 32-bit / 64-bit (PowerShell 5.1 bawaan Windows).

    Tugas:
      1. Cek status device EarnApp lewat API akun (field "banned").
      2. Kalau HIJAU  -> pastikan EarnApp tetap jalan.
      3. Kalau BLOCKED -> matikan EarnApp (+ service earnapp bila ada),
         bersihkan cache lokalnya, tunggu "off_seconds" (default 300 detik),
         nyalakan lagi, tunggu "settle_seconds" (default 180 detik),
         lalu cek lagi. Diulang sampai hijau.
         Jeda sengaja dipanjangkan supaya server sempat mencatat IP baru.

    Mode uji:
      -CheckOnly   : cetak status device lalu keluar (tidak menyentuh EarnApp).
      -DryRun      : hanya mencatat apa yang seharusnya dilakukan.
      -Once        : satu siklus lalu keluar.
      -LibraryOnly : hanya memuat fungsi (dipakai discover.ps1).

    Config: config.json di folder yang sama (dibuat oleh install.ps1).
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$DryRun,
    [switch]$CheckOnly,
    [switch]$LibraryOnly,
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not $ConfigPath) {
    if ($PSScriptRoot) { $ConfigPath = Join-Path $PSScriptRoot "config.json" }
    else { $ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "config.json" }
}

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogDir = Join-Path $ScriptDir "logs"
$LogFile = Join-Path $LogDir "watchdog.log"

$script:blockedNotified = $false
$script:authNotified = $false
$script:restartCount = 0
$script:restartTimes = New-Object System.Collections.ArrayList
$script:justRestarted = $false
$global:EarnAppCookieValues = @{}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 2MB)) {
            Move-Item -Path $LogFile -Destination "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
function Get-DefaultConfig {
    return [ordered]@{
        cookie_file             = "cookie.json"
        device_uuid             = ""
        device_title            = ""
        earnapp_exe             = ""
        off_seconds             = 300
        settle_seconds          = 180
        check_interval_seconds  = 120
        max_restarts_per_hour   = 6
        clear_cache_on_restart  = $true
        manage_service          = $true
        service_match           = "earnapp"
        api_timeout_seconds     = 30
        telegram_token          = ""
        telegram_chat_id        = ""
    }
}

function Read-WatchdogConfig {
    param([string]$Path)
    $cfg = Get-DefaultConfig
    if (Test-Path $Path) {
        try {
            $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($raw.PSObject.Properties.Name -contains $k) { $cfg[$k] = $raw.$k }
            }
        } catch {
            Write-Log "Config tidak valid: $($_.Exception.Message)" "WARN"
        }
    } else {
        Write-Log "Config belum ada: $Path (pakai default)" "WARN"
    }
    return $cfg
}

function Resolve-ConfigPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $ScriptDir $Path)
}

# ---------------------------------------------------------------------------
# Cookie (mendukung JSON Cookie-Editor/Playwright, cookies.txt, atau string)
# ---------------------------------------------------------------------------
function Set-CookieStore {
    param($Pairs)
    $global:EarnAppCookieValues = @{}
    foreach ($pair in @($Pairs)) {
        if ($pair -match '^([^=]+)=(.*)$') {
            $global:EarnAppCookieValues[$Matches[1].Trim()] = $Matches[2]
        }
    }
}

function Get-XsrfToken {
    foreach ($name in @("xsrf-token", "XSRF-TOKEN", "X-XSRF-Token")) {
        if ($global:EarnAppCookieValues.ContainsKey($name)) {
            return [string]$global:EarnAppCookieValues[$name]
        }
    }
    return ""
}

function Get-CookieHeader {
    param([string]$Path)
    $global:EarnAppCookieValues = @{}
    if (-not $Path -or -not (Test-Path $Path)) { return "" }
    $text = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $trim = $text.Trim()

    if ($trim.StartsWith("{") -or $trim.StartsWith("[")) {
        try {
            $obj = $trim | ConvertFrom-Json
            $list = $null
            if ($obj -is [System.Array]) { $list = $obj }
            elseif ($obj.PSObject.Properties.Name -contains "cookies") { $list = $obj.cookies }
            if ($list) {
                $pairs = @()
                foreach ($c in $list) {
                    if ($null -ne $c.name -and $null -ne $c.value) {
                        $pairs += ("{0}={1}" -f $c.name, $c.value)
                    }
                }
                if ($pairs.Count -gt 0) { Set-CookieStore $pairs; return ($pairs -join "; ") }
            }
            if ($obj -is [pscustomobject]) {
                $skip = @("label", "updated_at", "cookies", "url", "path", "sameSite")
                $pairs = @()
                foreach ($p in $obj.PSObject.Properties) {
                    if ($skip -contains $p.Name) { continue }
                    if ($p.Value -is [string] -or $p.Value -is [int] -or $p.Value -is [long]) {
                        $pairs += ("{0}={1}" -f $p.Name, $p.Value)
                    }
                }
                if ($pairs.Count -gt 0) { Set-CookieStore $pairs; return ($pairs -join "; ") }
            }
        } catch { }
    }

    if ($trim -match "\t(auth|oauth-token)\t") {
        $pairs = @()
        foreach ($line in ($trim -split "`r?`n")) {
            if ($line.StartsWith("#")) { continue }
            $cols = $line -split "\t"
            if ($cols.Count -ge 7) { $pairs += ("{0}={1}" -f $cols[5], $cols[6]) }
        }
        if ($pairs.Count -gt 0) { Set-CookieStore $pairs; return ($pairs -join "; ") }
    }

    $flat = ($trim -replace "\r?\n", " ")
    $pairs = @()
    foreach ($part in ($flat -split ";")) {
        $part = $part.Trim()
        if ($part) { $pairs += $part }
    }
    Set-CookieStore $pairs
    return ($pairs -join "; ")
}

# ---------------------------------------------------------------------------
# HTTP lewat curl.exe (Windows 10 1803+)
#
# Catatan: Invoke-RestMethod / .NET di PowerShell 5.1 ditolak Cloudflare
# EarnApp dengan HTTP 403 (fingerprint TLS/HTTP). curl.exe bawaan Windows
# berhasil (HTTP 200) dengan cookie & header yang sama, jadi curl dipakai
# lebih dulu dan Invoke-RestMethod hanya sebagai cadangan.
# ---------------------------------------------------------------------------
function Get-CurlPath {
    $candidates = @(
        (Join-Path $env:SystemRoot "System32\curl.exe"),
        (Join-Path $env:SystemRoot "Sysnative\curl.exe")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    try {
        $cmd = Get-Command "curl.exe" -ErrorAction Stop
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    } catch { }
    return ""
}

function ConvertTo-CurlQuoted {
    param([string]$Text)
    return ([string]$Text).Replace('\', '\\').Replace('"', '\"')
}

function Invoke-CurlJson {
    param(
        [string]$Url,
        [System.Collections.IDictionary]$Headers,
        [int]$TimeoutSeconds
    )
    $curl = Get-CurlPath
    if (-not $curl) { throw "curl.exe tidak ditemukan" }
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = 30 }

    $tempBase = Join-Path $env:TEMP ("earnapp-watchdog-" + $PID + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    $cfgPath = $tempBase + ".cfg"
    $outPath = $tempBase + ".json"
    $errPath = $tempBase + ".err"
    try {
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('url = "' + (ConvertTo-CurlQuoted $Url) + '"')
        foreach ($k in $Headers.Keys) {
            [void]$lines.Add('header = "' + (ConvertTo-CurlQuoted ($k + ": " + [string]$Headers[$k])) + '"')
        }
        [void]$lines.Add("silent")
        [void]$lines.Add("show-error")
        [void]$lines.Add("connect-timeout = " + [Math]::Max(5, [Math]::Min(15, $TimeoutSeconds)))
        [void]$lines.Add("max-time = " + $TimeoutSeconds)
        Set-Content -Path $cfgPath -Value $lines -Encoding ASCII

        $outArg = $outPath.Replace('\', '/')
        $code = & $curl -K $cfgPath -o $outArg -w '%{http_code}' 2>$errPath
        $codeText = ([string]$code).Trim()
        $status = 0
        [void][int]::TryParse($codeText, [ref]$status)

        if (-not (Test-Path $outPath)) {
            $errText = ""
            if (Test-Path $errPath) { $errText = (Get-Content -Path $errPath -Raw -ErrorAction SilentlyContinue) }
            throw ("curl gagal (kode '{0}'): {1}" -f $codeText, ([string]$errText).Trim())
        }

        $body = Get-Content -Path $outPath -Raw -Encoding UTF8
        if ($status -lt 200 -or $status -ge 300) {
            $short = [string]$body
            if ($short.Length -gt 200) { $short = $short.Substring(0, 200) }
            throw ("HTTP {0}: {1}" -f $status, $short)
        }
        if ([string]::IsNullOrWhiteSpace($body)) { return $null }
        return ($body | ConvertFrom-Json)
    } finally {
        foreach ($f in @($cfgPath, $outPath, $errPath)) {
            try { if (Test-Path $f) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue } } catch { }
        }
    }
}

# ---------------------------------------------------------------------------
# EarnApp API
# ---------------------------------------------------------------------------
function Get-EarnAppDevices {
    param($Config, [string]$CookieHeader)
    if (-not $CookieHeader) { throw "cookie kosong / belum ada" }
    $url = "https://earnapp.com/dashboard/api/devices?appid=earnapp&version=1.689.920"
    $headers = [ordered]@{
        "Cookie"           = $CookieHeader
        "User-Agent"       = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
        "Accept"           = "application/json, text/plain, */*"
        "Accept-Language"  = "en-US,en;q=0.9,id;q=0.8"
        "Referer"          = "https://earnapp.com/dashboard/me/passive-income"
        "Origin"           = "https://earnapp.com"
        "X-Requested-With" = "XMLHttpRequest"
        "Cache-Control"    = "no-cache"
        "Pragma"           = "no-cache"
    }
    $xsrf = Get-XsrfToken
    if ($xsrf) {
        $headers["xsrf-token"] = $xsrf
        $headers["X-XSRF-Token"] = $xsrf
    }

    $timeout = [int]$Config["api_timeout_seconds"]
    if ($timeout -le 0) { $timeout = 30 }

    $curl = Get-CurlPath
    $resp = $null
    $lastError = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            if ($curl) {
                $resp = Invoke-CurlJson -Url $url -Headers $headers -TimeoutSeconds $timeout
            } else {
                $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec $timeout -UseBasicParsing
            }
            $lastError = $null
            break
        } catch {
            $lastError = $_
            $msg = $_.Exception.Message
            # Ulangi sekali hanya untuk gangguan koneksi, bukan 401/403.
            if ($attempt -lt 2 -and $msg -like "curl gagal*") {
                Start-Sleep -Seconds 2
                continue
            }
            break
        }
    }
    if ($lastError) { throw $lastError }

    if ($resp -is [System.Array]) { return @($resp) }
    if ($resp.PSObject.Properties.Name -contains "devices") { return @($resp.devices) }
    return @()
}

function Get-PublicIp {
    $curl = Get-CurlPath
    $urls = @("https://api.ipify.org", "https://ifconfig.me/ip", "https://ipinfo.io/ip")
    if ($curl) {
        foreach ($u in $urls) {
            try {
                $ip = (& $curl -s -m 8 $u 2>$null)
                $ip = ([string]$ip).Trim()
                if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
            } catch { }
        }
    }
    foreach ($u in $urls) {
        try {
            $ip = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 12).Content.Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        } catch { }
    }
    return ""
}

function Resolve-WatchDevice {
    param($Devices, $Config, [string]$PublicIp)

    if (-not $Devices -or $Devices.Count -eq 0) { return $null }

    $uuid = [string]$Config["device_uuid"]
    if ($uuid) {
        $hit = @($Devices | Where-Object { [string]$_.uuid -eq $uuid })
        if ($hit.Count -ge 1) { return $hit[0] }
        Write-Log "device_uuid '$uuid' tidak ada di akun ini" "WARN"
    }

    $title = [string]$Config["device_title"]
    if (-not $title) { $title = $env:COMPUTERNAME }
    if ($title) {
        $hit = @($Devices | Where-Object { [string]$_.title -eq $title })
        if ($hit.Count -eq 1) { return $hit[0] }
        $hit = @($Devices | Where-Object {
            [string]$_.title -like "*$title*" -or $title -like "*$([string]$_.title)*"
        })
        if ($hit.Count -eq 1) { return $hit[0] }
    }

    if ($PublicIp) {
        $hit = @($Devices | Where-Object { @($_.ips) -contains $PublicIp })
        if ($hit.Count -eq 1) { return $hit[0] }
        if ($hit.Count -gt 1) {
            Write-Log "IP $PublicIp dipakai $($hit.Count) device; isi device_title manual" "WARN"
        }
    }
    return $null
}

function Get-BanInfo {
    param($Device)
    if ($null -eq $Device) { return $null }
    $b = $Device.banned
    if ($null -eq $b) { return $null }
    if ($b -is [bool]) {
        if ($b) { return "banned" } else { return $null }
    }
    if ($b -is [string]) {
        if ($b.Trim() -and $b -ne "false") { return $b } else { return $null }
    }
    $parts = @()
    foreach ($k in @("reason", "ban_reason", "ip", "note", "description")) {
        $v = $b.$k
        if ($v) { $parts += [string]$v }
    }
    if ($parts.Count -eq 0) {
        try { return ($b | ConvertTo-Json -Compress) } catch { return "banned" }
    }
    return ($parts -join " / ")
}

# ---------------------------------------------------------------------------
# EarnApp app / service
# ---------------------------------------------------------------------------
function Find-EarnAppExe {
    param($Config)
    $exe = [string]$Config["earnapp_exe"]
    if ($exe -and (Test-Path $exe)) { return $exe }

    try {
        $props = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -match "earnapp") {
                $val = [string]$p.Value
                if ($val -match '^"([^"]+)"') { $val = $Matches[1] }
                elseif ($val -match '^(\S+\.exe)') { $val = $Matches[1] }
                if (Test-Path $val) { return $val }
            }
        }
    } catch { }

    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles "EarnApp\earnapp.exe") }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} "EarnApp\earnapp.exe") }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Programs\EarnApp\earnapp.exe") }
    $candidates += "C:\Program Files (x86)\EarnApp\earnapp.exe"
    $candidates += "C:\Program Files\EarnApp\earnapp.exe"
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        $dir = Join-Path $root "EarnApp"
        if (Test-Path $dir) {
            $f = Get-ChildItem -Path $dir -Filter "earnapp*.exe" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($f) { return $f.FullName }
        }
    }
    return ""
}

function Get-EarnAppProcesses {
    try { return @(Get-Process -Name "earnapp*" -ErrorAction SilentlyContinue) }
    catch { return @() }
}

function Get-EarnAppServices {
    param($Config)
    if (-not $Config["manage_service"]) { return @() }
    $match = [string]$Config["service_match"]
    if (-not $match) { $match = "earnapp" }
    try {
        return @(Get-Service | Where-Object {
            $_.Name -like "*$match*" -or $_.DisplayName -like "*$match*"
        })
    } catch { return @() }
}

function Stop-EarnApp {
    param($Config, $Services, $Processes)
    $stoppedServices = @()
    foreach ($s in $Services) {
        try {
            if ($s.Status -eq "Running") {
                Stop-Service -Name $s.Name -Force -ErrorAction Stop
                $stoppedServices += $s.Name
                Write-Log "Service dihentikan: $($s.Name)"
            }
        } catch {
            Write-Log "Gagal stop service $($s.Name): $($_.Exception.Message)" "WARN"
        }
    }
    foreach ($p in $Processes) {
        try {
            if (-not $p.HasExited) {
                $p.CloseMainWindow() | Out-Null
                Start-Sleep -Milliseconds 700
                if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
                Write-Log "Proses dihentikan: $($p.ProcessName) (PID $($p.Id))"
            }
        } catch {
            Write-Log "Gagal stop proses PID $($p.Id): $($_.Exception.Message)" "WARN"
        }
    }
    return 
}

function Clear-EarnAppCache {
    param($Config)
    $enabled = $true
    if ($Config -and $Config.Contains("clear_cache_on_restart")) {
        $enabled = [bool]$Config["clear_cache_on_restart"]
    }
    if (-not $enabled) { return }
    $roots = @(
        (Join-Path $env:APPDATA "EarnApp"),
        (Join-Path $env:LOCALAPPDATA "EarnApp"),
        (Join-Path $env:ProgramData "EarnApp")
    )
    $removed = 0
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $logDir = Join-Path $root "logs"
        if (Test-Path -LiteralPath $logDir) {
            foreach ($pat in @("*.log", "*.log.old", "*.dmp", "*.tmp")) {
                foreach ($f in @(Get-ChildItem -LiteralPath $logDir -Filter $pat -File -ErrorAction SilentlyContinue)) {
                    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++ } catch { }
                }
            }
        }
        foreach ($name in @("Cache", "Code Cache", "GPUCache", "Local Storage", "Session Storage", "IndexedDB", "temp", "tmp")) {
            $p = Join-Path $root $name
            if (Test-Path -LiteralPath $p) {
                try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop; $removed++ } catch { }
            }
        }
    }
    Write-Log "Cache EarnApp dibersihkan ($removed item)."
}
function Start-EarnApp {

    param($Config, [string]$Exe, $StoppedServices)
    foreach ($name in @($StoppedServices)) {
        try {
            Start-Service -Name $name -ErrorAction Stop
            Write-Log "Service dinyalakan: $name"
        } catch {
            Write-Log "Gagal start service $name : $($_.Exception.Message)" "WARN"
        }
    }
    if (-not $Exe) {
        Write-Log "Path earnapp.exe tidak ditemukan; tidak bisa menyalakan" "ERROR"
        return
    }
    if (@(Get-EarnAppProcesses).Count -gt 0) { return }
    try {
        Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) | Out-Null
        Write-Log "Menyalakan EarnApp: $Exe"
    } catch {
        Write-Log "Gagal menyalakan EarnApp: $($_.Exception.Message)" "ERROR"
    }
}

# ---------------------------------------------------------------------------
# Telegram (opsional)
# ---------------------------------------------------------------------------
function Send-Telegram {
    param($Config, [string]$Text)
    $token = [string]$Config["telegram_token"]
    $chat = [string]$Config["telegram_chat_id"]
    if (-not $token -or -not $chat) { return }
    try {
        $body = @{
            chat_id                  = $chat
            text                     = $Text
            disable_web_page_preview = $true
        } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $token) `
            -Method Post -ContentType "application/json" -Body $body -TimeoutSec 20 | Out-Null
    } catch {
        Write-Log "Telegram gagal: $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
function Get-WatchState {
    param($Config)
    $state = [ordered]@{
        AppRunning  = $false
        Exe         = ""
        DeviceTitle = ""
        DeviceUuid  = ""
        Blocked     = $null
        BanInfo     = ""
        PublicIp    = ""
        Error       = ""
        Candidates  = @()
    }

    $state.Exe = Find-EarnAppExe $Config
    $state.AppRunning = (@(Get-EarnAppProcesses).Count -gt 0)

    try {
        $cookiePath = Resolve-ConfigPath ([string]$Config["cookie_file"])
        $cookie = Get-CookieHeader $cookiePath
        if (-not $cookie) { throw "cookie belum diisi ($cookiePath)" }

        $devices = Get-EarnAppDevices $Config $cookie
        if (-not $devices -or $devices.Count -eq 0) { throw "akun tidak mengembalikan device" }

        $dev = Resolve-WatchDevice $devices $Config ""
        if (-not $dev) {
            $state.PublicIp = Get-PublicIp
            $dev = Resolve-WatchDevice $devices $Config $state.PublicIp
        }

        if ($dev) {
            $state.DeviceTitle = [string]$dev.title
            $state.DeviceUuid = [string]$dev.uuid
            $ban = Get-BanInfo $dev
            if ($ban) {
                $state.Blocked = $true
                $state.BanInfo = $ban
            } else {
                $state.Blocked = $false
            }
        } else {
            $state.Blocked = $null
            $state.Candidates = @($devices | ForEach-Object { [string]$_.title })
            $state.Error = "device tidak cocok dengan '$($env:COMPUTERNAME)' / IP $($state.PublicIp); isi device_title"
        }
    } catch {
        $state.Blocked = $null
        $state.Error = $_.Exception.Message
    }
    return $state
}

# ---------------------------------------------------------------------------
# Satu siklus
# ---------------------------------------------------------------------------
function Invoke-Cycle {
    param($Config)

    $state = Get-WatchState $Config
    $label = if ($state.DeviceTitle) { $state.DeviceTitle } else { $env:COMPUTERNAME }
    if ($state.Error) { Write-Log "Status belum pasti: $($state.Error)" "WARN" }

    # Cookie bermasalah (401/403) -> beri tahu sekali, jangan klaim cookie mati
    # hanya karena gangguan jaringan.
    if ($state.Error -match 'HTTP (401|403)') {
        if ((-not $DryRun) -and (-not $script:authNotified)) {
            Send-Telegram $Config ("[COOKIE] {0}: cookie EarnApp tidak bisa dipakai ({1}). Watchdog tetap jalan tetapi belum bisa cek status; perbarui cookie.json." -f $label, $state.Error)
            $script:authNotified = $true
        }
    } elseif ($null -ne $state.Blocked) {
        $script:authNotified = $false
    }

    if ($state.Blocked -eq $true) {
        Write-Log "BLOCKED: $label ($($state.BanInfo))" "WARN"

        if ((-not $DryRun) -and (-not $script:blockedNotified)) {
            Send-Telegram $Config ("[BLOCKED] {0}: device diblokir ({1}). EarnApp dimatikan {2} detik lalu dinyalakan ulang sampai hijau." -f $label, $state.BanInfo, $Config["off_seconds"])
            $script:blockedNotified = $true
        }

        if ($DryRun) {
            Write-Log "DryRun: seharusnya stop EarnApp, tunggu $($Config['off_seconds']) detik, start lagi."
            return
        }

        $max = [int]$Config["max_restarts_per_hour"]
        if ($max -gt 0) {
            $cutoff = (Get-Date).AddHours(-1)
            $recent = @($script:restartTimes | Where-Object { $_ -gt $cutoff })
            if ($recent.Count -ge $max) {
                Write-Log "Batas $max restart/jam tercapai; tunggu 10 menit." "WARN"
                Start-Sleep -Seconds 600
                return
            }
        }
        [void]$script:restartTimes.Add((Get-Date))

        $services = Get-EarnAppServices $Config
        $procs = Get-EarnAppProcesses
        $stopped = Stop-EarnApp $Config $services $procs
        Clear-EarnAppCache $Config

        $script:restartCount++
        $off = [int]$Config["off_seconds"]
        if ($off -lt 1) { $off = 300 }
        Write-Log "Menunggu $off detik sebelum menyalakan lagi..."
        Start-Sleep -Seconds $off

        Start-EarnApp $Config $state.Exe $stopped

        $settle = [int]$Config["settle_seconds"]
        if ($settle -lt 1) { $settle = 180 }
        Write-Log "Menunggu $settle detik supaya status terbarui..."
        Start-Sleep -Seconds $settle
        $script:justRestarted = $true
        return
    }

    if ($state.Blocked -eq $false) {
        Write-Log "HIJAU: $label (device $($state.DeviceTitle))"
        if ((-not $DryRun) -and $script:blockedNotified) {
            Send-Telegram $Config ("[HIJAU] {0}: sudah hijau lagi setelah {1} restart." -f $label, $script:restartCount)
            $script:blockedNotified = $false
            $script:restartCount = 0
        }
        if (-not $state.AppRunning) {
            Write-Log "EarnApp tidak jalan padahal hijau; menyalakan..." "WARN"
            if (-not $DryRun) { Start-EarnApp $Config $state.Exe @() }
        }
        return
    }

    if (-not $state.AppRunning) {
        Write-Log "EarnApp tidak jalan; menyalakan..." "WARN"
        if (-not $DryRun) { Start-EarnApp $Config $state.Exe @() }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($LibraryOnly) { return }

$config = Read-WatchdogConfig $ConfigPath
Write-Log "===== EarnApp Watchdog mulai ====="
Write-Log ("Config: {0} | off={1}s settle={2}s interval={3}s service={4}" -f `
    $ConfigPath, $config["off_seconds"], $config["settle_seconds"], `
    $config["check_interval_seconds"], $config["manage_service"])

$exe = Find-EarnAppExe $config
if ($exe) { Write-Log "EarnApp: $exe" }
else { Write-Log "earnapp.exe belum ditemukan (isi 'earnapp_exe' di config bila perlu)" "WARN" }

if ($CheckOnly) {
    $state = Get-WatchState $config
    $state | ConvertTo-Json -Depth 6
    exit 0
}

while ($true) {
    try {
        Invoke-Cycle -Config $config
    } catch {
        Write-Log "Cycle error: $($_.Exception.Message)" "ERROR"
    }

    if ($Once) { break }

    $sleep = [int]$config["check_interval_seconds"]
    if ($script:justRestarted) {
        $sleep = 5
        $script:justRestarted = $false
    }
    if ($sleep -lt 1) { $sleep = 60 }
    Start-Sleep -Seconds $sleep
}
