FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://swupdate.cfg    \
    file://fw_env.config   \
"

# Enable the web UI (port 8080) so you can push .swu files via browser/curl
PACKAGECONFIG:append = " webserver mongoose"

do_install:append() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/swupdate.cfg  ${D}${sysconfdir}/swupdate.cfg
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}

FILES:${PN}:append = " \
    ${sysconfdir}/swupdate.cfg   \
    ${sysconfdir}/fw_env.config  \
"
