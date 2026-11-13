---
name: sneh-gui
description: See and operate the Sneh graphical desktop (Hyprland) from a terminal/SSH session - screenshots, clicks, typing, key combos, window lists. Use when a task needs a GUI app, a browser page, or visual verification on this machine.
---

# Driving the Sneh desktop

1. Make sure it's up: `sne desktop status --json` (if `running` is false: `sne desktop on`, wait ~5 s).
2. Look: `RK_SHOT_SCALE=0.5 sne gui screenshot` prints a PNG path. Open/read the image.
   Remember coordinates in a half-scale image must be doubled for `click`.
3. Act:
   - `sne gui launch <cmd>` (e.g. `foot`, `firefox URL`) then `sne gui windows` to find it
   - `sne gui focus class:<regex>`
   - `sne gui click X Y [left|right|middle|double]`
   - `sne gui type "text"` · `sne gui key ctrl+l` · `sne gui key enter`
4. Verify with another screenshot. Don't chain many blind actions.

Notes: windows tile automatically; `super+f` (sne gui key super+f) fullscreens the focused
window, which makes coordinates stable. Typing goes to the focused window only.
