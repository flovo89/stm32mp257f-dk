DESCRIPTION = "STM32MP257F-DK custom image — Linux on A35, Zephyr on M33, SWUpdate A/B OTA"

inherit core-image

# ---------------------------------------------------------------------------
# Core image features
# ---------------------------------------------------------------------------
IMAGE_FEATURES += " \
    ssh-server-openssh  \
    package-management  \
    debug-tweaks        \
"

# ---------------------------------------------------------------------------
# Package groups
# ---------------------------------------------------------------------------

# Board hardware support
IMAGE_INSTALL:append = " \
    kernel-modules          \
    linux-firmware          \
    i2c-tools               \
    usbutils                \
    mmc-utils               \
    ethtool                 \
    can-utils               \
"

# Filesystem tools (needed for SWUpdate raw writes + userdata formatting)
IMAGE_INSTALL:append = " \
    e2fsprogs               \
    e2fsprogs-tune2fs       \
    dosfstools              \
    util-linux              \
    util-linux-blkid        \
"

# Network
IMAGE_INSTALL:append = " \
    networkd-config         \
    openssh                 \
    openssh-sftp-server     \
    iproute2                \
"

# OTA update stack
IMAGE_INSTALL:append = " \
    swupdate                \
    libubootenv             \
    libubootenv-bin         \
"

# M33 coprocessor firmware + startup service
IMAGE_INSTALL:append = " \
    m33-firmware            \
"

# Debug / development helpers (remove for production)
IMAGE_INSTALL:append = " \
    strace                  \
    gdbserver               \
    procps                  \
    htop                    \
    nano                    \
    ldd                     \
    memtester               \
"

IMAGE_ROOTFS_SIZE        = "524288"
IMAGE_ROOTFS_EXTRA_SPACE = "65536"

# ---------------------------------------------------------------------------
# Workarounds
# ---------------------------------------------------------------------------
# etnaviv GPU driver triggers an OP-TEE PLL lock timeout (panic in
# clk_stm32_pll_init) on OP-TEE 4.0.0-stm32mp-r3. GPU is not needed for
# the A35+M33 use case, so blacklist the module.
ROOTFS_POSTPROCESS_COMMAND:append = " blacklist_etnaviv; "
blacklist_etnaviv() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/modprobe.d
    echo "blacklist etnaviv" > ${IMAGE_ROOTFS}${sysconfdir}/modprobe.d/blacklist-etnaviv.conf
}
