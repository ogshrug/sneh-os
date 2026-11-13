#!/usr/bin/env bash
# Final steps: boot order, guard marker, scrub secrets, reboot.

finish_install() {
    step "Finishing"
    if command -v efibootmgr >/dev/null && efibootmgr >/dev/null 2>&1; then
        local id
        id=$(efibootmgr | awk '/Linux Boot Manager/ {sub(/^Boot/, "", $1); sub(/\*$/, "", $1); print $1; exit}')
        if [[ -n $id ]]; then
            local rest
            rest=$(efibootmgr | awk -F': ' '/^BootOrder/ {print $2}' | tr ',' '\n' | grep -vx "$id" | paste -sd,)
            efibootmgr -o "${id}${rest:+,$rest}" >/dev/null && note "boot order: internal disk first ($id)"
        fi
    fi

    sync
    umount -R /mnt

    {
        echo "installed=$(date -Is)"
        echo "target=$TARGET"
        echo "host=$(cfg HOSTNAME)"
    } >"$SNEH_DIR/installed.done"
    rm -f "$SNEH_DIR/install.failed"
    # Many mini PCs boot USB first no matter what NVRAM says. Make the stick
    # non-bootable so the machine always falls through to the installed disk.
    # (Rename the files back to get the rescue system.)
    local efi
    for efi in "$USB"/EFI/BOOT/BOOT*.EFI "$USB"/EFI/BOOT/boot*.efi; do
        [[ -e $efi ]] && mv -f "$efi" "$efi.sneh-disabled"
    done
    note "stick boot loader disabled (rename EFI/BOOT/*.sneh-disabled back for rescue mode)"
    sed -i -E 's/^(PASSWORD|VNC_PASSWORD|WIFI_PSK|TAILSCALE_AUTHKEY)=.*/\1=<removed>/' "$SNEH_DIR/sneh.conf"
    note "secrets scrubbed from the stick; installed.done written"

    step "Done. ssh $(cfg USERNAME)@$(cfg HOSTNAME).local  ·  VNC $(cfg HOSTNAME).local:5900"
    sync
    if [[ -n ${SNEH_GUI:-} ]]; then
        rm -f "${SNEH_CONF:-/run/sneh/sneh.conf}"     # the app shows a Restart button
        return 0
    fi
    note "rebooting in 10 seconds"
    sleep 10
    systemctl reboot
}
