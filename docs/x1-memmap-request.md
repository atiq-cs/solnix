# Getting the X1's real low-memory picture: use `memmap`, not `smap`

## Why the first answer could not settle it

`smap` reported `0x58000000` = **1408 MiB**, yet the loader had just failed to allocate **820 MiB**.
That looked contradictory. It is not — **my question was wrong, not your reading.**

`usr/src/boot/efi/loader/memmap.c` does two things that destroy the information needed here:

1. `smap_type()` collapses **five** distinct EFI types into one `SMAP_TYPE_MEMORY`:
   `EfiLoaderCode`, `EfiLoaderData`, `EfiBootServicesCode`, `EfiBootServicesData`,
   `EfiConventionalMemory`.
2. The build loop (line ~127) then **merges adjacent regions of the same collapsed type** into one
   entry.

So a `type=01` length is an **upper bound** that can include memory the firmware is actively using —
not the amount `AllocatePages` can hand out. 1408 MiB "free" and a failed 820 MiB request are
perfectly consistent.

## What to run instead

At the `ok` prompt:

```
ok  memmap
```

`command_memmap` (`main.c:1063`) prints the **raw, unmerged** EFI memory map with **named** types:

```
                   Type     Physical      Virtual   #Pages Attr
```

`#Pages` is hex; each page is 4096 bytes.

## What I need from the output

Only the lines whose **Physical** address is below `0x100000000` (4 GiB), and among those, the ones
typed **`ConventionalMemory`**. For the largest few:

* `Physical` (start address)
* `#Pages` (hex)

That gives the true largest contiguous free run below 4 GiB. A photo of the whole `memmap` output is
ideal — it pages, so `space` advances it.

## If it is long

Just the single largest `ConventionalMemory` region below 4 GiB is enough: its `Physical` and
`#Pages`.

## Already established on your hardware, no need to re-check

* the loader reads the ISO9660 filesystem off USB (`ls /platform/i86pc/amd64` listed
  `boot_archive` + `boot_archive.hash`)
* `lsdev` shows both the USB stick and the internal 1 TB SSD (`disk0`, 1953525168 × 512 blocks)

So the media chain, USB enumeration, filesystem reads and disk visibility all work on real X1
firmware. The **only** failure is the staging allocation.
