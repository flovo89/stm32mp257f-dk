#!/bin/bash
# =============================================================================
# Flash STM32MP257F-DK SD card from Yocto build artifacts
# USAGE: sudo ./scripts/flash-sdcard.sh /dev/sdX [deploy_dir]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="${1:-}"
DEPLOY="${2:-${SCRIPT_DIR}/../yocto/build/tmp/deploy/images/stm32mp257f-dk}"

# ---- sanity checks ----
if [ -z "${DEV}" ]; then
    echo "Usage: $0 /dev/sdX [deploy_dir]"
    echo "  List removable block devices: lsblk -d -o NAME,SIZE,MODEL,TRAN"
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

# Guard against accidentally targeting a system drive (>= 64 GB)
SIZE_BYTES=$(blockdev --getsize64 "${DEV}")
SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
if [ "${SIZE_GB}" -gt 63 ]; then
    echo "ERROR: ${DEV} looks too large (${SIZE_GB} GB). Aborting."
    exit 1
fi

echo "=== Flashing ${DEV} (${SIZE_GB} GB) ==="
echo "Deploy dir: ${DEPLOY}"
echo ""
echo "WARNING: ALL DATA ON ${DEV} WILL BE ERASED."
read -r -p "Type 'yes' to continue: " CONFIRM
[ "${CONFIRM}" = "yes" ] || { echo "Aborted."; exit 1; }

# ---- locate artifacts ----
TFA="${DEPLOY}/tf-a-stm32mp257f-dk.stm32"
FIP="${DEPLOY}/fip-stm32mp257f-dk.bin"
KERNEL_DIR="${DEPLOY}"      # fitImage lives here
ROOTFS="${DEPLOY}/stm32mp257f-custom-image-stm32mp257f-dk.ext4"

for f in "${TFA}" "${FIP}" "${ROOTFS}"; do
    if [ ! -f "${f}" ]; then
        echo "ERROR: missing artifact: ${f}"
        echo "Run 'bitbake stm32mp257f-custom-image' first."
        exit 1
    fi
done

# ---- unmount any auto-mounted partitions ----
umount "${DEV}"?* 2>/dev/null || true

# ---- wipe existing partition table ----
dd if=/dev/zero of="${DEV}" bs=1M count=10 status=progress

# ---- create GPT partition table ----
sgdisk --zap-all "${DEV}"

# Sizes in MiB
MiB=1048576
P=1   # partition counter

create_part() {
    local label=$1 size_mib=$2
    # Find the next free sector
    START=$(sgdisk -F "${DEV}")
    END=$((START + size_mib * 1024 * 1024 / 512 - 1))
    sgdisk -n "${P}:${START}:+${size_mib}M" -c "${P}:${label}" "${DEV}"
    P=$((P+1))
}

create_part fsbl1     1      # p1
create_part fsbl2     1      # p2
create_part metadata1 1      # p3
create_part metadata2 1      # p4
create_part fip-a     4      # p5
create_part fip-b     4      # p6
create_part uenv      1      # p7
create_part boot-a    64     # p8
create_part boot-b    64     # p9
create_part rootfs-a  2048   # p10
create_part rootfs-b  2048   # p11

# userdata fills the rest
sgdisk -n "${P}:0:0" -c "${P}:userdata" "${DEV}"

partprobe "${DEV}" 2>/dev/null || true
sleep 2

# Helper: resolve partition device node (/dev/sdb1 or /dev/mmcblk0p1)
part() {
    local n=$1
    if [[ "${DEV}" =~ [0-9]$ ]]; then
        echo "${DEV}p${n}"
    else
        echo "${DEV}${n}"
    fi
}

echo ""
echo "=== Writing FSBL (TF-A BL2) ==="
dd if="${TFA}" of="$(part 1)" bs=512 status=progress
dd if="${TFA}" of="$(part 2)" bs=512 status=progress

echo ""
echo "=== Writing FIP (OP-TEE + U-Boot) ==="
dd if="${FIP}" of="$(part 5)" bs=512 status=progress

echo ""
echo "=== Writing U-Boot default environment ==="
UENV_TXT="${SCRIPT_DIR}/../yocto/layers/meta-custom/recipes-bsp/u-boot/files/stm32mp257f-dk-uenv.txt"
if [ -f "${UENV_TXT}" ]; then
    dd if=/dev/zero of="$(part 7)" bs=512 count=2048 status=none
    # fw_setenv requires fw_env.config — use raw dd for initial provisioning
    cp "${UENV_TXT}" /tmp/uenv_raw.txt
fi

echo ""
echo "=== Formatting boot partitions (FAT32) ==="
mkfs.fat -F 32 -n boot-a "$(part 8)"
mkfs.fat -F 32 -n boot-b "$(part 9)"

echo ""
echo "=== Copying kernel + DTB to boot-a ==="
MOUNT=$(mktemp -d)
mount "$(part 8)" "${MOUNT}"
for f in fitImage stm32mp257f-dk.dtb; do
    [ -f "${KERNEL_DIR}/${f}" ] && cp "${KERNEL_DIR}/${f}" "${MOUNT}/" && echo "  ${f}"
done
umount "${MOUNT}"
rmdir "${MOUNT}"

echo ""
echo "=== Writing rootfs to rootfs-a ==="
dd if="${ROOTFS}" of="$(part 10)" bs=4M status=progress
e2fsck -fp "$(part 10)" || true
resize2fs "$(part 10)"

echo ""
echo "=== Formatting rootfs-b (empty, for OTA) ==="
mkfs.ext4 -L rootfs-b "$(part 11)"

echo ""
echo "=== Formatting userdata ==="
mkfs.ext4 -L userdata "$(part 12)"

sync
echo ""
echo "=== DONE — SD card ready ==="
echo "Insert into STM32MP257F-DK, boot switch to SD card."
echo ""
echo "First SSH login (after boot):"
echo "  ssh root@192.168.7.80"
