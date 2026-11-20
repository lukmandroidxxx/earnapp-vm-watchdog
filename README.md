# EarnApp VM Watchdog (Windows 10 32-bit)

Bot lokal kecil untuk VM Windows 10 32-bit yang menjalankan **EarnApp**.
Tugasnya satu:

> Kalau device EarnApp **diblokir (blocked)**, matikan software/service EarnApp
> selama **1 menit**, nyalakan lagi, lalu cek lagi. Diulang sampai status
> **hijau**. Kalau sudah hijau, EarnApp dibiarkan tetap jalan.

Tidak butuh Python, tidak butuh install apa pun. Cukup **PowerShell 5.1**
yang sudah ada di Windows 10 (32-bit maupun 64-bit).

---

## Download cepat (link s.id)

Tombol darurat sudah di-upload supaya gampang diambil dari VM:

| Link | Isi |
|---|---|
| **https://s.id/3IDGf** | **PAKET LENGKAP .zip** — installer + watchdog + uninstaller + contoh config |
| **https://s.id/yELnc** | `stop-emergency.ps1` saja (versi universal: API + lokal) |
| https://s.id/9HCFq | mirror emergency script (cadangan) |
| https://github.com/lukmandroidxxx/earnapp-vm-watchdog/archive/refs/heads/main.zip | URL langsung ZIP paket lengkap |
| https://github.com/lukmandroidxxx/earnapp-vm-watchdog | repo public berisi semua file |
| https://gist.github.com/lukmandroidxxx/19f8e7817677fd672d9049bdf0525d25 | Gist emergency script + **Download ZIP** |

Kedua file emergency sekarang **identik** dan otomatis mendeteksi mode:
kalau task/folder `EarnAppWatchdogLocal` ada -> mode **lokal**, kalau
`EarnAppWatchdog` ada -> mode **API**. Bisa dipaksa dengan `-Local` / `-Api`.

Download langsung di VM (PowerShell):

```powershell
iwr https://s.id/yELnc -MaximumRedirection 5 -OutFile C:\stop-emergency.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\stop-emergency.ps1 -Status
```

Atau lewat browser: buka `https://s.id/yELnc`, **Save as**
`stop-emergency.ps1`, lalu jalankan PowerShell sebagai Administrator.

Pasang watchdog dari paket lengkap (PowerShell, PowerShell sebagai Administrator):

```powershell
iwr https://s.id/3IDGf -MaximumRedirection 5 -OutFile "$env:TEMP\vm-watchdog.zip"
Expand-Archive "$env:TEMP\vm-watchdog.zip" "$env:TEMP\vm-watchdog" -Force
cd "$env:TEMP\vm-watchdog\earnapp-vm-watchdog-main"
.\install.ps1                       # mode API (butuh cookie.json)
# atau: .\install-local.ps1         # mode lokal (tanpa cookie)
```

`cookie.json` sengaja **tidak ikut** di paket. Isi sendiri di VM untuk mode API;
mode lokal tidak memerlukannya.

---

## Isi folder

| File | Fungsi |
|---|---|
| `earnapp-watchdog.ps1` | Program utama (loop cek status + stop/start EarnApp). |
| `install.ps1` | Installer: salin file, buat `config.json`, daftarkan Scheduled Task. |
| `uninstall.ps1` | Hapus Scheduled Task + folder install (EarnApp tidak di-uninstall). |
| `stop-emergency.ps1` | **Tombol darurat (API + lokal, satu file)**: auto-detect mode, hentikan task + proses watchdog, lalu service/proses EarnApp. Bisa di-`Resume`. |
| `stop-emergency-local.ps1` | Mirror identik dari `stop-emergency.ps1` (dipakai installer lokal). Bisa dipakai untuk kedua mode. |
| `discover.ps1` | Cari device mana di akun yang milik VM ini, lalu isi `config.json`. |
| `config.example.json` | Contoh isi config. |
| `cookie.json` | **Diisi sendiri**: cookie akun EarnApp pemilik VM ini. |
| `logs/watchdog.log` | Log harian. |

---

## Cara kerja singkat

1. Setiap `check_interval_seconds` (default 120 detik) watchdog memanggil API:
   `GET https://earnapp.com/dashboard/api/devices?appid=earnapp&version=1.689.920`
   memakai cookie di `cookie.json`.
2. Device dicari dengan urutan: `device_uuid` -> `device_title` /
   `COMPUTERNAME` -> IP publik yang unik.
3. Kalau field `banned` **tidak null** -> dianggap **BLOCKED**:
   - service yang namanya mengandung `earnapp` dihentikan,
   - proses `earnapp*.exe` dihentikan,
   - **bersihkan cache lokal EarnApp**, tunggu `off_seconds` (300 detik),
   - service + `earnapp.exe` dinyalakan lagi,
   - tunggu `settle_seconds` (180 detik), lalu cek lagi.
4. Kalau `banned` **null** -> **HIJAU**: EarnApp dipastikan jalan, tidak diganggu.
5. Kalau status tidak bisa dipastikan (cookie mati / jaringan putus), watchdog
   **tidak** mematikan EarnApp; hanya mencatat peringatan di log.

Batas pengaman: maksimal `max_restarts_per_hour` restart per jam (default 6).
Kalau batas tercapai, watchdog menunggu 10 menit sebelum mencoba lagi.

### Cache EarnApp & jeda restart

Setiap kali device BLOCKED, watchdog sekarang:

1. menghentikan service + proses EarnApp,
2. menghapus **log, dump, dan folder cache** EarnApp
   (`%APPDATA%\EarnApp\logs`, `Cache`, `Code Cache`, `GPUCache`,
   `Local Storage`, `Session Storage`, `IndexedDB`, `temp`),
3. menunggu 300 detik, menyalakan lagi, lalu menunggu 180 detik sebelum cek.

Jeda sengaja dipanjangkan supaya status/IP baru sempat dicatat server
(terutama kalau IP sudah diganti lewat aplikasi proxy).

**Yang TIDAK dihapus:** `earnapp.settings`, `email`, `user_id`, dan file
identitas/UUID device. Jadi login dan device tidak hilang. Setelah restart,
EarnApp akan menulis ulang `earnapp.settings` otomatis.

Untuk VM yang sudah terpasang versi lama, update config-nya:

```powershell
$j = Get-Content C:\EarnAppWatchdog\config.json -Raw | ConvertFrom-Json
$j.off_seconds = 300; $j.settle_seconds = 180
$j.check_interval_seconds = 120; $j.max_restarts_per_hour = 6
$j.clear_cache_on_restart = $true
$j | ConvertTo-Json | Set-Content C:\EarnAppWatchdog\config.json -Encoding UTF8
Stop-ScheduledTask -TaskName EarnAppWatchdog
Start-ScheduledTask -TaskName EarnAppWatchdog
```

---

## Persiapan di tiap VM

1. Pastikan **EarnApp sudah ter-install dan pernah login/terhubung** di VM itu.
2. Siapkan **cookie akun EarnApp yang memiliki device VM tersebut**.
   - Bisa dari dashboard EarnApp (DevTools -> Network -> copy header `Cookie`), atau
   - file JSON hasil ekspor Cookie-Editor / Playwright, atau
   - file `cookies.txt` format Netscape.
   - Cookie akun lain = device tidak akan ketemu.
3. Salin seluruh folder ini ke VM (mis. `C:\EarnAppWatchdog`).
4. Simpan cookie sebagai `cookie.json` di folder itu.

> EarnApp Windows menyimpan ID device sendiri (prefix `sdk-win-...`).
> Jangan menyalin folder EarnApp antar-VM; cukup pasang EarnApp normal di VM.

---

## Instalasi

Buka **PowerShell sebagai Administrator** di folder ini, lalu:

```powershell
# 1) Cari device yang cocok dengan VM ini (opsional tapi disarankan)
.\discover.ps1

# Kalau sudah tahu judul device-nya:
.\discover.ps1 -DeviceTitle "sdk-win-20" -WriteConfig

# 2) Install watchdog (jalan otomatis saat user logon)
.\install.ps1 -DeviceTitle "sdk-win-20"

# Dengan notifikasi Telegram (opsional):
.\install.ps1 -DeviceTitle "sdk-win-20" `
  -TelegramToken "123456:ABC..." -TelegramChatId "5563427435"
```

Installer akan:
- menyalin script ke `C:\EarnAppWatchdog`,
- menulis `config.json`,
- membuat `run-hidden.vbs` (supaya tidak ada jendela PowerShell),
- mendaftarkan Scheduled Task **`EarnAppWatchdog`**: at logon, Highest, hidden,
  tanpa batas waktu, restart otomatis kalau gagal,
- langsung menyalakan task (kecuali pakai `-NoStart`).

Cek cepat setelah install:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\EarnAppWatchdog\earnapp-watchdog.ps1 -CheckOnly
```

Contoh output:

```json
{
  "AppRunning": true,
  "Exe": "C:\\Program Files (x86)\\EarnApp\\earnapp.exe",
  "DeviceTitle": "sdk-win-20",
  "DeviceUuid": "sdk-win-2920ac951ca21044ad228bc5010804fe",
  "Blocked": true,
  "BanInfo": "ip_quality / vpn / 129.224.201.79",
  "PublicIp": "67.175.196.201",
  "Error": "",
  "Candidates": []
}
```

`Blocked: true` = sedang diblokir, `false` = hijau, `null` = belum bisa dicek
(lihat `Error`).

---

## Isi `config.json`

| Key | Default | Arti |
|---|---|---|
| `cookie_file` | `cookie.json` | Path cookie (relatif ke folder install atau absolut). |
| `device_uuid` | `""` | UUID device (`sdk-win-...`). Paling akurat kalau diisi. |
| `device_title` | `""` | Judul device di dashboard, mis. `sdk-win-20`. |
| `earnapp_exe` | `""` | Path `earnapp.exe`. Kosong = cari otomatis (registry + Program Files). |
| `off_seconds` | `300` | Lama EarnApp dimatikan sebelum dinyalakan lagi. |
| `settle_seconds` | `180` | Jeda setelah dinyalakan sebelum cek status lagi. |
| `check_interval_seconds` | `120` | Jeda antar pengecekan saat hijau. |
| `max_restarts_per_hour` | `6` | Batas restart per jam. `0` = tanpa batas. |
| `clear_cache_on_restart` | `true` | Bersihkan log/dump/cache EarnApp tiap kali restart. |
| `manage_service` | `true` | Ikut menghentikan/menyalakan service yang mengandung `earnapp`. |
| `service_match` | `earnapp` | Kata kunci nama service (termasuk `luminati_net_updater_win_earnapp_com`). |
| `api_timeout_seconds` | `30` | Timeout request API. |
| `telegram_token` | `""` | Token bot Telegram (opsional). |
| `telegram_chat_id` | `""` | Chat ID tujuan notifikasi (opsional). |

Setelah mengubah `config.json`, restart task:

```powershell
Stop-ScheduledTask  -TaskName EarnAppWatchdog
Start-ScheduledTask -TaskName EarnAppWatchdog
```

---

## Uji tanpa mengganggu EarnApp

```powershell
# Hanya baca status, tidak menyentuh EarnApp
.\earnapp-watchdog.ps1 -CheckOnly

# Satu siklus, tapi stop/start hanya dicatat (tidak dijalankan)
.\earnapp-watchdog.ps1 -Once -DryRun

# Satu siklus sungguhan
.\earnapp-watchdog.ps1 -Once
```

`-DryRun` berguna untuk memastikan device yang terdeteksi benar sebelum
dibiarkan jalan otomatis.

---

## Log

```
C:\EarnAppWatchdog\logs\watchdog.log
```

Contoh baris:

```
2026-11-14 07:15:01 [INFO] ===== EarnApp Watchdog mulai =====
2026-11-14 07:15:01 [INFO] Config: C:\EarnAppWatchdog\config.json | off=60s settle=60s interval=60s service=True
2026-11-14 07:15:01 [INFO] EarnApp: C:\Program Files (x86)\EarnApp\earnapp.exe
2026-11-14 07:15:04 [WARN] BLOCKED: sdk-win-20 (ip_quality / vpn / 129.224.201.79)
2026-11-14 07:15:04 [INFO] Service dihentikan: luminati_net_updater_win_earnapp_com
2026-11-14 07:15:04 [INFO] Proses dihentikan: earnapp (PID 3120)
2026-11-14 07:15:04 [INFO] Menunggu 60 detik sebelum menyalakan lagi...
2026-11-14 07:16:04 [INFO] Service dinyalakan: luminati_net_updater_win_earnapp_com
2026-11-14 07:16:05 [INFO] Menyalakan EarnApp: C:\Program Files (x86)\EarnApp\earnapp.exe
2026-11-14 07:16:05 [INFO] Menunggu 60 detik supaya status terbarui...
2026-11-14 07:17:05 [INFO] HIJAU: sdk-win-20 (device sdk-win-20)
```

Log diputar otomatis ke `watchdog.log.old` kalau sudah lebih dari 2 MB.

---

## Troubleshooting

**`Blocked: null` dan `Error: device tidak cocok ...`**
Isi `device_title` (atau `device_uuid`) sesuai dashboard. Jalankan
`.\discover.ps1` untuk melihat daftar judul device di akun itu.

**`Error: cookie belum diisi` / HTTP 401/403**
Cookie salah, kosong, atau sudah kedaluwarsa. Export ulang cookie dari akun
yang benar. Watchdog tidak akan mematikan EarnApp kalau cookie bermasalah.

**`earnapp.exe belum ditemukan`**
Isi `earnapp_exe` di `config.json`, mis.
`C:\Program Files (x86)\EarnApp\earnapp.exe`.

**Task tidak jalan setelah reboot**
Scheduled Task berjalan **saat user logon**. Aktifkan auto-login VM
(`netplwiz`) atau jalankan task secara manual. Jangan set task ke
"Run whether user is logged on or not", karena EarnApp adalah aplikasi tray
dan butuh sesi user.

**EarnApp jalan tapi tetap BLOCKED terus**
Blokir karena IP (mis. `ip_quality` / `vpn` / `earnapp_ip_blacklist`) tidak
hilang hanya dengan restart. Restart membantu kalau blokirnya sementara atau
koneksi macet. Untuk blokir IP, VM perlu IP publik baru (ganti jaringan /
MAC). Ini batasan EarnApp, bukan bug watchdog.

**Cek task**

```powershell
Get-ScheduledTask -TaskName EarnAppWatchdog | Get-ScheduledTaskInfo
Get-ScheduledTask -TaskName EarnAppWatchdog | Select-Object State
```

**Matikan sementara tanpa uninstall**

```powershell
Stop-ScheduledTask -TaskName EarnAppWatchdog
# nyalakan lagi:
Start-ScheduledTask -TaskName EarnAppWatchdog
```

**Tombol darurat (mode API)** — `C:\EarnAppWatchdog\stop-emergency.ps1`

```powershell
.\stop-emergency.ps1                  # matikan watchdog + EarnApp, task DI-DISABLE
.\stop-emergency.ps1 -Api -Status     # paksa cek mode API
.\stop-emergency.ps1 -KeepEarnApp     # watchdog saja; EarnApp tetap jalan
.\stop-emergency.ps1 -Status          # cek keadaan, tidak mengubah apa pun
.\stop-emergency.ps1 -Resume          # enable + start task, nyalakan EarnApp lagi
```

Script ini menghentikan **watchdog dulu**, baru service/proses EarnApp, supaya
watchdog tidak menyalakan EarnApp kembali. Task ikut di-`Disable` supaya tidak
hidup lagi saat logon/reboot. Log tambahan: `logs\emergency.log`.
Kalau `-KeepTaskEnabled` dipakai, task tidak di-disable.

**Tombol darurat (mode lokal)** — `C:\EarnAppWatchdogLocal\stop-emergency-local.ps1`

```powershell
.\stop-emergency-local.ps1                  # matikan watchdog lokal + EarnApp, task DI-DISABLE
.\stop-emergency-local.ps1 -Local -Status   # paksa cek mode lokal
.\stop-emergency-local.ps1 -KeepEarnApp     # watchdog saja; EarnApp tetap jalan
.\stop-emergency-local.ps1 -Resume          # enable + start task, nyalakan EarnApp lagi
```

Fileno identik dengan versi API, jadi kalau download dari `https://s.id/yELnc`
dan disimpan sebagai `stop-emergency.ps1`, tetap bisa dipakai untuk mode lokal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\stop-emergency.ps1 -Local -Status
```

---

## Uninstall

```powershell
.\uninstall.ps1                 # hapus task + file + log
.\uninstall.ps1 -KeepConfig -KeepLogs
```

EarnApp sendiri **tidak** di-uninstall.

---

## Catatan penting

- Satu watchdog per VM. Jangan jalankan dua task untuk script yang sama.
- Cookie hanya disimpan lokal di VM (tidak dikirim ke mana pun kecuali ke
  `earnapp.com` dan, kalau diisi, Telegram).
- Status hijau berarti `banned == null` di API, **bukan** jaminan earning
  langsung naik; earning mengikuti *qualified uptime* EarnApp.
- Sejak 17 Nov 2026 dashboard memakai versi API `1.689.920` (sebelumnya
  `1.685.997`). Script sudah memakai versi baru. Endpoint `GET /devices` tidak
  memeriksa `xsrf-token`, jadi watchdog API tetap aman meskipun dashboard
  merotasi token (`/api/sec/rotate_xsrf`).

---

# Mode lokal (tanpa cookie / tanpa dashboard)

Script: `earnapp-watchdog-local.ps1`

Dipakai kalau VM **tidak boleh / tidak bisa** memakai cookie akun, atau kalau
dashboard EarnApp tidak bisa dihubungi. Mode ini membaca **jendela EarnApp**
langsung di VM, jadi tidak butuh login API sama sekali.

## Yang bisa dan tidak bisa

| Bisa | Tidak bisa |
|---|---|
| Deteksi tulisan `Earning blocked` / `Resource sharing blocked` | Tahu alasan ban (`ip_quality`, `blacklist`) |
| Deteksi halaman dashboard baru `Your IP is blocked` (jika tampil di jendela EarnApp) | Tahu IP publik device |
| Deteksi `Earning paused` | Tahu IP publik device |
| Deteksi EarnApp mati / hang | Tahu status device di dashboard |
| Restart EarnApp sampai tanda blocked hilang | Memastikan device benar-benar hijau di server |

Karena tidak memakai API, mode ini **tidak pernah** menyebut "cookie expired".
Kalau tanda blocked tidak hilang-hilang, biasanya blokir IP: VM perlu IP publik
baru (ganti jaringan/MAC), bukan restart terus.

Sejak dashboard EarnApp versi `1.689.920`, halaman blokir IP menampilkan
**`Your IP is blocked`** (bukan lagi hanya teks di aplikasi). Penanda itu sudah
masuk daftar default `blocked_texts`, termasuk label alasan baru seperti
`Low quality IP`, `Device blocked`, dan `IP blocked`. Kalau VM memakai bahasa
lain, tambahkan teksnya di `blocked_texts` pada `config.json`.

## Cara kerja

1. Cari proses `earnapp.exe` dan jendelanya (Win32 `EnumWindows`).
2. Baca semua teks di jendela lewat **UI Automation** bawaan .NET
   (`UIAutomationClient`, sudah ada di Windows 10 — tanpa install apa pun).
   Membaca saja: tidak klik, tidak screenshot, tidak mengubah jendela.
3. Cocokkan teks dengan daftar penanda blocked (Inggris, Indonesia, dan
   beberapa bahasa lain). Teks panjang (FAQ) dan "not blocked" diabaikan.
4. Kalau blocked: stop EarnApp + service, bersihkan cache, tunggu `off_seconds` (300 dtk),
   start lagi, tunggu `settle_seconds`, ulangi sampai tanda blocked hilang.
5. Kalau EarnApp mati: dinyalakan. Kalau hang: restart.

Jendela yang di-minimize atau disembunyikan **tetap terbaca** (sudah diuji).
Kalau jendela belum pernah dirender, script menampilkannya sebentar tanpa
mengambil fokus, membaca, lalu mengembalikan seperti semula.

## Install

PowerShell **sebagai Administrator**, di folder yang sama dengan script:

```powershell
.\install-local.ps1
```

Dengan Telegram (opsional):

```powershell
.\install-local.ps1 -TelegramChatId 5563427435 -TelegramToken 123:ABC
```

Yang dibuat:

- folder `C:\EarnAppWatchdogLocal\`
- `config.json` (tanpa cookie)
- `run-hidden.vbs` (launcher tanpa jendela)
- Scheduled Task `EarnAppWatchdogLocal` (saat logon, tersembunyi, Highest)

> **PENTING:** jangan pasang bersamaan dengan watchdog API
> (`EarnAppWatchdog`). Dua watchdog akan saling mematikan EarnApp.
> Pilih salah satu. Installer akan memberi peringatan kalau task API masih ada.

## Config

`C:\EarnAppWatchdogLocal\config.json` (contoh lengkap:
`config.local.example.json`).

| Key | Default | Arti |
|---|---|---|
| `earnapp_exe` | `""` | Path `earnapp.exe`; kosong = dicari otomatis |
| `process_names` | `["earnapp"]` | Nama proses yang dianggap EarnApp |
| `off_seconds` | `300` | Lama EarnApp dimatikan sebelum dinyalakan lagi |
| `settle_seconds` | `180` | Jeda setelah start sebelum cek lagi |
| `check_interval_seconds` | `120` | Jeda antar siklus |
| `max_restarts_per_hour` | `6` | Batas restart; kalau tercapai, tunggu 10 menit |
| `clear_cache_on_restart` | `true` | Bersihkan log/dump/cache EarnApp tiap restart |
| `manage_service` | `true` | Ikut stop/start service `luminati_net_updater_win_earnapp_com` |
| `stale_log_seconds` | `1800` | Log lebih tua dari ini + jendela tak terbaca = hang |
| `restart_when_paused` | `false` | Restart kalau status paused (default: biarkan) |
| `restart_when_unknown` | `false` | Restart kalau status tidak terbaca |
| `restart_when_hang` | `true` | Restart kalau hang |
| `window_probe_seconds` | `12` | Lama menampilkan jendela sebentar kalau teks belum terbaca |
| `blocked_texts` | `[]` | Tambahan penanda blocked (kosong = daftar bawaan) |
| `paused_texts` | `[]` | Tambahan penanda paused |
| `telegram_token` / `telegram_chat_id` | `""` | Notifikasi opsional |

## Uji sebelum dibiarkan jalan

```powershell
# Baca status lokal (JSON), tidak menyentuh EarnApp
.\earnapp-watchdog-local.ps1 -CheckOnly

# Satu siklus, stop/start hanya dicatat
.\earnapp-watchdog-local.ps1 -Once -DryRun

# Satu siklus sungguhan
.\earnapp-watchdog-local.ps1 -Once
```

Contoh keluaran `-CheckOnly` saat blocked:

```json
{
  "AppRunning": true,
  "WindowFound": true,
  "WindowTitle": "EarnApp",
  "Texts": ["Earning blocked", "Resource sharing blocked"],
  "Blocked": true,
  "BlockedEvidence": ["Earning blocked"],
  "State": "blocked"
}
```

Nilai `State`: `ok`, `blocked`, `paused`, `down`, `hang`, `unknown`.

## Log

```
C:\EarnAppWatchdogLocal\logs\watchdog-local.log
```

```
2026-11-14 07:41:07 [WARN] BLOCKED (lokal): sdk-win-20 -> 'Earning blocked / Resource sharing blocked'
2026-11-14 07:41:07 [INFO] Service dihentikan: luminati_net_updater_win_earnapp_com
2026-11-14 07:41:07 [INFO] Proses dihentikan: earnapp (PID 3120)
2026-11-14 07:41:07 [INFO] Menunggu 60 detik sebelum menyalakan lagi...
2026-11-14 07:42:07 [INFO] Menyalakan EarnApp: C:\Program Files (x86)\EarnApp\earnapp.exe
2026-11-14 07:43:08 [INFO] HIJAU (lokal): sdk-win-20 -> tanda blocked tidak terlihat lagi setelah 1 restart.
```

## Troubleshooting mode lokal

**`Status lokal belum pasti (jendela tidak terbaca)`**
Jendela EarnApp tidak ada atau belum dirender. Buka EarnApp sekali secara
manual, atau naikkan `window_probe_seconds`. Pastikan VM memakai sesi user
(auto-login), bukan "Run whether user is logged on or not".

**`UI Automation tidak tersedia`**
PowerShell di VM bukan 5.1 / komponen .NET hilang. Mode ini hanya jalan di
Windows 10 dengan PowerShell 5.1 bawaan.

**Teks jendela terbaca tapi tidak ada tanda blocked padahal di dashboard blocked**
Pastikan jendela EarnApp sedang di halaman status (bukan halaman Settings/FAQ).
`earnapp.settings` biasanya menyimpan `screen=main`. Kalau perlu, tambahkan
penanda khusus lewat `blocked_texts`.

**Restart terus tapi tetap blocked**
Kemungkinan besar blokir IP. Cek dari dashboard akun. Mode lokal tidak bisa
melihat alasan/IP — pakai watchdog API untuk itu, atau ganti IP VM.

**Cek / matikan task**

```powershell
Get-ScheduledTask -TaskName EarnAppWatchdogLocal | Get-ScheduledTaskInfo
Stop-ScheduledTask -TaskName EarnAppWatchdogLocal
Start-ScheduledTask -TaskName EarnAppWatchdogLocal
```

## Uninstall mode lokal

```powershell
.\uninstall-local.ps1
.\uninstall-local.ps1 -KeepConfig -KeepLogs
```

EarnApp sendiri **tidak** di-uninstall.
