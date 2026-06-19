#!/usr/bin/env python3
"""
Motor control script for STM32MP257F-DK M33 FOC firmware.

Sends MSG_TYPE_MOTOR_CMD frames over RPMsg and optionally streams
back motor status (speed, angle, Id, Iq) to the console.

Motor command frame (MSG_TYPE_MOTOR_CMD = 0x03, 11 bytes total):
  [0xA5][0x03][7][seq] [mode:u8][setpoint:f32LE][reserved:u16]

Motor status frame (MSG_TYPE_MOTOR_STATUS = 0x04, 26 bytes total):
  [0xA5][0x04][22][seq]
  [ts_ms:u32][speed_rads:f32][angle_rad:f32][id_ma:f32][iq_ma:f32]
  [state:u8][fault:u8]

Usage (on the board, as root):
  python3 scripts/motor_control.py off
  python3 scripts/motor_control.py speed 50         # 50 rad/s ≈ 478 RPM
  python3 scripts/motor_control.py angle 3.14       # 180° (π rad)
  python3 scripts/motor_control.py openloop 2.0     # 2 V on q-axis, no current sensors
  python3 scripts/motor_control.py speed 20 --monitor
"""

import argparse
import asyncio
import glob
import json
import os
import struct
import sys
import time
import threading

try:
    import websockets as _websockets
    _HAS_WEBSOCKETS = True
except ImportError:
    _HAS_WEBSOCKETS = False

WS_LOCAL = "ws://localhost:8765"

# ── Protocol constants (must match protocol.h) ────────────────────────────────

PROTO_MAGIC         = 0xA5
MSG_TYPE_ADC        = 0x01
MSG_TYPE_ENCODER    = 0x02
MSG_TYPE_MOTOR_CMD  = 0x03
MSG_TYPE_MOTOR_STATUS = 0x04

MOTOR_MODE_OFF      = 0
MOTOR_MODE_SPEED    = 1
MOTOR_MODE_ANGLE    = 2
MOTOR_MODE_OPENLOOP = 3

HDR_FMT = "<BBBB"          # magic, type, len, seq
HDR_LEN = struct.calcsize(HDR_FMT)

CMD_PAYLOAD_FMT = "<BfH"   # mode(u8), setpoint(f32), reserved(u16)
CMD_PAYLOAD_LEN = struct.calcsize(CMD_PAYLOAD_FMT)

STS_PAYLOAD_FMT = "<IffffBB"  # ts_ms, speed, angle, id_ma, iq_ma, state, fault
STS_PAYLOAD_LEN = struct.calcsize(STS_PAYLOAD_FMT)

RPMSG_MAX = 512
EPT_NAME  = "m33-ctrl"

STATE_NAMES = {0: "OFF", 1: "RUN", 2: "FAULT"}

# ── RPMsg device discovery ────────────────────────────────────────────────────

def find_and_bind_rpmsg():
    paths = glob.glob(f"/sys/bus/rpmsg/devices/virtio*.{EPT_NAME}.*")
    if not paths:
        sys.exit(f"ERROR: no '{EPT_NAME}' channel — is the M33 running?")
    sysfs = paths[0]
    dev_name = os.path.basename(sysfs)
    if not os.path.exists(os.path.join(sysfs, "driver")):
        with open(os.path.join(sysfs, "driver_override"), "w") as f:
            f.write("rpmsg_chrdev")
        with open("/sys/bus/rpmsg/drivers/rpmsg_chrdev/bind", "w") as f:
            f.write(dev_name)
        time.sleep(0.3)
    devs = [d for d in glob.glob("/dev/rpmsg[0-9]*") if not d.endswith("ctrl")]
    if not devs:
        sys.exit("ERROR: /dev/rpmsgN not found after binding.")
    return devs[0]

# ── Frame builder ─────────────────────────────────────────────────────────────

_seq = 0

def build_cmd_frame(mode, setpoint):
    global _seq
    payload = struct.pack(CMD_PAYLOAD_FMT, mode, setpoint, 0)
    hdr     = struct.pack(HDR_FMT, PROTO_MAGIC, MSG_TYPE_MOTOR_CMD,
                          CMD_PAYLOAD_LEN, _seq & 0xFF)
    _seq   += 1
    return hdr + payload

# ── Monitor thread ────────────────────────────────────────────────────────────

def monitor_loop(fd, stop_event):
    print(f"{'Time':>8}  {'State':6}  {'Speed rad/s':>12}  "
          f"{'Angle deg':>10}  {'Id mA':>8}  {'Iq mA':>8}  {'Fault':>5}")
    print("-" * 72)
    while not stop_event.is_set():
        try:
            msg = os.read(fd, RPMSG_MAX)
        except OSError:
            break
        if not msg or msg[0] != PROTO_MAGIC or len(msg) < HDR_LEN:
            continue
        _, mtype, length, _ = struct.unpack(HDR_FMT, msg[:HDR_LEN])
        payload = msg[HDR_LEN: HDR_LEN + length]

        if mtype == MSG_TYPE_MOTOR_STATUS and len(payload) >= STS_PAYLOAD_LEN:
            ts, spd, ang, id_ma, iq_ma, state, fault = \
                struct.unpack(STS_PAYLOAD_FMT, payload[:STS_PAYLOAD_LEN])
            ang_deg = ang * 180.0 / 3.14159265
            print(f"{ts/1000:8.2f}  {STATE_NAMES.get(state,'?'):6}  "
                  f"{spd:12.3f}  {ang_deg:10.2f}  "
                  f"{id_ma:8.1f}  {iq_ma:8.1f}  {fault:5d}",
                  flush=True)

# ── WebSocket path (used when dashboard service is running) ───────────────────

async def _ws_control(mode_name: str, setpoint: float, do_monitor: bool) -> None:
    async with _websockets.connect(WS_LOCAL, open_timeout=2) as ws:
        await ws.send(json.dumps({
            "cmd":      "motor",
            "mode":     mode_name,
            "setpoint": float(setpoint),
        }))
        print(f"Sent via WebSocket: mode={mode_name} setpoint={setpoint}")
        if not do_monitor:
            return
        print(f"{'Time':>8}  {'State':6}  {'Speed rad/s':>12}  "
              f"{'Angle deg':>10}  {'Id mA':>8}  {'Iq mA':>8}  {'Fault':>5}")
        print("-" * 72)
        async for raw in ws:
            try:
                data = json.loads(raw)
            except Exception:
                continue
            if data.get("type") == "motor_status":
                print(f"{data['ts_ms'] / 1000:8.2f}  "
                      f"{data.get('state', '?'):6}  "
                      f"{data.get('speed_rads', 0.0):12.3f}  "
                      f"{data.get('angle_deg',  0.0):10.2f}  "
                      f"{data.get('id_ma',       0.0):8.1f}  "
                      f"{data.get('iq_ma',       0.0):8.1f}  "
                      f"{data.get('fault',       0):5d}", flush=True)

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="FOC motor control via RPMsg")
    ap.add_argument("mode",
                    choices=["off", "speed", "angle", "openloop"],
                    help="Control mode (openloop: setpoint = q-axis voltage in V)")
    ap.add_argument("setpoint", type=float, nargs="?", default=0.0,
                    help="Target value: rad/s for speed, rad for angle")
    ap.add_argument("--dev", default="",
                    help="RPMsg device (auto-detect if not set)")
    ap.add_argument("--monitor", "-m", action="store_true",
                    help="Stream motor status to console after sending command")
    args = ap.parse_args()

    mode_map = {"off": MOTOR_MODE_OFF, "speed": MOTOR_MODE_SPEED,
                "angle": MOTOR_MODE_ANGLE, "openloop": MOTOR_MODE_OPENLOOP}
    mode = mode_map[args.mode]

    if mode != MOTOR_MODE_OFF and args.setpoint == 0.0:
        print("WARNING: setpoint is 0 — motor will not move")

    # Prefer WebSocket route so motor_control.py works alongside the dashboard
    # service (which owns /dev/rpmsg0). Falls back to direct RPMsg only when
    # the WS server is not running, or when --dev is explicitly specified.
    if not args.dev and _HAS_WEBSOCKETS:
        try:
            asyncio.run(_ws_control(args.mode, args.setpoint, args.monitor))
            return
        except KeyboardInterrupt:
            print("\nMonitoring stopped.")
            return
        except Exception as e:
            print(f"WebSocket unavailable ({e}), falling back to direct RPMsg...")

    dev = args.dev or find_and_bind_rpmsg()
    print(f"Device: {dev}  mode={args.mode}  setpoint={args.setpoint}")

    frame = build_cmd_frame(mode, float(args.setpoint))

    with open(dev, "r+b", buffering=0) as fd:
        # Subscribe first so M33 learns our address
        os.write(fd.fileno(), b"sub\n")
        time.sleep(0.1)

        # Send motor command
        os.write(fd.fileno(), frame)
        print(f"Sent: mode={args.mode} setpoint={args.setpoint}")

        if args.monitor:
            stop = threading.Event()
            t = threading.Thread(target=monitor_loop,
                                 args=(fd.fileno(), stop), daemon=True)
            t.start()
            try:
                t.join()
            except KeyboardInterrupt:
                stop.set()
                print("\nMonitoring stopped.")

if __name__ == "__main__":
    main()
