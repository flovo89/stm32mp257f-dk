# U-Boot boot script for STM32MP257F-DK A/B dual boot
# Compiled to boot.scr by mkimage

# ---- watchdog rollback logic ----
if test ${upgrade_available} = "1"; then
    if test ${bootcount} -ge ${bootlimit}; then
        echo "WARN: bootcount=${bootcount} >= limit=${bootlimit}, rolling back slot"
        if test ${boot_side} = "a"; then
            setenv boot_side b
        else
            setenv boot_side a
        fi
        setenv upgrade_available 0
        setenv bootcount 0
        saveenv
    else
        setenv bootcount ${bootcount}+1
        saveenv
    fi
fi

# ---- select active slot ----
if test ${boot_side} = "a"; then
    setenv boot_part    8
    setenv root_label   rootfs-a
else
    setenv boot_part    9
    setenv root_label   rootfs-b
fi

echo "Booting slot ${boot_side} (boot_part=${boot_part}, root=${root_label})"

# ---- load kernel + DTB from FAT boot partition ----
load mmc 0:${boot_part} ${kernel_addr_r} fitImage
load mmc 0:${boot_part} ${fdt_addr_r}    stm32mp257f-dk.dtb

setenv bootargs "root=/dev/disk/by-partlabel/${root_label} rootfstype=ext4 \
    rootwait rw console=ttySTM0,115200 ${extra_bootargs}"

bootz ${kernel_addr_r} - ${fdt_addr_r}
