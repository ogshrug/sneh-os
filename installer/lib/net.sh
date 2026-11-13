#!/usr/bin/env bash
# Live-ISO networking and remote access.

live_access() {
    step "Enabling SSH into the live installer"
    local host
    host="$(cfg HOSTNAME)-install"
    hostnamectl set-hostname "$host" 2>/dev/null || echo "$host" >/etc/hostname
    printf 'root:%s\n' "$(cfg PASSWORD)" | chpasswd
    if [[ -n $(cfg SSH_PUBKEY) ]]; then
        install -d -m700 /root/.ssh
        printf '%s\n' "$(cfg SSH_PUBKEY)" >/root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    fi
    # Answer as <host>.local via systemd-resolved mDNS.
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nMulticastDNS=yes\n' >/etc/systemd/resolved.conf.d/mdns.conf
    systemctl restart systemd-resolved || true
    systemctl start sshd || true
    note "ssh root@$host.local  (password = your install password)"
}

_online() { curl -fsI --connect-timeout 4 --max-time 6 https://archlinux.org >/dev/null 2>&1; }

_enable_mdns_links() {
    local ifc
    for ifc in $(ip -o link show up | awk -F': ' '$2 != "lo" {print $2}' | cut -d@ -f1); do
        resolvectl mdns "$ifc" yes 2>/dev/null || true
    done
}

bring_up_network() {
    step "Network"
    local _ first=20
    [[ $(cfg INSTALL_MODE net) == full ]] && first=3   # offline is fine: don't wait long
    for _ in $(seq 1 "$first"); do _online && break; sleep 2; done
    if ! _online && [[ -n $(cfg WIFI_SSID) ]]; then
        local dev
        rfkill unblock wifi 2>/dev/null || true
        dev=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}')
        [[ -n $dev ]] || die "Wi-Fi configured but no wireless interface found"
        note "connecting $dev to '$(cfg WIFI_SSID)'"
        local verb=connect
        cfg_yes WIFI_HIDDEN && verb=connect-hidden
        for _ in 1 2 3; do
            if [[ -n $(cfg WIFI_PSK) ]]; then
                iwctl --passphrase "$(cfg WIFI_PSK)" station "$dev" "$verb" "$(cfg WIFI_SSID)" && break
            else
                iwctl station "$dev" "$verb" "$(cfg WIFI_SSID)" && break
            fi
            sleep 5
        done
    fi
    local tries=45
    [[ $(cfg INSTALL_MODE net) == full ]] && tries=3
    for _ in $(seq 1 "$tries"); do _online && break; sleep 2; done
    if ! _online; then
        if [[ $(cfg INSTALL_MODE net) == full ]]; then
            ONLINE=0; export ONLINE
            note "offline - fine for a full install (agents and fonts are fetched on first boot with network)"
            return 0
        fi
        die "no internet after 90s (Ethernet unplugged? Wi-Fi details wrong?)"
    fi
    ONLINE=1; export ONLINE
    _enable_mdns_links
    timedatectl set-ntp true || true
    note "online: $(ip -4 -o addr show scope global | awk '{print $2" "$4}' | paste -sd' ')"
}

prepare_live_pacman() {
    step "Preparing pacman (keyring + mirrors)"
    local _
    # pacman-init and reflector run at boot; wait for them (bounded).
    # pacman-init is a oneshot: wait while it is still running, then make
    # sure the keyring exists (it ends "inactive" when done, not "active").
    for _ in $(seq 1 90); do
        [[ $(systemctl is-active pacman-init.service 2>/dev/null) == activating ]] || break
        sleep 2
    done
    if [[ ! -s /etc/pacman.d/gnupg/trustdb.gpg ]]; then
        pacman-key --init && pacman-key --populate archlinux
    fi
    # mirror ranking only matters when downloading (net mode)
    if [[ $(cfg INSTALL_MODE net) == net ]]; then
        for _ in $(seq 1 60); do
            systemctl is-active --quiet reflector.service || break
            sleep 2
        done
    else
        systemctl stop reflector.service 2>/dev/null || true
    fi
    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    if [[ ${ONLINE:-1} == 1 && $(cfg INSTALL_MODE net) == net ]]; then
        pacman -Sy --noconfirm --needed archlinux-keyring
    fi
}
