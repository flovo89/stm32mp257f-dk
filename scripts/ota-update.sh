#!/bin/bash
# =============================================================================
# Push an OTA update (.swu file) to the board via ethernet.
# Automatically selects the inactive slot.
# USAGE: ./scripts/ota-update.sh update.swu [board_ip]
#
# Flow:
#   1. SSH to board to read the currently active slot from U-Boot env
#   2. SCP the .swu to /tmp on the board
#   3. swupdate-client sends it to the running swupdate daemon with -e selection
#      (the IPC socket approach avoids the mongoose v1 /upload endpoint which
#       does not parse the 'selection' form field)
#   4. SSH reboot — U-Boot will boot the updated slot
# =============================================================================
set -euo pipefail

SWU="${1:-}"
BOARD_IP="${2:-192.168.7.80}"

if [ -z "${SWU}" ]; then
    echo "Usage: $0 <update.swu> [board_ip]"
    exit 1
fi
if [ ! -f "${SWU}" ]; then
    echo "ERROR: ${SWU} not found"
    exit 1
fi

echo "=== OTA update: ${SWU} → ${BOARD_IP} ==="

# Query the currently active slot.
# Two failure modes to handle:
#   1. SSH fails (board unreachable)         → || echo "a" fires
#   2. SSH succeeds but boot_side not yet set → fw_printenv prints nothing,
#      cut returns "", the || never fires, and CURRENT_SIDE ends up empty.
# Mode 2 happens on first OTA (boot_side is only written by a successful OTA
# script run).  Treat empty as "a" — the board defaults to slot A when
# boot_side is absent, so copy2 (write slot B) is the safe choice.
echo "Querying active slot..."
CURRENT_SIDE=$(ssh root@"${BOARD_IP}" \
    "fw_printenv boot_side 2>/dev/null | cut -d= -f2" 2>/dev/null || echo "a")
if [ -z "${CURRENT_SIDE}" ]; then
    echo "WARNING: boot_side not set in U-Boot env — defaulting to slot a (first install)"
    CURRENT_SIDE="a"
fi
echo "Currently booted: slot ${CURRENT_SIDE}"

if [ "${CURRENT_SIDE}" = "a" ]; then
    SELECTION="stable,copy2"
    TARGET_SLOT="B"
else
    SELECTION="stable,copy1"
    TARGET_SLOT="A"
fi
echo "Writing to slot ${TARGET_SLOT} (selection: ${SELECTION})"
echo ""

# Copy .swu to board tmpfs (~620 MB; board has 1.8 GB tmpfs available)
REMOTE_SWU="/tmp/$(basename "${SWU}")"
echo "Uploading $(du -Lsh "${SWU}" | cut -f1) to ${BOARD_IP}:${REMOTE_SWU} ..."
scp "${SWU}" "root@${BOARD_IP}:${REMOTE_SWU}"

# Trigger update via swupdate-client IPC socket — sends .swu to the running daemon
echo "Triggering update (selection: ${SELECTION})..."
if ! ssh root@"${BOARD_IP}" "swupdate-client -e '${SELECTION}' '${REMOTE_SWU}'"; then
    ssh root@"${BOARD_IP}" "rm -f '${REMOTE_SWU}'" 2>/dev/null || true
    echo ""
    echo "ERROR: swupdate-client failed — board NOT rebooted. Check logs:"
    echo "  ssh root@${BOARD_IP} journalctl -u swupdate --no-pager -n 30"
    exit 1
fi
ssh root@"${BOARD_IP}" "rm -f '${REMOTE_SWU}'" 2>/dev/null || true

echo ""
echo "=== Slot ${TARGET_SLOT} written. Rebooting board... ==="
ssh root@"${BOARD_IP}" "reboot" || true

echo ""
echo "Board will boot slot ${TARGET_SLOT} (upgrade_available=1, bootcount watchdog active)."
echo "If it boots successfully, confirm with:"
echo "  ssh root@${BOARD_IP} fw_setenv upgrade_available 0"
