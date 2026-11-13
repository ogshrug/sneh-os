#!/usr/bin/env bash
# Package selection, size trims, pacstrap (net or offline), hand-off to chroot.

_pkglist() { sed -e 's/#.*//' -e '/^\s*$/d' "$@" | tr -s ' \t' '\n' | sed '/^$/d'; }

# Packages for APPS=a,b,c (system/packages/apps.txt: "name: pkg pkg  # note").
# BROWSER=firefox (older configs) counts as the firefox app.
_apps() {
    local want; want=",$(cfg APPS files,vlc,images),"
    [[ $(cfg BROWSER none) == firefox ]] && want+="firefox,"
    sed -e 's/#.*//' "$SNEH_DIR/system/packages/apps.txt" | while IFS=: read -r name pkgs; do
        name=${name// /}
        [[ -n $name && $want == *,"$name",* ]] && tr -s ' \t' '\n' <<<"$pkgs" | sed '/^$/d'
    done
}

# Vendor IDs present on PCI + USB, lowercase, one per line.
_vendors() {
    { cat /sys/bus/pci/devices/*/vendor 2>/dev/null | sed 's/^0x//'
      cat /sys/bus/usb/devices/*/idVendor 2>/dev/null; } | tr 'A-F' 'a-f' | sort -u
}

firmware_packages() {
    local fw=$1 vendors pkg ids id matched=()
    if [[ $fw == full ]]; then
        awk '!/^#/ && NF {print $1}' "$SNEH_DIR/system/packages/firmware.txt"; return
    fi
    vendors=$(_vendors)
    while read -r pkg ids; do
        [[ -z $pkg || $pkg == \#* ]] && continue
        for id in $ids; do
            if [[ $id == '*' ]]; then
                [[ $(cfg PROFILE desktop) == laptop ]] && { matched+=("$pkg"); break; }
            elif grep -qx "$id" <<<"$vendors"; then
                matched+=("$pkg"); break
            fi
        done
    done <"$SNEH_DIR/system/packages/firmware.txt"
    ((${#matched[@]})) || matched=(linux-firmware-other)
    printf '%s\n' "${matched[@]}"
}

select_packages() {
    local prof kernel
    prof=$(cfg PROFILE desktop); kernel=$(cfg KERNEL linux-zen)
    mapfile -t PKGS < <(_pkglist "$SNEH_DIR"/system/packages/{base,desktop,"profile-$prof"}.txt)
    [[ $(cfg AGENTS claude,opencode) != none ]] && mapfile -t -O "${#PKGS[@]}" PKGS < <(_pkglist "$SNEH_DIR/system/packages/agents.txt")
    PKGS+=("$kernel")
    case $(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo) in
        GenuineIntel) PKGS+=(intel-ucode) ;;
        AuthenticAMD) PKGS+=(amd-ucode) ;;
    esac
    mapfile -t -O "${#PKGS[@]}" PKGS < <(firmware_packages "$(cfg FIRMWARE auto)")
    mapfile -t -O "${#PKGS[@]}" PKGS < <(_apps)
    [[ -n $(cfg TAILSCALE_AUTHKEY) || $(cfg VNC_BIND) == tailscale ]] && PKGS+=(tailscale)
    mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | awk '!seen[$0]++')
    export KERNEL=$kernel
    if [[ $(cfg AGENTS claude,opencode) != none ]] && ! grep -qw sse4_2 /proc/cpuinfo; then
        note "WARNING: this CPU lacks SSE4.2 - Claude Code and opencode (Bun) will not run on it"
    fi
    note "profile=$prof kernel=$kernel firmware: $(printf '%s\n' "${PKGS[@]}" | grep '^linux-firmware' | paste -sd' ')"
    note "${#PKGS[@]} packages requested"
}

# Never unpack docs, man pages, info, help or foreign translations: ~150 MB saved.
noextract_block() {
    local lang; lang=$(cfg LOCALE en_US.UTF-8); lang=${lang%%.*}
    cat <<EOF
NoExtract = usr/share/help/* usr/share/doc/* usr/share/gtk-doc/* usr/share/info/* usr/share/man/*
NoExtract = usr/share/locale/* !usr/share/locale/locale.alias !usr/share/locale/en* !usr/share/locale/${lang%%_*}*
NoExtract = usr/share/i18n/locales/* !usr/share/i18n/locales/en_US !usr/share/i18n/locales/en_GB !usr/share/i18n/locales/${lang} !usr/share/i18n/locales/i18n* !usr/share/i18n/locales/iso14651_t1* !usr/share/i18n/locales/translit_* !usr/share/i18n/locales/POSIX
EOF
}

_apply_pacman_opts() { # file
    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/; s/^#Color/Color/' "$1"
    grep -q '^NoExtract = usr/share/help' "$1" || sed -i "/^\[options\]/r /dev/stdin" "$1" < <(noextract_block)
}

setup_offline_repo() {
    step "Using the offline package repo on the stick"
    local r=/tmp/rkrepo f b
    rm -rf "$r"; mkdir -p "$r"
    # FAT can't store ':' (package epochs); the flasher saved them as %3A.
    for f in "$SNEH_DIR"/repo/*; do b=$(basename "$f"); ln -sf "$f" "$r/${b//%3A/:}"; done
    PACCONF=/tmp/pacman-offline.conf
    {
        printf '[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\nLocalFileSigLevel = Optional\nParallelDownloads = 5\n'
        noextract_block
        printf '\n[core]\nServer = file://%s\n\n[extra]\nServer = file://%s\n' "$r" "$r"
    } >"$PACCONF"
    pacman --config "$PACCONF" -Sy
    # newer packagers' keys: install the bundled keyring first
    pacman --config "$PACCONF" -S --noconfirm --needed archlinux-keyring || note "keyring update skipped"
    export PACCONF
}

install_base() {
    select_packages
    PACCONF=/etc/pacman.conf
    if [[ $(cfg INSTALL_MODE net) == full ]]; then
        [[ -f $SNEH_DIR/repo/core.db ]] || die "INSTALL_MODE=full but the stick has no sneh/repo (re-flash with -Mode full)"
        setup_offline_repo
    else
        _apply_pacman_opts /etc/pacman.conf
    fi
    # Pre-seed initramfs settings so the kernel install builds ONE small,
    # systemd-based image (no fallback image: saves ~90 MB on the ESP and a
    # minute of build time on old CPUs).
    mkdir -p /mnt/etc/mkinitcpio.conf.d /mnt/etc/mkinitcpio.d
    cat >/mnt/etc/mkinitcpio.conf.d/10-sneh.conf <<'EOF'
HOOKS=(systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=(-3)
EOF
    cat >"/mnt/etc/mkinitcpio.d/$KERNEL.preset" <<EOF
# Sneh: single image, no fallback
ALL_kver="/boot/vmlinuz-$KERNEL"
PRESETS=('default')
default_image="/boot/initramfs-$KERNEL.img"
EOF
    echo "KEYMAP=$(cfg KEYMAP us)" >/mnt/etc/vconsole.conf

    step "Installing base system (pacstrap, $(cfg INSTALL_MODE net) mode)"
    local try
    for try in 1 2 3; do
        pacstrap -C "$PACCONF" -K /mnt "${PKGS[@]}" && break
        ((try < 3)) || die "pacstrap failed 3 times"
        note "pacstrap failed, retrying ($try/3)"
        [[ $PACCONF == /etc/pacman.conf ]] && reflector --protocol https --latest 15 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null
        sleep 5
    done
    genfstab -U /mnt >>/mnt/etc/fstab
    [[ $PACCONF == /etc/pacman.conf ]] && cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    _apply_pacman_opts /mnt/etc/pacman.conf
    # Nothing in the cache is needed after install.
    find /mnt/var/cache/pacman/pkg -type f -delete 2>/dev/null || true
    local used; used=$(df -h --output=used /mnt 2>/dev/null | tail -1 | xargs) || used='?'
    note "installed: $used used on the target (btrfs zstd)"
}

configure_in_chroot() {
    step "Configuring the installed system"
    local stage=/mnt/root/sneh-install
    rm -rf "$stage"; mkdir -p "$stage"
    cp -r "$SNEH_DIR/lib" "$stage/lib"
    cp -r "$SNEH_DIR/system" "$stage/system"
    [[ -d $SNEH_DIR/extras ]] && cp -r "$SNEH_DIR/extras" "$stage/extras"
    install -m600 "$SNEH_DIR/sneh.conf" "$stage/sneh.conf"
    chmod 700 "$stage"
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
    arch-chroot /mnt env SNEH_DIR=/root/sneh-install ROOT_UUID="$ROOT_UUID" KERNEL="$KERNEL" \
        bash /root/sneh-install/lib/chroot.sh
    cp "$LOG" /mnt/var/log/sneh-install.log 2>/dev/null || true
    rm -rf "$stage"   # contains secrets
}
