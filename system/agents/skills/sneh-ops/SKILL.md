---
name: sneh-ops
description: Safe system administration on a Sneh (Arch Linux) machine - installing packages, editing config, services, updates, recovering from mistakes, staying within a 4 GB RAM budget. Use before changing anything outside the current project directory.
---

# Operating Sneh safely

- State: `sne status --json` (memory, zram, disk, services), `sne doctor`.
- Before system changes: `sne snapshot create "<reason>"`.
- Packages: `sudo pacman -S --needed <pkg>` (official repos). Search: `pacman -Ss <term>`.
  Check what is installed: `pacman -Qe`. Remove with deps: `sudo pacman -Rns <pkg>`.
- Services: `systemctl status|restart <unit>`, user units: `systemctl --user ...`; logs: `sne logs <unit>`.
- Memory budget: if `.memory_mb.available` < 600, avoid parallel builds (`-j1`), or `sne desktop off`.
- Config you may edit: `~/.config/hypr/user.lua` (Lua, Hyprland 0.57 API), `~/.config/fish/user.fish`,
  `~/.config/sneh/settings.env` + `sne setup`. Don't edit files under `/usr/share/sneh`.
- Undo: `sne snapshot list` → `sne snapshot diff N` → `sne snapshot undo N`.
- Update everything: `sne update`.
