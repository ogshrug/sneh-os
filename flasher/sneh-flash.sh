#!/usr/bin/env bash
# Sneh flasher for Linux. Same stick layout as sneh-flash.ps1:
# MBR + one FAT32 partition holding the Arch ISO files, patched boot entries,
# the installer, the system payload and sneh.conf.
#
#   sudo ./flasher/sneh-flash.sh -c my.conf -d /dev/sdX            # net install
#   sudo ./flasher/sneh-flash.sh -c my.conf -d /dev/sdX -m full    # offline (needs an Arch host: pacman)
#   INSTALL_UI=gui in my.conf: a graphical installer runs on the machine and
#   asks everything else (the stick then carries its packages: needs pacman too).
#
# Write my.conf from flasher/sneh.conf.example (or save one with the
# Windows flasher's -SaveConfig).
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MIRROR=https://geo.mirror.pkgbuild.com
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sneh
CONF='' DEV='' MODE='' ISO='' YES=0

die() { printf '\e[31m✗ %s\e[0m\n' "$*" >&2; exit 1; }
step() { printf '\e[38;2;200;65;47m▸\e[0m %s\n' "$*"; }
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "c:d:m:i:yh" o; do
    case $o in
        c) CONF=$OPTARG ;; d) DEV=$OPTARG ;; m) MODE=$OPTARG ;; i) ISO=$OPTARG ;; y) YES=1 ;; h) usage ;; *) usage 1 ;;
    esac
done
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
[[ -r $CONF ]] || die "config file required: -c my.conf (see flasher/sneh.conf.example)"
[[ -b $DEV ]] || die "block device required: -d /dev/sdX"
for t in sfdisk mkfs.vfat curl sha256sum; do command -v $t >/dev/null || die "missing tool: $t"; done
[[ $(lsblk -dno TYPE "$DEV") == disk ]] || die "$DEV is not a whole disk"
[[ $(lsblk -dno RM "$DEV" | xargs) == 1 || $(lsblk -dno TRAN "$DEV" | xargs) == usb ]] || die "$DEV is not removable/USB - refusing"
grep -q "^PASSWORD=<removed>" "$CONF" && die "config was scrubbed by a previous install; set PASSWORD again"

mode=${MODE:-$(grep -m1 '^INSTALL_MODE=' "$CONF" | cut -d= -f2)}; mode=${mode:-net}
ui=$(grep -m1 '^INSTALL_UI=' "$CONF" | cut -d= -f2); ui=${ui:-auto}
[[ $mode == full || $ui == gui ]] && ! command -v pacman >/dev/null     && die "full mode and the graphical installer need pacman on Linux (an Arch host). Use the Windows flasher."

mkdir -p "$CACHE"
if [[ -z $ISO ]]; then
    step "Fetching Arch ISO"
    curl -fsSL "$MIRROR/iso/latest/sha256sums.txt" -o "$CACHE/sha256sums.txt"
    name=$(grep -oE 'archlinux-[0-9.]+-x86_64\.iso' "$CACHE/sha256sums.txt" | head -1)
    ISO=$CACHE/$name
    curl -fL -C - -o "$ISO" "$MIRROR/iso/latest/$name"
    (cd "$CACHE" && grep " $name\$" sha256sums.txt | sha256sum -c -) || { rm -f "$ISO"; die "checksum mismatch"; }
fi

echo; lsblk -o NAME,SIZE,MODEL,TRAN "$DEV"
if ((YES == 0)); then
    read -rp "ERASE $DEV and write Sneh ($mode)? type the device name again: " again
    [[ $again == "$DEV" ]] || die "aborted"
fi

step "Partitioning $DEV"
umount "$DEV"?* 2>/dev/null || true
wipefs -aq "$DEV"
printf 'label: dos\nstart=2048, size=8GiB, type=c, bootable\n' | sfdisk -q "$DEV" 2>/dev/null \
    || printf 'label: dos\nstart=2048, type=c, bootable\n' | sfdisk -q "$DEV"
partprobe "$DEV" 2>/dev/null || true; udevadm settle
part=$(lsblk -lnpo NAME,TYPE "$DEV" | awk '$2=="part"{print $1; exit}')
mkfs.vfat -F32 -n SNEH "$part" >/dev/null

mnt=$(mktemp -d); isom=$(mktemp -d)
trap 'umount "$mnt" "$isom" 2>/dev/null; rmdir "$mnt" "$isom" 2>/dev/null' EXIT
mount "$part" "$mnt"; mount -o loop,ro "$ISO" "$isom"
step "Copying the Arch live system"
cp -r "$isom"/. "$mnt"/
umount "$isom"

step "Patching boot entries"
extra='copytoram=n cow_spacesize=2G script=/run/archiso/bootmnt/sneh/install.sh'
for f in "$mnt"/loader/entries/*.conf; do
    grep -q archisobasedir "$f" && ! grep -q 'script=' "$f" && sed -i "s|^\(options[[:space:]].*\)$|\1 $extra|" "$f"
done
sed -i 's/^timeout .*/timeout 3/; s/^beep on/beep off/' "$mnt/loader/loader.conf"
[[ -f $mnt/boot/grub/grub.cfg ]] && sed -i "/archisobasedir/ s|^\([[:space:]]*linux[[:space:]].*\)$|\1 $extra|; s/^timeout=.*/timeout=3/" "$mnt/boot/grub/grub.cfg"

step "Adding the Sneh payload"
mkdir -p "$mnt/sneh"
cp -r "$ROOT/installer/." "$mnt/sneh/"
cp -r "$ROOT/system" "$mnt/sneh/system"
sed 's/\r$//' "$CONF" >"$mnt/sneh/sneh.conf"
sed -i "s/^INSTALL_MODE=.*/INSTALL_MODE=$mode/" "$mnt/sneh/sneh.conf"

pkgs() { sed -e 's/#.*//' "$@" | tr -s ' 	' '
' | sed '/^$/d'; }
if [[ $mode == full || $ui == gui ]]; then
    want=()
    if [[ $mode == full ]]; then
        if [[ $ui == gui ]]; then    # edition + apps are chosen on the machine: carry them all
            profiles=(desktop laptop); apps=",$(awk -F: '/^[a-z0-9-]+:/ {printf "%s,", $1}' "$ROOT/system/packages/apps.txt")"
        else
            profiles=("$(grep -m1 '^PROFILE=' "$CONF" | cut -d= -f2 || echo desktop)")
            apps=",$(grep -m1 '^APPS=' "$CONF" | cut -d= -f2 || echo files,vlc,images),"
        fi
        mapfile -t want < <(pkgs "$ROOT"/system/packages/{base,desktop,agents}.txt; for pr in "${profiles[@]}"; do pkgs "$ROOT/system/packages/profile-$pr.txt"; done
            awk '!/^#/ && NF {print $1}' "$ROOT/system/packages/firmware.txt"
            sed -e 's/#.*//' "$ROOT/system/packages/apps.txt" | while IFS=: read -r n p; do n=${n// /}; [[ -n $n && $apps == *,"$n",* ]] && pkgs <(echo "$p"); done
            grep -m1 '^KERNEL=' "$CONF" | cut -d= -f2 || echo linux-zen
            printf '%s
' intel-ucode amd-ucode)
    fi
    [[ $ui == gui ]] && mapfile -t -O "${#want[@]}" want < <(pkgs "$ROOT/system/packages/installer-gui.txt")
    want+=(archlinux-keyring)
    step "Downloading packages for the stick ($mode mode$([[ $ui == gui ]] && echo ', graphical installer'))"
    tmpdb=$(mktemp -d); repo=$mnt/sneh/repo; mkdir -p "$repo"
    pacman -Syw --noconfirm --dbpath "$tmpdb" --cachedir "$CACHE/pkg" "${want[@]}" >/dev/null
    for f in "$CACHE"/pkg/*.pkg.tar.zst "$CACHE"/pkg/*.pkg.tar.zst.sig; do b=$(basename "$f"); cp "$f" "$repo/${b//:/%3A}"; done
    cp "$tmpdb"/sync/{core,extra}.db "$repo/"
    rm -rf "$tmpdb"
fi
if [[ $mode == full ]]; then
    curl -fsSL -o "$mnt/sneh/extras/MapleMono-NF-unhinted.zip" --create-dirs         https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-NF-unhinted.zip || true
fi

sync
step "Done: $(du -sh "$mnt" | cut -f1) on the stick. Boot the target from it (UEFI)."
