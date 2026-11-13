# Installing Sneh

## What you need

- The target machine:
  - x86_64 with UEFI. Nearly everything since 2012 qualifies; legacy-BIOS-only machines are not supported.
  - 2 GB of RAM minimum (4 GB is comfortable; the graphical installer needs 3 GB) and 16 GB of disk minimum.
- A USB stick: at least 4 GB for **net** mode, 8 GB for **full** mode. Everything on it is erased.
- A Windows 10/11 PC with PowerShell 7.4+ (`winget install Microsoft.PowerShell`), or a Linux PC (see the end).
- For **net** mode, Ethernet on the target (or Wi-Fi details entered in the flasher).

## Choose an edition and an install mode

|  | desktop | laptop |
|---|---|---|
| Screen | a virtual screen over VNC (a real one works too) | the built-in screen |
| Audio, Bluetooth, battery | no | yes |
| Sleeps / locks | never | locks on idle, sleeps after 20 min |
| VNC | always on | optional |
| Xwayland (X11 apps) | off (`XWAYLAND=on` in settings to enable) | on |

| Mode | Stick size | Network during install | First boot |
|---|---|---|---|
| net | ≈1.2 GB | required | Claude Code was already installed during the install |
| full | ≈2.3 GB | not needed | Claude Code and the Maple font are fetched once the machine is online |

## Choose an install style

|  | auto (unattended) | gui (graphical installer) |
|---|---|---|
| Who answers the questions | you, in the flasher, before writing the stick | whoever sits at the machine |
| Screen and keyboard on the target | not needed | needed |
| Best for | headless mini PCs, many identical machines | laptops and desktops with a screen |
| Stick size | net ≈1.2 GB · full ≈2.3 GB | net ≈1.5 GB (carries the installer app) · full ≈3 GB (both editions, every app) |

The flasher asks first: `install style: auto | gui`. With **gui** it only asks for net/full and an optional SSH key; everything else is asked on the machine.

### The graphical installer

Boot the target from the stick. After the usual boot messages the installer opens full screen (a GTK app in the `cage` kiosk, installed from the stick, so it needs no network to start):

1. **Welcome**: a laptop/desktop with a screen, or a headless box (SSH + VNC).
2. **Language and region**: language, keyboard layout, time zone (guessed when online).
3. **Network**: connection status and a Wi-Fi picker. Net sticks need a connection; full sticks don't.
4. **Disk**: only internal disks of 16 GB or more are listed, never the stick. The whole disk is used.
5. **Account**: computer name, username, password; VNC password and screen size for headless boxes; for screens, whether to ask for the password at startup.
6. **Apps and agents**: the optional apps, Claude Code / opencode, theme, animations, and the optional Firewatch wallpapers.
7. **Summary**, then **Install** asks you to confirm erasing the disk (this replaces the 30-second countdown).
8. **Progress** with the full log under *Details*, then **Restart now**.

It runs the same install engine as the unattended stick, so the result is identical. The log is saved on the stick as `sneh/install.log` either way.

For testing or kiosks, a `sneh/answers.json` next to the installer pre-fills every field and clicks through by itself (see `tests/qemu-e2e.ps1 -Gui`).

## Flash on Windows

Get the code, then run the flasher from an **Administrator** terminal (right-click Start → **Terminal (Admin)**):

```powershell
winget install Git.Git                 # if you don't have Git
winget install Microsoft.PowerShell    # PowerShell 7.4+
git clone https://github.com/ogshrug/sneh-os.git
cd sneh-os
pwsh -File flasher\sneh-flash.ps1
```

The wizard asks for:

- **edition** (`desktop` or `laptop`) and **install mode** (`net` or `full`), as above
- **kernel**:
  - `linux-zen` (default; the lowest-latency desktop kernel)
  - `linux`
  - `linux-lts`
- **CPU mitigations off**: makes system calls 5–20 % faster on old Intel CPUs. Only say yes for a single-user box on a trusted network.
- **hostname, username, password**: the password unlocks sudo. **Passwordless sudo** lets agents install packages without asking.
- **timezone, locale, keymaps**: the time zone is taken from Windows; the others default to `en_US.UTF-8` and `us`.
- **Wi-Fi**: optional. It can reuse this PC's current network.
- **Tailscale auth key**: optional. The machine joins your tailnet on first boot.
- **SSH key**:
  - It defaults to `~\.ssh\id_ed25519.pub` and offers to generate one if missing.
  - Password SSH logins are off when you provide a key.
- **VNC password, resolution and bind address**:
  - `lan`
  - `localhost` (reach it through an SSH tunnel only)
  - `tailscale`
- **theme, animations, agents**
- **apps** (optional, comma-separated): `files` (Thunar, the default), `spotify` (the app + a Spotify Connect speaker), `vlc`, `mpv` (a lighter player), `firefox`, `images` (imv). The list is `system/packages/apps.txt`; `none` installs none. Later: `sne apps list | add NAME | remove NAME`.
- **firewatch** (`FIREWATCH=yes|no`, default no): also download 14 Firewatch fan-art wallpapers on first boot. The default wallpaper is Sneh's own *dusk ridge* either way; the picker can fetch the set later.
- **target disk**: `auto`, or part of the model or serial (see "Disk safety").

Then it:
1. Downloads the latest Arch ISO and checks its SHA-256.
2. Lists your USB drives and makes you type the disk number twice.
3. Writes the stick.

Useful switches:

```powershell
# save answers (secrets included) and reuse them later
pwsh -File flasher\sneh-flash.ps1 -SaveConfig my.conf
pwsh -File flasher\sneh-flash.ps1 -ConfigPath my.conf -Mode full -Edition desktop -Force

# build the stick contents into a folder instead of a USB disk (no admin rights needed with -IsoRoot)
pwsh -File flasher\sneh-flash.ps1 -ConfigPath my.conf -OutDir D:\stick
```

The full mode cache lives in `%LOCALAPPDATA%\sneh`, so a second full flash downloads nothing that is already there.

## First boot of the stick

1. In the target's firmware setup:
   - UEFI on
   - CSM/Legacy off
   - Secure Boot off
   - USB first in the boot order
2. Plug in the stick and power on. Nothing needs a screen or a keyboard.
3. To watch progress (optional):
   ```sh
   ssh root@<hostname>-install.local          # your SSH key, or the install password
   tail -f /run/archiso/bootmnt/sneh/install.log
   ```
4. The install takes 5–25 minutes depending on network and disk speed, then the machine reboots into Sneh.

Afterwards the stick contains `sneh/install.log`. If something went wrong, it also has `sneh/install.failed`, and you can read both on Windows.

## Disk safety

The installer only considers disks that are:
- internal
- non-removable
- not on USB
- at least 16 GB
- not the stick itself

How it picks one:
- `TARGET_DISK=auto` refuses to continue if there is more than one candidate.
- Otherwise, give part of the model or serial (`TARGET_DISK=Samsung`) or a device path. The value must match exactly one candidate.
- `ALLOW_WIPE=yes` must be present, and there is a 30-second countdown (in the log and on SSH) before anything is written.

## After the install

The installer:
- Writes `sneh/installed.done` to the stick.
- Replaces `PASSWORD`, `VNC_PASSWORD`, `WIFI_PSK` and `TAILSCALE_AUTHKEY` in `sneh/sneh.conf` with `<removed>`.
- Renames the stick's `EFI/BOOT/*.EFI` files to `*.sneh-disabled`. Firmware that always boots USB first then falls through to the installed system.

To use the stick for rescue:
1. Rename the `.EFI` files back.
2. Boot from the stick. It recognises the finished install and starts SSH instead.
3. Connect with `ssh root@<hostname>-rescue.local` (key only).
4. Mount and chroot into the installed system (`lsblk` shows the disk; on NVMe use `/dev/nvme0n1p2` and `/dev/nvme0n1p1`):
   ```sh
   mount -o subvol=@ /dev/sda2 /mnt && mount /dev/sda1 /mnt/boot && arch-chroot /mnt
   ```

To reinstall:
1. Rename the `.EFI` files back.
2. Delete `installed.done`.
3. Restore the passwords in `sneh.conf`.

Or re-flash the stick.

## Connect

```sh
ssh <user>@<hostname>.local
```

VNC: `<hostname>.local:5900`, with your username and the VNC password. Use TigerVNC ≥ 1.13 or RealVNC Viewer (RSA-AES auth).

When VNC is bound to localhost:

```sh
ssh -L 5900:localhost:5900 <user>@<hostname>.local
# then connect the viewer to localhost:5900
```

## Flash on Linux

```sh
sudo ./flasher/sneh-flash.sh -c my.conf -d /dev/sdX             # net
sudo ./flasher/sneh-flash.sh -c my.conf -d /dev/sdX -m full     # full, Arch host only (uses pacman -Sw)
```

Write `my.conf` from `flasher/sneh.conf.example`.
