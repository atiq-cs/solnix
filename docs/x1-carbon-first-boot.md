install-media: FIRST REAL-HARDWARE BOOT -- X1 Carbon reaches the loader, fails staging an 820 MB ramdisk

The maintainer flashed usb-image-20260909/solnix-x86_64-usb.img to USB and booted a Lenovo X1 Carbon.
This is the first time any solnix image has run on non-EC2 hardware, and it got further than QEMU
could have promised: illumos logo, EFI loader executing, media read successfully. Then:

  Loading /platform/i86pc/amd64/boot_archive...
  failed to allocate 859832320 bytes for staging area: 9
  Booting...
  Can not load environment module: out of memory
  Can not load font module: out of memory
  No rootfs module provided, aborting
  ok

ROOT CAUSE, MECHANISM OBSERVED (traced through the gate source, not guessed):
  * usr/src/boot/efi/loader/copy.c:196 efi_loadaddr() calls
    BS->AllocatePages(AllocateMaxAddress, EfiLoaderData, pages, &paddr) with paddr = UINT32_MAX --
    it demands CONTIGUOUS pages BELOW 4 GB.
  * It stat()s the file, so it stages the UNCOMPRESSED size. boot_archive is 88,570,656 B gzip'd on
    the media but 859,832,320 B uncompressed -- byte-for-byte the number in the error.
  * Status 9 = EFI_OUT_OF_RESOURCES. Real ThinkPad firmware fragments the low 4 GB with runtime
    services, ACPI NVS, framebuffer and reserved regions.
  * Everything after is downstream of the failed staging: environment/font modules OOM, no rootfs,
    ok prompt.

THE RAMDISK IS 83.7% EMPTY. Measured on the raw UFS image: 720,025,532 of 859,832,320 bytes are zero,
i.e. ~133 MB of real content inside an 820 MB ramdisk. oi-make-livecd.sh:44 defaults RD_MB=820 for
minimal while its OWN COMMENT two lines earlier says minimal uses ~268 MB. A ~3x overshoot, and it is
the entire bug.

⚠️ WHY 8/8 QEMU BOOTS DID NOT CATCH THIS, which is the transferable lesson: QEMU/OVMF hands out a
clean, mostly-empty low-4GB memory map, so an 820 MB contiguous allocation succeeds there and fails on
any real machine whose firmware has fragmented that region. The test environment was systematically
more permissive than the target in exactly the dimension that mattered. Note also that this is NOT
the NVMe risk I flagged as most likely -- it fails BEFORE any disk driver loads. My predicted failure
mode was wrong; the actual one was in a part of the boot I had not thought to question.

Also worth stating plainly: the graphical variant defaults RD_MB=900 and would fail identically or
worse.

Fix in progress: shrink RD_MB to measured usage plus real headroom, with `gzip -dc boot_archive |
wc -c` as the acceptance metric since that value is literally what the loader asks EFI for. Fresh
artifacts will go in a new dated directory rather than overwriting the 2026-09-09 set.
