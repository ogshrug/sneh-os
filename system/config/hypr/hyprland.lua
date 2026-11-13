-- स्नेह Sneh — Hyprland (0.57+, Lua config)
-- Managed by `sne setup`. Put your own changes in ~/.config/hypr/user.lua.
-- Performance notes: blur and shadows are off (they cost the most on old iGPUs
-- and over VNC), vfr is on so idle frames aren't rendered, and animations are
-- short "melt" curves that can be turned off with `sne perf vnc`.

local ok_c, C = pcall(require, "colors")
if not ok_c then
    C = { bg = "080a18", surface = "0d1024", overlay = "1d2246", fg = "e6e2f7", muted = "8b8fb8",
          accent = "a99be8", accent2 = "efb2a4", urgent = "f2707a" }   -- dusk
end
local ok_s, S = pcall(require, "settings")
if not ok_s then S = { profile = "desktop", resolution = "1600x900@30", animations = true, kb_layout = "us", xwayland = false } end

local function rgba(hex, a) return "rgba(" .. hex .. (a or "ff") .. ")" end
local laptop = S.profile == "laptop"

------------------------------------------------------------------ monitors
-- Real displays: native mode. Headless outputs (no monitor on the mini PC):
-- the VNC resolution. Rules for outputs that don't exist are harmless.
-- sRGB, 8-bit: wide colour on an 8-bit panel only earns a warning (and costs a pass)
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = laptop and "auto" or 1, cm = "srgb", bitdepth = 8 })
for i = 1, 4 do
    hl.monitor({ output = "HEADLESS-" .. i, mode = S.resolution, position = "auto", scale = 1 })
end

------------------------------------------------------------------ programs
local terminal = "footclient"
local launcher = "fuzzel"
local files    = "sne app files"            -- Thunar, or yazi if Thunar isn't installed

------------------------------------------------------------------ autostart
hl.on("hyprland.start", function()
    hl.exec_cmd("/usr/share/sneh/bin/sneh-autostart")
end)

------------------------------------------------------------------ env
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

------------------------------------------------------------------ look
hl.config({
    general = {
        gaps_in  = 4,
        gaps_out = { top = 6, right = 12, bottom = 12, left = 12 },  -- inside the wallpaper frame
        border_size = 1,
        col = {
            active_border   = rgba(C.fg, "cc"),
            inactive_border = rgba(C.overlay),
        },
        resize_on_border = laptop,
        allow_tearing = false,
        layout = "dwindle",
    },

    decoration = {
        rounding       = 14,
        rounding_power = 2.4,
        active_opacity   = 1.0,
        inactive_opacity = 1.0,
        dim_inactive     = false,
        shadow = { enabled = false },
        blur   = { enabled = false },
    },

    animations = { enabled = S.animations },

    cursor = {
        -- headless outputs have no hardware cursor plane; draw it in software
        -- so it shows up in VNC and in `sne gui screenshot`.
        no_hardware_cursors = not laptop,
        inactive_timeout = 0,
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
        disable_splash_rendering = true,
        disable_watchdog_warning = true,
        disable_hyprland_guiutils_check = true,
        background_color = tonumber("0x" .. C.bg),
        mouse_move_enables_dpms = true,
        key_press_enables_dpms  = true,
        focus_on_activate = true,
    },

    ecosystem = {
        no_update_news  = true,
        no_donation_nag = true,
    },

    debug = { vfr = true },

    -- X11 apps need Xwayland (~60 MB). Off on the headless box, on for laptops;
    -- override with XWAYLAND=on|off in ~/.config/sneh/settings.env
    xwayland = { enabled = S.xwayland ~= false },

    dwindle = { preserve_split = true },
    master  = { new_status = "master" },

    input = {
        kb_layout = S.kb_layout,
        follow_mouse = 1,
        sensitivity = 0,
        repeat_rate = 35,
        repeat_delay = 280,
        touchpad = {
            natural_scroll = true,
            tap_to_click = true,
            disable_while_typing = true,
        },
    },
})

-- "Melt" motion: quick out-expo for opening, gentle fade for closing.
hl.curve("melt",  { type = "bezier", points = { {0.23, 1},   {0.32, 1} } })
hl.curve("ease",  { type = "bezier", points = { {0.65, 0.05}, {0.36, 1} } })
hl.curve("lin",   { type = "bezier", points = { {0, 0},      {1, 1} } })
hl.curve("soft",  { type = "spring", mass = 1, stiffness = 260, damping = 26 })

hl.animation({ leaf = "global",        enabled = true, speed = 6,   bezier = "melt" })
hl.animation({ leaf = "border",        enabled = true, speed = 4,   bezier = "melt" })
hl.animation({ leaf = "windows",       enabled = true, speed = 3.6, spring = "soft" })
hl.animation({ leaf = "windowsIn",     enabled = true, speed = 3.2, spring = "soft", style = "popin 92%" })
hl.animation({ leaf = "windowsOut",    enabled = true, speed = 1.4, bezier = "lin",  style = "popin 92%" })
hl.animation({ leaf = "fade",          enabled = true, speed = 2.4, bezier = "ease" })
hl.animation({ leaf = "layers",        enabled = true, speed = 3,   bezier = "melt" })
hl.animation({ leaf = "layersIn",      enabled = true, speed = 3,   bezier = "melt", style = "slide top" })
hl.animation({ leaf = "layersOut",     enabled = true, speed = 1.4, bezier = "lin",  style = "fade" })
hl.animation({ leaf = "workspaces",    enabled = true, speed = 2.6, bezier = "melt", style = "slidefade 12%" })

------------------------------------------------------------------ rules
hl.window_rule({ name = "suppress-maximize", match = { class = ".*" }, suppress_event = "maximize" })
hl.window_rule({
    name  = "fix-xwayland-drags",
    match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
    no_focus = true,
})
hl.window_rule({ name = "float-pickers", match = { class = "^(xdg-desktop-portal-gtk|pavucontrol|nm-connection-editor|blueman-manager)$" }, float = true })
hl.layer_rule({ name = "launcher-anim", match = { namespace = "^launcher$" }, no_anim = not S.animations })
-- The depth-clock wallpaper is re-rendered each minute and swapped in as a new
-- swaybg layer: fade it in over the old one (identical except the digits)
-- instead of the default slide, so only the time appears to change.
hl.layer_rule({ name = "wallpaper-fade", match = { namespace = "^wallpaper$" }, animation = "fade" })

------------------------------------------------------------------ workspaces
-- 1 desk: the everyday desktop - wallpaper, bar, dock, gaps, rounding.
-- 2 agents: plain - no gaps, borders or rounding, bar and dock hidden
--   (sne ws sync), the agents tmux session fills the screen.
hl.workspace_rule({ workspace = "1", default_name = "desk", persistent = true, default = true })
hl.workspace_rule({ workspace = "2", default_name = "agents", persistent = true,
    gaps_in = 0, gaps_out = 0, no_rounding = true, border_size = 1, no_shadow = true })  -- 1px: shows the split + focus
-- sne ws sync: bar/dock on the desk only; opens the agents tmux when you arrive on an empty 2
hl.on("workspace.active", function() hl.exec_cmd("sne ws sync") end)

------------------------------------------------------------------ binds
local M = "SUPER"
hl.bind(M .. " + RETURN",      hl.dsp.exec_cmd(terminal))
hl.bind(M .. " + SPACE",       hl.dsp.exec_cmd(launcher))
hl.bind(M .. " + D",           hl.dsp.exec_cmd("sne win desktop"))              -- show desktop / back
hl.bind("ALT + TAB",           hl.dsp.exec_cmd("sne win switch"))               -- switcher, hidden apps too
hl.bind(M .. " + TAB",         hl.dsp.exec_cmd("sne win switch"))
hl.bind(M .. " + E",           hl.dsp.exec_cmd(files))
hl.bind(M .. " + A",           hl.dsp.exec_cmd("sne ws agent"))                 -- agents workspace; there: one more agent
hl.bind(M .. " + Q",           hl.dsp.exec_cmd("sne win close"))  -- KEEP_ALIVE apps (Spotify) hide instead
hl.bind(M .. " + SHIFT + Q",   hl.dsp.window.close())
hl.bind(M .. " + V",           hl.dsp.window.float({ action = "toggle" }))
hl.bind(M .. " + F",           hl.dsp.window.fullscreen())
hl.bind(M .. " + J",           hl.dsp.layout("togglesplit"))
hl.bind(M .. " + N",           hl.dsp.exec_cmd("makoctl dismiss --all"))
hl.bind(M .. " + slash",       hl.dsp.exec_cmd("sne keys"))                     -- quick menu: every shortcut
hl.bind(M .. " + F1",          hl.dsp.exec_cmd("sne keys"))
hl.bind(M .. " + SHIFT + W",   hl.dsp.exec_cmd("sne wallpaper pick"))
hl.bind(M .. " + ALT + W",     hl.dsp.exec_cmd("sne wallpaper next"))
hl.bind(M .. " + SHIFT + T",   hl.dsp.exec_cmd("footclient -e btop"))
hl.bind(M .. " + SHIFT + S",   hl.dsp.exec_cmd("sh -c 'grim -g \"$(slurp)\" - | wl-copy && notify-send -a sneh \"region copied\"'"))
hl.bind("PRINT",               hl.dsp.exec_cmd("sh -c 'f=$(sne gui screenshot) && wl-copy < \"$f\" && notify-send -a sneh \"screenshot\" \"$f\"'"))
hl.bind(M .. " + ESCAPE",      hl.dsp.exec_cmd(laptop and "hyprlock" or "notify-send -a sneh 'headless' 'VNC is the lock: sne vnc password'"))
hl.bind(M .. " + SHIFT + R",   hl.dsp.exec_cmd("sne setup"))
hl.bind(M .. " + CTRL + A",    hl.dsp.exec_cmd("sne perf vnc"))
hl.bind(M .. " + CTRL + SHIFT + A", hl.dsp.exec_cmd("sne perf normal"))
hl.bind(M .. " + SHIFT + E",   hl.dsp.exit())

for _, d in ipairs({ "left", "right", "up", "down" }) do
    hl.bind(M .. " + " .. d,             hl.dsp.focus({ direction = d }))
    hl.bind(M .. " + SHIFT + " .. d,     hl.dsp.window.move({ direction = d }))
end
for _, kd in ipairs({ { "H", "left" }, { "L", "right" }, { "K", "up" } }) do
    hl.bind(M .. " + " .. kd[1], hl.dsp.focus({ direction = kd[2] }))
end

-- Two workspaces: 1 = the desktop (wallpaper, bar, dock), 2 = agents (plain).
for i = 1, 2 do
    hl.bind(M .. " + " .. i,           hl.dsp.focus({ workspace = i }))
    hl.bind(M .. " + SHIFT + " .. i,   hl.dsp.window.move({ workspace = i }))
end
hl.bind(M .. " + S",           hl.dsp.workspace.toggle_special("scratch"))
hl.bind(M .. " + mouse_down",  hl.dsp.focus({ workspace = 2 }))
hl.bind(M .. " + mouse_up",    hl.dsp.focus({ workspace = 1 }))
hl.bind(M .. " + mouse:272",   hl.dsp.window.drag(),   { mouse = true })
hl.bind(M .. " + mouse:273",   hl.dsp.window.resize(), { mouse = true })

if laptop then
    hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
    hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
    hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true })
    hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true })
    hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true })
    hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true })
    hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
end

------------------------------------------------------------------ user
pcall(require, "user")
