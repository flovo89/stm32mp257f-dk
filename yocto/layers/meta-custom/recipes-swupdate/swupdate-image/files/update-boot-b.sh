#!/bin/sh
# Mount the FAT32 boot-b partition and copy the staged kernel + DTB into it.
# Called by swupdate as a post-install shellscript for the stable/copy2 selection.
#
# swupdate calls this script three times: preinst, postinst, postfailure.
# Images are only staged to /tmp after preinst, so we skip all but postinst.
case "$1" in
    preinst|postfailure) exit 0 ;;
esac
set -e

BOOT_DEV="/dev/disk/by-partlabel/boot-b"
MNT="/mnt/swupdate-boot-update"
KERNEL_TMP="/tmp/Image.swu.tmp"
DTB_TMP="/tmp/stm32mp257f-dk.dtb.swu.tmp"

echo "[update-boot-b] Updating boot-b partition..."

mkdir -p "${MNT}"
mount -t vfat "${BOOT_DEV}" "${MNT}"

# boot.cmd does "load mmc 0:N fitImage" so copy Image under that name.
cp "${KERNEL_TMP}" "${MNT}/fitImage"
cp "${DTB_TMP}"    "${MNT}/stm32mp257f-dk.dtb"

# Ensure extlinux.conf exists — it is static (rootfs-b PARTUUID is fixed by GPT)
# and should survive across OTA updates, but create it if somehow missing.
if [ ! -f "${MNT}/extlinux/extlinux.conf" ]; then
    ROOTFS_B_UUID=$(blkid -s PARTUUID -o value /dev/disk/by-partlabel/rootfs-b 2>/dev/null)
    mkdir -p "${MNT}/extlinux"
    cat > "${MNT}/extlinux/extlinux.conf" << EOF
TIMEOUT 20
DEFAULT STM32MP25

LABEL STM32MP25
    KERNEL /fitImage
    FDT /stm32mp257f-dk.dtb
    APPEND root=PARTUUID=${ROOTFS_B_UUID} rootwait rw earlycon console=ttySTM0,115200
EOF
    echo "[update-boot-b] Created missing extlinux.conf (PARTUUID=${ROOTFS_B_UUID})"
fi

umount "${MNT}"
rmdir  "${MNT}" 2>/dev/null || true
rm -f  "${KERNEL_TMP}" "${DTB_TMP}"

# Switch U-Boot env to boot slot B on next reboot.
# CONFIG_BOOTLOADERHANDLER is not compiled into this swupdate build, so we
# call fw_setenv directly instead of relying on the sw-description bootenv section.
fw_setenv boot_side b upgrade_available 1 bootcount 0
echo "[update-boot-b] U-Boot env: boot_side=b upgrade_available=1"

echo "[update-boot-b] Done."
