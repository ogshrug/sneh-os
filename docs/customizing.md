# Customizing

Sneh keeps its pristine files in `/usr/share/sneh`. `sne setup` and `sne update` copy them into `~/.config`.
Put your own changes in the files below; those commands never overwrite them.

| File | What goes there |
|---|---|
| `~/.config/hypr/user.lua` | Hyprland (0.57 **Lua** API), loaded last |
| `~/.config/fish/user.fish` | shell aliases, environment |
| `~/.config/sneh/settings.env` | Sneh settings (see `docs/sne.md`); run `sne setup` after editing |

## Hyprland examples (`user.lua`)

```lua
-- bigger gaps and a different terminal key
hl.config({ general = { gaps_out = 16 } })
hl.bind("SUPER + T", hl.dsp.exec_cmd("footclient"))

-- float a specific app
hl.window_rule({ name = "float-calc", match = { class = "^(qalculate-gtk)$" }, float = true })

-- start something with the desktop
hl.on("hyprland.start", function() hl.exec_cmd("footclient -e btop") end)
```

`hyprctl dispatch` takes Lua too: `hyprctl dispatch 'hl.dsp.focus({ workspace = 2 })'`.

There are two workspaces (1 desk, 2 agents). Their rules and binds are in `hyprland.lua`; the dock's pinned apps are the `custom/d-*` modules in `/usr/share/sneh/templates/waybar__config.jsonc`, and apps that `SUPER+Q` hides instead of quitting are set with `KEEP_ALIVE=spotify|firefox` in settings.env.

## Making a theme

1. Copy `/usr/share/sneh/themes/ink` to a new folder, for example `~/my-theme`.
2. Edit `palette.env`:
   - `bg`, `surface`, `overlay`, `fg` and `muted` are the neutrals.
   - `accent` and `accent2` are the highlights.
   - `urgent` is for errors.
   - `sun` and `title` style the generated wallpaper used before a picture is chosen (`sne wallpaper reset` brings it back).
3. Install it and switch to it:
   ```sh
   sudo cp -r ~/my-theme /usr/share/sneh/themes/
   sne theme set my-theme
   ```

Every file in `/usr/share/sneh/templates/` is rendered with `{{key}}` substitution. The file name gives the destination: `a__b.ext` → `~/.config/a/b.ext`.

## Packages

```sh
sne snapshot create "before adding X"
sudo pacman -S <pkg>
```

There is deliberately no AUR helper. If you need one, `paru-bin` is a prebuilt binary, which keeps compilation off a 4 GB machine.
