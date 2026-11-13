#!/usr/bin/env python3
"""स्नेह Sneh graphical installer.

Runs full-screen in cage on the live USB (INSTALL_UI=gui). It asks the
questions, writes an ordinary sneh.conf to /run/sneh, and runs the same
install engine as the unattended stick (install.sh with SNEH_GUI=1),
showing its progress.

Testing / automation: SNEH_SETUP_ANSWERS=/path/answers.json pre-fills every
field and walks through the pages by itself ({"confirm": true} also confirms
the erase). SNEH_SETUP_DRYRUN=1 never touches a disk (UI development).
"""
import json
import os
import re
import shlex
import subprocess
import sys
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402

USB = "/run/archiso/bootmnt"
RK = os.environ.get("SNEH_RK", f"{USB}/sneh")
SYS = f"{RK}/system"
RUN = "/tmp/sneh-dryrun" if os.environ.get("SNEH_SETUP_DRYRUN") == "1" else "/run/sneh"
DRYRUN = os.environ.get("SNEH_SETUP_DRYRUN") == "1"
ANSWERS = {}
if os.environ.get("SNEH_SETUP_ANSWERS") and os.path.exists(os.environ["SNEH_SETUP_ANSWERS"]):
    with open(os.environ["SNEH_SETUP_ANSWERS"]) as f:
        ANSWERS = json.load(f)

LANGS = [("English (US)", "en_US.UTF-8"), ("English (UK)", "en_GB.UTF-8"), ("English (India)", "en_IN.UTF-8"),
         ("हिन्दी", "hi_IN.UTF-8"), ("Deutsch", "de_DE.UTF-8"), ("Français", "fr_FR.UTF-8"),
         ("Español", "es_ES.UTF-8"), ("Italiano", "it_IT.UTF-8"), ("Português (Brasil)", "pt_BR.UTF-8"),
         ("Nederlands", "nl_NL.UTF-8"), ("Svenska", "sv_SE.UTF-8"), ("Japanese", "ja_JP.UTF-8")]
KEYBOARDS = [("English (US)", "us", "us"), ("English (UK)", "gb", "uk"), ("German", "de", "de-latin1"),
             ("French", "fr", "fr-latin1"), ("Spanish", "es", "es"), ("Italian", "it", "it"),
             ("Portuguese (Brazil)", "br", "br-abnt2"), ("Swedish", "se", "sv-latin1"),
             ("Norwegian", "no", "no-latin1"), ("Danish", "dk", "dk-latin1"), ("Swiss German", "ch", "de_CH-latin1"),
             ("Dutch", "nl", "nl"), ("Japanese", "jp", "jp106")]
RESOLUTIONS = ["1280x720", "1600x900", "1920x1080", "2560x1440"]
STEPS = ["Welcome", "Language", "Network", "Disk", "Account", "Apps", "Summary", "Install"]

CSS = """
@define-color accent_bg_color #efb2a4;
@define-color accent_color #efb2a4;
@define-color accent_fg_color #080a18;
:root { --accent-bg-color: #efb2a4; --accent-color: #efb2a4; --accent-fg-color: #080a18; }
window, .main { background: #080a18; color: #e6e2f7; }
.sidebar { background: #0d1024; padding: 28px 18px; min-width: 230px; }
.sidebar .step { padding: 7px 12px; border-radius: 9px; color: #8b8fb8; font-weight: 500; }
.sidebar .step.done { color: #e6e2f7; }
.sidebar .step.current { background: #1d2246; color: #efb2a4; font-weight: 700; }
.brand { font-size: 13px; color: #8b8fb8; letter-spacing: 2px; margin-top: 10px; }
.title-1 { font-size: 30px; font-weight: 800; }
.lede { color: #8b8fb8; font-size: 15px; }
.card { background: #0d1024; border-radius: 16px; padding: 18px; border: 1px solid #1d2246; }
.choice { background: #0d1024; border-radius: 16px; padding: 20px; border: 2px solid #1d2246; }
.choice:checked { border-color: #efb2a4; background: #12163a; }
.choice .ctitle { font-size: 17px; font-weight: 700; }
.choice .cnote { color: #8b8fb8; }
.actions { padding: 16px 28px; border-top: 1px solid #1d2246; background: #0d1024; }
.suggested-action { background: #efb2a4; color: #080a18; }
.destructive-action { background: #f2707a; color: #080a18; }
.log { font-family: "JetBrains Mono", monospace; font-size: 11px; background: #05060f; color: #b9b6d6; }
.warn { color: #f2707a; font-weight: 600; }
.ok { color: #9ee6b4; }
progressbar trough { min-height: 10px; border-radius: 6px; background: #1d2246; }
progressbar progress { min-height: 10px; border-radius: 6px; background: #efb2a4; }
preferencesgroup > box > .boxed-list, .boxed-list { background: #0d1024; }
row { background: #0d1024; }
"""


def sh(cmd, timeout=20):
    try:
        return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def read_conf(path):
    cfg = {}
    try:
        for line in open(path, encoding="utf-8"):
            line = line.rstrip("\r\n")
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[re.sub(r"[^A-Z0-9_]", "", k)] = v
    except OSError:
        pass
    return cfg


def apps_catalog():
    out = []
    try:
        for line in open(f"{SYS}/packages/apps.txt", encoding="utf-8"):
            m = re.match(r"^\s*([a-z0-9-]+):\s*([^#]*)#\s*(.*)$", line)
            if m:
                out.append((m.group(1), m.group(3).strip()))
    except OSError:
        pass
    return out


def themes():
    try:
        return sorted(os.listdir(f"{SYS}/themes"), key=lambda t: (t != "dusk", t))
    except OSError:
        return ["dusk"]


def disks():
    """Eligible target disks, using the installer's own rules."""
    if DRYRUN:
        return [("/dev/sda", "Samsung SSD 860 EVO 250GB · 232.9 GiB · sata"),
                ("/dev/nvme0n1", "WD SN570 1TB · 931.5 GiB · nvme")]
    script = (f"export RK={shlex.quote(RK)} USB={USB}; source {shlex.quote(RK)}/lib/common.sh; "
              f"source {shlex.quote(RK)}/lib/disk.sh; for d in $(_candidates); do printf '%s\\t%s\\n' \"$d\" \"$(_describe \"$d\")\"; done")
    rows = []
    for line in sh(["bash", "-c", script]).splitlines():
        if "\t" in line:
            d, desc = line.split("\t", 1)
            rows.append((d, desc))
    return rows


def online():
    return subprocess.run(["curl", "-fsI", "--connect-timeout", "3", "--max-time", "5", "https://archlinux.org"],
                          capture_output=True).returncode == 0


def wifi_dev():
    m = re.search(r"Interface\s+(\S+)", sh(["iw", "dev"]))
    return m.group(1) if m else None


def wifi_networks(dev):
    sh(["iwctl", "station", dev, "scan"], 10)
    GLib.usleep(2_500_000)
    out = re.sub(r"\x1b\[[0-9;]*m", "", sh(["iwctl", "station", dev, "get-networks"]))
    nets = []
    for line in out.splitlines()[4:]:
        line = line.strip().lstrip(">").strip()
        cols = re.split(r"\s{2,}", line)
        if len(cols) >= 3 and cols[0]:
            nets.append((cols[0], cols[1], cols[2].count("*")))
    return nets


def guess_timezone():
    tz = sh("curl -fs --max-time 3 https://ipapi.co/timezone", 5).strip()
    return tz if tz and os.path.exists(f"/usr/share/zoneinfo/{tz}") else "UTC"


class Setup(Adw.Application):
    def __init__(self):
        super().__init__(application_id="os.sneh.Setup")
        self.stick = read_conf(f"{RK}/sneh.conf")
        self.cfg = {}
        self.page = 0
        self.wifi = {}
        self.install_ok = None

    # ------------------------------------------------------------------ chrome
    def do_activate(self):
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.FORCE_DARK)
        prov = Gtk.CssProvider()
        prov.load_from_string(CSS) if hasattr(prov, "load_from_string") else prov.load_from_data(CSS.encode())
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.win = Adw.ApplicationWindow(application=self, title="Install स्नेह")
        self.win.set_default_size(1280, 800)
        root = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.win.set_content(root)

        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, css_classes=["sidebar"])
        logo = Gtk.Image.new_from_file(f"{SYS}/branding/sneh-mark-dusk.svg")
        logo.set_pixel_size(72)
        logo.set_halign(Gtk.Align.START)
        side.append(logo)
        side.append(Gtk.Label(label="S N E H  ·  SETUP", css_classes=["brand"], xalign=0, margin_bottom=22))
        self.step_labels = []
        for s in STEPS:
            lab = Gtk.Label(label=s, xalign=0, css_classes=["step"])
            side.append(lab)
            self.step_labels.append(lab)
        spacer = Gtk.Box(vexpand=True)
        side.append(spacer)
        side.append(Gtk.Label(label=f"v{open(f'{SYS}/VERSION').read().strip() if os.path.exists(f'{SYS}/VERSION') else 'dev'}"
                              f" · {self.stick.get('INSTALL_MODE', 'net')} stick", css_classes=["brand"], xalign=0))
        root.append(side)

        main = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True, css_classes=["main"])
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT_RIGHT, vexpand=True, hexpand=True)
        main.append(self.stack)
        bar = Gtk.Box(spacing=12, css_classes=["actions"])
        self.back = Gtk.Button(label="Back")
        self.back.connect("clicked", lambda *_: self.go(self.page - 1))
        self.next = Gtk.Button(label="Continue", css_classes=["suggested-action", "pill"])
        self.next.connect("clicked", lambda *_: self.on_next())
        self.status = Gtk.Label(hexpand=True, xalign=0, css_classes=["warn"])
        bar.append(self.back)
        bar.append(self.status)
        bar.append(self.next)
        main.append(bar)
        root.append(main)

        builders = [self.p_welcome, self.p_language, self.p_network, self.p_disk,
                    self.p_account, self.p_apps, self.p_summary, self.p_install]
        for i, b in enumerate(builders):
            self.stack.add_named(self.scroller(b()), str(i))
        self.go(0)
        self.win.fullscreen() if not os.environ.get("SNEH_SETUP_WINDOWED") else None
        self.win.present()
        if ANSWERS:
            GLib.timeout_add(1600, self.autopilot)

    def scroller(self, child):
        # classic (always visible) scrollbar: on small screens it shows there's more below
        sc = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, overlay_scrolling=False)
        clamp = Adw.Clamp(maximum_size=760, margin_top=46, margin_bottom=30, margin_start=36, margin_end=36)
        clamp.set_child(child)
        sc.set_child(clamp)
        return sc

    def header(self, box, title, lede):
        box.append(Gtk.Label(label=title, xalign=0, css_classes=["title-1"], wrap=True))
        box.append(Gtk.Label(label=lede, xalign=0, css_classes=["lede"], wrap=True, margin_bottom=18))

    def go(self, i):
        i = max(0, min(i, len(STEPS) - 1))
        self.page = i
        self.stack.set_visible_child_name(str(i))
        for n, lab in enumerate(self.step_labels):
            for c in ("current", "done"):
                lab.remove_css_class(c)
            lab.add_css_class("current" if n == i else ("done" if n < i else "step"))
        self.back.set_sensitive(0 < i < 7)
        self.next.set_visible(i < 7)
        self.next.set_label("Install" if i == 6 else "Continue")
        self.next.remove_css_class("destructive-action")
        if i == 6:
            self.next.add_css_class("destructive-action")
        self.status.set_label("")
        enter = getattr(self, f"enter_{i}", None)
        if enter:
            enter()

    def on_next(self):
        check = getattr(self, f"check_{self.page}", None)
        err = check() if check else None
        if err:
            self.status.set_label(err)
            return
        if self.page == 6:
            self.confirm_erase()
            return
        self.go(self.page + 1)

    # ------------------------------------------------------------------ 0 welcome
    def p_welcome(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        pic = Gtk.Image.new_from_file(f"{SYS}/branding/sneh-mark-dusk.svg")
        pic.set_pixel_size(150)
        pic.set_halign(Gtk.Align.START)
        box.append(pic)
        self.header(box, "Install स्नेह", "A small, fast, agent-first Arch Linux. Answer a few questions and it "
                    "installs itself, usually in under fifteen minutes. Nothing is changed until the last step.")
        box.append(Gtk.Label(label="What kind of machine is this?", xalign=0, css_classes=["heading"], margin_top=8))
        has_battery = any(n.startswith("BAT") for n in os.listdir("/sys/class/power_supply")) if os.path.isdir("/sys/class/power_supply") else False
        self.ed_screen = Gtk.ToggleButton(css_classes=["choice"])
        self.ed_screen.set_child(self.choice_body("A laptop or a desktop with a screen",
                                                  "Sound, Bluetooth, brightness, a lock screen. VNC is optional."))
        self.ed_headless = Gtk.ToggleButton(css_classes=["choice"], group=self.ed_screen)
        self.ed_headless.set_child(self.choice_body("A headless box (no monitor)",
                                                    "A mini PC you reach over SSH and VNC. No audio stack, never sleeps."))
        default_screen = self.stick.get("PROFILE", "laptop" if has_battery else "laptop") != "desktop" or has_battery
        (self.ed_screen if default_screen else self.ed_headless).set_active(True)
        row = Gtk.Box(spacing=14, homogeneous=True)
        row.append(self.ed_screen)
        row.append(self.ed_headless)
        box.append(row)
        return box

    def choice_body(self, title, note):
        b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        b.append(Gtk.Label(label=title, xalign=0, wrap=True, css_classes=["ctitle"]))
        b.append(Gtk.Label(label=note, xalign=0, wrap=True, css_classes=["cnote"]))
        return b

    def check_0(self):
        self.cfg["PROFILE"] = "desktop" if self.ed_headless.get_active() else "laptop"

    # ------------------------------------------------------------------ 1 language
    def p_language(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.header(box, "Language and region", "Used for menus, dates and the keyboard.")
        grp = Adw.PreferencesGroup()
        self.lang = Adw.ComboRow(title="Language", model=Gtk.StringList.new([l for l, _ in LANGS]))
        self.kbd = Adw.ComboRow(title="Keyboard layout", model=Gtk.StringList.new([k for k, _, _ in KEYBOARDS]))
        zones = sh(["timedatectl", "list-timezones"]).split() or ["UTC"]
        self.zones = zones
        self.tz = Adw.ComboRow(title="Time zone", model=Gtk.StringList.new(zones), enable_search=True)
        self.tz.set_expression(Gtk.PropertyExpression.new(Gtk.StringObject, None, "string"))
        for w in (self.lang, self.kbd, self.tz):
            grp.add(w)
        box.append(grp)
        threading.Thread(target=self._guess_tz, daemon=True).start()
        return box

    def _guess_tz(self):
        tz = ANSWERS.get("timezone") or (guess_timezone() if online() else "UTC")
        GLib.idle_add(lambda: self.tz.set_selected(self.zones.index(tz)) if tz in self.zones else None)

    def check_1(self):
        self.cfg["LOCALE"] = LANGS[self.lang.get_selected()][1]
        _, xkb, km = KEYBOARDS[self.kbd.get_selected()]
        self.cfg["XKB_LAYOUT"], self.cfg["KEYMAP"] = xkb, km
        self.cfg["TIMEZONE"] = self.zones[self.tz.get_selected()]

    # ------------------------------------------------------------------ 2 network
    def p_network(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        full = self.stick.get("INSTALL_MODE") == "full"
        self.header(box, "Network", "This stick carries every package: a network is optional (agents and fonts arrive on "
                    "the first boot that has one)." if full else
                    "Packages are downloaded during the install, so this machine needs the internet. Plug in a cable or pick a Wi-Fi network.")
        self.net_state = Gtk.Label(xalign=0, css_classes=["heading"])
        box.append(self.net_state)
        self.wifi_group = Adw.PreferencesGroup(title="Wi-Fi")
        self.wifi_list = Gtk.ListBox(css_classes=["boxed-list"], selection_mode=Gtk.SelectionMode.NONE)
        self.wifi_group.add(self.wifi_list)
        rescan = Gtk.Button(label="Scan again", halign=Gtk.Align.START)
        rescan.connect("clicked", lambda *_: self.enter_2())
        box.append(self.wifi_group)
        box.append(rescan)
        self.wifi_group.set_visible(False)
        self.rescan = rescan
        return box

    def enter_2(self):
        self.net_state.set_label("Checking the connection…")
        threading.Thread(target=self._net_probe, daemon=True).start()

    def _net_probe(self):
        on = online()
        dev = wifi_dev()
        nets = wifi_networks(dev) if dev else []
        GLib.idle_add(self._net_show, on, dev, nets)

    def _net_show(self, on, dev, nets):
        self.is_online = on
        self.net_state.set_label("Connected to the internet ✓" if on else "Not connected")
        self.net_state.set_css_classes(["heading", "ok" if on else "warn"])
        self.wifi_group.set_visible(bool(dev))
        self.rescan.set_visible(bool(dev))
        while (r := self.wifi_list.get_first_child()) is not None:
            self.wifi_list.remove(r)
        for ssid, sec, bars in nets:
            row = Adw.ActionRow(title=ssid, subtitle=f"{sec} · {'▂▄▆█'[:max(1, bars)]}", activatable=True)
            btn = Gtk.Button(label="Connect", valign=Gtk.Align.CENTER)
            btn.connect("clicked", lambda _b, s=ssid, sc=sec, d=dev: self.wifi_connect(d, s, sc))
            row.add_suffix(btn)
            self.wifi_list.append(row)

    def wifi_connect(self, dev, ssid, sec):
        if sec == "open":
            self._wifi_do(dev, ssid, "")
            return
        dlg = Adw.MessageDialog(transient_for=self.win, heading=f"Password for {ssid}")
        entry = Gtk.PasswordEntry(show_peek_icon=True)
        dlg.set_extra_child(entry)
        dlg.add_response("cancel", "Cancel")
        dlg.add_response("ok", "Connect")
        dlg.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        dlg.connect("response", lambda d, r: self._wifi_do(dev, ssid, entry.get_text()) if r == "ok" else None)
        dlg.present()

    def _wifi_do(self, dev, ssid, psk):
        self.net_state.set_label(f"Connecting to {ssid}…")

        def work():
            args = ["iwctl"] + (["--passphrase", psk] if psk else []) + ["station", dev, "connect", ssid]
            subprocess.run(args, capture_output=True, timeout=40)
            for _ in range(15):
                if online():
                    break
                GLib.usleep(1_000_000)
            self.wifi = {"WIFI_SSID": ssid, "WIFI_PSK": psk}
            self._net_probe()
        threading.Thread(target=work, daemon=True).start()

    def check_2(self):
        if not getattr(self, "is_online", False) and self.stick.get("INSTALL_MODE") != "full":
            return "Connect to the internet first (this is a net-install stick)."
        self.cfg.update(self.wifi)

    # ------------------------------------------------------------------ 3 disk
    def p_disk(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.header(box, "Where to install", "Pick the internal disk. Everything on it will be erased: Sneh uses the whole disk.")
        self.disk_list = Gtk.ListBox(css_classes=["boxed-list"], selection_mode=Gtk.SelectionMode.NONE)
        box.append(self.disk_list)
        box.append(Gtk.Label(label="USB sticks and disks under 16 GB are not offered.", xalign=0, css_classes=["lede"]))
        self.disk_radios = []
        return box

    def enter_3(self):
        while (r := self.disk_list.get_first_child()) is not None:
            self.disk_list.remove(r)
        self.disk_radios = []
        first = None
        for dev, desc in disks():
            radio = Gtk.CheckButton(group=first)
            first = first or radio
            row = Adw.ActionRow(title=desc.split(" · ")[0] or dev, subtitle=f"{dev} · {' · '.join(desc.split(' · ')[1:])}")
            row.add_prefix(radio)
            row.set_activatable_widget(radio)
            self.disk_list.append(row)
            self.disk_radios.append((dev, desc, radio))
        want = ANSWERS.get("disk")
        for dev, _, radio in self.disk_radios:
            if dev == want:
                radio.set_active(True)
        if len(self.disk_radios) == 1:
            self.disk_radios[0][2].set_active(True)
        if not self.disk_radios:
            self.disk_list.append(Adw.ActionRow(title="No suitable disk found", subtitle="Sneh needs an internal disk of 16 GB or more."))

    def check_3(self):
        for dev, desc, radio in self.disk_radios:
            if radio.get_active():
                self.cfg["TARGET_DISK"], self.disk_desc = dev, desc
                return None
        return "Choose a disk."

    # ------------------------------------------------------------------ 4 account
    def p_account(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.header(box, "You and this computer", "Your account gets admin rights (sudo).")
        g = Adw.PreferencesGroup()
        self.e_host = Adw.EntryRow(title="Computer name", text=ANSWERS.get("hostname", "sneh"))
        self.e_user = Adw.EntryRow(title="Username", text=ANSWERS.get("username", ""))
        self.e_pw = Adw.PasswordEntryRow(title="Password", text=ANSWERS.get("password", ""))
        self.e_pw2 = Adw.PasswordEntryRow(title="Password again", text=ANSWERS.get("password", ""))
        for w in (self.e_host, self.e_user, self.e_pw, self.e_pw2):
            g.add(w)
        box.append(g)
        self.vnc_group = Adw.PreferencesGroup(title="Remote desktop (VNC)",
                                              description="How you'll see this headless box from another computer.")
        self.e_vnc = Adw.PasswordEntryRow(title="VNC password", text=ANSWERS.get("vnc_password", ""))
        self.res = Adw.ComboRow(title="Virtual screen size", model=Gtk.StringList.new(RESOLUTIONS), selected=1)
        self.vnc_group.add(self.e_vnc)
        self.vnc_group.add(self.res)
        box.append(self.vnc_group)
        self.laptop_group = Adw.PreferencesGroup(title="Login")
        self.sw_lock = Adw.SwitchRow(title="Ask for the password at startup",
                                     subtitle="Off = log straight in (the lock screen still works)", active=True)
        self.sw_vnc_laptop = Adw.SwitchRow(title="Also share this desktop over VNC", active=False)
        self.laptop_group.add(self.sw_lock)
        self.laptop_group.add(self.sw_vnc_laptop)
        box.append(self.laptop_group)
        return box

    def enter_4(self):
        headless = self.cfg.get("PROFILE") == "desktop"
        self.vnc_group.set_visible(headless)
        self.laptop_group.set_visible(not headless)

    def check_4(self):
        host, user = self.e_host.get_text().strip(), self.e_user.get_text().strip()
        pw = self.e_pw.get_text()
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9-]{0,62}", host):
            return "Computer name: letters, digits and dashes."
        if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user) or user in ("root", "greeter"):
            return "Username: lowercase letters, digits, - or _ (not root)."
        if len(pw) < 6:
            return "Password: at least 6 characters."
        if pw != self.e_pw2.get_text():
            return "The passwords don't match."
        self.cfg.update(HOSTNAME=host, USERNAME=user, PASSWORD=pw)
        if self.cfg.get("PROFILE") == "desktop" or self.sw_vnc_laptop.get_active():
            vnc = self.e_vnc.get_text() or pw
            if len(vnc) < 6:
                return "VNC password: at least 6 characters."
            self.cfg["VNC_PASSWORD"] = vnc
            self.cfg["VNC_RESOLUTION"] = RESOLUTIONS[self.res.get_selected()]
        if self.cfg.get("PROFILE") == "laptop":
            self.cfg["LOCK_ON_LOGIN"] = "yes" if self.sw_lock.get_active() else "no"
            self.cfg["VNC_ON_LAPTOP"] = "yes" if self.sw_vnc_laptop.get_active() else "no"
            if self.sw_vnc_laptop.get_active() and not self.e_vnc.get_text():
                self.cfg["VNC_PASSWORD"] = pw

    # ------------------------------------------------------------------ 5 apps
    def p_apps(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.header(box, "Apps and agents", "Everything here can be changed later with sne apps add|remove.")
        g = Adw.PreferencesGroup(title="Apps")
        default = set((ANSWERS.get("apps") or self.stick.get("APPS") or "files,vlc,images").split(","))
        self.app_rows = []
        for name, note in apps_catalog():
            r = Adw.SwitchRow(title=name, subtitle=note, active=name in default)
            g.add(r)
            self.app_rows.append((name, r))
        box.append(g)
        a = Adw.PreferencesGroup(title="AI agents", description="Command-line coding agents, preinstalled with a manual about this machine.")
        agents = set((ANSWERS.get("agents") or self.stick.get("AGENTS") or "claude,opencode").split(","))
        self.ag_claude = Adw.SwitchRow(title="Claude Code", active="claude" in agents)
        self.ag_oc = Adw.SwitchRow(title="opencode", active="opencode" in agents)
        a.add(self.ag_claude)
        a.add(self.ag_oc)
        box.append(a)
        t = Adw.PreferencesGroup(title="Look")
        self.themes = themes()
        self.theme = Adw.ComboRow(title="Theme", model=Gtk.StringList.new(self.themes))
        self.anim = Adw.SwitchRow(title="Animations", active=True)
        self.fw = Adw.SwitchRow(title="Firewatch wallpapers",
                                subtitle="14 fan-art pictures from wallhaven.cc, downloaded after install (~40 MB). The default is Sneh's own.",
                                active=str(ANSWERS.get("firewatch", self.stick.get("FIREWATCH", "no"))).lower() in ("yes", "true", "1"))
        t.add(self.theme)
        t.add(self.anim)
        t.add(self.fw)
        box.append(t)
        return box

    def check_5(self):
        self.cfg["APPS"] = ",".join(n for n, r in self.app_rows if r.get_active()) or "none"
        ag = [n for n, r in (("claude", self.ag_claude), ("opencode", self.ag_oc)) if r.get_active()]
        self.cfg["AGENTS"] = ",".join(ag) or "none"
        self.cfg["THEME"] = self.themes[self.theme.get_selected()]
        self.cfg["ANIMATIONS"] = "on" if self.anim.get_active() else "off"
        self.cfg["FIREWATCH"] = "yes" if self.fw.get_active() else "no"

    # ------------------------------------------------------------------ 6 summary
    def p_summary(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.header(box, "Ready to install", "Check the details. Install erases the disk below.")
        self.sum_group = Adw.PreferencesGroup()
        box.append(self.sum_group)
        self.sum_rows = []
        return box

    def enter_6(self):
        for r in self.sum_rows:
            self.sum_group.remove(r)
        c = self.cfg
        rows = [("Machine", "laptop / desktop with a screen" if c.get("PROFILE") == "laptop" else "headless box (SSH + VNC)"),
                ("Disk (will be erased)", f"{c.get('TARGET_DISK')} · {getattr(self, 'disk_desc', '')}"),
                ("Computer name", c.get("HOSTNAME", "")), ("Username", c.get("USERNAME", "")),
                ("Language · keyboard · time zone", f"{c.get('LOCALE')} · {c.get('XKB_LAYOUT')} · {c.get('TIMEZONE')}"),
                ("Apps", c.get("APPS", "")), ("Agents", c.get("AGENTS", "")),
                ("Look", c.get("THEME", "") + (" · + Firewatch wallpapers" if c.get("FIREWATCH") == "yes" else "")),
                ("Install type", "full (offline)" if self.stick.get("INSTALL_MODE") == "full" else "net (downloads packages)")]
        if c.get("WIFI_SSID"):
            rows.append(("Wi-Fi", c["WIFI_SSID"]))
        self.sum_rows = []
        for k, v in rows:
            r = Adw.ActionRow(title=k, subtitle=v)
            self.sum_group.add(r)
            self.sum_rows.append(r)

    def confirm_erase(self):
        if ANSWERS.get("confirm"):
            self.start_install()
            return
        dlg = Adw.MessageDialog(transient_for=self.win, heading="Erase the disk and install?",
                                body=f"Everything on {self.cfg.get('TARGET_DISK')} ({getattr(self, 'disk_desc', '')}) will be deleted. This can't be undone.")
        dlg.add_response("cancel", "Go back")
        dlg.add_response("erase", "Erase and install")
        dlg.set_response_appearance("erase", Adw.ResponseAppearance.DESTRUCTIVE)
        dlg.set_default_response("cancel")
        dlg.connect("response", lambda d, r: self.start_install() if r == "erase" else None)
        dlg.present()

    # ------------------------------------------------------------------ 7 install
    def p_install(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.inst_title = Gtk.Label(label="Installing स्नेह", xalign=0, css_classes=["title-1"])
        box.append(self.inst_title)
        self.inst_step = Gtk.Label(label="Starting…", xalign=0, css_classes=["lede"], wrap=True)
        box.append(self.inst_step)
        self.bar = Gtk.ProgressBar(margin_top=6, margin_bottom=6)
        box.append(self.bar)
        exp = Gtk.Expander(label="Details")
        self.logbuf = Gtk.TextBuffer()
        tv = Gtk.TextView(buffer=self.logbuf, editable=False, monospace=True, css_classes=["log"], wrap_mode=Gtk.WrapMode.CHAR)
        sc = Gtk.ScrolledWindow(min_content_height=320, child=tv)
        self.logview = tv
        exp.set_child(sc)
        box.append(exp)
        self.done_box = Gtk.Box(spacing=12, margin_top=10)
        self.restart = Gtk.Button(label="Restart now", css_classes=["suggested-action", "pill"])
        self.restart.connect("clicked", lambda *_: subprocess.run(["systemctl", "reboot"]))
        self.done_box.append(self.restart)
        self.done_box.set_visible(False)
        box.append(self.done_box)
        return box

    def start_install(self):
        c = dict(self.stick)
        for k in ("PASSWORD", "VNC_PASSWORD", "WIFI_PSK"):     # never reuse scrubbed placeholders
            c.pop(k, None)
        c.update(self.cfg)
        c["ALLOW_WIPE"] = "yes"
        c["INSTALL_UI"] = "gui"
        c.setdefault("INSTALL_MODE", self.stick.get("INSTALL_MODE", "net"))
        os.makedirs(RUN, exist_ok=True)
        conf = f"{RUN}/sneh.conf"
        fd = os.open(conf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            for k, v in c.items():
                f.write(f"{k}={v}\n")
        self.go(7)
        self.expected = 22.0
        self.seen = 0
        threading.Thread(target=self.run_engine, args=(conf,), daemon=True).start()
        GLib.timeout_add(400, self.tick)

    def run_engine(self, conf):
        if DRYRUN:
            cmd = ["bash", "-c", "for s in Network Disk 'Installing base system' Chroot 'Agents' Done; do echo \"▸ $s\"; sleep 1; done"]
        else:
            cmd = ["bash", f"{RK}/install.sh"]
        env = dict(os.environ, SNEH_CONF=conf, SNEH_GUI="1", TERM="dumb")
        p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in p.stdout:
            line = re.sub(r"\x1b\[[0-9;]*m", "", line)
            GLib.idle_add(self.on_line, line)
        rc = p.wait()
        GLib.idle_add(self.on_done, rc)

    def on_line(self, line):
        end = self.logbuf.get_end_iter()
        self.logbuf.insert(end, line)
        self.logview.scroll_to_iter(self.logbuf.get_end_iter(), 0, False, 0, 0)
        if line.startswith("▸ "):
            self.seen += 1
            self.inst_step.set_label(line[2:].strip())

    def tick(self):
        if self.install_ok is not None:
            return False
        self.bar.set_fraction(min(0.97, self.seen / self.expected))
        return True

    def on_done(self, rc):
        self.install_ok = rc == 0
        if self.install_ok:
            self.bar.set_fraction(1.0)
            self.inst_title.set_label("स्नेह is installed")
            self.inst_step.set_label("Remove the USB stick, then restart. The stick's own boot loader is switched off, "
                                     "so leaving it in is fine too.")
            self.done_box.set_visible(True)
            if ANSWERS.get("reboot"):
                GLib.timeout_add(3000, lambda: subprocess.run(["systemctl", "reboot"]))
        else:
            self.inst_title.set_label("The install stopped")
            self.inst_step.set_label("Open Details for the log (it is also saved as sneh/install.log on the stick). "
                                     "Nothing was changed if it stopped before the disk step.")
            self.inst_step.set_css_classes(["warn"])
            self.restart.set_label("Restart")
            self.done_box.set_visible(True)

    # ------------------------------------------------------------------ autopilot (tests)
    def autopilot(self):
        if self.page >= 7:
            return False
        if self.page == 0 and "profile" in ANSWERS:
            (self.ed_headless if ANSWERS["profile"] == "desktop" else self.ed_screen).set_active(True)
        self.on_next()
        return self.page < 7


if __name__ == "__main__":
    sys.exit(Setup().run([]))
