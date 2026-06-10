#!/bin/bash
# =============================================================================
# Flash STM32MP257F-DK SD card with dual A/B OTA layout.
# Replaces the ST single-rootfs layout; required before ota-update.sh can work.
#
# USAGE: sudo ./scripts/flash-sdcard-ab.sh /dev/sdX [deploy_dir]
#
# Partition map:
#  #  Label       Sectors       Size      Contents
#  1  fsbl1       34:545        256 KB    TF-A BL2 primary
#  2  fsbl2       546:1057      256 KB    TF-A BL2 backup
#  3  metadata1   1058:1569     256 KB    FWU metadata primary
#  4  metadata2   1570:2081     256 KB    FWU metadata backup
#  5  fip-a       2082:10273    4 MB      FIP slot A (OP-TEE + U-Boot)
#  6  fip-b       10274:18465   4 MB      FIP slot B (OTA target)
#  7  uenv        18466:19489   512 KB    U-Boot environment
#  8  boot-a      19490:150561  64 MB     FAT32  kernel + DTB slot A  <- initial
#  9  boot-b      150562:281633 64 MB     FAT32  kernel + DTB slot B
# 10  rootfs-a    281634:+2500M           ext4   root filesystem slot A <- initial
# 11  rootfs-b    +2500M                  ext4   root filesystem slot B
# 12  userdata    rest                    ext4   persistent user data
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="${1:-}"
DEPLOY="${2:-${SCRIPT_DIR}/../yocto/build/tmp/deploy/images/stm32mp25-disco}"

# ---- sanity checks --------------------------------------------------------
if [ -z "${DEV}" ]; then
    echo "Usage: $0 /dev/sdX [deploy_dir]"
    echo "  List block devices: lsblk -d -o NAME,SIZE,MODEL,TRAN"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo $0 $*)"
    exit 1
fi
if [ ! -b "${DEV}" ]; then
    echo "ERROR: ${DEV} is not a block device"
    exit 1
fi
SIZE_BYTES=$(blockdev --getsize64 "${DEV}")
SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
if [ "${SIZE_GB}" -gt 63 ]; then
    echo "ERROR: ${DEV} looks too large (${SIZE_GB} GB) — aborting to avoid wiping a system drive."
    exit 1
fi
if [ "${SIZE_GB}" -lt 6 ]; then
    echo "ERROR: ${DEV} is too small (${SIZE_GB} GB). Need at least 6 GB."
    echo "  Layout requires ~5.1 GB: 2x2500 MB rootfs + 2x64 MB boot + FIP/TF-A."
    exit 1
fi

# ---- locate artifacts -----------------------------------------------------
TFA="${DEPLOY}/arm-trusted-firmware/tf-a-stm32mp257f-dk-optee-sdcard.stm32"
METADATA="${DEPLOY}/arm-trusted-firmware/metadata.bin"
FIP="${DEPLOY}/fip/fip-stm32mp257f-dk-optee-sdcard.bin"
ROOTFS="${DEPLOY}/stm32mp257f-custom-image-stm32mp25-disco.rootfs.ext4"
KERNEL="${DEPLOY}/kernel/Image"
DTB="${DEPLOY}/kernel/stm32mp257f-dk.dtb"

for f in "${TFA}" "${METADATA}" "${FIP}" "${ROOTFS}" "${KERNEL}" "${DTB}"; do
    if [ ! -f "${f}" ]; then
        echo "ERROR: missing artifact: ${f}"
        echo "Run 'bitbake stm32mp257f-custom-image' first."
        exit 1
    fi
done

echo "=== Flashing STM32MP257F-DK A/B layout: ${DEV} (${SIZE_GB} GB) ==="
echo ""
echo "  TF-A    : ${TFA}"
echo "  FIP     : ${FIP}"
echo "  rootfs  : ${ROOTFS}"
echo ""
echo "WARNING: ALL DATA ON ${DEV} WILL BE ERASED."
read -r -p "Type 'yes' to continue: " CONFIRM
[ "${CONFIRM}" = "yes" ] || { echo "Aborted."; exit 1; }

# ---- helper: resolve partition device node --------------------------------
part() {
    local n=$1
    if [[ "${DEV}" =~ [0-9]$ ]]; then
        echo "${DEV}p${n}"
    else
        echo "${DEV}${n}"
    fi
}

# ---- unmount ---------------------------------------------------------------
umount "$(part)"?* 2>/dev/null || umount "${DEV}"?* 2>/dev/null || true

# ---- wipe first 10 MB -----------------------------------------------------
echo ""
echo "=== Wiping partition table ==="
dd if=/dev/zero of="${DEV}" bs=1M count=10 status=progress
sync

# ---- create GPT -----------------------------------------------------------
echo ""
echo "=== Creating GPT (A/B dual-boot layout) ==="
sgdisk --zap-all "${DEV}"

# -a 1: disable sector alignment enforcement for exact firmware offsets
# Use fsbla1/fsbla2 — matches ST TSV naming that flash-sdcard.sh uses and that
# works on this board. The ROM expects TF-A at sector 34 (fixed offset).
sgdisk -a 1 -n  1:34:545        -c  1:fsbla1    -t 1:8300 "${DEV}"
sgdisk -a 1 -n  2:546:1057      -c  2:fsbla2    -t 2:8300 "${DEV}"
sgdisk -a 1 -n  3:1058:1569     -c  3:metadata1 -t 3:8300 "${DEV}"
sgdisk -a 1 -n  4:1570:2081     -c  4:metadata2 -t 4:8300 "${DEV}"
sgdisk -a 1 -n  5:2082:10273    -c  5:fip-a     -t 5:8300 "${DEV}"
sgdisk -a 1 -n  6:10274:18465   -c  6:fip-b     -t 6:8300 "${DEV}"
sgdisk -a 1 -n  7:18466:19489   -c  7:uenv      -t 7:8300 "${DEV}"
# Filesystem partitions — standard 2048-sector alignment from here
sgdisk     -n  8:19490:150561   -c  8:boot-a    -t 8:0700 "${DEV}"
sgdisk     -n  9:150562:281633  -c  9:boot-b    -t 9:0700 "${DEV}"
sgdisk     -n 10:281634:+2500M  -c 10:rootfs-a  -t 10:8300 "${DEV}"
sgdisk     -n 11:0:+2500M       -c 11:rootfs-b  -t 11:8300 "${DEV}"
sgdisk     -n 12:0:0            -c 12:userdata  -t 12:8300 "${DEV}"

# ---- fix PARTUUIDs for fip-a/fip-b ----------------------------------------
# TF-A reads FWU metadata.bin which has hardcoded PARTUUIDs for fip-a/fip-b.
FIP_A_UUID=$(python3 -c "import uuid; d=open('${METADATA}','rb').read(); print(str(uuid.UUID(bytes_le=d[72:88])).upper())")
FIP_B_UUID=$(python3 -c "import uuid; d=open('${METADATA}','rb').read(); print(str(uuid.UUID(bytes_le=d[96:112])).upper())")
echo "  fip-a PARTUUID: ${FIP_A_UUID}"
echo "  fip-b PARTUUID: ${FIP_B_UUID}"
sgdisk --partition-guid=5:"${FIP_A_UUID}" "${DEV}"
sgdisk --partition-guid=6:"${FIP_B_UUID}" "${DEV}"

partprobe "${DEV}" 2>/dev/null || true
sleep 2

# ---- write TF-A BL2 -------------------------------------------------------
echo ""
echo "=== Writing TF-A BL2 (primary + backup) ==="
dd if="${TFA}" of="$(part 1)" bs=512 conv=notrunc status=progress
dd if="${TFA}" of="$(part 2)" bs=512 conv=notrunc status=progress

# ---- write FWU metadata ---------------------------------------------------
echo ""
echo "=== Writing FWU metadata ==="
dd if="${METADATA}" of="$(part 3)" bs=512 conv=notrunc status=progress
dd if="${METADATA}" of="$(part 4)" bs=512 conv=notrunc status=progress

# ---- write FIP slot A -----------------------------------------------------
echo ""
echo "=== Writing FIP slot A ==="
dd if="${FIP}" of="$(part 5)" bs=512 conv=notrunc status=progress

# ---- write rootfs-a -------------------------------------------------------
echo ""
echo "=== Writing rootfs-a ($(du -sh "${ROOTFS}" | cut -f1)) ==="
dd if="${ROOTFS}" of="$(part 10)" bs=4M conv=notrunc status=progress
e2fsck -fp "$(part 10)" || true
resize2fs "$(part 10)" || true

# ---- create boot-a FAT32 with kernel, DTB, and extlinux.conf -------------
echo ""
echo "=== Creating boot-a FAT32 ==="
mkfs.vfat -F 32 -n "boot-a" "$(part 8)"

BOOT_MNT="/tmp/flash-ab-boot-$$"
mkdir -p "${BOOT_MNT}"
mount -t vfat "$(part 8)" "${BOOT_MNT}"

# Copy kernel as "fitImage" — boot.cmd uses "load mmc 0:N fitImage"
cp "${KERNEL}" "${BOOT_MNT}/fitImage"
cp "${DTB}"    "${BOOT_MNT}/stm32mp257f-dk.dtb"

# Get rootfs-a PARTUUID for extlinux.conf
ROOTFS_A_UUID=$(blkid -s PARTUUID -o value "$(part 10)" 2>/dev/null)
echo "  rootfs-a PARTUUID: ${ROOTFS_A_UUID}"

mkdir -p "${BOOT_MNT}/extlinux"
cat > "${BOOT_MNT}/extlinux/extlinux.conf" << EOF
TIMEOUT 20
DEFAULT STM32MP25

LABEL STM32MP25
    KERNEL /fitImage
    FDT /stm32mp257f-dk.dtb
    APPEND root=PARTUUID=${ROOTFS_A_UUID} rootwait rw earlycon console=ttySTM0,115200
EOF

umount "${BOOT_MNT}"
rmdir  "${BOOT_MNT}"

# ---- create boot-b FAT32 with its own extlinux.conf -----------------------
echo ""
echo "=== Creating boot-b FAT32 ==="
mkfs.vfat -F 32 -n "boot-b" "$(part 9)"

BOOT_B_MNT="/tmp/flash-ab-bootb-$$"
mkdir -p "${BOOT_B_MNT}"
mount -t vfat "$(part 9)" "${BOOT_B_MNT}"
cp "${KERNEL}" "${BOOT_B_MNT}/fitImage"
cp "${DTB}"    "${BOOT_B_MNT}/stm32mp257f-dk.dtb"

ROOTFS_B_UUID=$(blkid -s PARTUUID -o value "$(part 11)" 2>/dev/null)
echo "  rootfs-b PARTUUID: ${ROOTFS_B_UUID}"

mkdir -p "${BOOT_B_MNT}/extlinux"
cat > "${BOOT_B_MNT}/extlinux/extlinux.conf" << EOF
TIMEOUT 20
DEFAULT STM32MP25

LABEL STM32MP25
    KERNEL /fitImage
    FDT /stm32mp257f-dk.dtb
    APPEND root=PARTUUID=${ROOTFS_B_UUID} rootwait rw earlycon console=ttySTM0,115200
EOF

umount "${BOOT_B_MNT}"
rmdir  "${BOOT_B_MNT}"

# ---- write U-Boot environment to absolute MMC offsets ---------------------
# Primary:   0x900000 = sector 18432  (tail of fip-b, CONFIG_ENV_OFFSET)
# Redundant: 0x940000 = sector 18944  (inside uenv,   CONFIG_ENV_OFFSET_REDUND)
echo ""
echo "=== Writing U-Boot environment ==="

UENV_IMG="${DEPLOY}/u-boot-env-ab.bin"
if [ ! -f "${UENV_IMG}" ]; then
    echo "ERROR: ${UENV_IMG} not found."
    echo "  Run: bitbake u-boot-stm32mp"
    exit 1
fi

dd if="${UENV_IMG}" of="${DEV}" bs=512 seek=18432 conv=notrunc status=none
dd if="${UENV_IMG}" of="${DEV}" bs=512 seek=18944 conv=notrunc status=none
echo "  U-Boot env written (sectors 18432 + 18944)."

# ---- create empty ext4 for rootfs-b and userdata --------------------------
echo ""
echo "=== Creating empty rootfs-b ext4 ==="
mkfs.ext4 -L rootfs-b "$(part 11)"

echo ""
echo "=== Creating userdata ext4 ==="
mkfs.ext4 -L userdata "$(part 12)"

sync
echo ""
echo "=== DONE — SD card ready for A/B OTA ==="
echo ""
echo "  1. Insert SD card into STM32MP257F-DK"
echo "  2. Set boot switch to SD card (BOOT0=1, BOOT1=0, BOOT2=0)"
echo "  3. Power on — Linux boots from slot A in ~30 s"
echo ""
echo "  OTA update:"
echo "    ./scripts/ota-update.sh <board-ip> swupdate-image-stm32mp25-disco.rootfs.swu"
