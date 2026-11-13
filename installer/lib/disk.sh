#!/usr/bin/env bash
# Target disk selection (paranoid) and partitioning.

MIN_DISK_BYTES=$((16 * 1024 * 1024 * 1024))

_boot_parent() {
    local src
    src=$(findmnt -no SOURCE "$USB" 2>/dev/null || true)
    [[ -n $src ]] && lsblk -no PKNAME "$src" 2>/dev/null | head -1
}

_describe() { # /dev/x -> "model serial size"
    local d=$1
    printf '%s %s %s %s' "$d" \
        "$(lsblk -dno MODEL "$d" 2>/dev/null | xargs)" \
        "$(lsblk -dno SERIAL "$d" 2>/dev/null | xargs)" \
        "$(lsblk -dno SIZE "$d" 2>/dev/null | xargs)"
}

_candidates() {
    local bootp d name
    bootp=$(_boot_parent)
    while read -r d; do
        name=${d#/dev/}
        [[ $name =~ ^(loop|zram|sr|fd|ram) ]] && continue
        [[ $name =~ (boot[0-9]+|rpmb)$ ]] && continue
        [[ -n $bootp && $name == "$bootp" ]] && continue
        [[ $(lsblk -dno TYPE "$d") == disk ]] || continue
        [[ $(lsblk -dno RM "$d" | xargs) == 0 ]] || continue
        [[ $(lsblk -dno TRAN "$d" | xargs) != usb ]] || continue
        (( $(lsblk -dbno SIZE "$d") >= MIN_DISK_BYTES )) || continue
        echo "$d"
    done < <(lsblk -dpno NAME)
}

pick_target_disk() {
    step "Choosing target disk"
    local want all=() d matches=()
    want=$(cfg TARGET_DISK auto)
    mapfile -t all < <(_candidates)
    for d in "${all[@]}"; do note "candidate: $(_describe "$d")"; done
    ((${#all[@]})) || die "no internal disk >= 16 GB found"

    if [[ $want == auto ]]; then
        ((${#all[@]} == 1)) || die "several internal disks found; set TARGET_DISK to part of the model/serial"
        TARGET=${all[0]}
    elif [[ $want == /dev/* ]]; then
        printf '%s\n' "${all[@]}" | grep -qx -- "$want" || die "$want is not an eligible internal disk"
        TARGET=$want
    else
        for d in "${all[@]}"; do
            if _describe "$d" | grep -qiF -- "$want"; then matches+=("$d"); fi
        done
        ((${#matches[@]} == 1)) || die "TARGET_DISK '$want' matched ${#matches[@]} disks (need exactly 1)"
        TARGET=${matches[0]}
    fi
    export TARGET
    note "target: $(_describe "$TARGET")"
    if [[ -n ${SNEH_GUI:-} ]]; then
        note "erasing $TARGET (confirmed in the graphical installer)"
    else
        note "ERASING $TARGET in 30 seconds. Power off now to abort."
        local i
        for i in 30 20 10; do note "$i..."; sleep 10; done
    fi
}

_part() { # disk n -> partition path
    lsblk -lnpo NAME,TYPE "$1" | awk '$2 == "part" {print $1}' | sed -n "${2}p"
}

partition_and_mount() {
    step "Partitioning $TARGET (GPT: 512M ESP + btrfs)"
    swapoff -a 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    wipefs -af "$TARGET"
    sgdisk --zap-all "$TARGET"
    sgdisk -n1:0:+512M -t1:ef00 -c1:SNEH_ESP -n2:0:0 -t2:8304 -c2:sneh "$TARGET"
    partprobe "$TARGET" || true
    udevadm settle
    sleep 2
    ESP=$(_part "$TARGET" 1); ROOT=$(_part "$TARGET" 2)
    [[ -b $ESP && -b $ROOT ]] || die "partitions did not appear"
    export ESP ROOT

    mkfs.fat -F32 -n SNEH "$ESP"
    mkfs.btrfs -f -L sneh "$ROOT"

    mount "$ROOT" /mnt
    local sv
    for sv in @ @home @log @pkg; do btrfs subvolume create "/mnt/$sv"; done
    umount /mnt

    local o=noatime,compress=zstd:1
    mount -o "$o,subvol=@" "$ROOT" /mnt
    mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg}
    mount -o "$o,subvol=@home" "$ROOT" /mnt/home
    mount -o "$o,subvol=@log" "$ROOT" /mnt/var/log
    mount -o "$o,subvol=@pkg" "$ROOT" /mnt/var/cache/pacman/pkg
    mount -o umask=0077 "$ESP" /mnt/boot
    note "mounted: $(findmnt -R -no TARGET /mnt | paste -sd' ')"
}
