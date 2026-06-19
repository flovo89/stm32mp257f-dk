DESCRIPTION = "STM32 M33 Dashboard — RPMsg WebSocket bridge and Flutter web frontend"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# frontend-web.tar.gz and rpmsg-ws-server.py are staged by scripts/build-frontend.sh
# before running bitbake.  The recipe will fail loudly if either file is missing.
SRC_URI = " \
    file://frontend-web.tar.gz  \
    file://rpmsg-ws-server.py   \
    file://motor_control.py     \
    file://m33ctl.py             \
    file://m33-dashboard.service \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "m33-dashboard.service"
SYSTEMD_AUTO_ENABLE    = "enable"

# python3-websockets is in meta-openembedded/meta-python
RDEPENDS:${PN} = "python3-core python3-asyncio python3-websockets"

do_install() {
    # Flutter web static files served by the HTTP side of rpmsg-ws-server.py
    install -d ${D}${datadir}/m33-dashboard
    cp -r ${WORKDIR}/web/. ${D}${datadir}/m33-dashboard/

    # WebSocket + HTTP bridge and motor control CLI
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/rpmsg-ws-server.py \
        ${D}${sbindir}/rpmsg-ws-server.py
    install -m 0755 ${WORKDIR}/motor_control.py \
        ${D}${sbindir}/motor_control.py
    install -m 0755 ${WORKDIR}/m33ctl.py \
        ${D}${sbindir}/m33ctl

    # Systemd unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/m33-dashboard.service \
        ${D}${systemd_system_unitdir}/m33-dashboard.service
}

FILES:${PN} = " \
    ${datadir}/m33-dashboard        \
    ${sbindir}/rpmsg-ws-server.py   \
    ${sbindir}/motor_control.py     \
    ${sbindir}/m33ctl               \
    ${systemd_system_unitdir}/m33-dashboard.service \
"
