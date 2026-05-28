DESCRIPTION = "STM32MP257F-DK custom image — Linux on A35, Zephyr on M33, SWUpdate A/B OTA"

inherit core-image

# ---------------------------------------------------------------------------
# Core image features
# ---------------------------------------------------------------------------
IMAGE_FEATURES += " \
    ssh-server-openssh  \
    package-management  \
    read-only-rootfs-delayed-writes \
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
