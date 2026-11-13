#!/usr/bin/env bash
# Shared helpers for the installer (live ISO) and the chroot stage.
# shellcheck disable=SC2034

declare -gA CFG=()

step() { printf '\n\e[38;2;200;65;47m▸\e[0m %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die() {
    printf '\n\e[31m✗ %s\e[0m\n' "$*" >&2
    if [[ -n ${SNEH_DIR:-} && -d ${SNEH_DIR:-} ]]; then
        { date -Is; echo "$*"; } >"$SNEH_DIR/install.failed" 2>/dev/null || true
        sync
    fi
    exit 1
}

# The boot stick is mounted read-only by archiso; we need it writable for the
# log, the installed.done marker and scrubbing secrets.
usb_writable() {
    mountpoint -q "$USB" || die "$USB is not mounted (was copytoram=n dropped from the boot entry?)"
    mount -o remount,rw "$USB" 2>/dev/null || true
}

start_log() {
    LOG="$SNEH_DIR/install.log"
    : >"$LOG"
    exec > >(tee -a "$LOG") 2>&1
    export LOG
}

on_error() {
    local line=$1 cmd=$2
    # set -E propagates the trap into $(...) subshells; only the main shell reports
    [[ $BASHPID == "$$" ]] || return 1
    printf '\n\e[31m✗ install failed at line %s: %s\e[0m\n' "$line" "$cmd"
    date -Is >"$SNEH_DIR/install.failed"
    echo "The live system stays up. ssh root@$(cfg HOSTNAME sneh)-install.local to debug." | tee -a "$SNEH_DIR/install.failed"
    sync
    exit 1
}

# KEY=value parser. Never `source` user-supplied files.
load_config() {
    local file=$1 line k v
    [[ -r $file ]] || die "missing config $file"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line || $line == \#* || $line != *=* ]] && continue
        k=${line%%=*}; v=${line#*=}
        k=${k//[^A-Z0-9_]/}
        [[ -n $k ]] && CFG[$k]=$v
    done <"$file"
}

cfg() { printf '%s' "${CFG[$1]:-${2:-}}"; }
cfg_yes() { [[ ${CFG[$1]:-${2:-no}} == yes ]]; }

validate_config() {
    [[ $(cfg HOSTNAME) =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "bad HOSTNAME"
    [[ $(cfg USERNAME) =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "bad USERNAME"
    [[ $(cfg USERNAME) != root && $(cfg USERNAME) != greeter ]] || die "USERNAME cannot be root/greeter"
    [[ -n $(cfg PASSWORD) && $(cfg PASSWORD) != '<removed>' ]] || die "PASSWORD missing (scrubbed after a previous install? set it again)"
    [[ $(cfg PROFILE desktop) =~ ^(desktop|laptop)$ ]] || die "PROFILE must be desktop or laptop"
    [[ $(cfg INSTALL_MODE net) =~ ^(net|full)$ ]] || die "INSTALL_MODE must be net or full"
    [[ $(cfg KERNEL linux-zen) =~ ^(linux|linux-zen|linux-lts)$ ]] || die "KERNEL must be linux, linux-zen or linux-lts"
    if [[ $(cfg PROFILE desktop) == desktop || $(cfg VNC_ON_LAPTOP no) == yes ]]; then
        [[ -n $(cfg VNC_PASSWORD) && $(cfg VNC_PASSWORD) != '<removed>' ]] || die "VNC_PASSWORD missing"
    fi
    [[ -e /usr/share/zoneinfo/$(cfg TIMEZONE UTC) ]] || die "unknown TIMEZONE $(cfg TIMEZONE)"
    [[ $(cfg VNC_RESOLUTION 1600x900) =~ ^[0-9]{3,4}x[0-9]{3,4}$ ]] || die "bad VNC_RESOLUTION"
    [[ $(cfg VNC_BIND lan) =~ ^(lan|localhost|tailscale)$ ]] || die "bad VNC_BIND"
    [[ -d $SNEH_DIR/system/themes/$(cfg THEME dusk) ]] || die "unknown THEME"
    cfg_yes ALLOW_WIPE || die "ALLOW_WIPE is not 'yes' - refusing to touch any disk"
    note "config ok: host=$(cfg HOSTNAME) user=$(cfg USERNAME) theme=$(cfg THEME dusk) target=$(cfg TARGET_DISK auto)"
}
