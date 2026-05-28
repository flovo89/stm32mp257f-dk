#!/bin/bash
# Clone all required Yocto layers for STM32MP257F-DK
# Yocto Scarthgap 5.0 LTS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS_DIR="${SCRIPT_DIR}/layers"

echo "=== STM32MP257F-DK Yocto Workspace Setup ==="
echo "Cloning layers into: ${LAYERS_DIR}"
echo ""

mkdir -p "${LAYERS_DIR}"

clone_layer() {
    local name=$1 url=$2 branch=$3
    if [ -d "${LAYERS_DIR}/${name}/.git" ]; then
        echo "[SKIP]  ${name} already cloned"
    else
        echo "[CLONE] ${name} (branch: ${branch})..."
        git clone "${url}" -b "${branch}" --depth=1 "${LAYERS_DIR}/${name}"
    fi
}

# --- Yocto base (Scarthgap = 5.0 LTS) ---
clone_layer poky \
    "https://git.yoctoproject.org/poky" \
    "scarthgap"

clone_layer meta-openembedded \
    "https://github.com/openembedded/meta-openembedded.git" \
    "scarthgap"

clone_layer meta-arm \
    "https://git.yoctoproject.org/meta-arm" \
    "scarthgap"

# --- ST BSP + distribution layers ---
# NOTE: If 'scarthgap' branch is missing, check for 'scarthgap-5.x.y' tags on
#       https://github.com/STMicroelectronics/meta-st-stm32mp/branches
clone_layer meta-st-stm32mp \
    "https://github.com/STMicroelectronics/meta-st-stm32mp.git" \
    "scarthgap"

clone_layer meta-st-openstlinux \
    "https://github.com/STMicroelectronics/meta-st-openstlinux.git" \
    "scarthgap"

# --- SWUpdate (OTA A/B update framework) ---
clone_layer meta-swupdate \
    "https://github.com/sbabic/meta-swupdate.git" \
    "scarthgap"

echo ""
echo "=== All layers ready ==="
echo ""
echo "Next: source init-env.sh"
