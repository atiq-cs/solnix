# R-P55 -- the bootable-on-hardware image (toward real RISC-V hardware)

Phase: R-P55 (the full root-pivot -- disk.img is now a real root fs).
This document is the boot-flow + partition-layout plan for R-P56 (real HW).

## What R-P55 already produced (qemu, boot-verified)

`rp55/disk.img` is a 4 MiB raw image holding a REAL root filesystem (the R-P55
v3 blockfs), populated at boot by the kernel from the ramfs:

    /sbin/init   /bin/sh   /bin/ls   /bin/cat   /bin/echo   /bin/true
    /etc/inittab /etc/release /etc/rc
    /root/persist            (proves cross-restart persistence as the live root)

The kernel MOUNTS this blockfs AS `/` (vfs_rootfs_pivot), and once pivoted,
`proc_execv` resolves `/sbin/init`, `/bin/sh`, `/bin/<util>` OFF THE DISK, and
`proc_openf` resolves `/etc/*`, `/bin/*`, `/sbin/*` reads off the disk.  init
(pid 1) reads `/etc/inittab` off the disk, respawns `/bin/sh` off the disk, and
the shell runs `/bin/<util>` off the disk.  This is the bootable-root milestone:
the root fs lives on disk.img and init/sh exec from it.

Boot proof (rp55/qemu-boot.log, -smp 2):
  * `[R-P55.1] ROOT-PIVOT PROVEN` -- /bin+/sbin+/etc populated, / pivoted, init/
    sh/ls read back off the disk as valid ELF.
  * `[R-P55.1] ROOT-PERSIST PROVEN` -- /root/persist survived a full qemu restart
    with the disk as the LIVE ROOT (boot 1 wrote it, this boot found it).

## The boot chain, today (qemu) and on real hardware (R-P56)

Today (qemu -kernel):

    OpenSBI (M-mode, -bios)  ->  the kernel (S-mode, -kernel unix.elf)
      ->  vfs_mount_init + vfs_blockfs_mount (probe virtio-blk)
      ->  run_rootpivot (populate + VFS_MOUNTROOT pivot)
      ->  run_init: exec /sbin/init OFF THE DISK ->  /bin/sh ->  /bin/<util>

The kernel ELF is still loaded by qemu's `-kernel`; the ROOT FS is on the disk.
To make disk.img a genuinely bootable-on-hardware image, R-P56 puts the kernel
+ OpenSBI ON the image too, so firmware loads them from the disk (no -kernel):

    ROM/u-boot SPL  ->  OpenSBI (fw_dynamic/fw_payload, M-mode)
      ->  u-boot proper (S-mode) reads the kernel from the disk's boot area
      ->  the kernel (S-mode) mounts the disk root (blockfs)  ->  init

## The partition layout for a bootable disk.img (R-P56)

A GPT image with a firmware/boot area + the root fs, mirroring the standard
RISC-V (SiFive/QEMU-virt-with-flash) layout:

    sector 0        protective MBR + GPT header
    part 1  (type 2E54B353-1271-4842-806F-...)  -- SPL / u-boot-SPL (if SoC ROM
                                                    loads SPL from a fixed part)
    part 2  (type BC13C2FF-59E6-4262-A352-B275FD6F7172, "extlinux/boot")
                    -- OpenSBI fw_payload (OpenSBI + u-boot proper) OR
                       fw_dynamic + the kernel as the payload
    part 3  (Linux/illumos root, our v3 blockfs)  -- /bin /sbin /etc /root ...

For QEMU-virt with `-drive`, the simplest bootable form skips GPT: OpenSBI's
fw_payload embeds the kernel, and the kernel finds the blockfs root at the fixed
disk offset (block 0 superblock) -- exactly what R-P55 does, minus the `-kernel`.
R-P56 wraps the kernel into an OpenSBI fw_payload so:

    qemu-system-riscv64 -machine virt -bios fw_payload.elf -drive file=disk.img,...

boots with NO `-kernel` -- OpenSBI jumps to the embedded kernel, which mounts the
disk root.  On real HW (e.g. VisionFive/Unmatched) the same fw_payload goes on
the board's boot medium and the root blockfs on the disk/SD.

## What R-P56 must add (the remaining gap to real HW)

  1. Build an OpenSBI `fw_payload` (or `fw_dynamic` + u-boot) that embeds/loads
     the kernel unix.elf, so firmware -- not qemu `-kernel` -- loads the kernel.
  2. A GPT (or the board's expected MBR) on disk.img with the boot area + the
     v3-blockfs root partition; teach the kernel to find the root partition's
     starting LBA (today it assumes the disk starts at the blockfs superblock).
  3. A real-HW virtio-blk / MMC / NVMe backend (the virtio-blk driver already
     works on QEMU-virt; an SD/MMC or SATA/NVMe driver is the HW-specific piece).
  4. A device tree / HW discovery path (QEMU passes a DTB in a1; the kernel
     already boots S-mode under OpenSBI, so wiring the DTB parse is incremental).

R-P55 delivers items that make this tractable: the root fs IS on the disk, the
kernel mounts it as / and execs init/sh off it, and files persist across a full
restart with the disk as the live root.  R-P56 is "put the kernel+firmware on
the image too, add a partition table, boot with -bios only".
