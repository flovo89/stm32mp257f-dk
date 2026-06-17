#!/usr/bin/env python3
"""
RPMsg ADC reader for the STM32MP257F-DK M33 firmware.

Reads binary ADC frames (and prints text frames) from the M33 endpoint.
The protocol uses a magic byte (0xA5) to distinguish binary frames from
legacy text messages (heartbeat, echo).

Binary frame layout — ADC (type=0x01, 12 bytes total):
  [0xA5][type:u8][len:u8][seq:u8] | [ts_ms:u32LE][ch0:u16LE][ch1:u16LE]

Binary frame layout — encoder (type=0x02, 16 bytes total):
  [0xA5][type:u8][len:u8][seq:u8] | [ts_ms:u32LE][position:i32LE][index_count:u32LE]

Current channel assignments (external GPIO on expansion connector):
  ch0 = ADC3_INP9   PC7   →  connect external voltage for non-zero readings
  ch1 = ADC3_INP6   PF11  →  connect external voltage for non-zero readings

Quadrature encoder (AMT103-D0500-I5000-S):
  A = PF13   B = PF14   Z (index, once/rev) = PF15

Usage (on the board, as root):
  python3 rpmsg-adc-reader.py          # auto-detect /dev/rpmsgN
  python3 rpmsg-adc-reader.py --dev /dev/rpmsg0
  python3 rpmsg-adc-reader.py --vref 3300   # Vref in mV (default 3300)
  python3 rpmsg-adc-reader.py --csv         # machine-readable output
"""

import argparse
import glob
import io
import os
import struct
import subprocess
import sys
import time

PROTO_MAGIC      = 0xA5
MSG_TYPE_ADC     = 0x01
MSG_TYPE_ENCODER = 0x02

HDR_FMT = "<BBBB"   # magic, type, len, seq
HDR_LEN = struct.calcsize(HDR_FMT)

ADC_PAYLOAD_FMT = "<IHH"   # ts_ms(u32), raw[0](u16), raw[1](u16)
ADC_PAYLOAD_LEN = struct.calcsize(ADC_PAYLOAD_FMT)

ENCODER_PAYLOAD_FMT = "<IiI"   # ts_ms(u32), position(i32), index_count(u32)
ENCODER_PAYLOAD_LEN = struct.calcsize(ENCODER_PAYLOAD_FMT)

EPT_NAME = "m33-ctrl"


# ── RPMsg device discovery ────────────────────────────────────────────────

def find_and_bind_rpmsg():
    """Locate the m33-ctrl sysfs entry, bind rpmsg_chrdev, return /dev/rpmsgN."""
    paths = glob.glob(f"/sys/bus/rpmsg/devices/virtio*.{EPT_NAME}.*")
    if not paths:
        sys.exit(f"ERROR: no '{EPT_NAME}' channel found. Is the M33 running?")

    sysfs = paths[0]
    dev_name = os.path.basename(sysfs)

    if not os.path.exists(os.path.join(sysfs, "driver")):
        print(f"Binding rpmsg_chrdev to {dev_name}...")
        with open(os.path.join(sysfs, "driver_override"), "w") as f:
            f.write("rpmsg_chrdev")
        with open("/sys/bus/rpmsg/drivers/rpmsg_chrdev/bind", "w") as f:
            f.write(dev_name)
        time.sleep(0.3)

    devs = [d for d in glob.glob("/dev/rpmsg[0-9]*")
            if not d.endswith("ctrl")]
    if not devs:
        sys.exit("ERROR: no /dev/rpmsgN appeared. Check dmesg.")

    return devs[0]


# ── Frame parsing ────────────────────────────────────────────────────────

def raw_to_voltage(raw, vref_mv):
    return raw * vref_mv / 4095.0


def parse_binary(hdr_bytes, fd, csv, vref_mv):
    magic, mtype, length, seq = struct.unpack(HDR_FMT, hdr_bytes)

    payload = fd.read(length)
    if len(payload) < length:
        return  # short read

    if mtype == MSG_TYPE_ADC and length >= ADC_PAYLOAD_LEN:
        ts_ms, ch0, ch1 = struct.unpack(ADC_PAYLOAD_FMT, payload[:ADC_PAYLOAD_LEN])
        v0 = raw_to_voltage(ch0, vref_mv)
        v1 = raw_to_voltage(ch1, vref_mv)
        if csv:
            print(f"ADC,{ts_ms},{ch0},{v0:.3f},{ch1},{v1:.3f}", flush=True)
        else:
            print(f"[ADC] ts={ts_ms:8d} ms | "
                  f"ch0={ch0:4d} ({v0:6.3f} V)  "
                  f"ch1={ch1:4d} ({v1:6.3f} V)  "
                  f"seq={seq:3d}",
                  flush=True)
    elif mtype == MSG_TYPE_ENCODER and length >= ENCODER_PAYLOAD_LEN:
        ts_ms, position, index_count = struct.unpack(
            ENCODER_PAYLOAD_FMT, payload[:ENCODER_PAYLOAD_LEN])
        if csv:
            print(f"ENC,{ts_ms},{position},{index_count}", flush=True)
        else:
            print(f"[ENC] ts={ts_ms:8d} ms | "
                  f"position={position:6d}  index_count={index_count:4d}  "
                  f"seq={seq:3d}",
                  flush=True)
    else:
        print(f"[BIN] type=0x{mtype:02x} len={length} seq={seq} "
              f"payload={payload.hex()}", flush=True)


# ── Main loop ────────────────────────────────────────────────────────────

# rpmsg_chrdev uses datagram semantics: each read() pops exactly one
# RPMsg message and discards any bytes beyond the requested count.
# Read with a buffer large enough to hold the largest possible message.
RPMSG_MAX_SIZE = 512


def run(dev, vref_mv, csv):
    print(f"Connected to {dev}  (Vref={vref_mv} mV)")
    if csv:
        print("type,ts_ms,ch0_raw_or_position,ch0_V_or_index_count,ch1_raw,ch1_V", flush=True)

    with open(dev, "r+b", buffering=0) as fd:
        # Send a subscribe byte so M33 learns our endpoint address.
        # OpenAMP on M33 records the src of the first received message as
        # dest_addr; without this write the ADC thread never unblocks.
        os.write(fd.fileno(), b"sub\n")
        time.sleep(0.05)
        while True:
            # Read one complete RPMsg message per call (datagram semantics).
            msg = fd.read(RPMSG_MAX_SIZE)
            if not msg:
                time.sleep(0.01)
                continue

            if msg[0] == PROTO_MAGIC and len(msg) >= HDR_LEN:
                parse_binary(msg[:HDR_LEN], io.BytesIO(msg[HDR_LEN:]), csv, vref_mv)
            else:
                text = msg.decode("utf-8", errors="replace").rstrip()
                if text:
                    print(f"[M33] {text}", flush=True)


def main():
    ap = argparse.ArgumentParser(description="RPMsg ADC reader")
    ap.add_argument("--dev",  default="",
                    help="RPMsg device, e.g. /dev/rpmsg0 (auto-detect if unset)")
    ap.add_argument("--vref", type=int, default=3300,
                    help="ADC reference voltage in mV (default 3300)")
    ap.add_argument("--csv", action="store_true",
                    help="Output CSV instead of human-readable text")
    args = ap.parse_args()

    dev = args.dev or find_and_bind_rpmsg()
    run(dev, args.vref, args.csv)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nDone.")
