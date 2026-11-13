# `sne` — the Sneh CLI

`sne` is the one tool for operating the machine, for you and for agents.
Every read command accepts `--json` (or `-j`). Write commands are idempotent and print `✓ …`.
With `--json`, they print `{"ok":true,"message":…}` instead. Errors print `{"ok":false,"error":…}` and exit 1.

## Status and health

| Command | What it does |
|---|---|
| `sne status [--json]` | host, profile, kernel, uptime, load, memory/swap/zram, temperature, disk, IPs, core services, desktop/VNC state, running agents, theme |
| `sne doctor` | checks network, sshd, avahi, zram, earlyoom, desktop, wayvnc, input group, claude/opencode, fonts and CPU SSE4.2, with fix hints |
| `sne logs session\|vnc\|hypr\|install\|firstboot\|<unit> [N]` | the last N lines of the relevant log |
| `sne version` | Sneh version |

## Desktop and remote access

| Command | What it does |
|---|---|
| `sne desktop status\|on\|off\|restart` | `off` stops Hyprland and frees ≈250 MB; the session supervisor waits until `on` |
| `sne vnc status\|on\|off\|restart` | wayvnc state; `off` persists across reboots |
| `sne vnc password [PW]` | change the VNC password (asks if omitted) |
| `sne vnc resolution 1920x1080` | resize the virtual screen and re-render the wallpaper |
| `sne vnc bind lan\|localhost\|tailscale` | which address VNC listens on |
| `sne perf vnc\|normal` | animations off/on (off feels best over slow links) |

## GUI automation

These commands work over SSH. Coordinates are screenshot pixels at scale 1.

| Command | What it does |
|---|---|
| `sne gui screenshot [FILE]` | PNG of the active output. `RK_SHOT_SCALE=0.5` gives a half-size image |
| `sne gui monitors\|windows\|active\|cursor` | JSON from Hyprland |
| `sne gui launch CMD [ARGS]` | start an app, detached |
| `sne gui focus class:REGEX` | also `title:REGEX` or `address:0x…`; a bare word means class |
| `sne gui move X Y` | move the pointer |
| `sne gui click [X Y] [left\|right\|middle\|double]` | move (optionally) and click |
| `sne gui scroll [N]` | wheel: N > 0 scrolls down, N < 0 up (default 3) |
| `sne gui type TEXT` | type into the focused window |
| `sne gui key COMBO` | e.g. `super+return`, `ctrl+shift+t`, `enter`, `esc`, `f5` |
| `sne gui workspace N`, `sne gui close` | workspaces and windows |
| `sne gui clipboard get\|set TEXT`, `sne gui notify TITLE [BODY]` | clipboard and notifications |

## Look

| Command | What it does |
|---|---|
| `sne theme list\|current\|set NAME` | the themes are `ink`, `rose`, `red-august`, `teal`, `aether`, `olive` and `blue-hour` |
| `sne wallpaper pick` | picker with thumbnails (`SUPER+SHIFT+W`) |
| `sne wallpaper next\|prev` | cycle through dusk ridge and `~/.local/share/sneh/wallpapers` (`SUPER+ALT+W`) |
| `sne wallpaper fetch\|unfetch` | download (or remove) the optional Firewatch set, 14 pictures from wallhaven.cc; the picker offers it too |
| `sne wallpaper set IMAGE` | use your own picture; the accent colour is taken from it (matugen) |
| `sne wallpaper list [--json]` | every wallpaper, the current one marked |
| `sne wallpaper clock on\|off` | the depth clock: the time is drawn *behind* the scenery (trees, towers) |
| `sne wallpaper reset` | back to *dusk ridge*, Sneh's own wallpaper |
| `sne keys [--list]` | the quick menu of every shortcut (`SUPER+/`); Enter runs the entry |
| `sne apps list\|add NAME\|remove NAME` | optional apps: `files` (Thunar) `spotify` `vlc` `mpv` `firefox` `images`; the dock hides what isn't installed |
| `sne spotify on\|off\|status` | Spotify Connect speaker (spotifyd): pick this PC in the Spotify app; the bar shows and controls what plays |
| `sne fonts [ZIP]` | (re)install Maple Mono NF (4 styles, about 4 MB) |
| `sne setup` | rebuild `~/.config` from `/usr/share/sneh` and keep your `user.*` files |

## Maintenance

| Command | What it does |
|---|---|
| `sne update` | pull the Sneh payload from `REPO_URL` (if set), run `pacman -Syu`, update Claude Code, clear the package cache, re-render |
| `sne fix fuzzel` | rebuild fuzzel 1.15.0 with the upstream mouse-wheel fix (install, first boot and `sne update` do this; build tools are removed after) |
| `sne snapshot list\|create [DESC]\|diff N\|undo N` | btrfs snapshots via snapper (pacman also snapshots automatically) |
| `sne agents status\|link` | agent CLI versions; re-link `AGENTS.md` and skills |
| `sne attach [NAME]` | open or attach the tmux session (default `agents`) |

## Settings file

`~/.config/sneh/settings.env` holds plain `KEY=value` lines. Edit it, then run `sne setup`.

| Key | Values |
|---|---|
| `PROFILE` | `desktop` \| `laptop` |
| `THEME` | a theme name |
| `ANIMATIONS` | `on` \| `off` |
| `XWAYLAND` | `on` \| `off` |
| `VNC_ENABLED` | `yes` \| `no` |
| `VNC_RESOLUTION` | `WxH` |
| `VNC_BIND` | `lan` \| `localhost` \| `tailscale` |
| `XKB_LAYOUT` | an xkb layout |
| `AGENTS` | the agents to install |
| `LOCK_ON_LOGIN` | `yes` \| `no` |
| `REPO_URL` | where `sne update` pulls the payload from |
| `WALLPAPER` | path to the current wallpaper |
| `CLOCK` | `on` \| `off`: the depth clock on the wallpaper |
| `APPS` | the optional apps chosen at install (`sne apps` keeps it up to date) |
| `SPOTIFY` | `on` \| `off`: the Spotify Connect speaker |
| `TERMINALS_ON_LOGIN` | `yes` \| `no`: open a terminal and the agents terminal on workspace 1 |
| `WEATHER_LOCATION` | a city for the bar's weather (empty = guess from your IP via wttr.in) |
