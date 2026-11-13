# Troubleshooting

## During the install

| Symptom | What to do |
|---|---|
| The stick doesn't boot | In firmware setup: UEFI on, CSM/Legacy **off**, Secure Boot **off**, USB first in the boot order. Legacy-BIOS-only machines can't boot the stick. |
| `ssh root@<host>-install.local` doesn't resolve | Find the IP in your router's DHCP list (hostname `<host>-install`), or wait: SSH starts about 30 s after the live system boots. |
| The install stopped | Read `sneh/install.log` and `sneh/install.failed` on the stick from any PC. The live system stays up, so you can SSH in and look. |
| "several internal disks found" | Set `TARGET_DISK=` to part of the model or serial, or `/dev/sdX`. The log lists the candidates. |
| "no internet after 90s" | Net mode needs a network. Plug in Ethernet, fix the Wi-Fi details, or flash in **full** mode. |
| "pacstrap failed 3 times" | Usually a mirror problem. Re-run the install: delete `install.failed`, and the stick still holds your config. |

## After the install

| Symptom | What to do |
|---|---|
| Can't find `<host>.local` | Windows resolves mDNS on recent builds. Otherwise use the IP from `sne status` (over the router) or set up Tailscale. |
| VNC says authentication failed or isn't supported | Use TigerVNC ≥ 1.13 or RealVNC Viewer (RSA-AES). The username is your Linux user. `sne vnc password` resets the password. |
| VNC shows a black screen or the connection is refused | `sne desktop status`, `sne logs session`, `sne logs vnc`. If the desktop crashed five times it parks itself: fix the cause, then `sne desktop on`. |
| The headless mini PC's desktop won't start at all | Some iGPUs refuse to start without a display attached. Plug in an HDMI dummy plug; Sneh will use it as the VNC screen. |
| Claude Code / opencode crash with "SSE4.2" | The CPU is too old for these Bun-based binaries. `sne doctor` confirms it. |
| Claude Code missing after a full (offline) install | It installs on the first boot that has network. To force it: `curl -fsSL https://claude.ai/install.sh \| bash` |
| The wallpaper is the plain theme one, not dusk ridge | `sne wallpaper reset`. The depth clock needs `python-pillow`. |
| No Firewatch wallpapers | They're optional: pick "get the Firewatch set" in the picker (`SUPER+SHIFT+W`) or run `sne wallpaper fetch`. |
| The mouse wheel doesn't scroll menus (keys, network, `ALT+TAB`, wallpapers) | fuzzel 1.15.0 needs the local fix: `sne fix fuzzel` (needs internet for about a minute). `pacman -Q fuzzel` should say `1.15.0-2.1`. |
| The wallpaper doesn't change / the clock stopped | `sne wallpaper next` restarts the clock loop; `pgrep -af "wallpaper daemon"` should show it. |
| The bar or dock is missing on the desk (or showing on agents) | `sne setup` resets it; `sne ws sync` re-applies the rule for the current workspace. |
| The bar says "Claude" without a percentage | The usage appears after Claude Code answers once (Pro/Max plans). `~/.claude/settings.json` must keep `statusLine` → `sneh-claude-status`. |
| Spotify: no sound | Sound comes out of the machine's own HDMI/headphone output, never over VNC. The Connect speaker (`sne spotify on`) needs Premium. Log in to the app with the QR code: there is no browser for the "Log in" button. |
| Out of memory | `sne status --json`, then `journalctl -u earlyoom -n 50`. Free the desktop's share with `sne desktop off`. |
| Something broke after a change | `sne snapshot list`, then `sne snapshot diff N`, then `sne snapshot undo N`. |

## Rescue

1. Rename `EFI/BOOT/*.sneh-disabled` on the stick back to `.EFI`.
2. Boot from the stick. It starts a rescue system instead of reinstalling, reachable with `ssh root@<host>-rescue.local` (your key).
3. Mount and chroot into the installed system:
   ```sh
   mount -o subvol=@ /dev/sda2 /mnt && mount /dev/sda1 /mnt/boot
   arch-chroot /mnt
   ```
