DESCRIPTION = "Creates the .swu OTA package for dual A/B SD card update"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://sw-description         \
    file://post-update.sh         \
"

# Pull in the image artifacts we'll bundle
do_compile[depends] += " \
    stm32mp257f-custom-image:do_image_complete \
    virtual/kernel:do_deploy                  \
"

inherit swupdate

SWUPDATE_IMAGES = " \
    stm32mp257f-custom-image \
    fitImage                 \
"

SWUPDATE_IMAGES_FSTYPES[stm32mp257f-custom-image] = ".ext4.gz"
SWUPDATE_IMAGES_FSTYPES[fitImage]                 = ""

S = "${WORKDIR}"
