DESCRIPTION = "Zephyr firmware for Cortex-M33 + systemd service to load it via remoteproc"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# The Zephyr ELF is built out-of-tree (see zephyr-app/) and placed here
# before running bitbake.  The recipe fails loudly if the file is missing.
SRC_URI = " \
    file://zephyr.elf;unpack=false        \
    file://m33-firmware-start.sh          \
    file://m33-firmware-start.service     \
    file://rpmsg-chat.sh                  \
"

S = "${WORKDIR}"

inherit systemd

# zephyr-m33.elf is a 32-bit ARM Thumb binary (Cortex-M33) intentionally
# packaged inside an AArch64 image — skip the architecture QA check.
INSANE_SKIP:${PN} = "arch"
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"

SYSTEMD_SERVICE:${PN}  = "m33-firmware-start.service"
SYSTEMD_AUTO_ENABLE    = "enable"

do_install() {
    # Firmware binary — Linux remoteproc looks for files in /lib/firmware/
    install -d ${D}${nonarch_base_libdir}/firmware
    install -m 0644 ${WORKDIR}/zephyr.elf \
        ${D}${nonarch_base_libdir}/firmware/zephyr-m33.elf

    # Helper scripts
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/m33-firmware-start.sh \
        ${D}${sbindir}/m33-firmware-start.sh
    install -m 0755 ${WORKDIR}/rpmsg-chat.sh \
        ${D}${sbindir}/rpmsg-chat.sh

    # Systemd unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/m33-firmware-start.service \
        ${D}${systemd_system_unitdir}/m33-firmware-start.service
}

FILES:${PN} = " \
    ${nonarch_base_libdir}/firmware/zephyr-m33.elf   \
    ${sbindir}/m33-firmware-start.sh                 \
    ${sbindir}/rpmsg-chat.sh                         \
    ${systemd_system_unitdir}/m33-firmware-start.service \
"
