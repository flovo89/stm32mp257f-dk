#!/bin/sh
# Mount the FAT32 boot-a partition and copy the staged kernel + DTB into it.
# Called by swupdate as a post-install shellscript for the stable/copy1 selection.
#
# swupdate calls this script three times: preinst, postinst, postfailure.
# Images are only staged to /tmp after preinst, so we skip all but postinst.
case "$1" in
    preinst|postfailure) exit 0 ;;
esac
set -e

BOOT_DEV="/dev/disk/by-partlabel/boot-a"
MNT="/mnt/swupdate-boot-update"
KERNEL_TMP="/tmp/Image.swu.tmp"
DTB_TMP="/tmp/stm32mp257f-dk.dtb.swu.tmp"

echo "[update-boot-a] Updating boot-a partition..."

mkdir -p "${MNT}"
mount -t vfat "${BOOT_DEV}" "${MNT}"

# boot.cmd does "load mmc 0:N fitImage" so copy Image under that name.
cp "${KERNEL_TMP}" "${MNT}/fitImage"
cp "${DTB_TMP}"    "${MNT}/stm32mp257f-dk.dtb"

# Ensure extlinux.conf exists — static (rootfs-a PARTUUID fixed by GPT), but
# create it if somehow missing.
if [ ! -f "${MNT}/extlinux/extlinux.conf" ]; then
    ROOTFS_A_UUID=$(blkid -s PARTUUID -o value /dev/disk/by-partlabel/rootfs-a 2>/dev/null)
    mkdir -p "${MNT}/extlinux"
    cat > "${MNT}/extlinux/extlinux.conf" << EOF
TIMEOUT 20
DEFAULT STM32MP25

LABEL STM32MP25
    KERNEL /fitImage
    FDT /stm32mp257f-dk.dtb
    APPEND root=PARTUUID=${ROOTFS_A_UUID} rootwait rw earlycon console=ttySTM0,115200
EOF
    echo "[update-boot-a] Created missing extlinux.conf (PARTUUID=${ROOTFS_A_UUID})"
fi

umount "${MNT}"
rmdir  "${MNT}" 2>/dev/null || true
rm -f  "${KERNEL_TMP}" "${DTB_TMP}"

# Switch U-Boot env to boot slot A on next reboot.
# CONFIG_BOOTLOADERHANDLER is not compiled into this swupdate build, so we
# call fw_setenv directly instead of relying on the sw-description bootenv section.
fw_setenv boot_side a upgrade_available 1 bootcount 0
echo "[update-boot-a] U-Boot env: boot_side=a upgrade_available=1"

echo "[update-boot-a] Done."
