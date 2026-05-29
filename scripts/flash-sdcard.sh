#!/bin/bash
# =============================================================================
# Flash STM32MP257F-DK SD card from Yocto build artifacts.
# Partition layout matches the ST TSV (FlashLayout_sdcard_stm32mp257f-dk-optee).
#
# USAGE: sudo ./scripts/flash-sdcard.sh /dev/sdX [deploy_dir]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="${1:-}"
DEPLOY="${2:-${SCRIPT_DIR}/../yocto/build/tmp/deploy/images/stm32mp25-disco}"

# ---------------------------------------------------------------------------
# Partition layout — sector offsets derived from ST TSV (512-byte sectors)
#
#  #  Name        Start       End         Size
#  1  fsbla1          34         545      256 KB  TF-A BL2 primary
#  2  fsbla2         546        1057      256 KB  TF-A BL2 backup
#  3  metadata1     1058        1569      256 KB  FWU metadata primary
#  4  metadata2     1570        2081      256 KB  FWU metadata backup
#  5  fip-a         2082       10273        4 MB  FIP slot A (OP-TEE + U-Boot)
#  6  fip-b        10274       18465        4 MB  FIP slot B (OTA target)
#  7  u-boot-env   18466       19489      512 KB  U-Boot environment
#  8  bootfs       19490      150561       64 MB  Kernel + DTBs
#  9  vendorfs    150562      662561      250 MB  Vendor filesystem
# 10  rootfs      662562     9051169     4096 MB  Root filesystem
# 11  userfs      9051170     end        rest     Persistent user data
# ---------------------------------------------------------------------------

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
if [ "${SIZE_GB}" -lt 14 ]; then
    echo "ERROR: ${DEV} is too small (${SIZE_GB} GB). Need at least 16 GB."
    exit 1
fi

# ---- locate artifacts -----------------------------------------------------
# Use the plain (non-OSTL) variants so that U-Boot loads stm32mp257f-dk.dtb.
# The OSTL external-DT variants force fdtfile=stm32mp257f-dk-ca35tdcid-ostl-*.dtb
# which sets m33_rproc compatible="st,stm32mp2-m33-tee" (requires signed firmware).
# The plain kernel DTS uses compatible="st,stm32mp2-m33" and allows unsigned firmware.
# The OP-TEE PLL panic that previously required the OSTL variant is avoided by
# blacklisting the etnaviv GPU driver in /etc/modprobe.d/blacklist-etnaviv.conf.
TFA="${DEPLOY}/arm-trusted-firmware/tf-a-stm32mp257f-dk-optee-sdcard.stm32"
METADATA="${DEPLOY}/arm-trusted-firmware/metadata.bin"
FIP="${DEPLOY}/fip/fip-stm32mp257f-dk-optee-sdcard.bin"
BOOTFS="${DEPLOY}/stm32mp257f-custom-image-stm32mp25-disco.splitted-bootfs.ext4"
VENDORFS="${DEPLOY}/stm32mp257f-custom-image-stm32mp25-disco.splitted-vendorfs.ext4"
ROOTFS="${DEPLOY}/stm32mp257f-custom-image-stm32mp25-disco.splitted-rootfs.ext4"
USERFS="${DEPLOY}/stm32mp257f-custom-image-stm32mp25-disco.splitted-userfs.ext4"

for f in "${TFA}" "${METADATA}" "${FIP}" "${BOOTFS}" "${VENDORFS}" "${ROOTFS}" "${USERFS}"; do
    if [ ! -f "${f}" ]; then
        echo "ERROR: missing artifact: ${f}"
        echo "Run 'bitbake stm32mp257f-custom-image' first."
        exit 1
    fi
done

echo "=== Flashing STM32MP257F-DK: ${DEV} (${SIZE_GB} GB) ==="
echo ""
echo "  TF-A    : ${TFA}"
echo "  FIP     : ${FIP}"
echo "  bootfs  : ${BOOTFS}"
echo "  vendorfs: ${VENDORFS}"
echo "  rootfs  : ${ROOTFS}"
echo "  userfs  : ${USERFS}"
echo ""
echo "WARNING: ALL DATA ON ${DEV} WILL BE ERASED."
read -r -p "Type 'yes' to continue: " CONFIRM
[ "${CONFIRM}" = "yes" ] || { echo "Aborted."; exit 1; }

# ---- helper: resolve partition device node --------------------------------
# /dev/sdb  → /dev/sdb1, /dev/sdb2, ...
# /dev/mmcblk0 → /dev/mmcblk0p1, /dev/mmcblk0p2, ...
part() {
    local n=$1
    if [[ "${DEV}" =~ [0-9]$ ]]; then
        echo "${DEV}p${n}"
    else
        echo "${DEV}${n}"
    fi
}

# ---- unmount any auto-mounted partitions ----------------------------------
umount "${DEV}"?* 2>/dev/null || true

# ---- wipe first 10 MB (clears old GPT / partition signatures) -------------
echo ""
echo "=== Wiping partition table ==="
dd if=/dev/zero of="${DEV}" bs=1M count=10 status=progress
sync

# ---- create GPT with ST partition layout ----------------------------------
echo ""
echo "=== Creating GPT ==="
sgdisk --zap-all "${DEV}"

# -a 1 disables sector-alignment enforcement so we can use the exact ST offsets
# Raw binary partitions (TF-A, metadata, FIP)
sgdisk -a 1 -n  1:34:545        -c  1:fsbla1     -t  1:8300 "${DEV}"
sgdisk -a 1 -n  2:546:1057      -c  2:fsbla2     -t  2:8300 "${DEV}"
sgdisk -a 1 -n  3:1058:1569     -c  3:metadata1  -t  3:8300 "${DEV}"
sgdisk -a 1 -n  4:1570:2081     -c  4:metadata2  -t  4:8300 "${DEV}"
sgdisk -a 1 -n  5:2082:10273    -c  5:fip-a      -t  5:8300 "${DEV}"
sgdisk -a 1 -n  6:10274:18465   -c  6:fip-b      -t  6:8300 "${DEV}"
sgdisk -a 1 -n  7:18466:19489   -c  7:u-boot-env -t  7:8300 "${DEV}"
# Filesystem partitions (naturally aligned)
sgdisk -a 1 -n  8:19490:150561  -c  8:bootfs     -t  8:8300 "${DEV}"
sgdisk -a 1 -n  9:150562:662561 -c  9:vendorfs   -t  9:8300 "${DEV}"
sgdisk -a 1 -n 10:662562:9051169 -c 10:rootfs    -t 10:8300 "${DEV}"
sgdisk -a 1 -n 11:9051170:0     -c 11:userfs     -t 11:8300 "${DEV}"

# Fix 1: set fip-a / fip-b PARTUUIDs to match what metadata.bin expects.
# TF-A reads the metadata and looks for partitions with these exact UUIDs.
FIP_A_UUID=$(python3 -c "import uuid; d=open('${METADATA}','rb').read(); print(str(uuid.UUID(bytes_le=d[72:88])).upper())")
FIP_B_UUID=$(python3 -c "import uuid; d=open('${METADATA}','rb').read(); print(str(uuid.UUID(bytes_le=d[96:112])).upper())")
echo "  fip-a PARTUUID : ${FIP_A_UUID}"
echo "  fip-b PARTUUID : ${FIP_B_UUID}"
sgdisk --partition-guid=5:"${FIP_A_UUID}" "${DEV}"
sgdisk --partition-guid=6:"${FIP_B_UUID}" "${DEV}"

# Fix 2: set rootfs PARTUUID to match what extlinux.conf in bootfs expects.
# The kernel uses this PARTUUID to mount the root filesystem.
ROOTFS_UUID=$(python3 -c "
import subprocess, re
r = subprocess.run(['strings', '${BOOTFS}'], capture_output=True, text=True)
m = re.search(r'root=PARTUUID=([0-9a-f-]+)', r.stdout, re.I)
print(m.group(1).upper() if m else '')
")
if [ -n "${ROOTFS_UUID}" ]; then
    echo "  rootfs PARTUUID: ${ROOTFS_UUID}"
    sgdisk --partition-guid=10:"${ROOTFS_UUID}" "${DEV}"
else
    echo "  WARN: could not extract rootfs PARTUUID from extlinux.conf"
fi

# Fix 3: set the GPT bootable attribute on bootfs (partition 8).
# U-Boot's distro_bootcmd runs 'part list -bootable' to find the boot
# partition; without this flag it falls back to partition 1 and hangs.
sgdisk -A 8:set:2 "${DEV}"

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

# ---- write FIP (OP-TEE + U-Boot) ------------------------------------------
echo ""
echo "=== Writing FIP slot A ==="
dd if="${FIP}" of="$(part 5)" bs=512 conv=notrunc status=progress
# Part 6 (fip-b) and part 7 (u-boot-env) left empty — populated by OTA / U-Boot

# ---- write filesystem images ----------------------------------------------
echo ""
echo "=== Writing bootfs ($(du -sh "${BOOTFS}" | cut -f1)) ==="
dd if="${BOOTFS}" of="$(part 8)" bs=4M conv=notrunc status=progress
e2fsck -fp "$(part 8)" || true

echo ""
echo "=== Writing vendorfs ($(du -sh "${VENDORFS}" | cut -f1)) ==="
dd if="${VENDORFS}" of="$(part 9)" bs=4M conv=notrunc status=progress
e2fsck -fp "$(part 9)" || true

echo ""
echo "=== Writing rootfs ($(du -sh "${ROOTFS}" | cut -f1)) ==="
dd if="${ROOTFS}" of="$(part 10)" bs=4M conv=notrunc status=progress
e2fsck -fp "$(part 10)" || true

echo ""
echo "=== Writing userfs ($(du -sh "${USERFS}" | cut -f1)) ==="
dd if="${USERFS}" of="$(part 11)" bs=4M conv=notrunc status=progress
e2fsck -fp "$(part 11)" || true

sync
echo ""
echo "=== DONE — SD card ready ==="
echo ""
echo "  1. Insert SD card into STM32MP257F-DK"
echo "  2. Set boot switch to SD card (BOOT0=1, BOOT1=0, BOOT2=0)"
echo "  3. Power on — Linux boots in ~30 s"
echo ""
echo "  First SSH login:"
echo "    ssh root@192.168.7.80   (empty password)"
