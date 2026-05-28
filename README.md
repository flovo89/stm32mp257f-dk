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
- Dual A/B partition layout — OTA updates over Ethernet via SWUpdate
- Automatic rollback if new image fails to boot (U-Boot watchdog counter)

---

## Repository Layout

```
stm32mp257f/
├── README.md                    ← you are here
│
├── yocto/                       ← Yocto build workspace
│   ├── setup.sh                 ← clone all upstream layers (run once)
│   ├── init-env.sh              ← source to activate bitbake environment
│   ├── conf/
│   │   ├── local.conf           ← machine, distro, image settings
│   │   └── bblayers.conf        ← layer list (paths relative to build/)
│   └── layers/
│       ├── poky/                ← cloned by setup.sh
│       ├── meta-openembedded/   ← cloned by setup.sh
│       ├── meta-arm/            ← cloned by setup.sh
│       ├── meta-st-stm32mp/     ← cloned by setup.sh  (ST BSP)
│       ├── meta-st-openstlinux/ ← cloned by setup.sh  (ST distro extras)
│       ├── meta-swupdate/       ← cloned by setup.sh  (OTA framework)
│       └── meta-custom/         ← board-specific customisations (versioned)
│           ├── conf/layer.conf
│           ├── recipes-core/images/
│           │   └── stm32mp257f-custom-image.bb     ← top-level image recipe
│           ├── recipes-bsp/u-boot/
│           │   ├── u-boot-stm32mp_%.bbappend
│           │   └── files/
│           │       ├── boot.cmd                    ← A/B boot script
│           │       └── stm32mp257f-dk-uenv.txt     ← default U-Boot env
│           ├── recipes-connectivity/networkd-config/
│           │   └── files/10-eth0.network           ← static IP 192.168.7.80/24
│           ├── recipes-remoteproc/m33-firmware/
│           │   ├── m33-firmware.bb
│           │   └── files/
│           │       ├── zephyr.elf                  ← built by build-zephyr.sh
│           │       ├── m33-firmware-start.sh
│           │       └── m33-firmware-start.service
│           ├── recipes-swupdate/
│           │   ├── swupdate/                       ← swupdate.cfg, fw_env.config
│           │   └── swupdate-image/                 ← sw-description, .swu recipe
│           └── wic/
│               └── stm32mp257f-dk-dualboot.wks     ← 12-partition GPT layout
│
├── zephyr/                      ← west workspace root (all Zephyr artefacts)
│   ├── .west/                   ← created by west init
│   ├── zephyr-app/              ← application + manifest (west.yml)
│   │   ├── west.yml             ← pins Zephyr v4.4.0
│   │   ├── CMakeLists.txt
│   │   ├── prj.conf             ← RPMsg, UART console, GPIO, watchdog
│   │   └── src/
│   │       └── main.c           ← RPMsg echo + 10 s heartbeat to Linux
│   ├── zephyr/                  ← Zephyr RTOS — cloned by west update
│   ├── modules/                 ← Zephyr modules — cloned by west update
│   └── bootloader/              ← MCUboot etc. — cloned by west update
│
└── scripts/
    ├── build-zephyr.sh          ← west build + copy ELF to Yocto layer
    ├── flash-sdcard.sh          ← initial SD card provisioning
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
    libegl1-mesa libsdl1.2-dev pylint xterm python3-subunit \
    mesa-common-dev zstd liblz4-tool \
    sgdisk dosfstools e2fsprogs curl \
    # Zephyr
    cmake ninja-build python3-venv
```

### Python tools

```bash
pip3 install --user west
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

> **If `scarthgap` branch is missing** from an ST repo, check for a
> `scarthgap-5.x.y` tag: `git -C layers/meta-st-stm32mp tag | grep scarthgap`
> and update `setup.sh` accordingly.

---

## Step 2 — Build the Zephyr M33 Application

The Zephyr ELF must exist before bitbake runs, because the
`m33-firmware` recipe packages it into the root filesystem.

### One-time west workspace setup

```bash
cd zephyr/zephyr-app
python3 -m venv venv
source venv/bin/activate
pip install west
west init -l .        # initialise workspace — places .west/ in zephyr/
west update           # fetch Zephyr + all modules (~1 GB) into zephyr/
```

Install the Zephyr SDK manually (`west sdk` is not available until Zephyr 4.0):

```bash
wget https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v1.0.0/zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz
tar xf zephyr-sdk-1.0.0_linux-x86_64_minimal.tar.xz -C ~/
~/zephyr-sdk-1.0.0/setup.sh -t arm-zephyr-eabi       # Cortex-M33 toolchain
```

### Build and deploy

```bash
cd ..   # back to stm32mp257f/
./scripts/build-zephyr.sh
```

This runs `west build -b stm32mp257f_dk/stm32mp257fxx/m33` and copies
`build/zephyr/zephyr.elf` into the Yocto recipe's `files/` directory.

---

## Step 3 — Build the Yocto Image

```bash
cd yocto
source init-env.sh          # activates bitbake, sets CWD to yocto/build/
bitbake stm32mp257f-custom-image
```

First build takes **2–4 hours** depending on CPU and internet speed.
Subsequent builds use the shared sstate cache and are much faster.

### Key build outputs (`build/tmp/deploy/images/stm32mp257f-dk/`)

| File | Description |
|------|-------------|
| `tf-a-stm32mp257f-dk.stm32` | TF-A BL2 — first-stage bootloader |
| `fip-stm32mp257f-dk.bin` | FIP: OP-TEE + U-Boot |
| `fitImage` | Linux kernel + DTB (FIT image) |
| `stm32mp257f-custom-image-*.ext4` | Root filesystem |
| `stm32mp257f-custom-image-*.tar.gz` | Root filesystem (NFS-root / inspection) |

### Useful partial builds

```bash
bitbake tf-a-stm32mp                       # TF-A only
bitbake fip-stm32mp                        # FIP only
bitbake virtual/kernel                     # kernel + DTB only
bitbake stm32mp257f-custom-image -c rootfs # rootfs only (no re-sign)
```

---

## Step 4 — Flash the SD Card (initial provisioning)

Insert a 32 GB (or larger) SD card and identify its device node:

```bash
lsblk -d -o NAME,SIZE,MODEL,TRAN
```

Then flash:

```bash
sudo ./scripts/flash-sdcard.sh /dev/sdX
```

The script will ask for confirmation before erasing, then:

1. Create the 12-partition GPT layout
2. Write TF-A BL2 to `fsbl1` and `fsbl2`
3. Write FIP to `fip-a`
4. Format `boot-a` (FAT32) and copy `fitImage` + DTB
5. Write rootfs to `rootfs-a` (ext4)
6. Format `rootfs-b`, `boot-b`, `userdata` (empty, ready for OTA)

Insert the SD card into the STM32MP257F-DK, set the boot switch to SD,
and power on.

---

## First Boot

After ~30 seconds:

```bash
ssh root@192.168.7.80      # empty password (debug-tweaks image feature)
```

Check M33 coprocessor:

```bash
systemctl status m33-firmware-start
cat /sys/class/remoteproc/remoteproc0/state   # should print: running
dmesg | grep -i remoteproc
```

Check SWUpdate web interface:

```bash
curl http://192.168.7.80:8080     # or open in browser
```

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

### How the boot selection works

U-Boot reads three environment variables from the `uenv` partition:

| Variable | Values | Meaning |
|----------|--------|---------|
| `boot_side` | `a` / `b` | Active slot |
| `upgrade_available` | `0` / `1` | Set to `1` by SWUpdate after writing a new image |
| `bootcount` | 0–3 | Incremented each boot while `upgrade_available=1` |

If `bootcount` reaches `bootlimit` (3) without `upgrade_available` being
cleared, U-Boot rolls back to the previous slot automatically.

### Sending an OTA update

Build and produce a `.swu` package:

```bash
source yocto/init-env.sh
bitbake swupdate-image
# package appears at:
# build/tmp/deploy/images/stm32mp257f-dk/swupdate-image-stm32mp257f-dk.swu
```

Push to the board (automatically selects the inactive slot):

```bash
./scripts/ota-update.sh \
    yocto/build/tmp/deploy/images/stm32mp257f-dk/swupdate-image-stm32mp257f-dk.swu
```

Or push manually via curl:

```bash
# Determine which slot to update (opposite of current)
ssh root@192.168.7.80 fw_printenv boot_side   # prints: boot_side=a

# Update slot B (selection stable,copy2 writes boot-b + rootfs-b)
curl -F "swupdate=@update.swu" \
     -F "selection=stable,copy2" \
     http://192.168.7.80:8080/upload
```

After the board reboots into the new image, confirm it is healthy:

```bash
ssh root@192.168.7.80 fw_setenv upgrade_available 0
```

If you do not confirm, U-Boot reverts to the previous slot after 3 boot
attempts.

---

## M33 Coprocessor (Zephyr)

### Architecture

```
Linux A35                          Zephyr M33
-----------                        ----------
/dev/rpmsgX  ←── RPMsg channel ──→ "m33-ctrl" endpoint
             (OpenAMP over shared SRAM + virtio)
```

The M33 starts at boot via `m33-firmware-start.service`, which writes
`zephyr-m33.elf` to the remoteproc sysfs node.

### Communicating from Linux

```bash
# Read heartbeat messages from M33
cat /dev/rpmsg0

# Send a message (echoed back by M33)
echo "hello M33" > /dev/rpmsg0
```

### Rebuilding and redeploying the Zephyr app

```bash
# Edit zephyr/zephyr-app/src/main.c, then:
./scripts/build-zephyr.sh

# Rebuild the Yocto image with the new ELF:
source yocto/init-env.sh
bitbake stm32mp257f-custom-image

# Build a new .swu package and push:
bitbake swupdate-image
./scripts/ota-update.sh build/tmp/deploy/images/stm32mp257f-dk/swupdate-image-*.swu
```

---

## Peripherals

All peripherals below are configured via the upstream ST kernel DTS for
the STM32MP257F-DK. No custom DTS overlay is required unless you need to
change pin assignments or enable optional hardware.

| Peripheral | Kernel interface | Notes |
|------------|-----------------|-------|
| Ethernet (GMAC) | `eth0` | Static IP 192.168.7.80/24 |
| eMMC | `/dev/mmcblk0` | Handled by `mmc-utils`, auto-detected |
| USB Host | `/dev/sdX`, `/dev/ttyUSBX` | `usbutils` installed |
| USB Device (OTG) | `/dev/gadget` | DTS `dr_mode = "otg"` |
| I2C buses | `/dev/i2c-X` | `i2c-tools` installed (`i2cdetect`) |
| UART console | `/dev/ttySTM0` | 115200 baud |
| CAN | `can0` | `can-utils` installed (`candump`, `cansend`) |

---

## Troubleshooting

**`bitbake` reports a missing machine config**
: Confirm `meta-st-stm32mp` is on the correct branch:
  `git -C yocto/layers/meta-st-stm32mp branch`

**M33 service fails with "no remoteproc found"**
: Check `dmesg | grep -i remoteproc` — the DTS node may be disabled or
  use a different compatible string. Enable `CONFIG_REMOTEPROC=y` and
  `CONFIG_STM32_RPROC=y` in the kernel config if missing.

**SSH unreachable after boot**
: Verify the static IP with a serial console: `ip addr show eth0`.
  Check `systemctl status systemd-networkd`.

**SWUpdate upload returns 400**
: Confirm the `hardware-compatibility` field in `sw-description` matches
  the board's `BOARD` identifier in `swupdate.cfg`.

**U-Boot rolls back every time**
: Log into the board before reboot and run
  `fw_setenv upgrade_available 0` to confirm the image is healthy.
