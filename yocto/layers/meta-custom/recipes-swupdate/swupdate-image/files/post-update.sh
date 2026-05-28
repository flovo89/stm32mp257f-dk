#!/bin/sh
# Post-update script run by SWUpdate after writing all images.
# Runs on the CURRENTLY BOOTED system, before reboot.
set -e

echo "[post-update] Update written successfully."

# Ensure the new root filesystem is cleanly fsck'd on first mount
SIDE=$(fw_printenv boot_side 2>/dev/null | cut -d= -f2 || echo "unknown")
echo "[post-update] Next boot will try slot: ${SIDE}"

if [ "${SIDE}" = "a" ]; then
    e2fsck -fp /dev/disk/by-partlabel/rootfs-a || true
else
    e2fsck -fp /dev/disk/by-partlabel/rootfs-b || true
fi

echo "[post-update] Done. Reboot to activate new image."
