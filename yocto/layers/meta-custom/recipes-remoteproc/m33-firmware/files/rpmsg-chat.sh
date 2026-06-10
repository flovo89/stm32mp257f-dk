#!/bin/sh
# =============================================================================
# Interactive RPMsg chat with the M33 Zephyr firmware.
#
# The M33 app:
#   - Echoes every message sent from Linux back to Linux
#   - Sends "M33 heartbeat #N" every 10 s once a client is connected
#
# USAGE (on the board, as root):
#   ./rpmsg-chat.sh           # interactive: type lines, see echo + heartbeats
#   ./rpmsg-chat.sh listen    # read-only (show heartbeats only)
#   ./rpmsg-chat.sh send "hi" # send one message and exit
#
# Prerequisites:
#   - M33 firmware running:  systemctl status m33-firmware-start
# =============================================================================
set -eu

EPT_NAME="m33-ctrl"
MODE="${1:-chat}"

# ---- find the m33-ctrl rpmsg channel device --------------------------------
RPMSG_SYSFS=$(ls -d /sys/bus/rpmsg/devices/virtio*.m33-ctrl.* 2>/dev/null | head -n 1)
if [ -z "${RPMSG_SYSFS}" ]; then
    echo "ERROR: no '${EPT_NAME}' rpmsg channel found. Is the M33 running?"
    echo "  systemctl start m33-firmware-start"
    exit 1
fi
RPMSG_DEV_NAME=$(basename "${RPMSG_SYSFS}")

# ---- bind rpmsg_chrdev driver if not already bound -------------------------
if [ ! -e "${RPMSG_SYSFS}/driver" ]; then
    echo "Binding rpmsg_chrdev to ${RPMSG_DEV_NAME}..."
    echo "rpmsg_chrdev" > "${RPMSG_SYSFS}/driver_override"
    echo "${RPMSG_DEV_NAME}" > /sys/bus/rpmsg/drivers/rpmsg_chrdev/bind
    sleep 0.2
fi

# ---- find the resulting /dev/rpmsgN ----------------------------------------
RPMSG_DEV=$(ls /dev/rpmsg[0-9]* 2>/dev/null | grep -v ctrl | head -n 1)
if [ -z "${RPMSG_DEV}" ]; then
    echo "ERROR: no /dev/rpmsgN device appeared. Check dmesg."
    exit 1
fi
echo "Connected via ${RPMSG_DEV}"

# ---- open once for read+write (avoids "device busy" on second open) --------
exec 3<>"${RPMSG_DEV}"

cleanup() {
    kill "${READ_PID}" 2>/dev/null || true
    exec 3>&-
}
trap cleanup EXIT

# ---- background reader (M33 sends \n-terminated messages) ------------------
# BusyBox's 'read <&3' on an O_RDWR fd is unreliable; cat <&3 works correctly.
cat <&3 | while IFS= read -r msg; do
    printf "[M33] %s\n" "${msg}"
done &
READ_PID=$!

# ---- mode ------------------------------------------------------------------
case "${MODE}" in
    listen)
        echo "Listening for M33 messages (Ctrl-C to stop)..."
        wait "${READ_PID}"
        ;;
    send)
        MSG="${2:-ping}"
        printf "%s" "${MSG}" >&3
        echo "[A35→M33] ${MSG}"
        sleep 0.5   # wait for echo
        ;;
    chat|*)
        echo "Chat mode — type a message and press Enter. Ctrl-D to quit."
        echo "M33 echoes every message back and sends heartbeats once connected."
        echo "---"
        while IFS= read -r line; do
            printf "%s" "${line}" >&3
            echo "[A35→M33] ${line}"
        done
        ;;
esac
