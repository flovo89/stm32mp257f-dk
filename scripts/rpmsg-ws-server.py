#!/usr/bin/env python3
"""
RPMsg → WebSocket + HTTP server for the STM32MP257F-DK M33 application.

Reads STATUS and ADC_CHUNK frames from the M33 RPMsg endpoint and broadcasts
them as JSON to connected WebSocket clients.  Accepts pulse commands from
WebSocket clients and forwards them to the M33.

  Port 8765 — WebSocket  (ws://<board-ip>:8765)
  Port 8080 — HTTP       (http://<board-ip>:8080)  → Flutter build

Broadcast messages (M33 → clients):
  {"type":"status",    "ts_ms":N, "freq_hz":N, "enabled":bool, "in_freq_hz":N}
  {"type":"adc_chunk", "ts_ms":N, "samples":[N, ...]}   # 128 u16 values per chunk

Command messages (clients → M33):
  {"cmd":"pulse", "freq_hz":N}   # 0=stop, 1..1000000=run

Usage (on the board, as root):
  python3 rpmsg-ws-server.py
  python3 rpmsg-ws-server.py --web-dir /path/to/frontend/build/web
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

PROTO_MAGIC         = 0xA5
MSG_TYPE_SET_FREQ   = 0x01
MSG_TYPE_STATUS     = 0x02
MSG_TYPE_ADC_CHUNK  = 0x03

HDR_FMT = "<BBBB"   # magic, type, len(u8), seq
HDR_LEN = struct.calcsize(HDR_FMT)   # 4 bytes

# STATUS payload: ts_ms(u32), out_freq_hz(u32), out_enabled(u8), in_freq_hz(u32)
STS_FMT = "<IIBI"
STS_LEN = struct.calcsize(STS_FMT)   # 13 bytes

# ADC_CHUNK payload: ts_ms(u32), count(u8), samples[128](u16)
CHUNK_FMT = "<IB128H"
CHUNK_LEN = struct.calcsize(CHUNK_FMT)   # 261 bytes

CMD_FMT = "<I"     # freq_hz(u32)
CMD_LEN = struct.calcsize(CMD_FMT)

RPMSG_MAX = 512
EPT_NAME  = "m33-ctrl"
WS_PORT   = 8765
HTTP_PORT = 8080

# ── Shared state ─────────────────────────────────────────────────────────────

_clients:  set = set()
_rpmsg_fd: int = -1
_cmd_seq:  int = 0

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

# ── RPMsg reader ─────────────────────────────────────────────────────────────

async def rpmsg_reader(queue: asyncio.Queue) -> None:
    global _rpmsg_fd
    dev  = find_and_bind_rpmsg()
    loop = asyncio.get_running_loop()
    print(f"Reading from {dev}")

    with open(dev, "r+b", buffering=0) as fd:
        _rpmsg_fd = fd.fileno()
        os.write(_rpmsg_fd, b"sub\n")
        await asyncio.sleep(0.1)

        while True:
            msg = await loop.run_in_executor(None, fd.read, RPMSG_MAX)
            if not msg or msg[0] != PROTO_MAGIC or len(msg) < HDR_LEN:
                continue

            _, mtype, length, _ = struct.unpack(HDR_FMT, msg[:HDR_LEN])
            payload = msg[HDR_LEN: HDR_LEN + length]

            if mtype == MSG_TYPE_STATUS and len(payload) >= STS_LEN:
                ts, out_freq, out_en, in_freq = struct.unpack(
                    STS_FMT, payload[:STS_LEN])
                await queue.put(json.dumps({
                    "type":       "status",
                    "ts_ms":      ts,
                    "freq_hz":    out_freq,   # keep legacy field name for UI compat
                    "enabled":    bool(out_en),
                    "in_freq_hz": in_freq,
                }))

            elif mtype == MSG_TYPE_ADC_CHUNK:
                # hdr.len is a sentinel (0xFF) because 261 > uint8_t max;
                # use the raw message length to extract the full payload.
                chunk_payload = msg[HDR_LEN: HDR_LEN + CHUNK_LEN]
                if len(chunk_payload) >= CHUNK_LEN:
                    ts, count, *all_s = struct.unpack(CHUNK_FMT, chunk_payload)
                    await queue.put(json.dumps({
                        "type":    "adc_chunk",
                        "ts_ms":   ts,
                        "samples": list(all_s[:count]),
                    }))

# ── Pulse command sender ──────────────────────────────────────────────────────

def send_pulse_cmd(freq_hz: int) -> None:
    global _rpmsg_fd, _cmd_seq
    if _rpmsg_fd < 0:
        return
    freq_hz = max(0, min(1_000_000, freq_hz))
    payload = struct.pack(CMD_FMT, freq_hz)
    hdr     = struct.pack("<BBBB", PROTO_MAGIC, MSG_TYPE_SET_FREQ,
                          CMD_LEN, _cmd_seq & 0xFF)
    _cmd_seq += 1
    try:
        os.write(_rpmsg_fd, hdr + payload)
    except OSError as e:
        print(f"[CMD] write error: {e}")

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
        async for raw in websocket:
            try:
                msg = json.loads(raw)
            except Exception:
                continue
            if msg.get("cmd") == "pulse":
                freq_hz = int(msg.get("freq_hz", 0))
                send_pulse_cmd(freq_hz)
                print(f"[CMD] freq_hz={freq_hz}")
    except Exception:
        pass
    finally:
        _clients.discard(websocket)
        print(f"[WS] client disconnected: {addr}  (total: {len(_clients)})")

# ── HTTP static file server ───────────────────────────────────────────────────

def start_http_server(web_dir: str) -> None:
    if not os.path.isdir(web_dir):
        print(f"[HTTP] WARNING: web dir '{web_dir}' not found — HTTP server not started.")
        print( "[HTTP]   Build first:  ./scripts/build-frontend.sh")
        return

    class _Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=web_dir, **kwargs)
        def log_message(self, fmt, *args):
            pass

    server = http.server.HTTPServer(("0.0.0.0", HTTP_PORT), _Handler)
    print(f"[HTTP] serving {web_dir}  →  http://0.0.0.0:{HTTP_PORT}")
    threading.Thread(target=server.serve_forever, daemon=True).start()

# ── Entry point ───────────────────────────────────────────────────────────────

async def _async_main(web_dir: str) -> None:
    start_http_server(web_dir)
    queue: asyncio.Queue = asyncio.Queue()
    async with websockets.serve(ws_handler, "0.0.0.0", WS_PORT):
        print(f"[WS]   server running  →  ws://0.0.0.0:{WS_PORT}")
        await asyncio.gather(
            rpmsg_reader(queue),
            broadcaster(queue),
        )

def main() -> None:
    _INSTALLED_WEB_DIR = "/usr/share/m33-dashboard"
    script_dir  = os.path.dirname(os.path.abspath(__file__))
    default_web = (
        _INSTALLED_WEB_DIR
        if os.path.isdir(_INSTALLED_WEB_DIR)
        else os.path.join(script_dir, "..", "frontend", "build", "web")
    )

    ap = argparse.ArgumentParser(description="RPMsg WebSocket bridge + HTTP server")
    ap.add_argument("--web-dir", default=default_web)
    ap.add_argument("--vref", type=int, default=1800,
                    help="(unused, kept for backwards compatibility)")
    args = ap.parse_args()

    print(f"Starting rpmsg-ws-server")
    try:
        asyncio.run(_async_main(os.path.abspath(args.web_dir)))
    except OSError as e:
        if e.errno == 98:
            sys.exit(f"ERROR: port {WS_PORT} in use — stop m33-dashboard service first")
        raise
    except KeyboardInterrupt:
        print("\nStopped.")

if __name__ == "__main__":
    main()
