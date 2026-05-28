#!/bin/bash
# Initialize Yocto build environment.
# USAGE: source init-env.sh
#
# This sources oe-init-build-env (which changes CWD to the build dir)
# and then installs our custom conf files.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS_DIR="${SCRIPT_DIR}/layers"
CONF_SRC="${SCRIPT_DIR}/conf"
BUILD_DIR="${SCRIPT_DIR}/build"

if [ ! -d "${LAYERS_DIR}/poky" ]; then
    echo "ERROR: layers not found — run ./setup.sh first"
    return 1
fi

# oe-init-build-env changes CWD to BUILD_DIR
source "${LAYERS_DIR}/poky/oe-init-build-env" "${BUILD_DIR}" > /dev/null 2>&1

# Replace the auto-generated stubs with our versioned conf files
cp "${CONF_SRC}/local.conf"    "${BUILD_DIR}/conf/local.conf"
cp "${CONF_SRC}/bblayers.conf" "${BUILD_DIR}/conf/bblayers.conf"

echo "Build environment ready. CWD: $(pwd)"
echo ""
echo "Build the full image:"
echo "  bitbake stm32mp257f-custom-image"
echo ""
echo "Build individual artifacts:"
echo "  bitbake tf-a-stm32mp          # TF-A BL2 (FSBL)"
echo "  bitbake fip-stm32mp           # FIP (OP-TEE + U-Boot)"
echo "  bitbake virtual/kernel        # Linux kernel"
echo "  bitbake stm32mp257f-custom-image -c rootfs  # rootfs only"
echo ""
echo "Artifacts: build/tmp/deploy/images/stm32mp257f-dk/"
