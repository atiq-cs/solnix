# A6-loader — illumos/arm64 EFI loader ZFS-read off real NVMe: FIXED, kernel hands off on real Graviton

## TL;DR

The illumos/arm64 EFI loader could not read the ZFS **object set** off the real
c6g.metal NVMe (`all block copies unavailable` / `can't read object set for
dataset 54`), stalling before the kernel handoff. Two independent problems, both
now fixed:

1. **Loader bug (the real one):** the EFI block-IO backend issued a single
   `ReadBlocks` of the full ZFS gang/indirect read (up to ~192 KB). AWS
   Nitro/Graviton UEFI's NVMe driver returns `EFI_SUCCESS` for such a large
   transfer but silently delivers only part of the buffer, corrupting the tail;
   ZFS then fails every copy's checksum. Fix: cap each `ReadBlocks` at
   `EFIPART_IOMAX_BYTES` (16 KiB). Under QEMU the reads already happened to be
   chunked to 16 KiB (they took the bounce-buffer path), which is why the *same
   image booted fine in QEMU* but failed on real silicon.
2. **A disk-image transfer artifact** in the AMI build (a `gzip | ssh | ssh |
   dd` pipe short-read) had corrupted the deep ZFS region of the test volume, so
   the first fixed-loader metal boot still failed. Re-streamed via a verified
   file copy + local `gunzip | dd` (raw volume md5 == source).

With the chunked-read loader **and** a byte-clean image, the loader on real
c6g.metal read the whole kernel + boot_archive + boot_archive.hash off real
NVMe with **zero ZFS errors** and printed **`Booting...`** — i.e. it handed off
to the kernel. The kernel then produced no console output (EC2 instance status
`impaired`); that is a kernel/console-handoff issue past the loader's job.

## The exact failing EFI block read (config-ok vs object-set-fail)

Diagnostic build (`-DEFIPART_DEBUG`) logging every `A6RS`
(`efipart_realstrategy` request) and `A6BLK` (each `ReadBlocks`) on real
c6g.metal:

```
A6RS in rw=1 blk=15212828 off=... size=131584 doff=524544 dblks=16236255 bs=512 last=16777215
A6RS dec need_buf=0 ioalign=8 buf=0x... bufaln=1        <- DIRECT path, aligned, single big read
A6BLK rd lba=15212828 nblks=257 bytes=131584 bs=512 st=0   <- ReadBlocks returns SUCCESS...
ZFS: i/o error - all block copies unavailable              <- ...but ZFS checksum fails
```

- Config/label/early-metadata reads (small, low LBA) succeed and pass ZFS
  checksums (243 reads OK before the first failure).
- The failing reads are **large single transfers** (`nblks` 257–384,
  128–192 KB) at high LBAs (11M–15M, deep pool data = kernel/boot_archive).
- Every failing `ReadBlocks` returns `st=0` (EFI_SUCCESS) yet ZFS rejects the
  data on all copies → the read *succeeds but returns wrong bytes*.
- `need_buf=0 ioalign=8` on real HW: reads take the **direct single-ReadBlocks**
  path. Under QEMU `need_buf=1`, so reads were chunked to 16 KiB and never hit
  the large-transfer bug — explaining the QEMU-vs-metal divergence.

## The fix

`usr/src/boot/efi/libefi/efipart.c`, `efipart_readwrite()` F_READ path: split
the request into `EFIPART_IOMAX_BYTES` (0x4000) chunks per `ReadBlocks`,
advancing `blk`/`buf` and bailing on the first error. Block-size-agnostic
(`maxblks = EFIPART_IOMAX_BYTES / BlockSize`, floored at 1). Diagnostics are
kept behind `#ifdef EFIPART_DEBUG` (off in the shipping build).

Patch: `src/aarch64-arm64-gate-patches/a6-loader-efipart-chunked-read.patch`
Full file: `src/aarch64-arm64-gate-patches/efipart.c`
Shipping loader (no debug): `a6-loader-BOOTAA64-fixed.efi` (md5 798e97fa...)

Rebuild: `bldenv -T aarch64 ../env/aarch64`, then
`dmake all` in `usr/src/boot/efi/libefi/arm64` and
`dmake install` in `usr/src/boot/efi/loader/arm64`
(installs `proto/root_aarch64/boot/loader64.efi`, copied to the ESP as
`EFI/BOOT/bootaa64.efi`).

## Does the kernel hand off on real c6g.metal now? YES.

Console (clean image + fixed loader, c6g.metal in us-east-2c, terminated):

```
... (loader reads kernel + boot_archive off real NVMe, 0 ZFS errors, all reads <=16384 bytes) ...
Loading /platform/armv8/aarch64/boot_archive.hash...
Booting...
```

`Booting...` is the loader's last line before `ExitBootServices` + jump to the
kernel entry. The loader-stage ZFS-read-off-real-NVMe is **fixed** and the
loader **hands off**.

## How far on real silicon / remaining stall

After `Booting...` the EC2 console produced **no kernel output** and the
instance went `impaired`. So on real Graviton:

- illumos EFI loader runs, reads the ESP + the **entire ZFS object set / kernel
  / boot_archive** off real NVMe (the A6-loader mandate: DONE), hands off.
- The kernel then either hangs before console init or writes to a console the
  EC2 system-log does not capture. No kernel banner on real silicon yet.

This is a **kernel/console-handoff** issue, separate from the loader ZFS-read
fix. The kernel-side `_CRS` NVMe/ENA path is proven under QEMU; exercising it on
silicon now needs the early-kernel console on Graviton to be captured (e.g. the
loader's `console=` UART vs the EC2 serial console) — the next leg.

## AWS

- c6g.metal test instances `i-0e665d620838fb1eb` (diag), `i-0579118de6be7ee64`
  (clean+fix): **terminated**.
- t3.small helpers: **terminated**. Working volume + all snapshots + all
  intermediate AMIs: **deleted/deregistered**.
- Build node `i-0d24c0ec7a9a0e109`: **left running**.
- No SG / 0.0.0.0/0 changes.

## Files (persisted, not committed)

- `src/aarch64-arm64-gate-patches/a6-loader-efipart-chunked-read.patch` — the fix
- `src/aarch64-arm64-gate-patches/efipart.c` — full patched file
- `src/aarch64-arm64-gate-patches/a6-loader-BOOTAA64-fixed.efi` — shipping loader
- `src/aarch64-arm64-gate-patches/a6hw-metal-console-loader-diag1.txt` — diag boot (large-read failure named)
- `src/aarch64-arm64-gate-patches/a6hw-metal-console-fix1-16kb.txt` — fix on corrupt image (transfer artifact)
- `src/aarch64-arm64-gate-patches/a6hw-metal-console-loader-fixed.txt` — clean image + fix: 0 ZFS errors, `Booting...`
