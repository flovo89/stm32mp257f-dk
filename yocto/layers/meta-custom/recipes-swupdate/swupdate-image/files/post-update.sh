#!/bin/sh
# Post-install script run by SWUpdate after all images are written.
case "$1" in
    preinst|postfailure) exit 0 ;;
esac
set -e
echo "[post-update] Update written successfully. Reboot to activate new slot."
