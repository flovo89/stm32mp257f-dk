DESCRIPTION = "Creates the .swu OTA package for dual A/B SD card update"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://sw-description         \
    file://post-update.sh         \
    file://update-boot-a.sh       \
    file://update-boot-b.sh       \
"

inherit swupdate

# IMAGE_DEPENDS is wired by swupdate-common.bbclass into do_swuimage[depends].
# do_compile[noexec]="1" in the class, so do_compile[depends] is a no-op.
IMAGE_DEPENDS = "stm32mp257f-custom-image virtual/kernel"

SWUPDATE_IMAGES = " \
    stm32mp257f-custom-image    \
    kernel/Image                \
    kernel/stm32mp257f-dk.dtb   \
"

# .rootfs.ext4.gz → looks for stm32mp257f-custom-image[-<machine>].rootfs.ext4.gz in DEPLOY_DIR_IMAGE.
# kernel/Image and kernel/stm32mp257f-dk.dtb: full relative paths — looked up exactly under DEPLOY_DIR_IMAGE.
SWUPDATE_IMAGES_FSTYPES[stm32mp257f-custom-image] = ".rootfs.ext4.gz"
