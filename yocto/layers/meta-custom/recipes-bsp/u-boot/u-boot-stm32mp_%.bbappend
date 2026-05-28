FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://stm32mp257f-dk-uenv.txt \
    file://boot.cmd                \
"

# Compile the boot script to boot.scr (U-Boot image format)
do_compile:append() {
    ${B}/tools/mkimage -C none -A arm64 -T script -d \
        ${WORKDIR}/boot.cmd ${WORKDIR}/boot.scr
}

do_install:append() {
    install -d ${D}/boot
    install -m 0644 ${WORKDIR}/stm32mp257f-dk-uenv.txt ${D}/boot/uEnv.txt
    install -m 0644 ${WORKDIR}/boot.scr               ${D}/boot/boot.scr
}

DEPLOYDIR_IMAGE ?= "${DEPLOY_DIR_IMAGE}"
