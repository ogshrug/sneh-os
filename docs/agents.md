# Sneh for agents (copy of system/agents/AGENTS.md, which agents read on the machine)

You are running on **Sneh**, a small Arch Linux build for a low-power machine
(often a 4 GB DDR3 mini PC with **no monitor**). Humans reach it over SSH and VNC.
This file is the ground truth about the machine. Read it before changing the system.

## The machine at a glance

| What | Where / how |
|---|---|
| Base | Arch Linux (rolling), kernel `linux-zen` by default |
| Profile | `sne status --json` → `.profile` (`desktop` = headless mini PC, `laptop`) |
| Desktop | Hyprland 0.57+ (Lua config) on a virtual `HEADLESS-1` output when no monitor is plugged in |
| Remote desktop | wayvnc on :5900, password + RSA-AES auth, supervised by `sne vnc daemon` |
| Shell | fish + starship; tmux sessions `agents`, `agents-2`, … (`sne attach [NAME]`) |
| Workspaces | **1 = desk** (wallpaper, bar, dock: the human's desktop) · **2 = agents** (plain: your tmux sessions full-screen, side by side) |
| Memory | zram swap (zstd, ½ RAM), earlyoom kills runaway processes before the kernel OOM does |
| Disk | btrfs (`@`, `@home`, `@log`, `@pkg`), zstd:1 compression, snapper snapshots |
| Packages | `pacman` (official repos only). There is no AUR helper; do not install one unless asked |
| Network | NetworkManager (`nmcli`), mDNS via avahi (`<hostname>.local`), optional Tailscale |
| Sneh payload | `/usr/share/sneh` (read-only, replaced by `sne update`) |
| User settings | `~/.config/sneh/settings.env` (KEY=value; edit with `sne` where possible) |

## `sne` — use it first

`sne` is the system CLI. Every read command accepts `--json`; prefer that over parsing text.

```sh
sne status --json            # memory, zram, temps, disk, services, desktop/vnc, agents running
sne doctor                   # health checks with fix hints
sne desktop off|on           # stop the GUI to free ~250 MB for heavy work; start it again
sne vnc status --json        # VNC state; sne vnc password|resolution|bind
sne theme list --json        # sne theme set NAME · sne wallpaper pick|next|set IMAGE
sne win list                 # every window (JSON), hidden ones too · sne win switch|close|desktop
sne ws desk|agents           # the two workspaces
sne net status               # network devices (JSON)
sne keys --json              # every keyboard shortcut
sne spotify status --json    # Spotify Connect speaker + what is playing
sne snapshot create "before X"   # ALWAYS before risky system changes
sne snapshot list | diff N | undo N
sne update                   # pacman -Syu + payload + agents
sne logs session|vnc|hypr|install|firstboot|<systemd-unit>
```

## Seeing and driving the desktop (GUI automation)

You can operate the graphical desktop from SSH, with no extra setup:

```sh
sne gui screenshot             # → path to a PNG; read it to see the screen
SNEH_SHOT_SCALE=0.5 sne gui screenshot   # half-size image (cheaper to look at)
sne gui windows                # JSON: class, title, workspace, at [x,y], size [w,h]
sne gui active | monitors | cursor
sne gui launch foot            # start an app (detached)
sne gui focus class:firefox    # or title:REGEX / address:0x...
sne gui click 640 360          # move + left click; also right|middle|double
sne gui type "hello"           # type text into the focused window
sne gui key ctrl+l             # key combos: super+return, alt+f4, enter, esc, tab ...
sne gui workspace 2 | close | clipboard get|set TEXT | notify TITLE BODY
```

Coordinates are pixels of the screenshot at scale 1 (the headless output sits at 0,0).
Loop: screenshot → decide → act → screenshot again to verify. Windows tile
automatically (dwindle layout), so window positions change as you open more.

Keybinds a human uses (handy with `sne gui key`; `sne keys --list` has them all):
`super+1` desk / `super+2` agents, `super+a` agents (again: one more agent
terminal, side by side), `super+return` terminal, `super+space` launcher,
`alt+tab` switcher, `super+q` close (Spotify only hides), `super+shift+q` quit,
`super+d` show desktop, `super+f` fullscreen, `super+/` the shortcut menu.

Leave the desk (workspace 1) to the human unless asked; do GUI work there only
when the task needs it, and keep your terminals on the agents workspace.

Claude Code's status line is `sneh-claude-status`: it caches your plan usage
(`$XDG_RUNTIME_DIR/sneh/claude.json`) for the bar. Keep it if you change
`~/.claude/settings.json`.

## Rules for changing this machine

1. **Snapshot first**: `sne snapshot create "what you're about to do"` before
   installing or removing packages or editing `/etc`. pacman also snapshots
   automatically (snap-pac).
2. **RAM is scarce.** Check `sne status --json` → `.memory_mb.available`. Don't run
   several heavy builds at once. Prefer `pacman` binaries over compiling.
   If you need everything, `sne desktop off` and then `sne desktop on` afterwards.
3. **Don't edit managed files**, because `sne setup` and `sne update` overwrite them:
   `~/.config/{hypr/hyprland.lua,waybar,fuzzel,foot,mako,tmux/tmux.conf}` and
   anything under `/usr/share/sneh`. Put changes in:
   - `~/.config/hypr/user.lua` (Hyprland Lua, loaded last)
   - `~/.config/fish/user.fish`
   - `~/.config/sneh/settings.env` (then `sne setup`)
4. Hyprland is **0.57 with a Lua config** (`hl.config{}`, `hl.bind()`,
   `hl.dsp.*`). Old hyprlang syntax (`bind = ...`) does not work.
   `hyprctl dispatch` takes Lua: `hyprctl dispatch 'hl.dsp.focus({ workspace = 2 })'`.
5. Keep services you add small, and give them `MemoryMax=` when they could grow.
6. Never disable sshd, NetworkManager or avahi. They are the only way in.
7. sudo may ask for a password unless the owner enabled passwordless sudo at
   install. If it does, ask the human rather than guessing.

## Where things live

```
/usr/share/sneh/bin/        sne, sneh-session (Hyprland supervisor), sneh-autostart, sneh-firstboot
/usr/share/sneh/config/     pristine user configs (copied by sne setup)
/usr/share/sneh/templates/  colour templates; file name a__b → ~/.config/a/b
/usr/share/sneh/themes/     palettes: dusk (default) ink rose red-august teal aether olive blue-hour
~/.local/state/sneh/        session.log, wayvnc.log
~/.local/share/sneh/wallpapers/  wallpapers (mine/ = added with sne wallpaper set, firewatch/ = optional set)
/usr/share/sneh/wallpapers/      dusk-ridge.jpg, the default (WALLPAPER= empty in settings.env)
~/.cache/sneh/session.env   WAYLAND_DISPLAY / HYPRLAND_INSTANCE_SIGNATURE for SSH sessions
/var/log/sneh-install.log   how this machine was installed
```

## Troubleshooting

- Desktop dead: `sne desktop status`, `sne logs session`, then `sne desktop restart`.
  After 5 quick crashes the supervisor parks it (`~/.config/sneh/desktop.off`).
- VNC refuses: `sne logs vnc`. Clients need RSA-AES or VeNCrypt support (TigerVNC ≥ 1.13, RealVNC).
- Out of memory: `sne status --json`, `journalctl -u earlyoom -n 50`.
- Broke something: `sne snapshot list`, then `sne snapshot undo N`.
