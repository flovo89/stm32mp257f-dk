# Allow both A→B and B→A OTA selections via the IPC socket.
# SWUpdate 2025.12+ requires explicit -q flags for each allowed selection;
# without them, swupdate-client gets "Selection ... is not allowed, rejected!"
SWUPDATE_ARGS="${SWUPDATE_ARGS} -q stable,copy1 -q stable,copy2"
