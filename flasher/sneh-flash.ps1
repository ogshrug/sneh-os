#Requires -Version 7.4
<#
.SYNOPSIS
  Sneh flasher: builds a self-installing Sneh USB stick (desktop/headless or laptop
  edition; net or full/offline install).

.DESCRIPTION
  Asks for install settings once, downloads and verifies the official Arch ISO,
  writes it to a FAT32 USB stick (UEFI boot), and adds the Sneh installer
  plus your settings. Plug the stick into the mini PC, power on, and it
  installs itself. Watch progress over SSH (root@<hostname>-install.local) or
  read sneh\install.log on the stick afterwards.

.PARAMETER ConfigPath
  Reuse an existing sneh.conf instead of answering prompts.
.PARAMETER IsoPath
  Use a local Arch ISO instead of downloading the latest one.
.PARAMETER DiskNumber
  Skip the USB picker and use this Windows disk number.
.PARAMETER AllowNonUsb
  Allow a non-USB disk (only for testing against a mounted VHD).
.PARAMETER SaveConfig
  Also save the answers to this path (secrets included!) for reuse.
.PARAMETER Mode
  net (default; packages download during install) or full (all packages on the stick, offline install).
.PARAMETER Edition
  desktop (headless mini PC, VNC) or laptop.
.PARAMETER IsoRoot
  Use an already-extracted ISO folder instead of mounting the ISO (no admin needed with -OutDir).
.PARAMETER OutDir
  Build the stick contents into this folder instead of a USB disk (no admin needed except to mount the ISO).
.EXAMPLE
  pwsh -File flasher\sneh-flash.ps1
.EXAMPLE
  pwsh -File flasher\sneh-flash.ps1 -Mode full -Edition desktop -SaveConfig my.conf
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$IsoPath,
    [int]$DiskNumber = -1,
    [switch]$AllowNonUsb,
    [string]$SaveConfig,
    [ValidateSet('net', 'full')][string]$Mode,
    [ValidateSet('desktop', 'laptop')][string]$Edition,
    [ValidateSet('auto', 'gui')][string]$Ui,
    [string]$OutDir,
    [string]$IsoRoot,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$CacheDir = Join-Path $env:LOCALAPPDATA 'sneh'
$Mirror   = 'https://geo.mirror.pkgbuild.com/iso/latest'
$Themes   = 'dusk', 'ink', 'rose', 'red-august', 'teal', 'aether', 'olive', 'blue-hour'
$SecretKeys = 'PASSWORD', 'VNC_PASSWORD', 'WIFI_PSK', 'TAILSCALE_AUTHKEY'

# ---------------------------------------------------------------- ui helpers
function Write-Brand {
    $bone = "`e[38;2;235;227;210m"; $red = "`e[38;2;200;65;47m"; $dim = "`e[38;2;133;125;110m"; $r = "`e[0m"
    Write-Host ''
    Write-Host "  ${red}स्नेह${r}  ${bone}s n e h${r}   ${dim}headless · agent-first · arch${r}"
    Write-Host "  ${dim}─────────────────────────────────────────────${r}"
    Write-Host ''
}
function Write-Step([string]$msg) { Write-Host "  `e[38;2;200;65;47m▸`e[0m $msg" }
function Write-Note([string]$msg) { Write-Host "    `e[38;2;133;125;110m$msg`e[0m" }
function Fail([string]$msg) { Write-Host "  `e[31m✗ $msg`e[0m"; exit 1 }

function Ask([string]$label, [string]$default = '', [scriptblock]$validate = $null, [string]$hint = '') {
    while ($true) {
        $suffix = if ($default) { " [$default]" } else { '' }
        $v = Read-Host "    $label$suffix"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $default }
        $v = $v.Trim()
        if (-not $validate -or (& $validate $v)) { return $v }
        Write-Host "    `e[31minvalid$(if ($hint) { ": $hint" })`e[0m"
    }
}
function AskSecret([string]$label, [int]$minLen = 0, [switch]$AllowEmpty) {
    while ($true) {
        $a = Read-Host "    $label" -AsSecureString | ConvertFrom-SecureString -AsPlainText
        if ($AllowEmpty -and $a -eq '') { return '' }
        if ($a.Length -lt $minLen) { Write-Host "    `e[31mneeds at least $minLen characters`e[0m"; continue }
        $b = Read-Host "    $label (again)" -AsSecureString | ConvertFrom-SecureString -AsPlainText
        if ($a -ceq $b) { return $a }
        Write-Host "    `e[31mdidn't match, try again`e[0m"
    }
}
function AskYesNo([string]$label, [bool]$default) {
    $d = if ($default) { 'Y/n' } else { 'y/N' }
    $v = Read-Host "    $label [$d]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v.Trim().ToLower().StartsWith('y')
}

# ---------------------------------------------------------------- config
function Read-SnehConf([string]$path) {
    $h = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $k, $v = $line -split '=', 2
        $h[$k.Trim()] = $v
    }
    return $h
}
function Write-SnehConf([System.Collections.IDictionary]$cfg, [string]$path) {
    $lines = @('# Sneh install settings. Parsed (never sourced) by the installer.',
               '# Secrets are scrubbed from the stick automatically after a successful install.')
    foreach ($k in $cfg.Keys) {
        $v = [string]$cfg[$k]
        if ($v -match "[`r`n]") { Fail "value for $k contains a newline" }
        $lines += "$k=$v"
    }
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-CurrentWifi {
    try {
        $out = netsh wlan show interfaces 2>$null
        $ssid = ($out | Select-String '^\s*SSID\s*:\s*(.+)$' | Select-Object -First 1).Matches.Groups[1].Value.Trim()
        if (-not $ssid) { return $null }
        $prof = netsh wlan show profile name="$ssid" key=clear 2>$null
        $key = ($prof | Select-String '^\s*Key Content\s*:\s*(.+)$' | Select-Object -First 1)
        return [pscustomobject]@{ Ssid = $ssid; Psk = if ($key) { $key.Matches.Groups[1].Value.Trim() } else { '' } }
    } catch { return $null }
}

function Get-IanaTimeZone {
    $iana = $null
    if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId((Get-TimeZone).Id, [ref]$iana)) { return $iana }
    return 'UTC'
}

function New-Config {
    $c = [ordered]@{}
    Write-Step 'Install style'
    Write-Note 'auto = answer everything here; the machine installs itself, no screen needed (headless boxes)'
    Write-Note 'gui  = a graphical installer on the machine asks the questions (laptops, desktops with a screen)'
    $c.INSTALL_UI = if ($Ui) { $Ui } else { Ask 'install style: auto | gui' 'auto' { param($v) $v -in 'auto', 'gui' } }
    if ($c.INSTALL_UI -eq 'gui') {
        Write-Note 'net  = small stick; packages download during the install (needs internet)'
        Write-Note 'full = every package for both editions on the stick; installs with no internet'
        $c.INSTALL_MODE = if ($Mode) { $Mode } else { Ask 'install mode: net | full' 'net' { param($v) $v -in 'net', 'full' } }
        $c.KERNEL = 'linux-zen'; $c.PERF_MITIGATIONS = 'on'; $c.FIRMWARE = 'auto'; $c.THEME = 'dusk'
        $defaultKey = @('id_ed25519.pub', 'id_ecdsa.pub', 'id_rsa.pub') | ForEach-Object { Join-Path $HOME ".ssh\$_" } | Where-Object { Test-Path $_ } | Select-Object -First 1
        $keyPath = Ask 'SSH public key to authorise (optional, Enter to skip)' $defaultKey { param($v) $v -eq '' -or (Test-Path -LiteralPath $v) }
        $c.SSH_PUBKEY = if ($keyPath) { (Get-Content -LiteralPath $keyPath -Raw).Trim() } else { '' }
        $c.SSH_PASSWORD_AUTH = if ($c.SSH_PUBKEY) { 'no' } else { 'yes' }
        return $c
    }
    Write-Step 'Edition'
    Write-Note 'desktop = headless mini PC: virtual screen over VNC, no audio, never sleeps'
    Write-Note 'laptop  = real screen, battery, audio, Bluetooth, lock screen (VNC optional)'
    $c.PROFILE = if ($Edition) { $Edition } else { Ask 'profile: desktop | laptop' 'desktop' { param($v) $v -in 'desktop', 'laptop' } }
    Write-Note 'net  = small stick; packages download during install (needs internet)'
    Write-Note 'full = every package on the stick (~1.3 GB extra); installs with no internet'
    $c.INSTALL_MODE = if ($Mode) { $Mode } else { Ask 'install mode: net | full' 'net' { param($v) $v -in 'net', 'full' } }
    Write-Note 'linux-zen = lowest latency desktop kernel · linux = stock · linux-lts = most conservative'
    $c.KERNEL = Ask 'kernel' 'linux-zen' { param($v) $v -in 'linux', 'linux-zen', 'linux-lts' }
    Write-Note 'CPU mitigations off = ~5-20% faster syscalls on old Intel CPUs, but weaker isolation'
    Write-Note 'between programs. Only sensible on a single-user box on a trusted network.'
    $c.PERF_MITIGATIONS = if (AskYesNo 'turn CPU vulnerability mitigations OFF for speed?' $false) { 'off' } else { 'on' }
    $c.FIRMWARE = 'auto'

    Write-Step 'Machine'
    $c.HOSTNAME = Ask 'hostname' 'sneh' { param($v) $v -match '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$' } 'letters, digits, dashes'
    $c.USERNAME = Ask 'username' ($env:USERNAME.ToLower() -replace '[^a-z0-9_-]', '') { param($v) $v -match '^[a-z_][a-z0-9_-]{0,31}$' -and $v -notin 'root', 'greeter' } 'lowercase, starts with a letter'
    $c.PASSWORD = AskSecret 'password (sudo + optional ssh)' 6
    $c.SUDO_NOPASSWD = if (AskYesNo 'passwordless sudo for this user? (lets agents install packages unattended)' $false) { 'yes' } else { 'no' }
    $c.TIMEZONE = Ask 'timezone' (Get-IanaTimeZone) { param($v) $v -match '^[A-Za-z0-9_+/-]+$' }
    $c.LOCALE   = Ask 'locale' 'en_US.UTF-8' { param($v) $v -match '^[A-Za-z_]+\.UTF-8$' }
    $c.KEYMAP   = Ask 'console keymap' 'us' { param($v) $v -match '^[A-Za-z0-9_-]+$' }
    $c.XKB_LAYOUT = Ask 'desktop keyboard layout (xkb)' 'us' { param($v) $v -match '^[a-z,]+$' }

    Write-Step 'Network'
    $c.WIFI_SSID = ''; $c.WIFI_PSK = ''; $c.WIFI_HIDDEN = 'no'
    if (AskYesNo 'configure Wi-Fi? (No = Ethernet only, recommended for install)' $false) {
        $cur = Get-CurrentWifi
        if ($cur -and (AskYesNo "use this PC's Wi-Fi '$($cur.Ssid)'?" $true)) {
            $c.WIFI_SSID = $cur.Ssid
            $c.WIFI_PSK = if ($cur.Psk) { $cur.Psk } else { AskSecret 'Wi-Fi password' 8 }
        } else {
            $c.WIFI_SSID = Ask 'Wi-Fi SSID' '' { param($v) $v.Length -ge 1 -and $v.Length -le 32 }
            $c.WIFI_PSK  = AskSecret 'Wi-Fi password (empty = open network)' 0 -AllowEmpty
        }
        $c.WIFI_HIDDEN = if (AskYesNo 'is the network hidden?' $false) { 'yes' } else { 'no' }
    }
    $c.TAILSCALE_AUTHKEY = Ask 'Tailscale auth key (optional, Enter to skip)' '' { param($v) $v -eq '' -or $v -match '^tskey-' } 'starts with tskey-'

    Write-Step 'Remote access'
    $defaultKey = @('id_ed25519.pub', 'id_ecdsa.pub', 'id_rsa.pub') | ForEach-Object { Join-Path $HOME ".ssh\$_" } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $defaultKey -and (Get-Command ssh-keygen -ErrorAction SilentlyContinue) -and (AskYesNo 'no SSH key found - generate one now?' $true)) {
        $kp = Join-Path $HOME '.ssh\id_ed25519'
        New-Item -ItemType Directory -Force (Split-Path $kp) | Out-Null
        & ssh-keygen -q -t ed25519 -f $kp -N "" -C "sneh" | Out-Null
        $defaultKey = "$kp.pub"
    }
    $keyPath = Ask 'SSH public key file (Enter to skip)' $defaultKey { param($v) $v -eq '' -or (Test-Path -LiteralPath $v) }
    $c.SSH_PUBKEY = if ($keyPath) { (Get-Content -LiteralPath $keyPath -Raw).Trim() } else { '' }
    $c.SSH_PASSWORD_AUTH = if (-not $c.SSH_PUBKEY) { 'yes' } elseif (AskYesNo 'also allow SSH password login?' $false) { 'yes' } else { 'no' }
    $c.VNC_ON_LAPTOP = 'no'; $c.LOCK_ON_LOGIN = 'yes'
    $c.VNC_PASSWORD = ''; $c.VNC_RESOLUTION = '1600x900'; $c.VNC_BIND = 'lan'
    $wantVnc = $c.PROFILE -eq 'desktop'
    if ($c.PROFILE -eq 'laptop') {
        $wantVnc = AskYesNo 'also serve the laptop desktop over VNC?' $false
        $c.VNC_ON_LAPTOP = if ($wantVnc) { 'yes' } else { 'no' }
        $c.LOCK_ON_LOGIN = if (AskYesNo 'lock screen right after the automatic login?' $true) { 'yes' } else { 'no' }
    }
    if ($wantVnc) {
        $c.VNC_PASSWORD = AskSecret 'VNC password' 6
        if ($c.PROFILE -eq 'desktop') { $c.VNC_RESOLUTION = Ask 'virtual screen resolution' '1600x900' { param($v) $v -match '^\d{3,4}x\d{3,4}$' } }
        $c.VNC_BIND = Ask 'VNC listens on: lan | localhost (ssh tunnel only) | tailscale' 'lan' { param($v) $v -in 'lan', 'localhost', 'tailscale' }
    }

    Write-Step 'Look'
    Write-Note ("themes: " + ($Themes -join ', '))
    $c.THEME = Ask 'theme' 'dusk' { param($v) $v -in $Themes }
    $c.ANIMATIONS = if (AskYesNo 'window animations? (No = snappier over VNC)' $true) { 'on' } else { 'off' }
    Write-Step 'Apps (optional)'
    $appLines = Get-Content (Join-Path $PSScriptRoot '..\system\packages\apps.txt') | Where-Object { $_ -match '^\s*[\w-]+\s*:' }
    $appNames = @($appLines | ForEach-Object { ($_ -split ':')[0].Trim() })
    foreach ($l in $appLines) { Write-Note (($l -split ':')[0].Trim().PadRight(9) + ($l -replace '^[^#]*#\s*', '')) }
    $c.APPS = Ask 'apps to install (comma-separated, or none)' 'files,vlc,images' {
        param($v) $v -eq 'none' -or @($v -split ',' | Where-Object { $_ -and $_ -notin $appNames }).Count -eq 0 }
    Write-Note 'The default wallpaper is Sneh''s own "dusk ridge". Optionally, 14 Firewatch fan-art'
    Write-Note 'wallpapers (wallhaven.cc, ~40 MB) can be downloaded on the machine for personal use.'
    $c.FIREWATCH = if (AskYesNo 'also download the Firewatch wallpapers?' $false) { 'yes' } else { 'no' }

    Write-Step 'Agents'
    $c.AGENTS = Ask 'agents to install (claude,opencode | claude | opencode | none)' 'claude,opencode' { param($v) $v -eq 'none' -or @($v -split ',' | Where-Object { $_ -and $_ -notin 'claude', 'opencode' }).Count -eq 0 }

    Write-Step 'Target disk inside the mini PC'
    Write-Note 'auto = the only internal disk >= 16 GB (install aborts if there are several).'
    Write-Note 'Or give part of the model/serial, e.g. "Samsung" or "KINGSTON SA400".'
    $c.TARGET_DISK = Ask 'target disk' 'auto' { param($v) $v -match '^[\w ./:+-]+$' }
    $c.REPO_URL = Ask 'git URL to pull Sneh updates from (optional)' ''
    $c.ALLOW_WIPE = 'yes'
    return $c
}

function Test-Config([System.Collections.IDictionary]$c) {
    if ($Ui) { $c['INSTALL_UI'] = $Ui }
    if ($c['INSTALL_UI'] -eq 'gui') {          # everything else is asked on the machine
        if ($Mode) { $c['INSTALL_MODE'] = $Mode }
        if (-not $c.Contains('INSTALL_MODE')) { $c['INSTALL_MODE'] = 'net' }
        return
    }
    $need = 'HOSTNAME', 'USERNAME', 'PASSWORD', 'TIMEZONE', 'TARGET_DISK'
    if ($c['PROFILE'] -ne 'laptop' -or $c['VNC_ON_LAPTOP'] -eq 'yes') { $need += 'VNC_PASSWORD' }
    foreach ($k in $need) {
        if (-not $c.Contains($k) -or [string]::IsNullOrWhiteSpace([string]$c[$k])) { Fail "config is missing $k" }
    }
    if (-not $c.Contains('PROFILE')) { $c['PROFILE'] = 'desktop' }
    if (-not $c.Contains('INSTALL_MODE')) { $c['INSTALL_MODE'] = 'net' }
    if ($Mode) { $c['INSTALL_MODE'] = $Mode }
    if ($Edition) { $c['PROFILE'] = $Edition }
    if ($c.PASSWORD -eq '<removed>') { Fail 'this config was scrubbed after an install; set PASSWORD and VNC_PASSWORD again' }
}

# ---------------------------------------------------------------- iso
function Get-ArchIso {
    if ($IsoPath) {
        if (-not (Test-Path -LiteralPath $IsoPath)) { Fail "ISO not found: $IsoPath" }
        Write-Note 'using local ISO (not checksum-verified)'
        return (Resolve-Path -LiteralPath $IsoPath).Path
    }
    New-Item -ItemType Directory -Force $CacheDir | Out-Null
    Write-Step 'Fetching Arch ISO checksums'
    $sums = (Invoke-WebRequest -Uri "$Mirror/sha256sums.txt" -UseBasicParsing).Content -split "`n"
    $line = $sums | Where-Object { $_ -match '^\s*([0-9a-f]{64})\s+\*?(archlinux-\d{4}\.\d{2}\.\d{2}-x86_64\.iso)\s*$' } | Select-Object -First 1
    if (-not $line) { Fail 'could not find a dated ISO in sha256sums.txt' }
    $null = $line -match '^\s*([0-9a-f]{64})\s+\*?(\S+)'
    $hash, $name = $Matches[1], $Matches[2]
    $dest = Join-Path $CacheDir $name
    if (-not (Test-Path $dest) -or (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower() -ne $hash) {
        Write-Step "Downloading $name (~1.4 GB, resumable)"
        & curl.exe -L --fail --retry 5 -C - -o $dest "$Mirror/$name"
        if ($LASTEXITCODE -ne 0) { Fail 'download failed' }
    } else { Write-Note "cached: $dest" }
    Write-Step 'Verifying SHA-256'
    if ((Get-FileHash $dest -Algorithm SHA256).Hash.ToLower() -ne $hash) {
        Remove-Item $dest -Force; Fail 'checksum mismatch - deleted the download, run again'
    }
    Write-Note 'ok'
    return $dest
}

# ---------------------------------------------------------------- usb
function Select-UsbDisk {
    if ($DiskNumber -ge 0) {
        $d = Get-Disk -Number $DiskNumber
        if ($d.BusType -ne 'USB' -and -not $AllowNonUsb) { Fail "disk $DiskNumber is not USB (use -AllowNonUsb for VHD tests)" }
        if ($d.IsBoot -or $d.IsSystem) { Fail "disk $DiskNumber is a Windows boot/system disk" }
        return $d
    }
    $disks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -ge 2GB })
    if (-not $disks) { Fail 'no USB stick >= 2 GB found - plug one in and run again' }
    Write-Step 'USB drives'
    foreach ($d in $disks) {
        $letters = (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter):" }) -join ' '
        Write-Host ("    [{0}] {1,-32} {2,7:N1} GB  {3}" -f $d.Number, $d.FriendlyName, ($d.Size / 1GB), $letters)
    }
    $n = Ask 'disk number to ERASE' '' { param($v) $v -match '^\d+$' -and [int]$v -in $disks.Number }
    $d = $disks | Where-Object Number -eq ([int]$n)
    Write-Host "    `e[31mEverything on '$($d.FriendlyName)' ($([math]::Round($d.Size/1GB,1)) GB) will be destroyed.`e[0m"
    $again = Read-Host '    type the disk number again to confirm'
    if ($again.Trim() -ne $n) { Fail 'confirmation did not match - nothing was changed' }
    return $d
}

function Initialize-Stick($disk, [string]$label) {
    Write-Step "Partitioning disk $($disk.Number) (MBR, FAT32 '$label')"
    if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
    if ($disk.PartitionStyle -ne 'RAW') { Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false }
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction SilentlyContinue
    $size = [uint64][math]::Min(8GB, $disk.Size - 4MB)
    $part = New-Partition -DiskNumber $disk.Number -Size $size -IsActive -MbrType FAT32 -AssignDriveLetter
    $null = Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel $label -Confirm:$false -Force
    for ($i = 0; $i -lt 20; $i++) {
        $letter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter
        if ($letter -and $letter -ne [char]0) { return "${letter}:" }
        Start-Sleep -Milliseconds 500
    }
    Fail 'Windows did not assign a drive letter to the new partition'
}

function Copy-Tree([string]$src, [string]$dst) {
    # "X:\." form: safe for drive roots and avoids the trailing-backslash-quote quirk
    $src = $src.TrimEnd('\') + '\.'; $dst = $dst.TrimEnd('\') + '\.'
    & robocopy.exe $src $dst /E /A-:R /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "copy failed ($src -> $dst), robocopy code $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
}

# Copy our scripts/configs normalising CRLF -> LF (a Windows checkout would break bash).
function Copy-Payload([string]$src, [string]$dst) {
    $srcFull = (Resolve-Path -LiteralPath $src).Path
    foreach ($f in Get-ChildItem -LiteralPath $srcFull -Recurse -File) {
        $rel = $f.FullName.Substring($srcFull.Length).TrimStart('\')
        $out = Join-Path $dst $rel
        New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        if ($bytes -notcontains 0) {
            $text = [Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
            [IO.File]::WriteAllText($out, $text, [Text.UTF8Encoding]::new($false))
        } else { [IO.File]::WriteAllBytes($out, $bytes) }
    }
}

function Update-BootEntries([string]$root) {
    # cow_spacesize: room in RAM for the graphical installer's packages (used only as needed)
    $extra = 'copytoram=n cow_spacesize=2G script=/run/archiso/bootmnt/sneh/install.sh'
    $patched = 0
    $entries = Join-Path $root 'loader\entries'
    if (Test-Path $entries) {
        foreach ($f in Get-ChildItem $entries -Filter '*.conf') {
            $t = [IO.File]::ReadAllText($f.FullName)
            if ($t -notmatch 'archisobasedir' -or $t -match 'script=') { continue }
            $t = [regex]::Replace($t, '(?m)^(options[ \t]+[^\r\n]*?)[ \t]*\r?$', "`$1 $extra")
            [IO.File]::WriteAllText($f.FullName, $t, [Text.UTF8Encoding]::new($false)); $patched++
        }
        $lc = Join-Path $root 'loader\loader.conf'
        if (Test-Path $lc) {
            $t = [IO.File]::ReadAllText($lc) -replace '(?m)^timeout\s+\d+', 'timeout 3' -replace '(?m)^beep\s+on', 'beep off'
            [IO.File]::WriteAllText($lc, $t, [Text.UTF8Encoding]::new($false))
        }
    }
    $grub = Join-Path $root 'boot\grub\grub.cfg'
    if (Test-Path $grub) {
        $t = [IO.File]::ReadAllText($grub)
        $t = [regex]::Replace($t, '(?m)^([ \t]*linux[ \t]+\S+[ \t]+[^\r\n]*archisobasedir[^\r\n]*?)[ \t]*\r?$', "`$1 $extra")
        $t = $t -replace '(?m)^timeout=\d+', 'timeout=3'
        [IO.File]::WriteAllText($grub, $t, [Text.UTF8Encoding]::new($false)); $patched++
    }
    if ($patched -eq 0) { Fail 'found no UEFI boot entries to patch - unsupported ISO layout' }
    Write-Note "patched $patched boot entr$(if ($patched -eq 1) {'y'} else {'ies'})"
}

# ---------------------------------------------------------------- main
. (Join-Path $PSScriptRoot 'lib\offline-repo.ps1')
Write-Brand
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $OutDir) { Fail 'run this from an Administrator PowerShell 7 (pwsh) window (or use -OutDir to build the stick contents into a folder)' }
foreach ($d in 'installer', 'system') { if (-not (Test-Path (Join-Path $RepoRoot $d))) { Fail "missing $d\ next to flasher\ - run from the repo checkout" } }

$cfg = if ($ConfigPath) { Write-Step "Using settings from $ConfigPath"; Read-SnehConf $ConfigPath } else { New-Config }
Test-Config $cfg
if ($SaveConfig) { Write-SnehConf $cfg $SaveConfig; Write-Note "saved settings to $SaveConfig (contains secrets)" }
if ($cfg['INSTALL_UI'] -eq 'gui') { Write-Note "graphical installer · install: $($cfg.INSTALL_MODE)" }
else { Write-Note "edition: $($cfg.PROFILE) · install: $($cfg.INSTALL_MODE) · kernel: $($cfg['KERNEL'])" }

$iso = if ($IsoRoot) { $null } else { Get-ArchIso }
$disk = if ($OutDir) { $null } else { Select-UsbDisk }
if ($disk -and $cfg.INSTALL_MODE -eq 'full' -and $disk.Size -lt 7GB) { Fail 'full mode needs a stick of at least 8 GB' }

$img = $null
if ($IsoRoot) {
    $isoSrc = (Resolve-Path -LiteralPath $IsoRoot).Path.TrimEnd([char]92) + [char]92
} else {
    Write-Step 'Mounting ISO'
    $img = Mount-DiskImage -ImagePath $iso -PassThru
}
try {
    if ($img) { $isoSrc = "$(($img | Get-Volume).DriveLetter):\" }
    $label = 'SNEH'
    $entry = Get-ChildItem (Join-Path $isoSrc 'loader\entries') -Filter '*.conf' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($entry -and ((Get-Content $entry.FullName -Raw) -match 'archisolabel=(\S+)')) { $label = $Matches[1] }
    if (-not (Test-Path (Join-Path $isoSrc 'EFI\BOOT'))) { Fail 'ISO has no EFI\BOOT - not an Arch UEFI ISO?' }

    if ($OutDir) {
        New-Item -ItemType Directory -Force $OutDir | Out-Null
        $usb = (Resolve-Path $OutDir).Path.TrimEnd('\')
        Set-Content -LiteralPath (Join-Path $usb 'FAT-LABEL.txt') -Value $label
    } else {
        if (-not $Force) {
            Write-Host ''
            if (-not (AskYesNo "write Sneh to disk $($disk.Number) '$($disk.FriendlyName)' now?" $true)) { Fail 'aborted' }
        }
        $usb = Initialize-Stick $disk $label
    }
    Write-Step "Copying Arch live system to $usb"
    Copy-Tree $isoSrc "$usb\"
} finally {
    if ($img) { Dismount-DiskImage -ImagePath $iso | Out-Null }
}

Write-Step 'Patching boot entries for unattended install'
Update-BootEntries "$usb\"

Write-Step 'Adding Sneh installer + system payload'
$rk = Join-Path "$usb\" 'sneh'
Copy-Payload (Join-Path $RepoRoot 'installer') $rk
Copy-Payload (Join-Path $RepoRoot 'system') (Join-Path $rk 'system')
Write-SnehConf $cfg (Join-Path $rk 'sneh.conf')
Remove-Item (Join-Path $rk 'installed.done'), (Join-Path $rk 'install.failed') -ErrorAction SilentlyContinue

if ($cfg['INSTALL_UI'] -eq 'gui' -and $cfg.INSTALL_MODE -ne 'full') {
    Build-OfflineRepo $RepoRoot $cfg (Join-Path $rk 'repo') $CacheDir -GuiOnly
}
if ($cfg.INSTALL_MODE -eq 'full') {
    Build-OfflineRepo $RepoRoot $cfg (Join-Path $rk 'repo') $CacheDir
    $extras = Join-Path $rk 'extras'; New-Item -ItemType Directory -Force $extras | Out-Null
    $zip = Join-Path $CacheDir 'MapleMono-NF-unhinted.zip'
    if (-not (Test-Path $zip)) {
        & curl.exe -sSL --fail -o $zip 'https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-NF-unhinted.zip'
        if ($LASTEXITCODE -ne 0) { Remove-Item $zip -ErrorAction SilentlyContinue; Write-Note 'Maple Mono download failed (installer falls back to JetBrains Mono)' }
    }
    if (Test-Path $zip) { Copy-Item $zip $extras }
}

if (-not $OutDir) {
    Write-Step 'Flushing'
    Write-VolumeCache -DriveLetter $usb.TrimEnd(':')
}

$size = (Get-ChildItem -LiteralPath "$usb\" -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host ("  `e[38;2;235;227;210mDone.`e[0m  {0:N0} MB on the stick ({1} mode, {2} edition). Next:" -f ($size / 1MB), $cfg.INSTALL_MODE, $cfg.PROFILE)
if ($OutDir) { Write-Note "Stick contents are in $usb - copy them onto a FAT32 partition (any label) to boot." }
Write-Note '1. Firmware: UEFI boot ON, CSM/Legacy OFF, Secure Boot OFF, USB first in boot order.'
if ($cfg['INSTALL_UI'] -eq 'gui') {
    Write-Note '2. Boot the machine from the stick with a screen, keyboard and mouse attached.'
    Write-Note '3. The graphical installer opens by itself: answer the questions, press Install, then Restart.'
    Write-Note '   Leaving the stick in afterwards is fine: its boot loader switches itself off.'
    return
}
if ($cfg.PROFILE -eq 'desktop') {
    Write-Note '2. Plug in Ethernet (unless you set Wi-Fi) and the stick, power on. No screen needed.'
} else {
    Write-Note '2. Plug in the stick (and power), boot. The screen shows progress; nothing to type.'
}
Write-Note "3. Watch:   ssh root@$($cfg.HOSTNAME)-install.local   then: tail -f /run/archiso/bootmnt/sneh/install.log"
Write-Note "4. When it reboots (~10-25 min):  ssh $($cfg.USERNAME)@$($cfg.HOSTNAME).local$(if ($cfg.PROFILE -eq 'desktop' -or $cfg['VNC_ON_LAPTOP'] -eq 'yes') { "   ·   VNC: $($cfg.HOSTNAME).local:5900" })"
Write-Note '   Leaving the stick in is fine: sneh\installed.done stops a second install.'
Write-Note '   To reinstall: delete sneh\installed.done and put PASSWORD/VNC_PASSWORD back into sneh\sneh.conf.'
