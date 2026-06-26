#!/usr/bin/env python3
"""
m33ctl — control CLI for the STM32MP257F-DK M33 application.

Routes through the WebSocket bridge (ws://localhost:8765) when the
m33-dashboard service is running, so commands never conflict with it over
/dev/rpmsg0.  Falls back to direct device access when the service is stopped.

Usage:
  m33ctl status              show connection route and current state
  m33ctl freq <hz>           set output frequency in Hz (0 = stop, 1..1000000 = run)
  m33ctl off                 stop output  (alias for: m33ctl freq 0)
  m33ctl monitor             stream live status at 10 Hz
"""

import argparse
import asyncio
import glob
import json
import os
import socket
import struct
import sys
import time

PROTO_MAGIC         = 0xA5
MSG_TYPE_SET_FREQ   = 0x01
MSG_TYPE_STATUS     = 0x02
MSG_TYPE_ADC_CHUNK  = 0x03

HDR_FMT = "<BBBB"   # magic, type, len(u8), seq
HDR_LEN = struct.calcsize(HDR_FMT)   # 4 bytes

# STATUS payload: ts_ms(u32), out_freq_hz(u32), out_enabled(u8), in_freq_hz(u32)
STS_FMT = "<IIBI"
STS_LEN = struct.calcsize(STS_FMT)   # 13 bytes

RPMSG_MAX  = 512
EPT_NAME   = "m33-ctrl"
WS_DEFAULT = "ws://localhost:8765"

try:
    import websockets as _wsl
    _HAS_WS = True
except ImportError:
    _HAS_WS = False

# ── Device / service discovery ────────────────────────────────────────────────

def find_and_bind_rpmsg():
    paths = glob.glob(f"/sys/bus/rpmsg/devices/virtio*.{EPT_NAME}.*")
    if not paths:
        return None
    sysfs    = paths[0]
    dev_name = os.path.basename(sysfs)
    if not os.path.exists(os.path.join(sysfs, "driver")):
        try:
            open(os.path.join(sysfs, "driver_override"), "w").write("rpmsg_chrdev")
            open("/sys/bus/rpmsg/drivers/rpmsg_chrdev/bind", "w").write(dev_name)
            time.sleep(0.3)
        except OSError:
            pass
    devs = [d for d in glob.glob("/dev/rpmsg[0-9]*") if not d.endswith("ctrl")]
    return devs[0] if devs else None

def ws_reachable(url):
    host  = url.split("://", 1)[-1].split("/")[0]
    parts = host.rsplit(":", 1)
    host, port = (parts[0], int(parts[1])) if len(parts) == 2 else (parts[0], 8765)
    try:
        socket.create_connection((host, port), timeout=0.5).close()
        return True
    except OSError:
        return False

def choose_route(force_dev, ws_url):
    if force_dev:
        return "rpmsg", force_dev
    if _HAS_WS and ws_reachable(ws_url):
        return "ws", ws_url
    dev = find_and_bind_rpmsg()
    if dev:
        return "rpmsg", dev
    sys.exit(
        "ERROR: M33 is not running or reachable.\n"
        "  Check:  systemctl status m33-firmware-start\n"
        "  Start:  systemctl start  m33-firmware-start"
    )

# ── Helpers ───────────────────────────────────────────────────────────────────

def _fmt_freq(hz: int) -> str:
    if hz == 0:
        return "OFF"
    if hz >= 1_000_000:
        return f"{hz / 1_000_000:.4g} MHz"
    if hz >= 1_000:
        return f"{hz / 1_000:.4g} kHz"
    return f"{hz} Hz"

def _print_status(ts_ms: int, out_freq_hz: int, enabled: bool,
                  in_freq_hz: int = 0) -> None:
    state = "RUNNING" if enabled else "STOPPED"
    print(f"  Output    : {_fmt_freq(out_freq_hz)} ({state})")
    in_str = f"{_fmt_freq(in_freq_hz)} (detected)" if in_freq_hz else "no signal"
    print(f"  Input     : {in_str}")
    print(f"  Uptime    : {ts_ms / 1000:.1f} s")

# ── WebSocket paths ───────────────────────────────────────────────────────────

async def _ws_set_freq(url: str, freq_hz: int) -> None:
    async with _wsl.connect(url) as ws:
        await ws.send(json.dumps({"cmd": "pulse", "freq_hz": freq_hz}))

async def _ws_get_status(url: str) -> None:
    async with _wsl.connect(url) as ws:
        async for raw in ws:
            msg = json.loads(raw)
            if msg.get("type") == "status":
                _print_status(msg["ts_ms"], msg["freq_hz"], msg["enabled"],
                              msg.get("in_freq_hz", 0))
                return

async def _ws_monitor(url: str) -> None:
    async with _wsl.connect(url) as ws:
        print(f"{'Time s':>8}  {'Output':>12}  {'Input':>12}  State")
        print("─" * 50)
        async for raw in ws:
            msg = json.loads(raw)
            if msg.get("type") == "status":
                ts    = msg["ts_ms"] / 1000.0
                state = "RUN " if msg["enabled"] else "STOP"
                in_f  = msg.get("in_freq_hz", 0)
                print(f"{ts:8.1f}  {_fmt_freq(msg['freq_hz']):>12}  "
                      f"{_fmt_freq(in_f):>12}  {state}", flush=True)

# ── Direct RPMsg paths ────────────────────────────────────────────────────────

def _rpmsg_send_freq(fd: int, freq_hz: int) -> None:
    payload = struct.pack("<I", freq_hz)
    hdr     = struct.pack("<BBBB", PROTO_MAGIC, MSG_TYPE_SET_FREQ, len(payload), 0)
    os.write(fd, hdr + payload)

def _rpmsg_monitor_loop(fd: int) -> None:
    print(f"{'Time s':>8}  {'Output':>12}  {'Input':>12}  State")
    print("─" * 50)
    while True:
        msg = os.read(fd, RPMSG_MAX)
        if not msg or msg[0] != PROTO_MAGIC or len(msg) < HDR_LEN:
            continue
        _, mtype, length, _ = struct.unpack(HDR_FMT, msg[:HDR_LEN])
        payload = msg[HDR_LEN: HDR_LEN + length]
        if mtype == MSG_TYPE_STATUS and len(payload) >= STS_LEN:
            ts, freq_hz, enabled, in_freq = struct.unpack(STS_FMT, payload[:STS_LEN])
            state = "RUN " if enabled else "STOP"
            print(f"{ts/1000:8.1f}  {_fmt_freq(freq_hz):>12}  "
                  f"{_fmt_freq(in_freq):>12}  {state}", flush=True)

# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_status(args):
    route, target = choose_route(getattr(args, "dev", None), WS_DEFAULT)
    print(f"Route : {route}  →  {target}")
    if route == "ws":
        try:
            asyncio.run(_ws_get_status(target))
        except Exception as e:
            print(f"  (could not fetch status: {e})")
    else:
        print("  (status not available over direct RPMsg — use 'monitor')")

def cmd_freq(args):
    hz = int(args.hz)
    hz = max(0, min(1_000_000, hz))
    route, target = choose_route(getattr(args, "dev", None), WS_DEFAULT)
    if route == "ws":
        asyncio.run(_ws_set_freq(target, hz))
    else:
        with open(target, "r+b", buffering=0) as f:
            os.write(f.fileno(), b"sub\n")
            time.sleep(0.1)
            _rpmsg_send_freq(f.fileno(), hz)
    print(f"Set: {_fmt_freq(hz)}")

def cmd_off(args):
    args.hz = 0
    cmd_freq(args)

def cmd_monitor(args):
    route, target = choose_route(getattr(args, "dev", None), WS_DEFAULT)
    print(f"Monitoring via {route}  →  {target}  (Ctrl-C to stop)")
    try:
        if route == "ws":
            asyncio.run(_ws_monitor(target))
        else:
            with open(target, "r+b", buffering=0) as f:
                os.write(f.fileno(), b"sub\n")
                time.sleep(0.1)
                _rpmsg_monitor_loop(f.fileno())
    except KeyboardInterrupt:
        print()

# ── Argument parser ───────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="m33ctl — STM32MP257F-DK M33 control",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  m33ctl freq 1000       # 1 kHz output\n"
            "  m33ctl freq 1000000    # 1 MHz output\n"
            "  m33ctl off             # stop output\n"
            "  m33ctl monitor         # stream live status (output + input freq)\n"
        ),
    )
    ap.add_argument("--dev", metavar="DEV",
                    help="Force direct /dev/rpmsgN access (skips WS bridge)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status",  help="Show current output and input state")

    p_freq = sub.add_parser("freq", help="Set output frequency in Hz (0 = stop)")
    p_freq.add_argument("hz", type=int, metavar="HZ",
                        help="Frequency in Hz (0..1000000)")

    sub.add_parser("off",     help="Stop output (alias for freq 0)")
    sub.add_parser("monitor", help="Stream live status at 10 Hz")

    args = ap.parse_args()
    dispatch = {
        "status":  cmd_status,
        "freq":    cmd_freq,
        "off":     cmd_off,
        "monitor": cmd_monitor,
    }
    dispatch[args.cmd](args)

if __name__ == "__main__":
    main()
