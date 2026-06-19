#!/usr/bin/env python3
"""
RPMsg → WebSocket + HTTP server for the STM32MP257F-DK M33 FOC firmware.

Reads ADC, encoder, and motor-status frames from the M33 RPMsg endpoint and
broadcasts them as JSON to connected WebSocket clients.  Also accepts motor
commands from WebSocket clients and forwards them to the M33.

  Port 8765 — WebSocket  (ws://<board-ip>:8765)
  Port 8080 — HTTP       (http://<board-ip>:8080)  → Flutter build

Usage (on the board, as root):
  python3 scripts/rpmsg-ws-server.py
  python3 scripts/rpmsg-ws-server.py --web-dir /path/to/frontend/build/web
  python3 scripts/rpmsg-ws-server.py --vref 1800

Install dependency (once):
  pip3 install websockets
"""

import argparse
import asyncio
import fcntl
import glob
import http.server
import json
import os
import re
import struct
import sys
import threading
import time

import websockets

# ── Protocol constants (must match protocol.h) ───────────────────────────────

PROTO_MAGIC         = 0xA5
MSG_TYPE_ADC        = 0x01
MSG_TYPE_ENCODER    = 0x02
MSG_TYPE_MOTOR_CMD  = 0x03
MSG_TYPE_MOTOR_STATUS = 0x04

HDR_FMT = "<BBBB"
HDR_LEN = struct.calcsize(HDR_FMT)

ADC_FMT     = "<IHH"          # ts_ms, ch0, ch1
ADC_LEN     = struct.calcsize(ADC_FMT)

ENC_FMT     = "<IiI"          # ts_ms, position, index_count
ENC_LEN     = struct.calcsize(ENC_FMT)

STS_FMT     = "<IffffBB"      # ts_ms, speed_rads, angle_rad, id_ma, iq_ma, state, fault
STS_LEN     = struct.calcsize(STS_FMT)

CMD_PAYLOAD_FMT = "<BfH"      # mode, setpoint, reserved
CMD_PAYLOAD_LEN = struct.calcsize(CMD_PAYLOAD_FMT)

RPMSG_MAX   = 512
EPT_NAME    = "m33-ctrl"
WS_PORT     = 8765
HTTP_PORT   = 8080

STATE_NAMES = {0: "off", 1: "run", 2: "fault"}

# ── Gate-driver enable GPIO (Linux gpio-cdev, /dev/gpiochipN) ────────────────

class _MotorEnableGPIO:
    """Toggle a GPIO via the Linux character device API (no CONFIG_GPIO_SYSFS needed)."""

    # ioctl numbers derived from linux/gpio.h
    _CHIPINFO  = 0x8044B401   # GPIO_GET_CHIPINFO_IOCTL   (_IOR  0xB4,0x01, 68 B)
    _GETHANDLE = 0xC16CB403   # GPIO_GET_LINEHANDLE_IOCTL (_IOWR 0xB4,0x03,364 B)
    _SETVALS   = 0xC040B409   # GPIOHANDLE_SET_LINE_VALUES_IOCTL (_IOWR 0xB4,0x09,64 B)

    def __init__(self, pin_name: str) -> None:
        m = re.match(r'^p([a-z])(\d+)$', pin_name.lower())
        if not m:
            raise ValueError(f"Bad pin '{pin_name}' — expected like pb5 or pd1")
        bank   = m.group(1).upper()
        offset = int(m.group(2))

        chip = self._find_chip(bank)
        chip_fd = os.open(chip, os.O_RDWR | os.O_CLOEXEC)
        try:
            self._fd = self._open_output(chip_fd, offset)
        finally:
            os.close(chip_fd)

        self.set(False)
        print(f"[ENABLE] {pin_name.upper()} → {chip} offset {offset} initialized LOW (disabled)")

    @staticmethod
    def _find_chip(bank: str) -> str:
        target = f"gpio{bank.lower()}"           # "gpiob"
        for n in range(32):
            path = f"/dev/gpiochip{n}"
            if not os.path.exists(path):
                break
            try:
                fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
                try:
                    buf = bytearray(68)            # sizeof(gpiochip_info)
                    fcntl.ioctl(fd, 0x8044B401, buf)
                    nam = buf[ 0:32].rstrip(b"\x00").decode("ascii", errors="replace").lower()
                    lbl = buf[32:64].rstrip(b"\x00").decode("ascii", errors="replace").lower()
                    if target in (nam, lbl) or target in nam or target in lbl:
                        return path
                finally:
                    os.close(fd)
            except OSError:
                pass
        # Fallback: GPIOA=chip0, GPIOB=chip1, … (standard STM32 DT ordering)
        return f"/dev/gpiochip{ord(bank) - ord('A')}"

    @staticmethod
    def _open_output(chip_fd: int, offset: int) -> int:
        # struct gpiohandle_request (364 bytes):
        #  [  0] __u32 lineoffsets[64]    (256 B)
        #  [256] __u32 flags              (  4 B)
        #  [260] __u8  default_values[64] ( 64 B)
        #  [324] char  consumer_label[32] ( 32 B)
        #  [356] __u32 lines              (  4 B)
        #  [360] int   fd   ← filled in by kernel
        buf = bytearray(364)
        struct.pack_into("<I",  buf,   0, offset)        # lineoffsets[0]
        struct.pack_into("<I",  buf, 256, 0x2)           # flags = OUTPUT
        struct.pack_into("32s", buf, 324, b"m33-enable") # consumer_label
        struct.pack_into("<I",  buf, 356, 1)             # lines = 1
        fcntl.ioctl(chip_fd, 0xC16CB403, buf)
        (line_fd,) = struct.unpack_from("<i", buf, 360)
        return line_fd

    def set(self, active: bool) -> None:
        # struct gpiohandle_data: __u8 values[64]
        buf = bytearray(64)
        buf[0] = 1 if active else 0
        try:
            fcntl.ioctl(self._fd, 0xC040B409, buf)
        except OSError as e:
            print(f"[ENABLE] set error: {e}", file=sys.stderr)

    def __del__(self) -> None:
        try:
            os.close(self._fd)
        except Exception:
            pass

# ── Shared state ─────────────────────────────────────────────────────────────

_clients: set = set()
_rpmsg_fd: int = -1   # raw file descriptor for writing motor commands
_cmd_seq:  int = 0
_enable_gpio: "_MotorEnableGPIO | None" = None

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

async def rpmsg_reader(queue: asyncio.Queue, vref_mv: int) -> None:
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

            elif mtype == MSG_TYPE_MOTOR_STATUS and len(payload) >= STS_LEN:
                ts, spd, ang, id_ma, iq_ma, state, fault = \
                    struct.unpack(STS_FMT, payload[:STS_LEN])
                await queue.put(json.dumps({
                    "type":        "motor_status",
                    "ts_ms":       ts,
                    "speed_rads":  round(spd, 4),
                    "speed_rpm":   round(spd * 60.0 / 6.2832, 1),
                    "angle_rad":   round(ang, 4),
                    "angle_deg":   round(ang * 57.2958, 2),
                    "id_ma":       round(id_ma, 1),
                    "iq_ma":       round(iq_ma, 1),
                    "state":       STATE_NAMES.get(state, "unknown"),
                    "fault":       fault,
                }))

# ── Motor command sender ──────────────────────────────────────────────────────

def send_motor_cmd(mode: int, setpoint: float) -> None:
    global _rpmsg_fd, _cmd_seq, _enable_gpio
    if _rpmsg_fd < 0:
        return
    if _enable_gpio is not None:
        _enable_gpio.set(mode != 0)
    payload = struct.pack(CMD_PAYLOAD_FMT, mode, setpoint, 0)
    hdr     = struct.pack("<BBBB", PROTO_MAGIC, MSG_TYPE_MOTOR_CMD,
                          CMD_PAYLOAD_LEN, _cmd_seq & 0xFF)
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
            # Accept motor commands from the dashboard:
            # {"cmd":"motor", "mode":"speed", "setpoint":30.0}
            try:
                msg = json.loads(raw)
            except Exception:
                continue
            if msg.get("cmd") == "motor":
                mode_map = {"off": 0, "speed": 1, "angle": 2, "openloop": 3}
                mode = mode_map.get(str(msg.get("mode", "off")), 0)
                sp   = float(msg.get("setpoint", 0.0))
                send_motor_cmd(mode, sp)
                print(f"[CMD] mode={msg.get('mode')} setpoint={sp}")
    except Exception:
        pass
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
            pass

    server = http.server.HTTPServer(("0.0.0.0", HTTP_PORT), _Handler)
    print(f"[HTTP] serving {web_dir}  →  http://0.0.0.0:{HTTP_PORT}")
    threading.Thread(target=server.serve_forever, daemon=True).start()

# ── Entry point ───────────────────────────────────────────────────────────────

async def _async_main(web_dir: str, vref_mv: int, enable_gpio_pin: str) -> None:
    global _enable_gpio
    if enable_gpio_pin:
        try:
            _enable_gpio = _MotorEnableGPIO(enable_gpio_pin)
        except Exception as e:
            print(f"[ENABLE] WARNING: could not init GPIO '{enable_gpio_pin}': {e}",
                  file=sys.stderr)
    start_http_server(web_dir)
    queue: asyncio.Queue = asyncio.Queue()
    async with websockets.serve(ws_handler, "0.0.0.0", WS_PORT):
        print(f"[WS]   server running  →  ws://0.0.0.0:{WS_PORT}")
        await asyncio.gather(
            rpmsg_reader(queue, vref_mv),
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
                    help="ADC reference voltage in mV (default: 1800)")
    ap.add_argument("--enable-gpio", default="", metavar="PIN",
                    help="Gate driver enable pin, e.g. pb5 or pd1 (default: disabled)")
    args = ap.parse_args()

    print(f"Starting — vref={args.vref} mV"
          + (f"  enable-gpio={args.enable_gpio}" if args.enable_gpio else ""))
    try:
        asyncio.run(_async_main(os.path.abspath(args.web_dir), args.vref,
                                args.enable_gpio))
    except OSError as e:
        if e.errno == 98:
            sys.exit(f"ERROR: port {WS_PORT} in use — stop m33-dashboard service first")
        raise
    except KeyboardInterrupt:
        print("\nStopped.")

if __name__ == "__main__":
    main()
