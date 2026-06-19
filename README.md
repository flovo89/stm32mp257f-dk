# STM32MP257F-DK Embedded Linux + Zephyr Platform

Target board: **STM32MP257F-DK** evaluation board  
SoC: STM32MP257F — dual Cortex-A35 (Linux) + Cortex-M33 (Zephyr)

## Overview

| Core | OS | Role |
|------|----|------|
| Cortex-A35 × 2 | Linux (Yocto Scarthgap 5.0) | Application processor |
| Cortex-M33 | Zephyr RTOS | Real-time coprocessor |

Features:
- Static IP `192.168.7.80/24` on eth0, SSH available on first boot
- eMMC, USB, I2C, CAN exposed via standard kernel drivers
- M33 Zephyr firmware loaded automatically at boot via Linux remoteproc
- RPMsg channel between A35 and M33 for inter-processor communication
- FOC (Field-Oriented Control) BLDC motor control loop on M33 at 10 kHz
- INA240 current sensing: ADC3 ch0 on PC7/INP9, ch1 on PF11/INP6
- Quadrature encoder on PF15/PG5 (A/B), 4× software EXTI decode
- 3-phase PWM: PA5 hardware TIM2_CH4 AF8 (Phase A) + PF13/PF14 GPIO software PWM (Phases B/C)
- Speed, angle, and open-loop voltage control from Linux via RPMsg; web dashboard at 50 Hz
- Dual A/B partition layout — OTA updates over Ethernet via SWUpdate
- Automatic rollback if new image fails to boot (U-Boot watchdog counter)

---

## Repository Layout

```
stm32mp257f-dk/
├── README.md
│
├── yocto/                       ← Yocto build workspace
│   ├── setup.sh                 ← clone all upstream layers (run once)
│   ├── init-env.sh              ← source to activate bitbake environment
│   └── layers/
│       ├── poky/                ← cloned by setup.sh
│       ├── meta-openembedded/   ← cloned by setup.sh
│       ├── meta-arm/            ← cloned by setup.sh
│       ├── meta-st-stm32mp/     ← cloned by setup.sh  (ST BSP)
│       ├── meta-st-openstlinux/ ← cloned by setup.sh  (ST distro extras)
│       ├── meta-swupdate/       ← cloned by setup.sh  (OTA framework)
│       └── meta-custom/         ← board-specific customisations (versioned)
│           ├── recipes-core/images/
│           │   └── stm32mp257f-custom-image.bb
│           ├── recipes-bsp/u-boot/
│           │   └── files/boot.cmd, stm32mp257f-dk-uenv.txt
│           ├── recipes-connectivity/networkd-config/
│           │   └── files/10-eth0.network   ← static IP 192.168.7.80/24
│           ├── recipes-remoteproc/m33-firmware/
│           │   ├── m33-firmware.bb
│           │   └── files/
│           │       ├── zephyr.elf              ← built by build-zephyr.sh
│           │       ├── m33-firmware-start.sh
│           │       └── m33-firmware-start.service
│           ├── recipes-dashboard/m33-dashboard/
│           │   ├── m33-dashboard.bb
│           │   └── files/
│           │       ├── frontend-web.tar.gz     ← built by build-frontend.sh
│           │       ├── rpmsg-ws-server.py      ← staged by build-frontend.sh
│           │       ├── motor_control.py        ← staged by build-frontend.sh
│           │       ├── m33ctl.py               ← staged by build-frontend.sh
│           │       └── m33-dashboard.service
│           ├── recipes-swupdate/
│           └── wic/stm32mp257f-dk-dualboot.wks
│
├── zephyr/                      ← west workspace root
│   ├── zephyr-app/
│   │   ├── west.yml             ← pins Zephyr v4.4.0
│   │   ├── CMakeLists.txt
│   │   ├── prj.conf
│   │   ├── boards/stm32mp257f_dk_stm32mp257fxx_m33.overlay
│   │   └── src/
│   │       ├── main.c           ← RPMsg + task loop
│   │       ├── adc.c / adc.h    ← ADC3, ch0=PC7/INP9, ch1=PF11/INP6
│   │       ├── encoder.c / .h   ← quadrature decode via GPIO EXTI
│   │       ├── pwm.c / pwm.h    ← TIM2 center-aligned PWM (PA5 HW + PF13/PF14 SW)
│   │       ├── foc.c / foc.h    ← FOC loop: Clarke/Park, PI controllers, SVPWM
│   │       └── protocol.h       ← binary frame format
│   └── zephyr/                  ← cloned by west update
│
├── frontend/                    ← Flutter web dashboard source
│   ├── pubspec.yaml
│   ├── lib/main.dart            ← single-page dashboard, auto-connects via WS
│   └── web/index.html
│
└── scripts/
    ├── build-zephyr.sh          ← west build + copy ELF to Yocto layer
    ├── build-frontend.sh        ← flutter build web + stage for Yocto
    ├── rpmsg-ws-server.py       ← RPMsg → WebSocket + HTTP bridge (port 8765/8080)
    ├── m33ctl.py                ← unified M33 CLI: status / monitor / motor control
    ├── rpmsg-adc-reader.py      ← legacy direct reader (use m33ctl instead)
    ├── rpmsg-chat.sh            ← low-level RPMsg debug shell (stop dashboard first)
    ├── motor_control.py         ← legacy motor CLI   (use m33ctl instead)
    ├── flash-sdcard-ab.sh       ← initial SD card provisioning
    ├── fix-sdcard-ab.sh         ← post-wic patch: fix PARTUUIDs + copy DTB to boot-a
    └── ota-update.sh            ← push OTA update, auto slot selection
```

---

## Prerequisites

### Host packages (Debian/Ubuntu)

```bash
sudo apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping python3-git python3-jinja2 \
    libsdl1.2-dev pylint xterm python3-subunit \
    mesa-common-dev zstd lz4 libcrypt-dev \
    dosfstools e2fsprogs curl \
    cmake ninja-build python3-venv
```

### Python tools

```bash
pip3 install --user west
```

### Shell requirement

Yocto's `oe-init-build-env` and `init-env.sh` are bash scripts. If your login shell is Fish (or any non-POSIX shell), drop into bash first:

```fish
bash
source yocto/init-env.sh
```

---

## Step 1 — Clone Yocto Layers

```bash
cd yocto
./setup.sh
```

This clones six upstream layers into `yocto/layers/` using `--depth=1`:

| Layer | Purpose |
|-------|---------|
| `poky` | Yocto reference distro (Scarthgap 5.0 LTS) |
| `meta-openembedded` | OE community recipes |
| `meta-arm` | ARM toolchain + TF-A support |
| `meta-st-stm32mp` | STM32MP BSP: TF-A, OP-TEE, U-Boot, kernel, machine configs |
| `meta-st-openstlinux` | ST distribution extras |
| `meta-swupdate` | SWUpdate OTA framework |

---

## Step 2 — Build the Zephyr M33 Firmware

The Zephyr ELF must exist before bitbake runs — `m33-firmware.bb` packages it directly.

### One-time west workspace setup

```bash
cd zephyr/zephyr-app
python3 -m venv venv
source venv/bin/activate
pip install west
west init -l .        # initialise workspace, places .west/ in zephyr/
west update           # fetch Zephyr + modules (~1 GB)
```

Install the Zephyr SDK (Cortex-M33 toolchain):

```bash
wget https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v1.0.0/zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
tar xf zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz -C ~/
~/zephyr-sdk-1.0.0/setup.sh -t arm-zephyr-eabi
```

### Build and stage

```bash
./scripts/build-zephyr.sh
```

Runs `west build -b stm32mp257f_dk/stm32mp257fxx/m33` and copies
`build/zephyr/zephyr.elf` into `yocto/layers/meta-custom/recipes-remoteproc/m33-firmware/files/`.

---

## Step 3 — Build the Flutter Web Dashboard

The Flutter build output must exist before bitbake runs — `m33-dashboard.bb` packages it.

```bash
./scripts/build-frontend.sh
```

On the first run this downloads the Flutter SDK (~700 MB) into `.flutter/` automatically, then builds and tarballs the web output into the recipe's `files/` directory. Subsequent runs skip the download.

The script stages four files for BitBake into the recipe `files/` directory:
- `frontend-web.tar.gz` — compiled Flutter web app
- `rpmsg-ws-server.py` — WebSocket bridge daemon
- `motor_control.py` — motor control CLI (legacy, kept for compatibility)
- `m33ctl.py` — unified M33 CLI (installed as `/usr/sbin/m33ctl`)

---

## Step 4 — Build the Yocto Image

```bash
cd yocto
source init-env.sh          # activates bitbake, sets CWD to yocto/build/
bitbake stm32mp257f-custom-image
```

First build takes **2–4 hours** depending on CPU and internet speed.
Subsequent builds use the shared sstate cache and are much faster.

### Key build outputs (`build/tmp/deploy/images/stm32mp25-disco/`)

| File | Description |
|------|-------------|
| `tf-a-stm32mp257f-dk.stm32` | TF-A BL2 — first-stage bootloader |
| `fip-stm32mp257f-dk.bin` | FIP: OP-TEE + U-Boot |
| `fitImage` | Linux kernel + DTB |
| `stm32mp257f-custom-image-*.ext4` | Root filesystem |

### Useful partial builds

```bash
bitbake m33-firmware                       # firmware + startup service only
bitbake m33-dashboard                      # dashboard + WS server only
bitbake virtual/kernel                     # kernel + DTB only
bitbake stm32mp257f-custom-image -c rootfs # rootfs only (no re-sign)
```

---

## Step 5 — Flash the SD Card (initial provisioning)

Identify your SD card device:

```bash
lsblk -d -o NAME,SIZE,MODEL,TRAN
```

Then flash:

```bash
sudo ./scripts/flash-sdcard-ab.sh /dev/sdX
```

The script asks for confirmation, then:

1. Creates the 12-partition GPT layout
2. Writes TF-A BL2 to `fsbl1` and `fsbl2`
3. Writes FIP to `fip-a`
4. Formats `boot-a` (FAT32) and copies `fitImage` + DTB
5. Writes rootfs to `rootfs-a` (ext4)
6. Formats `rootfs-b`, `boot-b`, `userdata` (empty, ready for OTA)

Insert the SD card into the STM32MP257F-DK, set the boot switch to SD, and power on.

---

## First Boot

After ~30 seconds:

```bash
ssh root@192.168.7.80      # empty password (debug-tweaks image feature)
```

Check the M33 coprocessor:

```bash
systemctl status m33-firmware-start
cat /sys/class/remoteproc/remoteproc0/state   # should print: running
```

Open the dashboard in a browser:

```
http://192.168.7.80:8080
```

The page displays live graphs for ADC ch0 (PC7), ADC ch1 (PF11), and encoder position, updated at 1 Hz over WebSocket. The WebSocket bridge (`m33-dashboard.service`) starts automatically after the M33 firmware is running.

---

## SD Card Partition Layout

| # | GPT Label | FS | Size | Contents |
|---|-----------|----|------|----------|
| 1 | `fsbl1` | raw | 1 MB | TF-A BL2 (primary) |
| 2 | `fsbl2` | raw | 1 MB | TF-A BL2 (backup) |
| 3 | `metadata1` | raw | 1 MB | SWUpdate boot metadata |
| 4 | `metadata2` | raw | 1 MB | SWUpdate boot metadata (backup) |
| 5 | `fip-a` | raw | 4 MB | FIP slot A: OP-TEE + U-Boot |
| 6 | `fip-b` | raw | 4 MB | FIP slot B (OTA target) |
| 7 | `uenv` | raw | 1 MB | U-Boot environment (libubootenv) |
| 8 | `boot-a` | FAT32 | 64 MB | Kernel + DTB slot A |
| 9 | `boot-b` | FAT32 | 64 MB | Kernel + DTB slot B |
| 10 | `rootfs-a` | ext4 | 2 GB | Root filesystem slot A ← initial |
| 11 | `rootfs-b` | ext4 | 2 GB | Root filesystem slot B ← OTA target |
| 12 | `userdata` | ext4 | ~24 GB | Persistent application data |

---

## A/B Dual Boot and OTA Updates

### How boot selection works

U-Boot reads three environment variables from the `uenv` partition:

| Variable | Values | Meaning |
|----------|--------|---------|
| `boot_side` | `a` / `b` | Active slot |
| `upgrade_available` | `0` / `1` | Set to `1` by SWUpdate after writing a new image |
| `bootcount` | 0–3 | Incremented each boot while `upgrade_available=1` |

If `bootcount` reaches `bootlimit` (3) without `upgrade_available` being cleared, U-Boot rolls back to the previous slot automatically.

### Sending an OTA update

```bash
source yocto/init-env.sh
bitbake swupdate-image
./scripts/ota-update.sh \
    yocto/build/tmp/deploy/images/stm32mp25-disco/swupdate-image-stm32mp25-disco.swu
```

After the board reboots into the new image, confirm it is healthy:

```bash
ssh root@192.168.7.80 fw_setenv upgrade_available 0
```

---

## M33 Coprocessor (Zephyr)

### Architecture

```
Linux A35                          Zephyr M33
─────────────────                  ─────────────────────────────────────────
rpmsg-ws-server.py ←─ RPMsg ────→  FOC loop 10 kHz (TIM2 ISR)
port 8765 (WS)         channel       ├─ ADC3 ch0 PC7/INP9  (INA240 phase A)
port 8080 (HTTP)    "m33-ctrl"       ├─ ADC3 ch1 PF11/INP6 (INA240 phase B)
Browser dashboard ←────────────      ├─ Encoder A/B: PF15, PG5
m33ctl            ──────────────→    └─ PWM: PA5(A-HW), PF13(B-SW), PF14(C-SW)
PB5 (gate enable) ─ gpio-cdev ──→  (external gate driver EN)
```

Binary frame protocol (see `zephyr-app/src/protocol.h`):

| Type | Payload | Rate |
|------|---------|------|
| `0x01` ADC | ts_ms, ch0_raw (u16), ch1_raw (u16) | 50 Hz |
| `0x02` Encoder | ts_ms, position (i32), index_count (u32) | 50 Hz |
| `0x03` Motor cmd | mode (u8), setpoint (f32) | on demand (Linux→M33) |
| `0x04` Motor status | ts_ms, speed_rads, angle_rad, id_ma, iq_ma, state, fault | 50 Hz |

### Communicating from Linux

Use `m33ctl` — it automatically routes through the WebSocket bridge
(`m33-dashboard.service`) when it is running, so it never conflicts with the
dashboard over `/dev/rpmsg0`.  Falls back to direct device access when the
service is stopped.

```bash
# Check M33 + bridge status, and which route commands will use:
m33ctl status

# Stream all live data (ADC + encoder + motor):
m33ctl monitor

# Stream only motor status:
m33ctl monitor --motor

# Motor control:
m33ctl motor speed    30       # 30 rad/s ≈ 286 RPM  (closed-loop, needs sensors)
m33ctl motor angle    1.57     # hold at 90°          (closed-loop, needs sensors)
m33ctl motor openloop 2.0      # 2 V on q-axis        (open-loop, no sensors needed)
m33ctl motor off

# Send a command and watch live status:
m33ctl motor speed 20 --monitor
```

### M33 trace log

```bash
mount -t debugfs none /sys/kernel/debug
cat /sys/kernel/debug/remoteproc/remoteproc*/trace0
```

### Rebuilding after changes

```bash
# 1. Rebuild firmware
./scripts/build-zephyr.sh

# 2. Rebuild dashboard (if frontend changed)
./scripts/build-frontend.sh

# 3. Rebuild image and OTA
source yocto/init-env.sh
bitbake stm32mp257f-custom-image
bitbake swupdate-image
./scripts/ota-update.sh yocto/build/tmp/deploy/images/stm32mp25-disco/swupdate-image-*.swu
```

---

## Peripherals

| Peripheral | Pin(s) | Notes |
|------------|--------|-------|
| Ethernet (GMAC) | `eth0` | Static IP 192.168.7.80/24 |
| PWM Phase A | PA5 | TIM2_CH4 AF8, hardware center-aligned 10 kHz |
| PWM Phase B | PF13 | GPIO output, TIM2 CH2 compare ISR (software) |
| PWM Phase C | PF14 | GPIO output, TIM2 CH3 compare ISR (software) |
| Bridge enable | PB5 | Linux GPIO (CID1/A35), driven HIGH on motor on, LOW on off |
| ADC current ch0 | PC7 (INP9) | INA240 phase A, 12-bit, 1.8 V ref |
| ADC current ch1 | PF11 (INP6) | INA240 phase B, 12-bit, 1.8 V ref |
| Encoder A | PF15 | GPIO input, EXTI both-edge, 4× quadrature |
| Encoder B | PG5 | GPIO input, EXTI both-edge |
| eMMC | `/dev/mmcblk0` | `mmc-utils` installed |
| USB Host | `/dev/sdX`, `/dev/ttyUSBX` | `usbutils` installed |
| I2C buses | `/dev/i2c-X` | `i2c-tools` installed |
| UART console | `/dev/ttySTM0` | 115200 baud |
| CAN | `can0` | `can-utils` installed |

### Pin assignment rationale

Only 5 GPIO pins on the STM32MP257F-DK are both RIFSC CID2 (M33-writable) and
physically accessible on the expansion headers: **PA5, PF13, PF14, PF15, PG5**.
All other candidate pins are CID1 (A35-only), CID3 (M0+), or electrically
inaccessible on this board revision. TIM2 is the only CID2-accessible GP timer;
PA5 (TIM2_CH4, AF8) is its only output pin with a CID2-capable AF — all other
TIM2 AF pins are CID1. Phases B and C use GPIO toggling from TIM2 compare ISRs.
PC7 and PF11 work as ADC inputs despite being CID1 because ANALOG mode is the
GPIO power-on reset state.

The gate driver enable is **PB5** (CID1, controlled by Linux A35). The
`rpmsg-ws-server.py` daemon sets it HIGH when any motor mode is commanded and
LOW on `motor off`. To use a different pin pass `--enable-gpio pd1` (or any
`pXN` name) to `rpmsg-ws-server.py` and update `m33-dashboard.service`.

### Motor control

```bash
# On the board, as root — use m33ctl (routes via WebSocket when dashboard is running):
m33ctl motor speed    30       # 30 rad/s ≈ 286 RPM  (closed-loop, needs sensors)
m33ctl motor angle    1.57     # hold at 90°          (closed-loop, needs sensors)
m33ctl motor openloop 2.0      # 2 V on q-axis        (open-loop, no sensors needed)
m33ctl motor off
m33ctl motor speed 20 --monitor
```

Closed-loop speed and angle modes require working current sensors (INA240 on PC7/PF11).
Open-loop mode bypasses current sensing — the setpoint is the q-axis voltage in volts
(clamped to ±Vdc/√3 ≈ ±13.9 V) and the encoder is used for angle tracking only.
Start with a small voltage (1–3 V) when testing open-loop.

---

## Troubleshooting

**`bitbake` reports a missing machine config**
: Confirm `meta-st-stm32mp` is on the correct branch:
  `git -C yocto/layers/meta-st-stm32mp branch`

**M33 service fails with "no remoteproc found"**
: Check `dmesg | grep -i remoteproc`. Enable `CONFIG_REMOTEPROC=y` and
  `CONFIG_STM32_RPROC=y` in the kernel config if missing.

**Dashboard page loads but shows "Disconnected"**
: Check `systemctl status m33-dashboard` on the board. The service requires
  the M33 to be running first — confirm with
  `cat /sys/class/remoteproc/remoteproc0/state` (should print `running`).

**`python3-websockets` not found during bitbake**
: The package lives in `meta-openembedded/meta-python`. Confirm that layer
  is present in `bblayers.conf`.

**SSH unreachable after boot**
: Verify the static IP with a serial console: `ip addr show eth0`.
  Check `systemctl status systemd-networkd`.

**U-Boot rolls back every time**
: SSH into the board before reboot and run
  `fw_setenv upgrade_available 0` to confirm the image is healthy.
