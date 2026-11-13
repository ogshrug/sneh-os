#!/usr/bin/env bash
# Runs inside `arch-chroot /mnt`. SNEH_DIR = staged stick payload (/root/sneh-install),
# ROOT_UUID = btrfs root, KERNEL = installed kernel package.
set -Eeuo pipefail
# shellcheck source=common.sh
source "$SNEH_DIR/lib/common.sh"
load_config "$SNEH_DIR/sneh.conf"

U=$(cfg USERNAME)
H=/home/$U
SYS=/usr/share/sneh
PROFILE=$(cfg PROFILE desktop)
KERNEL=${KERNEL:-linux-zen}
INSTALL_SUDOERS=/etc/sudoers.d/00-sneh-install
trap 'rm -f "$INSTALL_SUDOERS"' EXIT

as_user() { sudo -u "$U" -H "$@"; }

# ------------------------------------------------------------------ basics
step "Locale, time, hostname"
ln -sf "/usr/share/zoneinfo/$(cfg TIMEZONE UTC)" /etc/localtime
hwclock --systohc 2>/dev/null || true
loc=$(cfg LOCALE en_US.UTF-8)
for l in "$loc" en_US.UTF-8; do
    if grep -q "^#\s*${l} UTF-8" /etc/locale.gen; then
        sed -i "s|^#\s*${l} UTF-8|${l} UTF-8|" /etc/locale.gen
    elif ! grep -q "^${l} UTF-8" /etc/locale.gen; then
        echo "${l} UTF-8" >>/etc/locale.gen
    fi
done
locale-gen
echo "LANG=$loc" >/etc/locale.conf
echo "KEYMAP=$(cfg KEYMAP us)" >/etc/vconsole.conf
printf '%s\n' "$(cfg HOSTNAME)" >/etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $(cfg HOSTNAME).localdomain $(cfg HOSTNAME)
EOF

# ------------------------------------------------------------------ payload
step "Installing Sneh payload to $SYS"
rm -rf "$SYS"
cp -r "$SNEH_DIR/system" "$SYS"
find "$SYS" -type d -exec chmod 755 {} +
find "$SYS" -type f -exec chmod 644 {} +
chmod 755 "$SYS"/bin/*
# Noto Sans Devanagari (OFL): स्नेह in the bar, terminal, launcher and lock screen
install -Dm644 -t /usr/local/share/fonts/sneh "$SYS"/fonts/*.ttf && fc-cache -f >/dev/null 2>&1 || true
ln -sf "$SYS/bin/sne" /usr/local/bin/sne
cp -rT "$SYS/rootfs" /
sed -i "s|@USER@|$U|g" /etc/greetd/config.toml
# Laptops keep the stock lid/power-key behaviour (suspend on lid close).
[[ $PROFILE == laptop ]] && rm -f /etc/systemd/logind.conf.d/10-sneh.conf

# ------------------------------------------------------------------ user
step "User $U"
# Login shell stays bash (ssh 'cmd', scp, rsync and agents all expect POSIX);
# interactive terminals hand off to fish via ~/.bashrc.
id "$U" &>/dev/null || useradd -m -G wheel,input,video -s /bin/bash "$U"
cat >"$H/.bashrc" <<'RCEOF'
# Sneh: bash for scripts/ssh commands, fish for interactive terminals.
export PATH="$HOME/.local/bin:$PATH"   # before the return: `ssh host claude` needs it too
[[ $- != *i* ]] && return
if [[ -z ${SNEH_NO_FISH:-} && -z ${BASH_EXECUTION_STRING:-} ]] && command -v fish >/dev/null; then
    exec fish
fi
PS1='\u@\h \w \$ '
RCEOF
printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n' >"$H/.bash_profile"
chown "$U:$U" "$H/.bashrc" "$H/.bash_profile"
[[ $PROFILE == laptop ]] && usermod -aG audio "$U" 2>/dev/null
printf '%s:%s\n' "$U" "$(cfg PASSWORD)" | chpasswd
passwd -l root >/dev/null
echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
echo "$U ALL=(ALL:ALL) NOPASSWD: ALL" >"$INSTALL_SUDOERS"
cfg_yes SUDO_NOPASSWD && echo "$U ALL=(ALL:ALL) NOPASSWD: ALL" >/etc/sudoers.d/20-sneh-agent
chmod 440 /etc/sudoers.d/*

# ------------------------------------------------------------------ ssh
step "SSH"
install -d -m700 -o "$U" -g "$U" "$H/.ssh"
if [[ -n $(cfg SSH_PUBKEY) ]]; then
    printf '%s\n' "$(cfg SSH_PUBKEY)" >"$H/.ssh/authorized_keys"
    chown "$U:$U" "$H/.ssh/authorized_keys"; chmod 600 "$H/.ssh/authorized_keys"
fi
pwauth=no
if cfg_yes SSH_PASSWORD_AUTH || [[ -z $(cfg SSH_PUBKEY) ]]; then pwauth=yes; fi
cat >/etc/ssh/sshd_config.d/10-sneh.conf <<EOF
PermitRootLogin no
PasswordAuthentication $pwauth
KbdInteractiveAuthentication no
AllowTcpForwarding yes
X11Forwarding no
ClientAliveInterval 60
UseDNS no
EOF

# ------------------------------------------------------------------ network
step "Network (NetworkManager + mDNS)"
sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf
if [[ -n $(cfg WIFI_SSID) ]]; then
    f=/etc/NetworkManager/system-connections/sneh-wifi.nmconnection
    {
        printf '[connection]\nid=sneh-wifi\ntype=wifi\nautoconnect=true\n\n'
        printf '[wifi]\nmode=infrastructure\nssid=%s\nhidden=%s\n\n' "$(cfg WIFI_SSID)" "$(cfg_yes WIFI_HIDDEN && echo true || echo false)"
        if [[ -n $(cfg WIFI_PSK) ]]; then printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$(cfg WIFI_PSK)"; fi
        printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
    } >"$f"
    chmod 600 "$f"
fi
# Headless box: don't make boot wait for the network.
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true

# ------------------------------------------------------------------ boot
step "Bootloader (systemd-boot, $KERNEL)"
if ! bootctl install --esp-path=/boot; then
    note "could not write EFI variables; relying on the fallback EFI/BOOT/BOOTX64.EFI"
    bootctl install --esp-path=/boot --no-variables
fi
cat >/boot/loader/loader.conf <<EOF
default sneh.conf
timeout 0
console-mode max
editor no
EOF
opts="root=UUID=$ROOT_UUID rootflags=subvol=@ rw quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=auto zswap.enabled=0 nowatchdog"
[[ $(cfg PERF_MITIGATIONS on) == off ]] && opts+=" mitigations=off"
cat >/boot/loader/entries/sneh.conf <<EOF
title   Sneh
linux   /vmlinuz-$KERNEL
initrd  /initramfs-$KERNEL.img
options $opts
EOF
rm -f /boot/initramfs-*-fallback.img
[[ -s /boot/initramfs-$KERNEL.img ]] || mkinitcpio -P
# hold Space at power-on to see the menu (timeout 0 = instant boot)

# ------------------------------------------------------------------ services
step "Services ($PROFILE profile)"
svcs=(NetworkManager sshd avahi-daemon earlyoom greetd systemd-timesyncd fstrim.timer
      systemd-boot-update.service sneh-firstboot.service)
if [[ $PROFILE == laptop ]]; then
    svcs+=(bluetooth power-profiles-daemon)
fi
systemctl enable "${svcs[@]}"
if [[ $PROFILE == laptop ]]; then
    # audio for every user session (socket-activated, costs nothing until used)
    systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
fi
# Nothing on this box prints, scans or needs these.
systemctl mask systemd-homed.service systemd-userdbd.socket 2>/dev/null || true

install -d -m755 /var/lib/sneh
echo "$U" >/var/lib/sneh/user
touch /var/lib/sneh/firstboot
if [[ -n $(cfg TAILSCALE_AUTHKEY) ]]; then
    install -m600 /dev/null /var/lib/sneh/tailscale.authkey
    cfg TAILSCALE_AUTHKEY >/var/lib/sneh/tailscale.authkey
fi
pacman -Q tailscale &>/dev/null && systemctl enable tailscaled

step "Snapshots (snapper)"
if snapper --no-dbus -c root create-config / 2>&1; then
    sed -i -e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' \
           -e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="8"/' \
           -e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="4"/' \
           -e "s/^ALLOW_USERS=.*/ALLOW_USERS=\"$U\"/" /etc/snapper/configs/root
    systemctl enable snapper-cleanup.timer
else
    note "snapper config failed (non-fatal)"
fi

# ------------------------------------------------------------------ fonts
step "Fonts"
if [[ -f $SNEH_DIR/extras/MapleMono-NF-unhinted.zip ]]; then
    tmp=$(mktemp -d)
    if unzip -qo -j "$SNEH_DIR/extras/MapleMono-NF-unhinted.zip" 'MapleMono-NF-Regular.ttf' 'MapleMono-NF-Bold.ttf' 'MapleMono-NF-Italic.ttf' 'MapleMono-NF-BoldItalic.ttf' -d "$tmp"; then
        install -Dm644 -t /usr/local/share/fonts/maple "$tmp"/*.ttf && note "Maple Mono NF (4 styles, from the stick)"
    fi
    rm -rf "$tmp"
elif [[ $(cfg INSTALL_MODE net) == net ]]; then
    tmp=$(mktemp -d)
    if curl -fsSL --max-time 120 -o "$tmp/m.zip" https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-NF-unhinted.zip \
       && unzip -qo -j "$tmp/m.zip" 'MapleMono-NF-Regular.ttf' 'MapleMono-NF-Bold.ttf' 'MapleMono-NF-Italic.ttf' 'MapleMono-NF-BoldItalic.ttf' -d "$tmp/f"; then
        install -Dm644 -t /usr/local/share/fonts/maple "$tmp"/f/*.ttf && note "Maple Mono NF (4 styles)"
    else
        note "Maple Mono download failed; first boot will retry (JetBrains Mono is the fallback)"
    fi
    rm -rf "$tmp"
fi
fc-cache -f >/dev/null 2>&1 || true

# ------------------------------------------------------------------ desktop for the user
step "Desktop config for $U"
install -d -o "$U" -g "$U" "$H/.config" "$H/.config/sneh"
cat >"$H/.config/sneh/settings.env" <<EOF
PROFILE=$PROFILE
THEME=$(cfg THEME dusk)
ANIMATIONS=$(cfg ANIMATIONS on)
VNC_RESOLUTION=$(cfg VNC_RESOLUTION 1600x900)
VNC_BIND=$(cfg VNC_BIND lan)
VNC_ENABLED=$( [[ $PROFILE == laptop ]] && cfg VNC_ON_LAPTOP no || echo yes )
XKB_LAYOUT=$(cfg XKB_LAYOUT us)
AGENTS=$(cfg AGENTS claude,opencode)
APPS=$(cfg APPS files,vlc,images)
LOCK_ON_LOGIN=$(cfg LOCK_ON_LOGIN yes)
REPO_URL=$(cfg REPO_URL)
WALLPAPER=
FIREWATCH=$(cfg FIREWATCH no)
EOF
install -m600 /dev/null "$H/.config/sneh/vnc.pass"
cfg VNC_PASSWORD >"$H/.config/sneh/vnc.pass"
chown -R "$U:$U" "$H/.config"
as_user "$SYS/bin/sne" setup
# fuzzel 1.15.0 ignores the mouse wheel: build the upstream fix (needs the network;
# offline installs get it at first boot or with sne update)
as_user "$SYS/bin/sne" fix fuzzel || note "fuzzel wheel fix not built now; first boot retries"

# ------------------------------------------------------------------ agents (non-fatal)
step "Agents"
if [[ ,$(cfg AGENTS claude,opencode), == *,claude,* ]]; then
    as_user bash -c 'set -o pipefail; curl -fsSL --max-time 90 https://claude.ai/install.sh | bash' \
        || note "Claude Code not installed now; first boot retries when online"
fi
# Non-interactive SSH (`ssh box claude -p ...`) never reads ~/.bashrc on Arch,
# so put the agent CLIs on the system PATH too (the links follow self-updates).
ln -sf "$H/.local/bin/claude" /usr/local/bin/claude
ln -sf "$H/.opencode/bin/opencode" /usr/local/bin/opencode
if [[ ,$(cfg AGENTS claude,opencode), == *,opencode,* ]]; then
    as_user "$SYS/bin/sne" agents install-opencode || note "opencode not installed now; first boot retries when online"
fi
as_user "$SYS/bin/sne" agents link

# Do the one-time "needs update" jobs now so the first boot doesn't (saves ~10 s).
ldconfig
systemd-hwdb update 2>/dev/null || true
journalctl --update-catalog 2>/dev/null || true
touch /etc/.updated /var/.updated

step "Chroot stage complete"
