#!/bin/sh
# Load and start the Zephyr M33 firmware via Linux remoteproc subsystem.
# The kernel DTS must have the M33 remoteproc node enabled.

set -e

FIRMWARE="zephyr-m33.elf"
REMOTEPROC_BASE="/sys/class/remoteproc"

# Find the remoteproc instance that maps to the M33 core.
# ST's kernel names it something like "m33-coprocessor" or "m33@...".
find_m33_rproc() {
    for rp in "${REMOTEPROC_BASE}"/remoteproc*; do
        [ -d "${rp}" ] || continue
        name=$(cat "${rp}/name" 2>/dev/null || true)
        if echo "${name}" | grep -qiE 'm33|cm33|coprocessor'; then
            echo "${rp}"
            return 0
        fi
    done
    # Fallback: first available remoteproc
    ls -d "${REMOTEPROC_BASE}/remoteproc0" 2>/dev/null || true
}

RP=$(find_m33_rproc)
if [ -z "${RP}" ]; then
    echo "ERROR: no remoteproc device found for M33 — check DTS and kernel config" >&2
    exit 1
fi

# Stop if already running (e.g. after a warm reboot)
STATE=$(cat "${RP}/state" 2>/dev/null || echo "offline")
if [ "${STATE}" = "running" ]; then
    echo "M33 already running; stopping for reload..."
    echo stop > "${RP}/state"
    sleep 1
fi

echo "${FIRMWARE}" > "${RP}/firmware"
echo start         > "${RP}/state"

# Give the firmware a moment to boot
sleep 2
STATE=$(cat "${RP}/state")
if [ "${STATE}" = "running" ]; then
    echo "M33 firmware '${FIRMWARE}' started on ${RP}"
else
    echo "ERROR: M33 start failed, state=${STATE}" >&2
    exit 1
fi
