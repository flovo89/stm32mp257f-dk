#!/bin/bash
# =============================================================================
# Build the Zephyr M33 application and copy the ELF to the Yocto layer.
# USAGE: ./scripts/build-zephyr.sh
#
# Prerequisites (one-time setup):
#   cd zephyr/zephyr-app && python3 -m venv venv && source venv/bin/activate
#   pip install west && west init -l . && west update
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZEPHYR_WS="${SCRIPT_DIR}/../zephyr"
APP_DIR="${ZEPHYR_WS}/zephyr-app"
DEST="${SCRIPT_DIR}/../yocto/layers/meta-custom/recipes-remoteproc/m33-firmware/files"

BOARD="stm32mp257f_dk/stm32mp257fxx/m33"

echo "=== Building Zephyr M33 app ==="
cd "${APP_DIR}"

if [ ! -d "${ZEPHYR_WS}/.west" ]; then
    echo "ERROR: west workspace not initialized."
    echo "Run: cd zephyr/zephyr-app && west init -l . && west update"
    exit 1
fi

west build -b "${BOARD}" . --build-dir build -- \
    -DCONFIG_LOG_DEFAULT_LEVEL=3

ELF="${APP_DIR}/build/zephyr/zephyr.elf"
if [ ! -f "${ELF}" ]; then
    echo "ERROR: build succeeded but ${ELF} not found"
    exit 1
fi

echo ""
echo "=== Copying ELF to Yocto layer ==="
cp "${ELF}" "${DEST}/zephyr.elf"
echo "  → ${DEST}/zephyr.elf"

echo ""
echo "=== Done ==="
echo "Now run: source yocto/init-env.sh && bitbake stm32mp257f-custom-image"
