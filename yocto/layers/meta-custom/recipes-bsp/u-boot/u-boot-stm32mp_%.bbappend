FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://stm32mp257f-dk-uenv.txt \
    file://boot.cmd                \
"

# mkimage + mkenvimage from the native sysroot
DEPENDS:append = " u-boot-tools-native"

do_compile:append() {
    mkimage -C none -A arm64 -T script -d \
        ${WORKDIR}/boot.cmd ${WORKDIR}/boot.scr
}

do_install:append() {
    install -d ${D}/boot
    install -m 0644 ${WORKDIR}/stm32mp257f-dk-uenv.txt ${D}/boot/uEnv.txt
    install -m 0644 ${WORKDIR}/boot.scr               ${D}/boot/boot.scr
}

do_deploy:append() {
    # ST u-boot recipe sets DEPLOYDIR → deploy/images/<machine>/u-boot/
    # Put the env binary at the top level so flash-sdcard-ab.sh finds it
    # alongside the other flash artifacts.
    # -r: redundant format (CRC + flags + data) required by
    # CONFIG_SYS_REDUNDAND_ENVIRONMENT=y; without -r U-Boot fails the CRC
    # check and silently falls back to compiled-in defaults.
    install -d ${DEPLOY_DIR_IMAGE}
    mkenvimage -r -s 0x2000 -o ${DEPLOY_DIR_IMAGE}/u-boot-env-ab.bin \
        ${WORKDIR}/stm32mp257f-dk-uenv.txt
}
