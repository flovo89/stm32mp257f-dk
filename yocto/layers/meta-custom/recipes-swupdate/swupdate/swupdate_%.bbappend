FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://swupdate.cfg              \
    file://fw_env.config             \
    file://systemd.cfg               \
    file://09-accepted-selections.sh \
"

# NOTE: swupdate uses Kconfig (via defconfig + .cfg fragments), not PACKAGECONFIG.
# CONFIG_WEBSERVER=y and CONFIG_MONGOOSE=y are already set in the upstream defconfig.
# CONFIG_SYSTEMD=y is added via files/systemd.cfg so the daemon calls sd_notify(READY=1)
# and systemd (Type=notify) does not kill it after TimeoutStartSec.

do_install:append() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/swupdate.cfg  ${D}${sysconfdir}/swupdate.cfg
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
    install -d ${D}${sysconfdir}/swupdate/conf.d
    install -m 0755 ${WORKDIR}/09-accepted-selections.sh \
        ${D}${sysconfdir}/swupdate/conf.d/09-accepted-selections.sh
}

FILES:${PN}:append = " \
    ${sysconfdir}/swupdate.cfg                          \
    ${sysconfdir}/fw_env.config                         \
    ${sysconfdir}/swupdate/conf.d/09-accepted-selections.sh \
"
