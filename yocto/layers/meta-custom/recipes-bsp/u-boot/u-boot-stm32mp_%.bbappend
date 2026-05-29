FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://stm32mp257f-dk-uenv.txt \
    file://boot.cmd                \
"

# mkimage from the native sysroot — avoids relying on the per-config build dir
DEPENDS:append = " u-boot-tools-native"

# Compile the boot script to boot.scr (U-Boot image format)
do_compile:append() {
    mkimage -C none -A arm64 -T script -d \
        ${WORKDIR}/boot.cmd ${WORKDIR}/boot.scr
}

do_install:append() {
    install -d ${D}/boot
    install -m 0644 ${WORKDIR}/stm32mp257f-dk-uenv.txt ${D}/boot/uEnv.txt
    install -m 0644 ${WORKDIR}/boot.scr               ${D}/boot/boot.scr
}
