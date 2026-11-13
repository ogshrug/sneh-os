# How Sneh is built

## The stick

The stick does not use a custom ISO. The flasher:
1. Creates one MBR partition with FAT32.
2. Copies the contents of the official Arch ISO onto it.
3. Appends to every UEFI boot entry: `copytoram=n script=/run/archiso/bootmnt/sneh/install.sh`.

That works with the stock ISO because of two of its features:
- archiso finds its boot medium by searching partitions for `/boot/<uuid>.uuid`, so a FAT copy boots fine. That is also why the stick must have a partition table.
- The live system's `~/.automated_script.sh` runs whatever `script=` points to, on tty1, as root.

`copytoram=n` keeps the stick mounted at `/run/archiso/bootmnt`. The installer remounts it read-write to write the log, the markers and the scrubbed config.

```
stick/
  EFI/ loader/ arch/ boot/        ← the Arch ISO, untouched except boot entry options
  sneh/
    install.sh lib/*.sh           ← installer
    system/                       ← OS payload (→ /usr/share/sneh)
    sneh.conf                  ← your settings (KEY=value, parsed, never sourced)
    repo/  extras/                ← full mode only: packages + .sig, trimmed core.db/extra.db, font zip
    install.log  installed.done   ← written by the installer
```

## Installer stages (`installer/`)

| File | Stage |
|---|---|
| `install.sh` | guard (`installed.done` → rescue mode), logging to the stick, ERR trap |
| `lib/common.sh` | config parser and validation, `die`/`step`/`note` |
| `lib/net.sh` | live SSH + mDNS (`<host>-install.local`), Ethernet/Wi-Fi bring-up, keyring/mirrors |
| `lib/disk.sh` | candidate filtering, 30 s countdown, GPT (512 MB ESP + btrfs `@ @home @log @pkg`) |
| `lib/base.sh` | package selection (profile, kernel, CPU microcode, **firmware by PCI/USB vendor ID**), NoExtract, single-image initramfs preset, pacstrap (net or offline repo) |
| `lib/chroot.sh` | locale and time, payload, user (bash login shell → fish when interactive), sshd, NetworkManager, systemd-boot, services, snapper, fonts, `sne setup`, Claude Code |
| `lib/finish.sh` | boot order, `installed.done`, scrub secrets, disable the stick's EFI, reboot |

## Offline (full) mode

`flasher/lib/offline-repo.ps1` does the following on Windows, with no pacman:
1. Downloads `core.db` and `extra.db`.
2. Parses every package's `desc` file with .NET's tar reader.
3. Resolves the dependency closure the way pacman does: core before extra, literal names before providers, and virtual names satisfied by already-selected packages.
4. Downloads every package and its detached `.sig` in parallel, then verifies each SHA-256.
5. Writes **trimmed** databases containing only the bundled packages, so pacman on the target can never pick a package that isn't on the stick.

Package names with an epoch (`1:2.0`) contain `:`, which neither FAT nor NTFS can store, so they're saved as `%3A`. The installer symlinks them back to their real names.

## The running system

```
greetd (autologin, tty1)
 └─ sneh-session        supervises Hyprland: restart on exit, park after 5 fast crashes, honour `sne desktop off`
     └─ start-hyprland → Hyprland (Lua config)
         └─ sneh-autostart
             ├─ no real monitor? → hyprctl output create headless
             ├─ writes ~/.cache/sneh/session.env (lets SSH sessions find the desktop)
             ├─ sne wallpaper daemon → swaybg   (depth clock: re-rendered once a minute, faded in)
             ├─ waybar (one process, two bars: header + dock) · mako · foot --server · ydotoold
             ├─ sne vnc daemon → wayvnc (supervised, flock'd, config regenerated each start)
             └─ laptop: hypridle (+ hyprlock)
 Hyprland event "workspace.active" → sne ws sync
             bar + dock shown on workspace 1 (desk), hidden on 2 (agents);
             arriving on an empty agents workspace opens the agents tmux
```

### Workspaces

Two only. **1 · desk** is the everyday desktop: the wallpaper, the header bar, the dock
(pinned apps + a tab per open window), gaps, rounding and animations. **2 · agents** is
plain (Hyprland workspace rule: no gaps, no rounding, 1px border): tmux sessions
`agents`, `agents-2`, … fill the screen side by side (`SUPER+A` adds one). The bar
and dock are toggled with waybar's SIGUSR1; `$XDG_RUNTIME_DIR/sneh/bar.hidden`
records the state and any waybar reload resets it.

### The depth-clock wallpaper

`sneh-wallpaper prep` (Pillow) crops the picture to the screen, finds the dark
layer that touches the bottom edge (trees, towers, cliffs: Otsu threshold on the lower
two thirds, flood-filled from the bottom row) and saves it as a cut-out, then picks
text colours from the sky. `render` draws the clock *between* the picture and the
cut-out, adds the frame in the bar colour and writes a JPEG to `$XDG_RUNTIME_DIR`.
`sne wallpaper daemon` runs it every minute and starts a new swaybg on top of the old
one; a Hyprland layer rule fades it in. Between renders only a sleeping bash is
resident. The default picture is *dusk ridge* (`system/wallpapers`, drawn by a Pillow
script, so it ships with Sneh). Your own live in `~/.local/share/sneh/wallpapers`; the
optional Firewatch set from wallhaven.cc is downloaded there only on request, never
shipped on the stick.

### The bar's data

- Claude plan usage: Claude Code's status line runs `sneh-claude-status`, which
  caches the `rate_limits` it receives in `$XDG_RUNTIME_DIR/sneh/claude.json`;
  `sne bar agents` (bar) and `sne bar tmux` (agents workspace) read it.
- Player: waybar's MPRIS module (Spotify app or the spotifyd Connect speaker).
- Weather: wttr.in every 30 min (`WEATHER_LOCATION=` in settings.env).

Theming: each file in `system/templates/` is named after its destination (`waybar__colors.css` → `~/.config/waybar/colors.css`). `sne theme set` substitutes `{{key}}` from `themes/<name>/palette.env`, plus `palette.override` if `sne wallpaper set` produced one. It then renders the theme's SVG wallpaper with `rsvg-convert` (used until a picture is chosen) and reloads Hyprland, Waybar, mako, tmux and swaybg.

## Why these choices

- **Hyprland on a headless output, not Xvnc.** It's one compositor for both editions. wayvnc captures the real desktop, and agents can screenshot and drive it through Wayland protocols.
- **bash login shell.** `ssh host 'cmd'`, scp, rsync and agent tools all expect POSIX syntax. fish only starts for interactive terminals.
- **No AUR helper.** Everything comes from the official repos. The exceptions are downloads into your home: Maple Mono (four TTF files, about 4 MB instead of a 200 MB font package), the optional Firewatch wallpapers, Claude Code and opencode (their official installers, so they update themselves), and the Spotify client (fetched by the official-repo `spotify-launcher`). One package is rebuilt locally: fuzzel 1.15.0 ignores the mouse wheel, so the installer builds it with the two-line upstream fix (`system/patches/fuzzel`, version `1.15.0-2.1`), then removes the build tools. The next Arch release of fuzzel carries the fix and replaces it.
- **Memory.** The desktop idles at about 0.7 GB on a 4 GB Haswell mini PC: the GTK accessibility bus, dconf and the desktop portals are switched off (nothing headless uses them), waybar's two bars share one process, and the clock wallpaper has no resident renderer.
- **Snapshots, but no timeline.** snap-pac snapshots each pacman transaction, with at most 8 kept. Timeline snapshots on a small disk are mostly noise.
