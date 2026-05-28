#!/bin/bash
# =============================================================================
# Push an OTA update (.swu file) to the board via ethernet.
# Automatically selects the inactive slot.
# USAGE: ./scripts/ota-update.sh update.swu [board_ip]
# =============================================================================
set -euo pipefail

SWU="${1:-}"
BOARD_IP="${2:-192.168.7.80}"
BOARD_PORT="8080"

if [ -z "${SWU}" ]; then
    echo "Usage: $0 <update.swu> [board_ip]"
    exit 1
fi
if [ ! -f "${SWU}" ]; then
    echo "ERROR: ${SWU} not found"
    exit 1
fi

echo "=== OTA update: ${SWU} → ${BOARD_IP} ==="

# Query current boot slot from the board
echo "Querying active slot..."
CURRENT_SIDE=$(ssh root@"${BOARD_IP}" "fw_printenv boot_side 2>/dev/null | cut -d= -f2" 2>/dev/null || echo "a")
echo "Currently booted: slot ${CURRENT_SIDE}"

if [ "${CURRENT_SIDE}" = "a" ]; then
    TARGET_SELECTION="stable,copy2"
    TARGET_SLOT="B"
else
    TARGET_SELECTION="stable,copy1"
    TARGET_SLOT="A"
fi

echo "Writing to slot ${TARGET_SLOT} (selection: ${TARGET_SELECTION})"
echo ""

# Push via SWUpdate web API
curl --fail --progress-bar \
    -F "swupdate=@${SWU}" \
    -F "selection=${TARGET_SELECTION}" \
    "http://${BOARD_IP}:${BOARD_PORT}/upload"

echo ""
echo "=== Update written to slot ${TARGET_SLOT}. Rebooting board... ==="
ssh root@"${BOARD_IP}" "reboot" || true

echo ""
echo "Board will boot slot ${TARGET_SLOT}."
echo "If it boots successfully, confirm with:"
echo "  ssh root@${BOARD_IP} fw_setenv upgrade_available 0"
