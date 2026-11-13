#!/usr/bin/env bash
# Graphical install (INSTALL_UI=gui): put a tiny Wayland kiosk (cage) and the
# GTK setup app into the live system - from the package repo on the stick, so
# no network is needed - and run it full-screen on this console. The app writes
# /run/sneh/sneh.conf and runs install.sh again with SNEH_GUI=1 to install.

gui_mode() {
    step "Starting the graphical installer"
    [[ -f $RK/repo/core.db ]] || die "this stick has no sneh/repo (re-flash it with the graphical installer)"
    # pacman keyring (pacman-init runs at boot)
    local _
    for _ in $(seq 1 90); do
        [[ $(systemctl is-active pacman-init.service 2>/dev/null) == activating ]] || break
        sleep 1
    done
    [[ -s /etc/pacman.d/gnupg/trustdb.gpg ]] || { pacman-key --init && pacman-key --populate archlinux; }
    systemctl stop reflector.service 2>/dev/null || true

    local r=/tmp/rkrepo f b conf=/tmp/pacman-gui.conf
    rm -rf "$r"; mkdir -p "$r"
    for f in "$RK"/repo/*; do b=$(basename "$f"); ln -sf "$f" "$r/${b//%3A/:}"; done
    printf '[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\nLocalFileSigLevel = Optional\n' >"$conf"
    printf '\n[core]\nServer = file://%s\n\n[extra]\nServer = file://%s\n' "$r" "$r" >>"$conf"
    note "installing the setup app into the live system (from the stick)"
    pacman --config "$conf" -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
    # shellcheck disable=SC2046
    pacman --config "$conf" -S --noconfirm --needed $(_pkglist "$RK/system/packages/installer-gui.txt") \
        || die "could not install the graphical installer's packages"
    install -Dm644 -t /usr/share/fonts/sneh "$RK"/system/fonts/*.ttf 2>/dev/null || true
    fc-cache -f >/dev/null 2>&1 || true

    note "launching"
    # The live system autologs root in on tty1 and runs us there, so cage can
    # take the screen directly. Software rendering keeps it working on any GPU
    # (and in VMs); the app is just forms and a progress bar.
    export XDG_RUNTIME_DIR=/run/user/0
    mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
    export WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1 GSK_RENDERER=cairo GDK_BACKEND=wayland
    export XKB_DEFAULT_LAYOUT=${XKB_DEFAULT_LAYOUT:-us} SNEH_RK="$RK" NO_AT_BRIDGE=1
    [[ -f $RK/answers.json ]] && export SNEH_SETUP_ANSWERS="$RK/answers.json"
    local tries=0
    until cage -s -- python3 "$RK/gui/sneh-setup.py"; do
        tries=$((tries + 1))
        ((tries < 3)) || { note "the graphical installer could not start; falling back to the console"; return 1; }
        sleep 2
    done
}

_pkglist() { sed -e 's/#.*//' -e '/^\s*$/d' "$@" | tr -s ' \t' '\n' | sed '/^$/d'; }
