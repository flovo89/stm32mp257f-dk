#!/usr/bin/env python3
"""
m33ctl — unified control CLI for the STM32MP257F-DK M33 coprocessor.

Automatically routes through the WebSocket bridge (ws://localhost:8765) when
the m33-dashboard service is running, so commands never conflict with it over
/dev/rpmsg0.  Falls back to direct device access when the service is stopped.

Usage:
  m33ctl status
  m33ctl monitor [--adc] [--encoder] [--motor]
  m33ctl motor speed    <rad/s>   [-m]     closed-loop speed (needs current sensors)
  m33ctl motor angle    <rad>     [-m]     closed-loop angle (needs current sensors)
  m33ctl motor openloop <V>       [-m]     open-loop q-axis voltage, no sensors
  m33ctl motor off                         stop motor
"""

import argparse
import asyncio
import fcntl
import glob
import json
import os
import re
import socket
import struct
import sys
import time

# ── Protocol constants (mirror protocol.h) ───────────────────────────────────

PROTO_MAGIC           = 0xA5
MSG_TYPE_ADC          = 0x01
MSG_TYPE_ENCODER      = 0x02
MSG_TYPE_MOTOR_CMD    = 0x03
MSG_TYPE_MOTOR_STATUS = 0x04

HDR_FMT = "<BBBB"
HDR_LEN = struct.calcsize(HDR_FMT)
ADC_FMT = "<IHH"
ADC_LEN = struct.calcsize(ADC_FMT)
ENC_FMT = "<IiI"
ENC_LEN = struct.calcsize(ENC_FMT)
STS_FMT = "<IffffBB"
STS_LEN = struct.calcsize(STS_FMT)
CMD_FMT = "<BfH"
CMD_LEN = struct.calcsize(CMD_FMT)

RPMSG_MAX  = 512
EPT_NAME   = "m33-ctrl"
WS_DEFAULT = "ws://localhost:8765"

MOTOR_MODES = {"off": 0, "speed": 1, "angle": 2, "openloop": 3}
STATE_NAMES = {0: "off", 1: "run", 2: "fault"}

try:
    import websockets as _wsl
    _HAS_WS = True
except ImportError:
    _HAS_WS = False

# ── Gate-driver enable GPIO (Linux gpio-cdev, /dev/gpiochipN) ────────────────

class _MotorEnableGPIO:
    """Toggle a GPIO via the Linux character device API (no CONFIG_GPIO_SYSFS needed)."""

    _CHIPINFO  = 0x8044B401
    _GETHANDLE = 0xC16CB403
    _SETVALS   = 0xC040B409

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
        target = f"gpio{bank.lower()}"
        for n in range(32):
            path = f"/dev/gpiochip{n}"
            if not os.path.exists(path):
                break
            try:
                fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
                try:
                    buf = bytearray(68)
                    fcntl.ioctl(fd, 0x8044B401, buf)
                    nam = buf[ 0:32].rstrip(b"\x00").decode("ascii", errors="replace").lower()
                    lbl = buf[32:64].rstrip(b"\x00").decode("ascii", errors="replace").lower()
                    if target in (nam, lbl) or target in nam or target in lbl:
                        return path
                finally:
                    os.close(fd)
            except OSError:
                pass
        return f"/dev/gpiochip{ord(bank) - ord('A')}"

    @staticmethod
    def _open_output(chip_fd: int, offset: int) -> int:
        buf = bytearray(364)
        struct.pack_into("<I",  buf,   0, offset)
        struct.pack_into("<I",  buf, 256, 0x2)
        struct.pack_into("32s", buf, 324, b"m33-enable")
        struct.pack_into("<I",  buf, 356, 1)
        fcntl.ioctl(chip_fd, 0xC16CB403, buf)
        (line_fd,) = struct.unpack_from("<i", buf, 360)
        return line_fd

    def set(self, active: bool) -> None:
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
    host = url.split("://", 1)[-1].split("/")[0]
    parts = host.rsplit(":", 1)
    host, port = (parts[0], int(parts[1])) if len(parts) == 2 else (parts[0], 8765)
    try:
        socket.create_connection((host, port), timeout=0.5).close()
        return True
    except OSError:
        return False

def choose_route(force_dev, ws_url):
    """Return ('ws', ws_url) or ('rpmsg', '/dev/rpmsgN') or raise SystemExit."""
    if force_dev:
        return "rpmsg", force_dev
    if _HAS_WS and ws_reachable(ws_url):
        return "ws", ws_url
    dev = find_and_bind_rpmsg()
    if dev:
        return "rpmsg", dev
    sys.exit(
        "ERROR: M33 is not running or reachable.\n"
        "  Check:   systemctl status m33-firmware-start\n"
        "  Start:   systemctl start  m33-firmware-start"
    )

# ── Formatting helpers ────────────────────────────────────────────────────────

def _motor_header():
    print(f"{'Time s':>8}  {'State':5}  {'Speed rad/s':>11}  "
          f"{'Angle deg':>9}  {'Id mA':>7}  {'Iq mA':>7}")
    print("─" * 58)

def _motor_row(ts_ms, state, speed, angle_deg, id_ma, iq_ma):
    print(f"{ts_ms/1000:8.2f}  {state:5}  {speed:11.3f}  "
          f"{angle_deg:9.2f}  {id_ma:7.1f}  {iq_ma:7.1f}", flush=True)

# ── Direct RPMsg I/O ──────────────────────────────────────────────────────────

def _rpmsg_open(dev):
    try:
        fd = open(dev, "r+b", buffering=0)
        os.write(fd.fileno(), b"sub\n")
        time.sleep(0.05)
        return fd
    except OSError as e:
        if e.errno == 16:
            sys.exit(
                f"ERROR: {dev} is busy — the dashboard service holds it.\n"
                "  Either use m33ctl normally (it routes via WebSocket),\n"
                "  or stop the service:  systemctl stop m33-dashboard"
            )
        raise

def _rpmsg_monitor_loop(fd, vref_mv, show_adc, show_enc, show_motor):
    hdr = True
    while True:
        msg = fd.read(RPMSG_MAX)
        if not msg or msg[0] != PROTO_MAGIC or len(msg) < HDR_LEN:
            continue
        _, mtype, length, _ = struct.unpack(HDR_FMT, msg[:HDR_LEN])
        payload = msg[HDR_LEN: HDR_LEN + length]

        if mtype == MSG_TYPE_ADC and len(payload) >= ADC_LEN and show_adc:
            ts, ch0, ch1 = struct.unpack(ADC_FMT, payload[:ADC_LEN])
            v0 = ch0 * vref_mv / 4095000.0
            v1 = ch1 * vref_mv / 4095000.0
            print(f"[ADC]  ts={ts:8d} ms  "
                  f"ch0={ch0:4d} ({v0:.3f} V)  ch1={ch1:4d} ({v1:.3f} V)",
                  flush=True)

        elif mtype == MSG_TYPE_ENCODER and len(payload) >= ENC_LEN and show_enc:
            ts, pos, idx = struct.unpack(ENC_FMT, payload[:ENC_LEN])
            print(f"[ENC]  ts={ts:8d} ms  pos={pos:8d}  idx={idx}", flush=True)

        elif mtype == MSG_TYPE_MOTOR_STATUS and len(payload) >= STS_LEN and show_motor:
            ts, spd, ang, id_ma, iq_ma, state, _ = struct.unpack(STS_FMT, payload[:STS_LEN])
            if hdr:
                _motor_header()
                hdr = False
            _motor_row(ts, STATE_NAMES.get(state, "?"), spd, ang * 57.2958, id_ma, iq_ma)

def _rpmsg_send_motor(fd, mode_int, setpoint):
    payload = struct.pack(CMD_FMT, mode_int, float(setpoint), 0)
    hdr     = struct.pack("<BBBB", PROTO_MAGIC, MSG_TYPE_MOTOR_CMD, CMD_LEN, 0)
    os.write(fd.fileno(), hdr + payload)

# ── WebSocket I/O ─────────────────────────────────────────────────────────────

async def _ws_monitor_loop(url, vref_mv, show_adc, show_enc, show_motor):
    hdr = True
    async with _wsl.connect(url, open_timeout=3) as ws:
        async for raw in ws:
            try:
                data = json.loads(raw)
            except Exception:
                continue
            t = data.get("type")
            if t == "adc" and show_adc:
                print(f"[ADC]  ts={data['ts_ms']:8d} ms  "
                      f"ch0={data['ch0']:4d} ({data.get('ch0_v',0):.3f} V)  "
                      f"ch1={data['ch1']:4d} ({data.get('ch1_v',0):.3f} V)",
                      flush=True)
            elif t == "encoder" and show_enc:
                print(f"[ENC]  ts={data['ts_ms']:8d} ms  "
                      f"pos={data['position']:8d}  "
                      f"idx={data.get('index_count',0)}", flush=True)
            elif t == "motor_status" and show_motor:
                if hdr:
                    _motor_header()
                    hdr = False
                _motor_row(data["ts_ms"],
                           data.get("state", "?"),
                           data.get("speed_rads", 0.0),
                           data.get("angle_deg",  0.0),
                           data.get("id_ma",      0.0),
                           data.get("iq_ma",      0.0))

async def _ws_motor_cmd(url, mode_name, setpoint, do_monitor, vref_mv):
    async with _wsl.connect(url, open_timeout=3) as ws:
        await ws.send(json.dumps({
            "cmd":      "motor",
            "mode":     mode_name,
            "setpoint": float(setpoint),
        }))
        print(f"Sent via WebSocket: mode={mode_name} setpoint={setpoint}")
        if do_monitor:
            await _ws_monitor_loop(url, vref_mv, False, False, True)

# ── Subcommand: status ────────────────────────────────────────────────────────

def cmd_status(args):
    # M33 remoteproc state
    print("M33 coprocessor:")
    found = False
    for p in sorted(glob.glob("/sys/class/remoteproc/remoteproc*/state")):
        found = True
        name_p = p.replace("/state", "/name")
        name  = open(name_p).read().strip() if os.path.exists(name_p) else os.path.dirname(p).split("/")[-1]
        state = open(p).read().strip()
        mark  = "✓" if state == "running" else "✗"
        print(f"  {mark}  {name}: {state}")
    if not found:
        print("  ✗  no remoteproc found — M33 firmware not loaded")

    # Bridge
    up = _HAS_WS and ws_reachable(args.ws_url)
    print(f"\nDashboard service (ws://{args.ws_url.split('://',1)[-1]}):")
    print(f"  {'✓' if up else '✗'}  {'running' if up else 'not reachable'}")

    # Direct device
    dev = find_and_bind_rpmsg()
    print(f"\nDirect RPMsg device:")
    if not dev:
        print("  ✗  no /dev/rpmsgN (M33 not running or rpmsg_chrdev not bound)")
    else:
        try:
            open(dev, "r+b", buffering=0).close()
            print(f"  ✓  {dev} (available)")
        except OSError:
            print(f"  !  {dev} (busy — held by dashboard service)")

    # Routing decision
    print()
    if up:
        print("→  Commands route via WebSocket  (dashboard service owns the device)")
    elif dev:
        print(f"→  Commands route direct to {dev}")
    else:
        print("→  No route available — start M33:  systemctl start m33-firmware-start")

# ── Subcommand: monitor ───────────────────────────────────────────────────────

def cmd_monitor(args):
    show_adc = show_enc = show_motor = True
    if args.adc or args.encoder or args.motor:
        show_adc   = args.adc
        show_enc   = args.encoder
        show_motor = args.motor

    route, target = choose_route(args.dev, args.ws_url)
    print(f"Monitoring via {'WebSocket' if route=='ws' else target}  (Ctrl-C to stop)")

    try:
        if route == "ws":
            asyncio.run(_ws_monitor_loop(target, args.vref, show_adc, show_enc, show_motor))
        else:
            with _rpmsg_open(target) as fd:
                _rpmsg_monitor_loop(fd, args.vref, show_adc, show_enc, show_motor)
    except KeyboardInterrupt:
        print("\nStopped.")

# ── Subcommand: motor ─────────────────────────────────────────────────────────

def cmd_motor(args):
    mode = args.motor_cmd
    sp   = args.setpoint

    if mode != "off" and sp == 0.0:
        print("WARNING: setpoint is 0 — motor will not move")

    route, target = choose_route(args.dev, args.ws_url)

    # Gate driver enable (direct path only — WS path handled by the server)
    gpio = None
    if route == "rpmsg" and args.enable_gpio:
        try:
            gpio = _MotorEnableGPIO(args.enable_gpio)
        except Exception as e:
            print(f"WARNING: could not init enable GPIO: {e}", file=sys.stderr)

    try:
        if route == "ws":
            asyncio.run(_ws_motor_cmd(target, mode, sp, args.monitor, args.vref))
        else:
            if gpio is not None:
                gpio.set(MOTOR_MODES[mode] != 0)
            with _rpmsg_open(target) as fd:
                _rpmsg_send_motor(fd, MOTOR_MODES[mode], sp)
                print(f"Sent direct: mode={mode} setpoint={sp}")
                if args.monitor:
                    print(f"Monitoring via {target}  (Ctrl-C to stop)")
                    _rpmsg_monitor_loop(fd, args.vref, False, False, True)
    except KeyboardInterrupt:
        print("\nStopped.")

# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        prog="m33ctl",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--ws-url", default=WS_DEFAULT,
                    metavar="URL", help=f"WebSocket URL (default: {WS_DEFAULT})")
    ap.add_argument("--dev", default="",
                    metavar="DEV", help="Force direct /dev/rpmsgN, skip WebSocket")
    ap.add_argument("--vref", type=int, default=1800,
                    metavar="MV", help="ADC Vref in mV (default: 1800)")
    ap.add_argument("--enable-gpio", default="", metavar="PIN",
                    help="Gate driver enable pin for direct mode, e.g. pb5 or pd1"
                         " (WS mode: configured in service)")

    sub = ap.add_subparsers(dest="cmd", metavar="command")
    sub.required = True

    sub.add_parser("status", help="Show M33 + bridge status")

    p_mon = sub.add_parser("monitor", help="Stream live data (ADC / encoder / motor)")
    p_mon.add_argument("--adc",     action="store_true", help="ADC channels only")
    p_mon.add_argument("--encoder", action="store_true", help="Encoder only")
    p_mon.add_argument("--motor",   action="store_true", help="Motor status only")

    p_mot = sub.add_parser("motor", help="Send motor commands")
    p_mot.add_argument("motor_cmd",
                       choices=list(MOTOR_MODES),
                       metavar="speed|angle|openloop|off")
    p_mot.add_argument("setpoint", type=float, nargs="?", default=0.0,
                       help="rad/s (speed), rad (angle), V (openloop)")
    p_mot.add_argument("-m", "--monitor", action="store_true",
                       help="Stream motor status after sending command")

    args = ap.parse_args()
    {"status": cmd_status, "monitor": cmd_monitor, "motor": cmd_motor}[args.cmd](args)

if __name__ == "__main__":
    main()
