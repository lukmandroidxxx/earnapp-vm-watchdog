# -*- coding: utf-8 -*-
<#
    EarnApp VM Watchdog - MODE LOKAL (tanpa cookie / tanpa dashboard)
    -----------------------------------------------------------------
    Berjalan di Windows 10 32-bit / 64-bit, PowerShell 5.1 bawaan Windows.
    Tidak butuh Python, tidak butuh install apa pun, TIDAK butuh cookie akun.

    Cara kerja:
      1. Membaca teks jendela EarnApp lewat UI Automation bawaan .NET
         (tanpa klik, tanpa screenshot, tanpa mengubah jendela).
      2. Kalau teks menunjukkan "Earning blocked" / "Resource sharing blocked"
         (atau bahasa lain yang terdaftar), EarnApp dimatikan, tunggu
         "off_seconds" (default 300 detik), cache lokalnya dibersihkan,
         lalu dinyalakan lagi. Jeda "settle_seconds" default 180 detik
         supaya status sempat terbarui.
      3. Kalau EarnApp mati / hang, dinyalakan ulang.
      4. Kalau tidak ada tanda blocked, EarnApp dibiarkan jalan.

    Catatan penting:
      - Mode ini TIDAK tahu alasan ban (ip_quality / blacklist) dan tidak
        tahu IP publik. Itu hanya diketahui lewat API akun.
      - Karena itu script ini TIDAK PERNAH menyebut "cookie expired".
      - Pakai SALAH SATU: watchdog API (earnapp-watchdog.ps1) ATAU watchdog
        lokal ini. Jangan dua-duanya, nanti saling mematikan EarnApp.

    Mode uji:
      -CheckOnly   : cetak status lokal (JSON) lalu keluar, tidak menyentuh EarnApp.
      -DryRun      : hanya mencatat tindakan yang seharusnya dilakukan.
      -Once        : satu siklus lalu keluar.
      -LibraryOnly : hanya memuat fungsi.

    Config: config.json di folder yang sama (dibuat oleh install-local.ps1).
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

if (-not $ConfigPath) {
    if ($PSScriptRoot) { $ConfigPath = Join-Path $PSScriptRoot "config.json" }
    else { $ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "config.json" }
}

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogDir = Join-Path $ScriptDir "logs"
$LogFile = Join-Path $LogDir "watchdog-local.log"

$script:blockedNotified = $false
$script:restartCount = 0
$script:restartTimes = New-Object System.Collections.ArrayList
$script:justRestarted = $false
$script:apiWatchdogWarned = $false

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
function Get-DefaultBlockedTexts {
    return @(
        "earning blocked",
        "income blocked",
        "resource sharing blocked",
        # Dashboard baru (1.689.920): halaman /ip_block + label alasan ban.
        "your ip is blocked",
        "ip is blocked",
        "ip blocked",
        "device blocked",
        "low quality ip",
        "wrong ip type",
        "country not supported",
        "change your ip address",
        "use residential ip address",
        "remove other bandwidth sharing apps",
        "remove vpn",
        "do not use proxy",
        "penghasilan diblokir",
        "berbagi sumber daya diblokir",
        "perolehan disekat",
        "perkongsian sumber disekat",
        "verdienst blockiert",
        "ingresos bloqueados",
        "gains bloques",
        "guadagno bloccato",
        "ganhos bloqueados",
        "gelir kazanma engellendi",
        "acumularea castigurilor blocata"
    )
}

function Get-DefaultPausedTexts {
    return @(
        "earning paused",
        "resource sharing paused",
        "sharing resources paused",
        "earning off",
        "penghasilan dijeda",
        "berbagi sumber daya dijeda"
    )
}

function Get-DefaultConfig {
    return [ordered]@{
        earnapp_exe              = ""
        process_names            = @("earnapp")
        off_seconds              = 300
        settle_seconds           = 180
        check_interval_seconds   = 120
        max_restarts_per_hour    = 6
        clear_cache_on_restart   = $true
        manage_service           = $true
        service_match            = "earnapp"
        stale_log_seconds        = 1800
        restart_when_paused      = $false
        restart_when_unknown     = $false
        restart_when_hang        = $true
        window_probe_seconds     = 12
        blocked_texts            = @()
        paused_texts             = @()
        telegram_token           = ""
        telegram_chat_id         = ""
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
# Teks: normalisasi + pencocokan penanda
# ---------------------------------------------------------------------------
function ConvertTo-MatchText {
    param([string]$Text)
    if (-not $Text) { return "" }
    $t = $Text.ToLowerInvariant()
    try {
        $norm = $t.Normalize([Text.NormalizationForm]::FormD)
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in $norm.ToCharArray()) {
            if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
                [void]$sb.Append($ch)
            }
        }
        $t = $sb.ToString()
    } catch { }
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

function Test-NegativeText {
    param([string]$Text)
    if (-not $Text) { return $false }
    return [bool]($Text -match 'not blocked|unblocked|tidak diblokir|tidak terblokir|no blocked')
}

function Find-TextHits {
    param([string[]]$Texts, [string[]]$Markers)
    $hits = New-Object System.Collections.ArrayList
    $clean = @()
    foreach ($m in @($Markers)) {
        $mm = ConvertTo-MatchText ([string]$m)
        if ($mm) { $clean += $mm }
    }
    if ($clean.Count -eq 0) { return @() }

    foreach ($raw in @($Texts)) {
        if (-not $raw) { continue }
        $t = ConvertTo-MatchText ([string]$raw)
        if (-not $t) { continue }
        if ($t.Length -gt 120) { continue }
        if (Test-NegativeText $t) { continue }
        foreach ($mm in $clean) {
            if ($t -eq $mm -or $t.Contains($mm)) {
                if (-not $hits.Contains([string]$raw)) { [void]$hits.Add([string]$raw) }
                break
            }
        }
    }
    return @($hits)
}

# ---------------------------------------------------------------------------
# Win32 helper (cari jendela EarnApp; baca saja, tidak mengubah apa pun)
# ---------------------------------------------------------------------------
if (-not ("EarnAppLocalWin32" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class EarnAppLocalWin32 {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int cmd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder sb, int max);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);

    public static List<IntPtr> GetWindows() {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }

    public static uint GetProcessId(IntPtr hWnd) {
        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        return pid;
    }

    public static string GetTitle(IntPtr hWnd) {
        StringBuilder sb = new StringBuilder(512);
        GetWindowTextW(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string GetClass(IntPtr hWnd) {
        StringBuilder sb = new StringBuilder(256);
        GetClassNameW(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }
}
"@
}

$script:UiaReady = $false
try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $script:UiaReady = [bool]("System.Windows.Automation.AutomationElement" -as [type])
} catch {
    $script:UiaReady = $false
}

# ---------------------------------------------------------------------------
# EarnApp: proses, exe, service
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
    param($Config)
    $names = @()
    foreach ($n in @($Config["process_names"])) {
        $n = ([string]$n).Trim()
        if ($n) { $names += $n }
    }
    if ($names.Count -eq 0) { $names = @("earnapp") }
    $procs = @()
    foreach ($n in $names) {
        try {
            $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue)
        } catch { }
    }
    return @($procs)
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

# ---------------------------------------------------------------------------
# Sinyal lokal: earnapp.settings + umur log
# ---------------------------------------------------------------------------
function Get-EarnAppSettings {
    # Catatan: key sengaja diberi nama "Data", bukan "Values", karena
    # OrderedDictionary sudah punya properti .Values.
    $result = [ordered]@{ Found = $false; Path = ""; Data = @{} }
    $candidates = @()
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA "EarnApp\earnapp.settings") }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "EarnApp\earnapp.settings") }
    foreach ($p in $candidates) {
        if (-not (Test-Path $p)) { continue }
        $result.Found = $true
        $result.Path = $p
        try {
            foreach ($line in (Get-Content -Path $p -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*([^=]+)=(.*)$') {
                    $result.Data[$Matches[1].Trim()] = $Matches[2].Trim()
                }
            }
        } catch { }
        break
    }
    return $result
}

function Get-EarnAppLogInfo {
    $result = [ordered]@{ Found = $false; Path = ""; AgeSeconds = $null; LastWrite = $null }
    $dirs = @()
    if ($env:APPDATA) { $dirs += (Join-Path $env:APPDATA "EarnApp\logs") }
    if ($env:LOCALAPPDATA) { $dirs += (Join-Path $env:LOCALAPPDATA "EarnApp\logs") }
    $newest = $null
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        try {
            foreach ($f in @(Get-ChildItem -Path $d -Filter "*.log" -File -ErrorAction SilentlyContinue)) {
                if (-not $newest -or $f.LastWriteTime -gt $newest.LastWriteTime) { $newest = $f }
            }
        } catch { }
    }
    if ($newest) {
        $result.Found = $true
        $result.Path = $newest.FullName
        $result.LastWrite = $newest.LastWriteTime
        $result.AgeSeconds = [int]((Get-Date) - $newest.LastWriteTime).TotalSeconds
    }
    return $result
}

# ---------------------------------------------------------------------------
# UI Automation: baca teks jendela EarnApp (read-only)
# ---------------------------------------------------------------------------
function Get-EarnAppWindows {
    param([int[]]$ProcessIds)
    $list = New-Object System.Collections.ArrayList
    if (-not $ProcessIds -or $ProcessIds.Count -eq 0) { return @() }
    try {
        foreach ($h in [EarnAppLocalWin32]::GetWindows()) {
            $pid2 = [int][EarnAppLocalWin32]::GetProcessId($h)
            if ($ProcessIds -notcontains $pid2) { continue }
            $title = [string][EarnAppLocalWin32]::GetTitle($h)
            $class = [string][EarnAppLocalWin32]::GetClass($h)
            # Jendela tanpa judul & tanpa class WPF biasanya jendela bantu; tetap disimpan
            # sebagai kandidat terakhir.
            [void]$list.Add([pscustomobject]@{
                Handle  = $h
                Pid     = $pid2
                Title   = $title
                Class   = $class
                Visible = [bool][EarnAppLocalWin32]::IsWindowVisible($h)
                Iconic  = [bool][EarnAppLocalWin32]::IsIconic($h)
            })
        }
    } catch { }
    return @($list)
}

function Get-EarnAppUiTexts {
    param([IntPtr]$Handle)
    $result = [ordered]@{ Ok = $false; Texts = @(); Ids = @(); Title = ""; Error = "" }
    if (-not $script:UiaReady) {
        $result.Error = "UI Automation tidak tersedia"
        return $result
    }
    try {
        $el = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
        if (-not $el) {
            $result.Error = "FromHandle mengembalikan null"
            return $result
        }
        try { $result.Title = [string]$el.Current.Name } catch { }

        $all = $el.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )
        $texts = New-Object System.Collections.ArrayList
        $ids = New-Object System.Collections.ArrayList
        foreach ($e in $all) {
            try {
                $name = [string]$e.Current.Name
                if (-not $name) { continue }
                $name = $name.Trim()
                if (-not $name) { continue }
                if (-not $texts.Contains($name)) { [void]$texts.Add($name) }
                $id = [string]$e.Current.AutomationId
                if ($id) { [void]$ids.Add($id) }
            } catch { }
        }
        $result.Texts = @($texts)
        $result.Ids = @($ids)
        $result.Ok = $true
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Get-MergedUiTexts {
    param($Windows)
    $merged = [ordered]@{
        Ok        = $false
        Texts     = @()
        Ids       = @()
        BestTitle = ""
        BestClass = ""
    }
    $texts = New-Object System.Collections.ArrayList
    $ids = New-Object System.Collections.ArrayList
    $bestCount = -1
    foreach ($w in @($Windows)) {
        $ui = Get-EarnAppUiTexts -Handle $w.Handle
        if (-not $ui.Ok) { continue }
        $merged.Ok = $true
        $count = @($ui.Texts).Count
        if ($count -gt $bestCount) {
            $bestCount = $count
            $merged.BestTitle = $w.Title
            $merged.BestClass = $w.Class
        }
        foreach ($t in @($ui.Texts)) {
            if (-not $texts.Contains($t)) { [void]$texts.Add($t) }
        }
        foreach ($id in @($ui.Ids)) {
            if (-not $ids.Contains($id)) { [void]$ids.Add($id) }
        }
    }
    $merged.Texts = @($texts)
    $merged.Ids = @($ids)
    return $merged
}

function Read-EarnAppUi {
    param($Config)
    $state = [ordered]@{
        ProcessIds      = @()
        WindowFound     = $false
        WindowTitle     = ""
        WindowClass     = ""
        Texts           = @()
        Ids             = @()
        ShownTemporarily = $false
        Error           = ""
    }

    if (-not $script:UiaReady) {
        $state.Error = "UI Automation tidak tersedia di PowerShell ini"
        return $state
    }

    $procs = @(Get-EarnAppProcesses $Config)
    $pids = @($procs | ForEach-Object { [int]$_.Id })
    $state.ProcessIds = $pids
    if ($pids.Count -eq 0) {
        $state.Error = "earnapp.exe tidak jalan"
        return $state
    }

    $wins = @(Get-EarnAppWindows -ProcessIds $pids)
    if ($wins.Count -eq 0) {
        $state.Error = "jendela EarnApp tidak ditemukan"
        return $state
    }

    # Baca semua jendela milik earnapp lalu gabungkan teksnya. Ini mencegah
    # dialog kecil / jendela bantu menutupi status di jendela utama.
    $wins = @($wins | Sort-Object -Property `
        @{ Expression = { if ($_.Visible -and -not $_.Iconic) { 0 } elseif ($_.Iconic) { 1 } else { 2 } } }, `
        @{ Expression = { if ($_.Class -like "*HwndWrapper*") { 0 } else { 1 } } })

    $merged = Get-MergedUiTexts -Windows $wins
    if (@($merged.Texts).Count -gt 0) {
        $state.WindowFound = $true
        $state.WindowTitle = $merged.BestTitle
        $state.WindowClass = $merged.BestClass
        $state.Texts = @($merged.Texts)
        $state.Ids = @($merged.Ids)
        return $state
    }

    # Cadangan: jendela mungkin belum pernah dirender (mis. start /S).
    # Tampilkan kandidat utama sebentar tanpa mengambil fokus, baca, lalu
    # kembalikan seperti semula.
    $probe = [int]$Config["window_probe_seconds"]
    if ($probe -lt 3) { $probe = 12 }

    $primary = $wins[0]
    $wasVisible = $primary.Visible
    $wasIconic = $primary.Iconic
    try {
        if ($wasIconic) { [void][EarnAppLocalWin32]::ShowWindow($primary.Handle, 9) }   # SW_RESTORE
        else { [void][EarnAppLocalWin32]::ShowWindow($primary.Handle, 8) }             # SW_SHOWNA
        $state.ShownTemporarily = $true
    } catch { }

    $deadline = (Get-Date).AddSeconds($probe)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $merged = Get-MergedUiTexts -Windows $wins
        if (@($merged.Texts).Count -gt 0) { break }
    }

    try {
        if ($wasIconic) { [void][EarnAppLocalWin32]::ShowWindow($primary.Handle, 6) }        # SW_MINIMIZE
        elseif (-not $wasVisible) { [void][EarnAppLocalWin32]::ShowWindow($primary.Handle, 0) } # SW_HIDE
    } catch { }

    if (@($merged.Texts).Count -gt 0) {
        $state.WindowFound = $true
        $state.WindowTitle = $merged.BestTitle
        $state.WindowClass = $merged.BestClass
        $state.Texts = @($merged.Texts)
        $state.Ids = @($merged.Ids)
        return $state
    }

    $state.Error = "teks jendela tidak terbaca (UI Automation)"
    return $state
}

# ---------------------------------------------------------------------------
# Telegram (opsional) - tidak pernah menyebut cookie
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
# Status lokal
# ---------------------------------------------------------------------------
function Get-LocalState {
    param($Config)

    $blockedMarkers = @($Config["blocked_texts"])
    if ($blockedMarkers.Count -eq 0) { $blockedMarkers = Get-DefaultBlockedTexts }
    $pausedMarkers = @($Config["paused_texts"])
    if ($pausedMarkers.Count -eq 0) { $pausedMarkers = Get-DefaultPausedTexts }

    $state = [ordered]@{
        Time             = (Get-Date).ToString("s")
        Computer         = $env:COMPUTERNAME
        AppRunning       = $false
        Exe              = ""
        ProcessIds       = @()
        WindowFound      = $false
        WindowTitle      = ""
        Texts            = @()
        AutomationIds    = @()
        Blocked          = $null
        BlockedEvidence  = @()
        PausedSetting    = $null
        PausedText       = @()
        LogPath          = ""
        LogAgeSeconds    = $null
        AppHang          = $false
        State            = "unknown"
        Error            = ""
    }

    $state.Exe = Find-EarnAppExe $Config
    $procs = @(Get-EarnAppProcesses $Config)
    $state.AppRunning = ($procs.Count -gt 0)
    $state.ProcessIds = @($procs | ForEach-Object { [int]$_.Id })

    $settings = Get-EarnAppSettings
    if ($settings.Found -and $settings.Data.ContainsKey("paused")) {
        $p = ([string]$settings.Data["paused"]).ToLowerInvariant()
        if ($p -eq "true" -or $p -eq "1") { $state.PausedSetting = $true }
        elseif ($p -eq "false" -or $p -eq "0") { $state.PausedSetting = $false }
    }

    $logInfo = Get-EarnAppLogInfo
    if ($logInfo.Found) {
        $state.LogPath = $logInfo.Path
        $state.LogAgeSeconds = $logInfo.AgeSeconds
    }

    if (-not $state.AppRunning) {
        $state.State = "down"
        return $state
    }

    $ui = Read-EarnAppUi $Config
    $state.WindowFound = $ui.WindowFound
    $state.WindowTitle = $ui.WindowTitle
    $state.Texts = @($ui.Texts)
    $state.AutomationIds = @($ui.Ids)
    if ($ui.Error) { $state.Error = $ui.Error }

    $blockedHits = @(Find-TextHits -Texts $state.Texts -Markers $blockedMarkers)
    $pausedHits = @(Find-TextHits -Texts $state.Texts -Markers $pausedMarkers)

    # AutomationId kadang menyimpan status walau teksnya kosong.
    $idBlocked = $false
    for ($i = 0; $i -lt $state.AutomationIds.Count; $i++) {
        $id = [string]$state.AutomationIds[$i]
        if ($id -match 'blocked_reason|ValueBlocked|^blocked$') { $idBlocked = $true; break }
    }

    $state.BlockedEvidence = @($blockedHits)
    $state.PausedText = @($pausedHits)

    if ($blockedHits.Count -gt 0 -or $idBlocked) {
        $state.Blocked = $true
        $state.State = "blocked"
        return $state
    }

    $state.Blocked = $false

    if ($pausedHits.Count -gt 0 -or $state.PausedSetting -eq $true) {
        $state.State = "paused"
        return $state
    }

    $stale = [int]$Config["stale_log_seconds"]
    if ($stale -gt 0 -and $null -ne $state.LogAgeSeconds -and $state.LogAgeSeconds -gt $stale -and $state.Texts.Count -eq 0) {
        $state.AppHang = $true
        $state.State = "hang"
        return $state
    }

    if ($state.Texts.Count -gt 0) {
        $state.State = "ok"
    } else {
        $state.State = "unknown"
    }
    return $state
}

# ---------------------------------------------------------------------------
# Aksi: stop / start EarnApp
# ---------------------------------------------------------------------------
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
    if (@(Get-EarnAppProcesses $Config).Count -gt 0) { return }
    try {
        Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) | Out-Null
        Write-Log "Menyalakan EarnApp: $Exe"
    } catch {
        Write-Log "Gagal menyalakan EarnApp: $($_.Exception.Message)" "ERROR"
    }
}

function Restart-EarnApp {
    param($Config, [string]$Exe)
    $services = @(Get-EarnAppServices $Config)
    $procs = @(Get-EarnAppProcesses $Config)
    $stopped = @(Stop-EarnApp $Config $services $procs)
    Clear-EarnAppCache $Config

    $script:restartCount++
    $off = [int]$Config["off_seconds"]
    if ($off -lt 1) { $off = 300 }
    Write-Log "Menunggu $off detik sebelum menyalakan lagi..."
    Start-Sleep -Seconds $off

    Start-EarnApp $Config $Exe $stopped

    $settle = [int]$Config["settle_seconds"]
    if ($settle -lt 1) { $settle = 180 }
    Write-Log "Menunggu $settle detik supaya status terbarui..."
    Start-Sleep -Seconds $settle
    $script:justRestarted = $true
}

# ---------------------------------------------------------------------------
# Peringatan kalau watchdog API juga aktif
# ---------------------------------------------------------------------------
function Test-ApiWatchdogRunning {
    try {
        $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -like "*earnapp-watchdog.ps1*" -and
                $_.CommandLine -notlike "*earnapp-watchdog-local.ps1*"
            })
        return ($running.Count -gt 0)
    } catch { return $false }
}

# ---------------------------------------------------------------------------
# Satu siklus
# ---------------------------------------------------------------------------
function Invoke-Cycle {
    param($Config)

    if ((-not $script:apiWatchdogWarned) -and (Test-ApiWatchdogRunning)) {
        Write-Log "PERINGATAN: watchdog API (earnapp-watchdog.ps1) juga jalan. Hentikan salah satu supaya tidak saling restart." "WARN"
        $script:apiWatchdogWarned = $true
    }

    $state = Get-LocalState $Config
    $label = $env:COMPUTERNAME
    if ($state.Error) { Write-Log "Catatan: $($state.Error)" "WARN" }

    switch ($state.State) {
        "blocked" {
            $evidence = (@($state.BlockedEvidence) -join " / ")
            if (-not $evidence) { $evidence = "penanda blocked di jendela EarnApp" }
            Write-Log "BLOCKED (lokal): $label -> '$evidence'" "WARN"

            if ((-not $DryRun) -and (-not $script:blockedNotified)) {
                Send-Telegram $Config ("[BLOCKED-LOKAL] {0}: jendela EarnApp menunjukkan `"{1}`". EarnApp dimatikan {2} detik lalu dinyalakan ulang sampai tanda blocked hilang. (mode lokal, tanpa cookie)" -f $label, $evidence, $Config["off_seconds"])
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
            Restart-EarnApp $Config $state.Exe
            return
        }

        "hang" {
            Write-Log "HANG (lokal): $label -> log terakhir $($state.LogAgeSeconds) detik lalu, jendela tidak terbaca" "WARN"
            if ($DryRun) {
                Write-Log "DryRun: seharusnya restart EarnApp karena hang."
                return
            }
            if (-not $Config["restart_when_hang"]) {
                Write-Log "restart_when_hang=false; hanya dicatat." "WARN"
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
            Restart-EarnApp $Config $state.Exe
            return
        }

        "down" {
            if ($DryRun) {
                Write-Log "DryRun: EarnApp tidak jalan; seharusnya dinyalakan."
                return
            }
            Write-Log "EarnApp tidak jalan; menyalakan..." "WARN"
            Start-EarnApp $Config $state.Exe @()
            return
        }

        "paused" {
            Write-Log "PAUSED (lokal): $label -> EarnApp dalam posisi paused (settings/text)" "WARN"
            if ($Config["restart_when_paused"]) {
                if ($DryRun) {
                    Write-Log "DryRun: seharusnya restart karena paused."
                    return
                }
                Restart-EarnApp $Config $state.Exe
            } else {
                Write-Log "restart_when_paused=false; dibiarkan (mungkin memang disengaja)."
            }
            return
        }

        "unknown" {
            Write-Log "Status lokal belum pasti (jendela tidak terbaca)." "WARN"
            if ($Config["restart_when_unknown"]) {
                if ($DryRun) {
                    Write-Log "DryRun: seharusnya restart karena status tidak pasti."
                    return
                }
                Restart-EarnApp $Config $state.Exe
            }
            return
        }

        default {
            # "ok"
            if ($script:blockedNotified) {
                Write-Log "HIJAU (lokal): $label -> tanda blocked tidak terlihat lagi setelah $($script:restartCount) restart."
                if (-not $DryRun) {
                    Send-Telegram $Config ("[HIJAU-LOKAL] {0}: tanda blocked tidak terlihat lagi setelah {1} restart. (mode lokal)" -f $label, $script:restartCount)
                }
                $script:blockedNotified = $false
                $script:restartCount = 0
            } else {
                Write-Log "OK (lokal): $label -> EarnApp jalan, tidak ada tanda blocked."
            }
            return
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($LibraryOnly) { return }

$config = Read-WatchdogConfig $ConfigPath
Write-Log "===== EarnApp Watchdog LOKAL mulai (tanpa cookie) ====="
Write-Log ("Config: {0} | off={1}s settle={2}s interval={3}s service={4}" -f `
    $ConfigPath, $config["off_seconds"], $config["settle_seconds"], `
    $config["check_interval_seconds"], $config["manage_service"])
if (-not $script:UiaReady) {
    Write-Log "UI Automation tidak tersedia; deteksi blocked tidak bisa dipakai (hanya cek proses)." "ERROR"
}

$exe = Find-EarnAppExe $config
if ($exe) { Write-Log "EarnApp: $exe" }
else { Write-Log "earnapp.exe belum ditemukan (isi 'earnapp_exe' di config bila perlu)" "WARN" }

if ($CheckOnly) {
    $state = Get-LocalState $config
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
