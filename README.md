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
- Pulse generator on M33: 0–1 MHz square wave on PA5 (TIM2_CH4 AF8), 50 % duty cycle
- Frequency configurable over Ethernet via web dashboard or `m33ctl` CLI
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
│   │       ├── pulse_gen.c / .h ← TIM2 hardware PWM on PA5, 0–1 MHz
│   │       └── protocol.h       ← binary frame format
│   └── zephyr/                  ← cloned by west update
│
├── frontend/                    ← Flutter web UI source
│   ├── pubspec.yaml
│   ├── lib/main.dart            ← pulse generator controller, auto-connects via WS
│   └── web/index.html
│
└── scripts/
    ├── build-zephyr.sh          ← west build + copy ELF to Yocto layer
    ├── build-frontend.sh        ← flutter build web + stage for Yocto
    ├── rpmsg-ws-server.py       ← RPMsg → WebSocket + HTTP bridge (port 8765/8080)
    ├── m33ctl.py                ← M33 CLI: status / freq / off / monitor
    ├── rpmsg-chat.sh            ← low-level RPMsg text debug shell (stop m33-dashboard first)
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

The script stages three files for BitBake into the recipe `files/` directory:
- `frontend-web.tar.gz` — compiled Flutter web app
- `rpmsg-ws-server.py` — WebSocket bridge daemon
- `m33ctl.py` — M33 CLI (installed as `/usr/sbin/m33ctl`)

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

The page shows the current pulse generator state and lets you set the output frequency (preset buttons + custom Hz input). The WebSocket bridge (`m33-dashboard.service`) starts automatically after the M33 firmware is running.

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
rpmsg-ws-server.py ←─ RPMsg ────→  Pulse generator (TIM2 hardware PWM)
port 8765 (WS)         channel       └─ PA5 (TIM2_CH4, AF8)  0–1 MHz
port 8080 (HTTP)    "m33-ctrl"            50 % duty cycle, no ISR
Browser dashboard ←────────────
m33ctl            ──────────────→  SET_FREQ command (freq_hz u32)
```

Binary frame protocol (see `zephyr-app/src/protocol.h`):

| Type | Direction | Payload | Rate |
|------|-----------|---------|------|
| `0x01` SET_FREQ | Linux → M33 | freq_hz (u32)  —  0=stop, 1..1 000 000=run | on demand |
| `0x02` STATUS   | M33 → Linux | ts_ms (u32), freq_hz (u32), enabled (u8) | 10 Hz |

Text frames (not starting with `0xA5`) are echoed back — used by `rpmsg-chat.sh` for diagnostics.

### Communicating from Linux

Use `m33ctl` — it automatically routes through the WebSocket bridge
(`m33-dashboard.service`) when it is running, so it never conflicts with the
dashboard over `/dev/rpmsg0`.  Falls back to direct device access when the
service is stopped.

```bash
# Show connection route and current output state:
m33ctl status

# Set frequency (0 = stop):
m33ctl freq 1000       # 1 kHz
m33ctl freq 1000000    # 1 MHz
m33ctl freq 0          # stop

# Stop output (alias for freq 0):
m33ctl off

# Stream live status at 10 Hz:
m33ctl monitor
```

The web dashboard at `http://192.168.7.80:8080` provides the same control with preset
buttons (Off / 1 Hz / 1 kHz / 10 kHz / 100 kHz / 1 MHz) and a custom frequency input.

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
| Pulse output | PA5 | TIM2_CH4 AF8, hardware edge-aligned PWM, 0–1 MHz, 50 % duty |
| eMMC | `/dev/mmcblk0` | `mmc-utils` installed |
| USB Host | `/dev/sdX`, `/dev/ttyUSBX` | `usbutils` installed |
| I2C buses | `/dev/i2c-X` | `i2c-tools` installed |
| UART console | `/dev/ttySTM0` | 115200 baud |
| CAN | `can0` | `can-utils` installed |

### Pin assignment rationale

PA5 is the only expansion-header GPIO pin on the STM32MP257F-DK that is both
RIFSC CID2 (M33-writable) and has a TIM2 alternate function (TIM2_CH4, AF8).
TIM2 is a 32-bit timer clocked at 200 MHz, giving an ARR range of 199 (1 MHz)
to 199 999 999 (1 Hz) — the full 1 Hz–1 MHz range fits without a prescaler.
No ISR is needed; the hardware PWM output runs autonomously once started.

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
