# A6 FINAL: FR-fix on real Graviton (c6g.metal) -- RESULT

## Verdict

The FR (PL011 flag-register) fix WORKS. On real Graviton the bounded flag
poll no longer hangs the console forever -- the kernel now boots PAST the
first bcons/prom print, loads its modules, and prints the illumos version
string. The console milestone is met: kernel-proper output flows on real
silicon. The boot then dies on a NEW, unrelated early-memory bug
(`bmemlist_alloc Out of memory`), not the console/FR hang.

## The [A6KCON:FR=] value (real Graviton PL011 flag register)

    [A6KCON:FR=00000000]

FR reads **0x00000000** at `bi_bsvc_uart_mmio_base + 0x18` on the real
c6g.metal Graviton. (Confirmed twice: this v5 boot AND the earlier
stale-AMI boot both read FR=0x00000000.)

## [A6KCON:PUT] result

    Z
    [A6KCON:PUT hang txfe]

- TXFF (bit 5) = 0  -> the pre-write "wait while TXFF" loop passes immediately.
- The 'Z' is written to UARTDR (raw write reaches the console fine).
- TXFE (bit 7) = 0  -> the post-write "wait until TXFE set" loop exhausts its
  1,000,000 cap  -> `hang txfe`.

Because FR is stuck at all-zero, TXFE never asserts. The OLD (unbounded) poll
spun forever here -> "markers appear, banner never does". The FR fix's BOUNDED
poll (cap 1e6) times out and CONTINUES -- which is exactly why the kernel now
proceeds to module load.

## Does the SunOS banner appear on real c6g.metal now?

Not yet -- but for a DIFFERENT reason. The console/FR hang is gone. The boot
now reaches, in order:

    Setting currdev to zfs:armpool/ROOT/braich:
    Booting...
    [A6KCON:BOP]                 (kernel proper entry, MMU on)
    [A6KCON:FR=00000000]         (real Graviton PL011 FR)
    Z
    [A6KCON:PUT hang txfe]       (bounded poll times out, does NOT hang)
    module .../unix:   text at [0xfffffffffe02a000, ...]  data ...
    module .../genunix: text at [0xfffffffffe621a20, ...] data ...
    module .../platmod: text at [...] data ...
    illumos Version arm64-gate-0-gae3cab2471 64-bit
    DEBUG enabled
    bmemlist_alloc Out of memory
    Press any key to reboot.
    Resetting...

`[A6KCON:BCONS]` did not surface in the captured buffer (interleaved/scrolled
behind the loader's banner redraw), but `[A6KCON:BOP]` + the FR block + the
version string prove the kernel proper is running and printing on real
silicon.

## How far the kernel boots

banner: NO (blocked before it)
probe:  NO
root:   NO (root already mounted via ZFS bootfs=armpool/ROOT/braich by loader)
shell:  NO

Furthest point: **module load + illumos version print**, then
`bmemlist_alloc Out of memory` in early boot memory setup. This is the new
frontier -- strictly past where the FR hang used to stop it.

## The exact next fix (FR value as evidence)

The FR fix itself needs no further work for the *hang* -- the bounded poll is
correct and lets boot proceed. Two follow-ups, in priority order:

1. **NEW BLOCKER (do this next): `bmemlist_alloc Out of memory`.**
   Early boot memory-list allocator runs dry before the banner. This is the
   real next milestone. Investigate `bmemlist_init` / `bmemlist_alloc` in
   `usr/src/uts/armv8/os/fakebop.c` and how the EC2/Graviton physical memory
   map (from the FDT/UEFI memory map) is fed into the boot memlist -- the
   metal box has far more RAM than QEMU, so a too-small static bmemlist arena
   or a bad memory-map parse would exhaust it. This is unrelated to the UART.

2. **PL011 FR=0x00000000 on Graviton (console robustness).**
   A healthy PL011 at idle reads FR=0x00000090 (TXFE bit7=1, RXFE bit4=1).
   Graviton returning 0x00000000 means the flag register at `base+0x18` is NOT
   behaving as a standard SBSA PL011 FR at that offset -- either:
     - the SPCR/console UART on Graviton is a different UART type (e.g. an
       8250/16550-style or a Graviton-specific block) whose 0x18 offset is not
       the PL011 FR, or
     - the MMIO base handed in via `bi_bsvc_uart_mmio_base` is not the console
       UART's PL011 register block on this platform.
   Because FR never reflects real TX state, `boot_uart_putchar()`'s
   flag-checked path is unsafe on Graviton. The durable console fix is to stop
   trusting FR here: either (a) drop the TXFE post-wait entirely and keep only
   a bounded TXFF pre-guard (raw DR writes already reach the console, as proven
   by every A6KCON marker), or (b) detect FR==0 once at bcons_init and fall
   back to unconditional raw DR writes. Option (a)/(b) removes the `hang txfe`
   stall cost on every character. This does NOT block the banner today (the
   bounded poll already lets it through), so it is secondary to fix #1.

## Artifacts / IDs (account mala, us-east-2)

- FR-fix source: `illumos-gate/usr/src/uts/armv8/os/fakebop.c` (bop_init:
  raw FR read @base+0x18, emit `[A6KCON:FR=xxxxxxxx]`, bounded TXFF/TXFE poll
  cap 1e6 -> `[A6KCON:PUT ok|hang txff|hang txfe]`).
- unix (FR-fix): 2126584 bytes, `illumos Version arm64-gate-0-gae3cab2471`,
  contains all six A6KCON markers.
- Bootable image: `/aarch64/arm64-gate/qemu-setup/illumos-disk.img`
  md5 **cb20e37d681ad9b6a28ec0092134e035** (after fixing BOTH the empty ESP
  and the empty ZFS pool -- see "Image build defect" below).
- Snapshot: `snap-06bb85068093687ed` (10G, md5 verified byte-clean on dd).
- AMI: **ami-0bb916e76c8bb7db4** (arm64 / uefi / ena) -- the fully bootable one.
- Metal that produced this log: `i-0b5062ac9f8db896b` (c6g.metal, TERMINATED).
- Raw console: `a6-frfix-console-raw.txt`; cleaned: `a6-frfix-console-clean.txt`.

## Image build defect found + fixed (why the first boots failed)

`tools/build_qemu.sh` uses `pv < out/illumos.zfs | zfs receive ...` under
`set -e`. On the build node `pv` is not installed, so the `zfs receive`
failed and the script aborted BEFORE populating the ESP. The delivered
`illumos-disk.img` therefore had:
  - an EMPTY EFI System Partition (no `EFI/BOOT/bootaa64.efi`) -> UEFI dropped
    to the interactive shell, "Failed to find bootable partition", ZERO console.
  - an EMPTY ZFS pool (`armpool/ROOT` skeleton only, no `ROOT/braich`, bootfs
    unset) -> even with a loader, "Failed to find bootable partition".

Fix applied (no source change needed to boot -- build-tooling gap):
  1. lofi-mapped the image, `zfs receive out/illumos.zfs` into
     `armpool/ROOT/braich` (no `pv`), set `bootfs=armpool/ROOT/braich`.
  2. `mkfs -F pcfs` the ESP slice, copied
     `proto/root_aarch64/boot/loader64.efi` -> `EFI/BOOT/bootaa64.efi`.
  3. Re-imaged (md5 cb20e37d), snapshot, AMI, metal boot.

Recommend: drop `pv` from `build_qemu.sh` (or `pipe -N`/`cat` fallback) so the
image build no longer silently ships an unbootable disk.
