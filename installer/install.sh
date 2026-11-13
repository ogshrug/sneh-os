#!/usr/bin/env bash
# Sneh unattended installer. Started by the Arch ISO's .automated_script.sh
# via the `script=` kernel parameter the flasher adds. It is copied to
# /tmp/startup_script first, so everything else is resolved from the stick.
set -Eeuo pipefail

USB=/run/archiso/bootmnt
SNEH_DIR="$USB/sneh"
export SNEH_DIR USB
LIB="$SNEH_DIR/lib"

# shellcheck source=lib/common.sh
source "$LIB/common.sh"

# Booting the stick again after a successful install gives you an SSH-able
# rescue system (key login only - the passwords were scrubbed) instead of a
# second install. Fix things with: mount -o subvol=@ /dev/<disk>2 /mnt; arch-chroot /mnt
rescue_mode() {
    echo "sneh: already installed (sneh/installed.done). Rescue mode."
    load_config "$SNEH_DIR/sneh.conf" 2>/dev/null || true
    local host; host="$(cfg HOSTNAME sneh)-rescue"
    hostnamectl set-hostname "$host" 2>/dev/null || true
    if [[ -n $(cfg SSH_PUBKEY) ]]; then
        install -d -m700 /root/.ssh
        printf '%s\n' "$(cfg SSH_PUBKEY)" >/root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nMulticastDNS=yes\n' >/etc/systemd/resolved.conf.d/mdns.conf
        systemctl restart systemd-resolved 2>/dev/null || true
        systemctl start sshd 2>/dev/null || true
        echo "sneh: ssh root@$host.local (your SSH key). To reinstall, delete sneh/installed.done and restore the passwords in sneh.conf."
    else
        echo "sneh: no SSH key in sneh.conf - rescue over SSH unavailable."
    fi
}

main() {
    usb_writable
    if [[ -e "$SNEH_DIR/installed.done" ]]; then
        rescue_mode
        exit 0
    fi
    rm -f "$SNEH_DIR/install.failed"
    # Graphical stick: hand the screen to the setup app. It comes back here
    # with SNEH_GUI=1 and its answers in SNEH_CONF to do the actual install.
    if [[ -z ${SNEH_GUI:-} ]] && grep -q '^INSTALL_UI=gui' "$SNEH_DIR/sneh.conf" 2>/dev/null; then
        # shellcheck source=lib/gui.sh
        source "$LIB/gui.sh"
        LOG="$SNEH_DIR/install-gui.log"; exec > >(tee -a "$LOG") 2>&1
        gui_mode && exit 0
        note "continuing with the unattended installer"
    fi
    start_log
    trap 'on_error $LINENO "$BASH_COMMAND"' ERR

    step "Sneh installer $(cat "$SNEH_DIR/system/VERSION" 2>/dev/null || echo dev) starting on $(date -Is)"
    load_config "${SNEH_CONF:-$SNEH_DIR/sneh.conf}"
    validate_config

    # shellcheck source=lib/net.sh
    source "$LIB/net.sh"
    # shellcheck source=lib/disk.sh
    source "$LIB/disk.sh"
    # shellcheck source=lib/base.sh
    source "$LIB/base.sh"
    # shellcheck source=lib/finish.sh
    source "$LIB/finish.sh"

    live_access          # ssh into the live system to watch progress
    bring_up_network
    prepare_live_pacman
    pick_target_disk
    partition_and_mount
    install_base
    configure_in_chroot
    finish_install
}

main "$@"
