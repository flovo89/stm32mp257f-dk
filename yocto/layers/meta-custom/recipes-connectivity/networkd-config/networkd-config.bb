DESCRIPTION = "Static IP network configuration for STM32MP257F-DK (eth0 = 192.168.7.80/24)"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://10-eth0.network  \
    file://10-lo.network    \
"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/10-eth0.network ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${WORKDIR}/10-lo.network   ${D}${sysconfdir}/systemd/network/
}

FILES:${PN}  = "${sysconfdir}/systemd/network/*"
RDEPENDS:${PN} = "systemd"
