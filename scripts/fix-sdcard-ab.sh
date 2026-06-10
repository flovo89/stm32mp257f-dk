#!/bin/bash
# =============================================================================
# Fix an A/B SD card image written by wic:
#   1. Set fip-a/fip-b PARTUUIDs to match what metadata.bin expects
#   2. Copy DTB from kernel/ subdir to the root of boot-a
#   3. Create extlinux/extlinux.conf on boot-a so U-Boot can boot the kernel
#
# USAGE: sudo ./scripts/fix-sdcard-ab.sh /dev/mmcblk0 [deploy_dir]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="${1:-}"
DEPLOY="${2:-${SCRIPT_DIR}/../yocto/build/tmp/deploy/images/stm32mp25-disco}"

if [ -z "${DEV}" ]; then
    echo "Usage: $0 /dev/mmcblk0 [deploy_dir]"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo $0 $*)"
    exit 1
fi

METADATA="${DEPLOY}/arm-trusted-firmware/metadata.bin"
if [ ! -f "${METADATA}" ]; then
    echo "ERROR: missing ${METADATA}"
    exit 1
fi

# ---- extract expected PARTUUIDs from metadata.bin -------------------------
FIP_A_UUID=$(python3 -c "import uuid; d=open('${METADATA}','rb').read(); print(str(uuid.UUID(bytes_le=d[72:88])).upper())")
FIP_B_UUID=$(python3 -c "import uuid; d=open('${METADATA}','rb').read(); print(str(uuid.UUID(bytes_le=d[96:112])).upper())")
echo "  fip-a PARTUUID (from metadata.bin): ${FIP_A_UUID}"
echo "  fip-b PARTUUID (from metadata.bin): ${FIP_B_UUID}"

# ---- fix fip-a/fip-b PARTUUIDs --------------------------------------------
echo ""
echo "=== Fixing fip-a and fip-b PARTUUIDs ==="
umount "${DEV}"p* 2>/dev/null || umount "${DEV}"[0-9]* 2>/dev/null || true
sgdisk --partition-guid=5:"${FIP_A_UUID}" "${DEV}"
sgdisk --partition-guid=6:"${FIP_B_UUID}" "${DEV}"
partprobe "${DEV}" 2>/dev/null || true
sleep 1
echo "  Done."

# ---- remount boot-a -------------------------------------------------------
BOOT_MNT="/tmp/fix-boot-a-$$"
mkdir -p "${BOOT_MNT}"

# Find boot-a partition (p8 in our layout)
BOOT_A_DEV=""
for p in "${DEV}p8" "${DEV}8"; do
    [ -b "${p}" ] && BOOT_A_DEV="${p}" && break
done
if [ -z "${BOOT_A_DEV}" ]; then
    # Try by-partlabel
    BOOT_A_DEV="/dev/disk/by-partlabel/boot-a"
fi

echo ""
echo "=== Fixing boot-a partition (${BOOT_A_DEV}) ==="
mount -t vfat "${BOOT_A_DEV}" "${BOOT_MNT}"

# Copy DTB from kernel/ subdir to FAT root (wic puts it in a subdirectory)
if [ -f "${BOOT_MNT}/kernel/stm32mp257f-dk.dtb" ]; then
    cp "${BOOT_MNT}/kernel/stm32mp257f-dk.dtb" "${BOOT_MNT}/stm32mp257f-dk.dtb"
    echo "  Copied DTB to FAT root."
fi

# Get rootfs-a PARTUUID (p10 in our layout)
ROOTFS_A_UUID=""
for p in "${DEV}p10" "${DEV}10"; do
    if [ -b "${p}" ]; then
        ROOTFS_A_UUID=$(blkid -s PARTUUID -o value "${p}" 2>/dev/null || true)
        break
    fi
done
if [ -z "${ROOTFS_A_UUID}" ]; then
    ROOTFS_A_UUID=$(blkid -s PARTUUID -o value /dev/disk/by-partlabel/rootfs-a 2>/dev/null || true)
fi
echo "  rootfs-a PARTUUID: ${ROOTFS_A_UUID}"

# Create extlinux.conf
mkdir -p "${BOOT_MNT}/extlinux"
cat > "${BOOT_MNT}/extlinux/extlinux.conf" << EOF
TIMEOUT 20
DEFAULT STM32MP25

LABEL STM32MP25
    KERNEL /fitImage
    FDT /stm32mp257f-dk.dtb
    APPEND root=PARTUUID=${ROOTFS_A_UUID} rootwait rw earlycon console=ttySTM0,115200
EOF
echo "  Created extlinux/extlinux.conf."

umount "${BOOT_MNT}"
rmdir "${BOOT_MNT}"
sync

echo ""
echo "=== SD card fix complete ==="
echo "  Insert card and power on the board."
