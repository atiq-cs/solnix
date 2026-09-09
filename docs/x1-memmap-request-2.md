# One more `memmap` read — and why the 2 MiB figure can't be the whole story

## What you reported

```
Physical 0x58000000   #Pages 0x200   Attr UC WC WT WB
```

`0x200` = 512 pages = **2 MiB**, spanning `0x58000000`–`0x58200000`.

## Why that cannot be the machine's limit

A consistency check settles it. A **normal installed** illumos `boot_archive` (measured on our live
build host `dixi`) is **140,771,328 bytes = 134 MiB** uncompressed. If 2 MiB were genuinely the
largest free block below 4 GB on your X1, then **no illumos system could ever boot on it** — not our
installer, not a finished install, nothing. The 820 MiB live ramdisk is unusually large, but 134 MiB
is simply what illumos needs.

So the 2 MiB line is almost certainly **one region among many** in a paged listing, not the largest.
Likely the free memory below 4 GB is fragmented into many regions, or the list continued past what
was read.

## What would settle it

`memmap` output is **paged** — press `space` to advance. What I need is either:

* **the whole listing** (photos across pages are fine), or
* just the `ConventionalMemory` lines with **`#Pages` larger than `0x200`** — I only care about the
  big ones, below `0x100000000`.

If it turns out every free region below 4 GB really is ~2 MiB, that is a genuinely unusual firmware
memory map and worth knowing — it would mean this machine needs a different approach entirely, not a
smaller image.

## About the NixOS comparison

Good instinct, and worth stating why it doesn't transfer. NixOS boots
`firmware → systemd-boot/GRUB → Linux kernel + initrd`, and Linux receives the initrd address through
a **64-bit** capable handover, so its initrd can live anywhere in physical memory.

illumos passes modules via **multiboot2 tags**, and `usr/src/uts/common/sys/multiboot2.h:234-235`
declares:

```c
struct multiboot_tag_module {
        uint32_t mb_mod_start;
        uint32_t mb_mod_end;
};
```

Those are **32-bit** fields, so an illumos ramdisk *must* live below 4 GB. The `UINT32_MAX` cap in
`loader/copy.c:191` is structural, not conservatism — and it is why the NixOS stick boots on hardware
where ours does not. The difference is the boot protocol, not the media layout, so copying NixOS's
image structure would not help.

(The 64-bit `ramdisk_start`/`ramdisk_end` properties in `fakebop.c:1560` are *derived from* those
32-bit tags, so they do not widen anything.)
