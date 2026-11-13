#Requires -Version 7.4
<#
.SYNOPSIS
  End-to-end test: flash -> boot the stick in a UEFI VM -> unattended install -> reboot -> verify.

.DESCRIPTION
  Needs: QEMU for Windows (C:\Program Files\qemu), WSL2 (any distro with mkfs.vfat, used to
  build the FAT32 stick image), Windows OpenSSH. No admin rights needed.
  The VM mimics the target: UEFI, 4 GB RAM, 2 cores, one blank internal disk, stick on USB.

  Phases (each can be re-run):  -Phase stick | install | verify | all
#>
param(
    [ValidateSet('all', 'stick', 'install', 'verify', 'boot')][string]$Phase = 'all',
    [ValidateSet('net', 'full')][string]$Mode = 'net',
    [ValidateSet('desktop', 'laptop')][string]$Edition = 'desktop',
    [string]$Iso,
    [int]$TimeoutMin = 60,
    [ValidateSet('whpx', 'tcg')][string]$Accel = 'whpx',
    [switch]$NoStick,
    [switch]$Offline,     # cut the VM off from the internet (proves full mode needs no network)
    [string]$BootCpu = '',  # CPU for the post-install boot (needs SSE4.2 for Claude Code)
    [switch]$KeepVm,        # leave the VM running after the checks (default: shut it down)
    [switch]$Gui            # graphical-installer stick, driven by an answers file
)
$ErrorActionPreference = 'Stop'
$Root  = Split-Path -Parent $PSScriptRoot
$Work  = Join-Path $Root '.work\e2e'
$Qemu  = 'C:\Program Files\qemu'
$Key   = Join-Path $Work 'testkey'
$Img   = Join-Path $Work 'stick.img'
$Disk  = Join-Path $Work 'target.qcow2'
$Vars  = Join-Path $Work 'vars.fd'
$SshOpts = @('-i', $Key, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-p', '2222')
New-Item -ItemType Directory -Force $Work | Out-Null
# Windows OpenSSH refuses keys with inherited ACLs; Git's ssh doesn't care.
$SshExe = @('C:\Program Files\Git\usr\bin\ssh.exe', (Get-Command ssh -ErrorAction SilentlyContinue).Source) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$ScpExe = Join-Path (Split-Path $SshExe) 'scp.exe'

function Log($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" }
function WslPath([string]$p) { '/mnt/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/') }

function Build-Stick {
    if (-not $Iso) { $Iso = Get-ChildItem (Join-Path $Root '.work\cache') -Filter 'archlinux-*-x86_64.iso' | Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName }
    if (-not $Iso) { throw 'no ISO: pass -Iso or put one in .work\cache' }
    if (-not (Test-Path $Key)) { & ssh-keygen -q -t ed25519 -N '' -f $Key -C sneh-e2e | Out-Null }
    $conf = Join-Path $Work 'test.conf'
    @"
PROFILE=$Edition
INSTALL_MODE=$Mode
KERNEL=linux-zen
PERF_MITIGATIONS=on
FIRMWARE=auto
HOSTNAME=sne-e2e
USERNAME=tester
PASSWORD=testpass123
SUDO_NOPASSWD=yes
TIMEZONE=UTC
LOCALE=en_US.UTF-8
KEYMAP=us
XKB_LAYOUT=us
WIFI_SSID=
WIFI_PSK=
WIFI_HIDDEN=no
TAILSCALE_AUTHKEY=
SSH_PUBKEY=$((Get-Content "$Key.pub" -Raw).Trim())
SSH_PASSWORD_AUTH=no
VNC_ON_LAPTOP=yes
LOCK_ON_LOGIN=no
VNC_PASSWORD=vncpass123
VNC_RESOLUTION=1280x800
VNC_BIND=lan
THEME=dusk
ANIMATIONS=on
BROWSER=none
AGENTS=claude,opencode
TARGET_DISK=auto
REPO_URL=
ALLOW_WIPE=yes
INSTALL_UI=$(if ($Gui) { 'gui' } else { 'auto' })
"@ | Set-Content -LiteralPath $conf -NoNewline

    Log 'extracting ISO (WSL)'
    $isoRoot = Join-Path $Work 'isoroot'
    if (-not (Test-Path (Join-Path $isoRoot 'EFI'))) {
        wsl -u root -e sh -c "set -e; mkdir -p /tmp/rkiso; mount -o loop,ro '$(WslPath $Iso)' /tmp/rkiso; rm -rf '$(WslPath $isoRoot)'; mkdir -p '$(WslPath $isoRoot)'; cp -r /tmp/rkiso/. '$(WslPath $isoRoot)/'; umount /tmp/rkiso"
        if ($LASTEXITCODE) { throw 'ISO extract failed' }
    }
    Log 'running the flasher (-OutDir)'
    $out = Join-Path $Work 'stick'
    Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
    & pwsh -NoProfile -File (Join-Path $Root 'flasher\sneh-flash.ps1') -ConfigPath $conf -IsoRoot $isoRoot -OutDir $out -Force
    if ($LASTEXITCODE) { throw 'flasher failed' }
    if ($Gui) {   # the setup app reads this and clicks through by itself
        @{ profile = $Edition; timezone = 'UTC'; hostname = 'sne-e2e'; username = 'tester'; password = 'testpass123';
           vnc_password = 'vncpass123'; confirm = $true; reboot = $false } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $out 'sneh\answers.json')
    }

    Log 'building FAT32 stick image (WSL)'
    $sizeMB = if ($Mode -eq 'full') { 4096 } else { 2560 }
    $label = (Get-Content (Join-Path $out 'FAT-LABEL.txt')).Trim()
    # same layout the Windows flasher writes: MBR, one bootable FAT32 (0x0c) partition at 1 MiB
    $sh = @"
set -e
rm -f /tmp/sne.img; truncate -s ${sizeMB}M /tmp/sne.img
printf 'label: dos
start=2048, type=c, bootable
' | sfdisk -q /tmp/sne.img
dev=`$(losetup -f --show -o 1048576 /tmp/sne.img)
mkfs.vfat -F32 -n '$label' `$dev >/dev/null
mkdir -p /tmp/rkm; mount `$dev /tmp/rkm
cp -r '$(WslPath $out)/.' /tmp/rkm/; rm -f /tmp/rkm/FAT-LABEL.txt; sync
umount /tmp/rkm; losetup -d `$dev
cp /tmp/sne.img '$(WslPath $Img)'; rm /tmp/sne.img
"@
    wsl -u root -e sh -c ($sh -replace "`r", '')
    if ($LASTEXITCODE) { throw 'image build failed' }
    Log "stick image: $Img"
}

function Start-Vm([switch]$Fresh, [string]$Cpu = '') {
    if ($Fresh -or -not (Test-Path $Disk)) {
        Remove-Item $Disk, $Vars -ErrorAction SilentlyContinue
        & "$Qemu\qemu-img.exe" create -q -f qcow2 $Disk 32G
        Copy-Item "$Qemu\share\edk2-i386-vars.fd" $Vars
    }
    # Start-Process does not quote array elements: keep every path free of spaces
    $Code = Join-Path $Work 'code.fd'
    if (-not (Test-Path $Code)) { Copy-Item "$Qemu\share\edk2-x86_64-code.fd" $Code }
    $qargs = @(
        '-accel', $(if ($Accel -eq 'whpx') { 'whpx,kernel-irqchip=off' } else { 'tcg,thread=multi' }), '-machine', 'q35', '-m', '4096', '-smp', '2',
        '-drive', "if=pflash,format=raw,readonly=on,file=$Code",
        '-drive', "if=pflash,format=raw,file=$Vars",
        '-device', 'qemu-xhci'
    )
    if ($Cpu) { $qargs += '-cpu', $Cpu }
    if (-not $NoStick) { $qargs += '-drive', "if=none,id=stick,format=raw,file=$Img", '-device', 'usb-storage,drive=stick,removable=on' }
    $qargs += @(
        '-drive', "if=virtio,format=qcow2,file=$Disk",
        '-nic', "user,model=virtio-net-pci$(if ($Offline) { ',restrict=on' }),hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:5901-:5900",
        '-vga', 'virtio', '-display', 'none',
        '-monitor', 'tcp:127.0.0.1:4444,server,nowait',
        '-serial', "file:$((Join-Path $Work 'serial.log') -replace '\\','/')"
    )
    Log 'starting VM'
    $p = Start-Process -FilePath "$Qemu\qemu-system-x86_64.exe" -ArgumentList $qargs -PassThru -WindowStyle Hidden `
        -RedirectStandardError (Join-Path $Work 'qemu.err')
    Start-Sleep 3
    if ($p.HasExited) { throw "qemu exited: $(Get-Content (Join-Path $Work 'qemu.err') -Raw)" }
    return $p
}

function Screendump([string]$name) {
    try {
        $c = [Net.Sockets.TcpClient]::new('127.0.0.1', 4444); $s = $c.GetStream()
        $w = [IO.StreamWriter]::new($s); $w.AutoFlush = $true
        $f = (Join-Path $Work "$name.ppm") -replace '\\', '/'
        $w.WriteLine("screendump $f"); Start-Sleep 1; $c.Close()
    } catch { }
}

function Invoke-VmSsh([string]$user, [string]$cmd) {
    $o = & $SshExe @SshOpts "$user@127.0.0.1" $cmd 2>$null
    return @{ Code = $LASTEXITCODE; Out = ($o -join "`n") }
}

$script:whpxRetries = 0; $script:shot = 0
function Wait-Install($vm) {
    $deadline = (Get-Date).AddMinutes($TimeoutMin); $last = ''
    while ((Get-Date) -lt $deadline) {
        if ($vm.HasExited) { throw 'VM exited during install' }
        # WHPX on some AMD hosts randomly pauses the guest ("Unexpected VP exit code 4").
        # If that happens before the installer touched the disk, just power-cycle and retry.
        if ((Get-Content (Join-Path $Work 'qemu.err') -Raw -ErrorAction SilentlyContinue) -match 'Unexpected VP exit') {
            # the glitch often hits the installer's own reboot: if the stick says it's done, it's done
            Stop-Process -Id $vm.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 2
            $done = wsl -u root -e sh -c "mkdir -p /tmp/rkchk; mount -o loop,ro,offset=1048576 '$(WslPath $Img)' /tmp/rkchk && ls /tmp/rkchk/sneh; umount /tmp/rkchk" 2>$null
            if (($done -join ' ') -match 'installed\.done') { Log 'install finished (VM glitched on its reboot)'; return }
            if ($script:whpxRetries++ -ge 3) { throw 'WHPX keeps crashing the VM' }
            Log "WHPX glitch - power-cycling the VM (retry $script:whpxRetries)"
            Stop-Process -Id $vm.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 2
            $vm = Start-Vm -Fresh; $last = ''; continue
        }
        if ($Gui) { Screendump ('gui-{0:D2}' -f $script:shot++) }
        $r = Invoke-VmSsh 'root' 'tail -n 3 /run/archiso/bootmnt/sneh/install.log 2>/dev/null; ls /run/archiso/bootmnt/sneh/ 2>/dev/null | grep -E "installed.done|install.failed"'
        if ($r.Code -eq 0 -and $r.Out -ne $last) { $last = $r.Out; Log ("live: " + ($r.Out -split "`n" | Select-Object -Last 2) -join ' | ') }
        if ($r.Out -match 'install.failed') {
            Invoke-VmSsh 'root' 'cat /run/archiso/bootmnt/sneh/install.log' | ForEach-Object { $_.Out } | Set-Content (Join-Path $Work 'install.log')
            throw "install FAILED - see $Work\install.log"
        }
        if ($r.Out -match 'installed.done') {
            (Invoke-VmSsh 'root' 'cat /run/archiso/bootmnt/sneh/install.log').Out | Set-Content (Join-Path $Work 'install.log')
            Log 'install finished; waiting for reboot'; return
        }
        Start-Sleep 15
    }
    Screendump 'timeout'
    throw "install did not finish in $TimeoutMin min"
}

# WHPX can die on a guest warm reset; power-cycle instead (the installer's own
# reboot is irrelevant here - on real hardware it is a plain reset).
function Restart-Cold($vm) {
    Start-Sleep 25   # let scrub + sync + EFI-disable finish (installer reboots after 10 s)
    Stop-Process -Id $vm.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    $script:vm = Start-Vm -Cpu $BootCpu
}

function Test-Installed {
    $deadline = (Get-Date).AddMinutes(8)
    do { Start-Sleep 10; $r = Invoke-VmSsh 'tester' 'echo up' } while ($r.Out -ne 'up' -and (Get-Date) -lt $deadline)
    if ($r.Out -ne 'up') { Screendump 'noboot'; throw 'installed system not reachable over SSH as tester' }
    Log 'installed system is up over SSH'
    Start-Sleep 25   # let the desktop + firstboot settle
    $checks = [ordered]@{
        'sne status --json'     = 'sne status --json'
        'desktop running'      = 'sne desktop status --json'
        'vnc running'          = 'sne vnc status --json'
        'zram active'          = 'cat /proc/swaps'
        'screenshot'           = 'f=$(sne gui screenshot) && file "$f" && cp "$f" /tmp/e2e-shot.png'
        'gui windows'          = 'sne gui launch footclient && sleep 3 && sne gui windows'
        'type/key'             = 'sne gui type "echo sneh-ok" && sne gui key enter && sleep 1 && echo typed'
        'theme switch'         = 'sne theme set teal && sne theme current && sne theme set dusk'
        'default wallpaper'    = 'readlink -f ~/.config/sneh/wallpaper.current | grep -x /usr/share/sneh/wallpapers/dusk-ridge.jpg && test ! -d ~/.local/share/sneh/wallpapers/firewatch'
        'fuzzel wheel fix'     = 'pacman -Q fuzzel | grep -E "1\.15\.0-[0-9]+\.1$|fuzzel 1\.(1[6-9]|[2-9][0-9])\."'
        'agents'               = 'sne agents status --json'
        'doctor'               = 'sne doctor'
        'disk usage'           = 'df -h / /boot | tail -2; sudo btrfs filesystem du -s / 2>/dev/null | tail -1'
        'idle memory'          = 'free -m'
        'boot time'            = 'systemd-analyze 2>/dev/null | head -1'
        'failed units'         = 'systemctl --failed --no-legend'
        'session log'          = 'tail -n 15 ~/.local/state/sneh/session.log'
    }
    $report = foreach ($k in $checks.Keys) {
        $r = Invoke-VmSsh 'tester' $checks[$k]
        $mark = if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }
        Log "$mark  $k"
        "### $mark $k (exit $($r.Code))`n$($r.Out)`n"
    }
    $report | Set-Content (Join-Path $Work 'report.md')
    & $ScpExe -i $Key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 2222 tester@127.0.0.1:/tmp/e2e-shot.png (Join-Path $Work 'desktop.png') 2>$null
    Log "report: $Work\report.md  screenshot: $Work\desktop.png"
}

switch ($Phase) {
    'stick'   { Build-Stick }
    'install' { $vm = Start-Vm -Fresh; Wait-Install $vm; Restart-Cold $vm; Test-Installed }
    'verify'  { Test-Installed }
    'boot'    { $vm = Start-Vm -Cpu $BootCpu; Test-Installed }
    'all'     { Build-Stick; $vm = Start-Vm -Fresh; Wait-Install $vm; Restart-Cold $vm; Test-Installed }
}
# don't leave a 4 GB VM running in the background
if (-not $KeepVm -and $script:vm) { Stop-Process -Id $script:vm.Id -Force -ErrorAction SilentlyContinue; Log 'VM stopped' }
