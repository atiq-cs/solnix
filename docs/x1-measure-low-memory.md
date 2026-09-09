# Measuring how much low memory your X1 Carbon actually has

The first boot failed because the loader could not get **859,832,320 bytes contiguous below 4 GB**
(`EFI_OUT_OF_RESOURCES`). The fix shrinks that request. But how much the firmware *will* give is a
property of your machine, and we are currently predicting rather than measuring it.

If the next image also fails, you can get the real number from the `ok` prompt you are already at —
no rebuild, no reflash.

## At the `ok` prompt

The illumos loader has a built-in memory map command. Try, in order:

```
ok  smap
ok  memmap
ok  show
```

`smap` prints the UEFI memory map: type, physical start, page count. What matters is the largest
**`Conventional`** (usable) run that lies entirely **below `0x100000000`** (4 GB). Sum the page
counts of the biggest such block and multiply by 4096.

Useful too:

```
ok  show                 # all loader variables
ok  lsdev                # devices the loader can see (confirms it found the USB)
ok  ls /platform/i86pc/amd64    # confirms it can read the media
```

## What to send back

Either a photo of the `smap` output, or just the single largest below-4 GB `Conventional` block's
size. That converts the next `RD_MB` choice from a guess into an engineered number.

## Why this is worth doing once

`RD_MB` is a build parameter (`scripts/oi-make-livecd.sh`), so it can be set to anything. Knowing the
real ceiling means picking a value that fits with margin on the first try instead of bisecting by
reflashing.

## Note on what this is not

This says nothing about NVMe, wifi or graphics — the boot dies before any of those load. Those remain
untested on this hardware.
