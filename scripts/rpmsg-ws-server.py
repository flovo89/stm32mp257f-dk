#!/usr/bin/env python3
"""
RPMsg → WebSocket + HTTP server for the STM32MP257F-DK M33 firmware.

Reads ADC and encoder binary frames from the M33 RPMsg endpoint and
broadcasts them as JSON to connected WebSocket clients.  Also serves
the Flutter web dashboard as static files.

  Port 8765 — WebSocket  (ws://<board-ip>:8765)
  Port 8080 — HTTP       (http://<board-ip>:8080)  → Flutter build

Usage (on the board, as root):
  python3 scripts/rpmsg-ws-server.py
  python3 scripts/rpmsg-ws-server.py --web-dir /path/to/frontend/build/web
  python3 scripts/rpmsg-ws-server.py --vref 3300

Install dependency (once):
  pip3 install websockets
"""

import argparse
import asyncio
import glob
import http.server
import json
import os
import struct
import sys
import threading
import time

import websockets

# ── Protocol constants (must match protocol.h) ───────────────────────────────

PROTO_MAGIC      = 0xA5
MSG_TYPE_ADC     = 0x01
MSG_TYPE_ENCODER = 0x02

HDR_FMT = "<BBBB"          # magic, type, len, seq
HDR_LEN = struct.calcsize(HDR_FMT)

ADC_FMT = "<IHH"           # ts_ms(u32), ch0(u16), ch1(u16)
ADC_LEN = struct.calcsize(ADC_FMT)

ENC_FMT = "<IiI"           # ts_ms(u32), position(i32), index_count(u32)
ENC_LEN = struct.calcsize(ENC_FMT)

RPMSG_MAX = 512
EPT_NAME  = "m33-ctrl"
WS_PORT   = 8765
HTTP_PORT = 8080

# ── Shared state ─────────────────────────────────────────────────────────────

_clients: set = set()

# ── RPMsg device discovery ───────────────────────────────────────────────────

def find_and_bind_rpmsg() -> str:
    paths = glob.glob(f"/sys/bus/rpmsg/devices/virtio*.{EPT_NAME}.*")
    if not paths:
        sys.exit(f"ERROR: no '{EPT_NAME}' channel found — is the M33 running?")
    sysfs    = paths[0]
    dev_name = os.path.basename(sysfs)
    if not os.path.exists(os.path.join(sysfs, "driver")):
        print(f"Binding rpmsg_chrdev to {dev_name}…")
        with open(os.path.join(sysfs, "driver_override"), "w") as f:
            f.write("rpmsg_chrdev")
        with open("/sys/bus/rpmsg/drivers/rpmsg_chrdev/bind", "w") as f:
            f.write(dev_name)
        time.sleep(0.3)
    devs = [d for d in glob.glob("/dev/rpmsg[0-9]*") if not d.endswith("ctrl")]
    if not devs:
        sys.exit("ERROR: no /dev/rpmsgN appeared after binding.")
    return devs[0]

# ── RPMsg reader (blocking I/O off the event loop) ───────────────────────────

async def rpmsg_reader(queue: asyncio.Queue, vref_mv: int) -> None:
    dev  = find_and_bind_rpmsg()
    loop = asyncio.get_running_loop()
    print(f"Reading from {dev}")

    with open(dev, "r+b", buffering=0) as fd:
        # First write registers our endpoint address with the M33.
        os.write(fd.fileno(), b"sub\n")
        await asyncio.sleep(0.1)

        while True:
            # Blocks until one complete RPMsg datagram arrives.
            msg = await loop.run_in_executor(None, fd.read, RPMSG_MAX)
            if not msg or msg[0] != PROTO_MAGIC or len(msg) < HDR_LEN:
                continue

            _, mtype, length, _ = struct.unpack(HDR_FMT, msg[:HDR_LEN])
            payload = msg[HDR_LEN: HDR_LEN + length]

            if mtype == MSG_TYPE_ADC and len(payload) >= ADC_LEN:
                ts, ch0, ch1 = struct.unpack(ADC_FMT, payload[:ADC_LEN])
                await queue.put(json.dumps({
                    "type":  "adc",
                    "ts_ms": ts,
                    "ch0":   ch0,
                    "ch1":   ch1,
                    "ch0_v": round(ch0 * vref_mv / 4095.0 / 1000.0, 4),
                    "ch1_v": round(ch1 * vref_mv / 4095.0 / 1000.0, 4),
                }))

            elif mtype == MSG_TYPE_ENCODER and len(payload) >= ENC_LEN:
                ts, pos, idx = struct.unpack(ENC_FMT, payload[:ENC_LEN])
                await queue.put(json.dumps({
                    "type":        "encoder",
                    "ts_ms":       ts,
                    "position":    pos,
                    "index_count": idx,
                }))

# ── Broadcaster ───────────────────────────────────────────────────────────────

async def broadcaster(queue: asyncio.Queue) -> None:
    while True:
        msg = await queue.get()
        if not _clients:
            continue
        await asyncio.gather(
            *[ws.send(msg) for ws in list(_clients)],
            return_exceptions=True,
        )

# ── WebSocket handler ─────────────────────────────────────────────────────────

async def ws_handler(websocket, *_args):
    _clients.add(websocket)
    addr = getattr(websocket, "remote_address", "?")
    print(f"[WS] client connected: {addr}  (total: {len(_clients)})")
    try:
        await websocket.wait_closed()
    finally:
        _clients.discard(websocket)
        print(f"[WS] client disconnected: {addr}  (total: {len(_clients)})")

# ── HTTP static file server ───────────────────────────────────────────────────

def start_http_server(web_dir: str) -> None:
    if not os.path.isdir(web_dir):
        print(f"[HTTP] WARNING: web dir '{web_dir}' not found — HTTP server not started.")
        print( "[HTTP]   Build first:  cd frontend && flutter build web")
        return

    class _Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=web_dir, **kwargs)

        def log_message(self, fmt, *args):
            pass  # silence per-request access log

    server = http.server.HTTPServer(("0.0.0.0", HTTP_PORT), _Handler)
    print(f"[HTTP] serving {web_dir}  →  http://0.0.0.0:{HTTP_PORT}")
    threading.Thread(target=server.serve_forever, daemon=True).start()

# ── Entry point ───────────────────────────────────────────────────────────────

async def _async_main(web_dir: str, vref_mv: int) -> None:
    start_http_server(web_dir)
    queue: asyncio.Queue = asyncio.Queue()
    try:
        server = websockets.serve(ws_handler, "0.0.0.0", WS_PORT)
    except Exception:
        raise
    async with server:
        print(f"[WS]   server running  →  ws://0.0.0.0:{WS_PORT}")
        await asyncio.gather(
            rpmsg_reader(queue, vref_mv),
            broadcaster(queue),
        )

def main() -> None:
    # When installed by Yocto the script lives at /usr/sbin/ and web assets
    # are at /usr/share/m33-dashboard/.  When run from the source tree the
    # web assets are at ../frontend/build/web/ relative to scripts/.
    _INSTALLED_WEB_DIR = "/usr/share/m33-dashboard"
    script_dir  = os.path.dirname(os.path.abspath(__file__))
    default_web = (
        _INSTALLED_WEB_DIR
        if os.path.isdir(_INSTALLED_WEB_DIR)
        else os.path.join(script_dir, "..", "frontend", "build", "web")
    )

    ap = argparse.ArgumentParser(description="RPMsg WebSocket bridge + HTTP server")
    ap.add_argument("--web-dir", default=default_web,
                    help=f"Flutter build/web output dir (default: {default_web})")
    ap.add_argument("--vref", type=int, default=3300,
                    help="ADC reference voltage in mV (default: 3300)")
    args = ap.parse_args()

    print(f"Starting — vref={args.vref} mV")
    try:
        asyncio.run(_async_main(os.path.abspath(args.web_dir), args.vref))
    except OSError as e:
        if e.errno == 98:  # EADDRINUSE
            sys.exit(
                f"ERROR: port {WS_PORT} already in use.\n"
                f"  Stop the service first:  systemctl stop m33-dashboard"
            )
        raise
    except KeyboardInterrupt:
        print("\nStopped.")

if __name__ == "__main__":
    main()
