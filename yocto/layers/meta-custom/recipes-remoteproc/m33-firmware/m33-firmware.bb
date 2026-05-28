DESCRIPTION = "Zephyr firmware for Cortex-M33 + systemd service to load it via remoteproc"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# The Zephyr ELF is built out-of-tree (see zephyr-app/) and placed here
# before running bitbake.  The recipe fails loudly if the file is missing.
SRC_URI = " \
    file://zephyr.elf;unpack=false        \
    file://m33-firmware-start.sh          \
    file://m33-firmware-start.service     \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN}  = "m33-firmware-start.service"
SYSTEMD_AUTO_ENABLE    = "enable"

do_install() {
    # Firmware binary — Linux remoteproc looks for files in /lib/firmware/
    install -d ${D}${nonarch_base_libdir}/firmware
    install -m 0644 ${WORKDIR}/zephyr.elf \
        ${D}${nonarch_base_libdir}/firmware/zephyr-m33.elf

    # Helper script
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/m33-firmware-start.sh \
        ${D}${sbindir}/m33-firmware-start.sh

    # Systemd unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/m33-firmware-start.service \
        ${D}${systemd_system_unitdir}/m33-firmware-start.service
}

FILES:${PN} = " \
    ${nonarch_base_libdir}/firmware/zephyr-m33.elf   \
    ${sbindir}/m33-firmware-start.sh                 \
    ${systemd_system_unitdir}/m33-firmware-start.service \
"
