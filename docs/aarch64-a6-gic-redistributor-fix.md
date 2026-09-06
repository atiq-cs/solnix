# aarch64 A6-GIC: the GICv3 redistributor-count root cause + fix

The last blocker to the SunOS banner on real AWS Graviton (c6g.metal) was
`gicthree.c:1581`:

```
panic[cpu0]: assertion failed: num_redistributors >= max_ncpus (0x10 >= 0x40),
             file: ../../armv8/io/gicthree.c, line: 1581
```

64 cpus (`max_ncpus` 0x40), but only 16 redistributors (0x10) discovered.

## How the answer was obtained (no kernel rebuild needed)

The prior `[A6GIC]` diagnostic used `dboot_printf`, whose output never reached
the Graviton serial console, so the plan was to re-route it and rebuild. That
rebuild is not necessary to answer the question: the loader hands dboot the
firmware's own ACPI tables, so **Linux on the same instance type sees the exact
same MADT**. A Linux c6g.metal was launched, `/sys/firmware/acpi/tables/APIC`
dumped, and the instance terminated inside ~4 minutes.

The table is decoded by `a6gic-decode_madt.py`, which walks it exactly as
`synth_scan_madt()` does (`while (item < end && item->Length != 0)`), and is
carried verbatim as `a6hw-graviton-MADT.bin` (5268 bytes, OEM `AMAZON`).

## Ground truth (real c6g.metal MADT)

```
sig=APIC length=5268 rev=5 oem=AMAZON
subtable counts: {GICC: 64, GICMSI: 1, GICITS: 4}

ngicc = 64                      <- NOT 16
standalone GICR subtables = 0   <- the GICC-fallback path is the correct one
distinct GicrBaseAddress = 64, in FOUR blocks of 16:
    0xbc00080000 .. 0xbc00260000   (16 cpus, stride 0x20000)
    0xbd00080000 .. 0xbd00260000   (16 cpus)
    0xbe00080000 .. 0xbe00260000   (16 cpus)
    0xbf00080000 .. 0xbf00260000   (16 cpus)
unique deltas: 0x20000 (within a block), 0xffe20000 (~4GiB between blocks)
```

Of the two candidates in the A6-mem diagnosis, **(b) is correct and (a) is
refuted**: `ngicc` is genuinely 64, the MADT scan does not under-count, and the
redistributors are **not** one contiguous block.

### Why the count was exactly 16

The old code took the LOWEST `GicrBaseAddress` as a single region base and
sized it `ngicc * 0x40000`. That region nominally spans
`0xbc00080000..0xbc01080000`, but only `0xbc00080000..0xbc00280000` is real
redistributor space. The 16th redistributor of that first physical block sets
`GICR_TYPER_Last`, and `gicthree.c`'s walker terminates a region on **either**
`GICR_TYPER_Last` or region end -- so it stopped at 16 and never looked at the
other three blocks. This also explains the otherwise-baffling observation that
sizing at `0x20000` vs `0x40000` produced the same 16: the limiter was never
the size, it was `TYPER.Last` plus three whole blocks that were never declared.

## What `gicthree.c` actually parses (matched exactly)

`gicv3_attach()` (usr/src/uts/armv8/io/gicthree.c):

```c
gc->gc_redist_stride = ddi_prop_get_int(..., "redistributor-stride", 0);
num_redist_regions   = ddi_prop_get_int(..., "#redistributor-regions", 1);
for (i = 0; i < gc->gc_num_redist_regions; ++i) {
        ddi_regs_map_setup(dip, 1 + i, &gc->gc_redist_regions[i].base, ...);
        gc->gc_redist_regions[i].size =
            i_ddi_pd_getreg(dip, 1 + i)->regspec_size;
}
```

So: `reg` index 0 is the distributor, `reg` indices `1..N` are the N
redistributor regions, each region's size comes from its own regspec, and N
comes from `#redistributor-regions`. The `reg` pair count must match the
property exactly. `gicv3_assign_redistributors()` then walks each region
independently, which is what makes multiple regions the correct fix.

## The fix (dboot_synth_fdt.c)

We carry the whole file; `a6-gic-multiregion-redistributors.patch` is the diff.

1. **Collect every per-cpu base.** `synth_gicr_insert()` inserts each GICC
   `GicrBaseAddress` into a sorted, deduplicated `NCPU`-sized array (NCPU=128
   on this port, one redistributor per cpu) during the existing MADT walk.
2. **Coalesce into regions.** `synth_gicr_coalesce()` derives the stride from
   the data (the smallest positive delta between adjacent bases -- 0x20000 for
   a 2-frame redistributor, 0x40000 when VLPIS adds the vector frames) and cuts
   maximal constant-stride runs into one region each, sizing each region
   `ncpus_in_run * stride`. A standalone GICR subtable, if firmware provides
   one, still takes its own base/length directly.
3. **Emit N regions.** `#redistributor-regions` is now the computed region
   count (was hardcoded `1`) and `reg` carries the GICD pair followed by one
   pair per region. Capped at `SYNTH_GICR_MAX_REGIONS` (16); overflow prints a
   warning and truncates, so `gicthree.c` VERIFYs on a short count rather than
   silently mis-mapping MMIO.
4. **Visible diagnostic.** `[A6GIC]` now goes out via a raw store to the SPCR
   UART data register -- the mechanism proven to print on Graviton by the
   `[A6KCON:*]` markers -- rather than `dboot_printf`/bcons, which is not wired
   to the SPCR UART on the quiet-loader path. The MMU is off in dboot, so the
   SPCR base is directly addressable. It falls back to `dboot_printf` when no
   SPCR UART was found (QEMU virt, where `dboot_printf` works anyway).

   **Bounded TXFF poll:** unlike the 14-byte `[A6KCON:*]` markers, this
   diagnostic emits a few hundred bytes, which overruns the PL011's 32-byte TX
   FIFO and would garble output. Each byte now waits for `!TXFF` (UARTFR at
   0x18 = `dr[6]`, TXFF = bit 5), and the wait is **capped** because Graviton's
   PL011 does not drive TXFF/TXFE the way SBSA implies -- the same quirk the
   boot_uart FR-poll fix handles. An unbounded spin would hang the boot rather
   than print.

On this hardware the fix emits:

```
#redistributor-regions = 4
  reg pair 1: 0xbc00080000 size 0x200000   (16 cpus)
  reg pair 2: 0xbd00080000 size 0x200000   (16 cpus)
  reg pair 3: 0xbe00080000 size 0x200000   (16 cpus)
  reg pair 4: 0xbf00080000 size 0x200000   (16 cpus)
```

QEMU virt is unaffected: its bases form a single constant-stride run, so the
algorithm yields exactly one region -- the previous behaviour.

## Verified before any cross-build

`a6gic-test_gicr_regions.c` is a runnable host harness split into two
deliberately independent halves:

- a **hardware model** built ONLY from the MADT -- which addresses physically
  hold a redistributor, and which of those are the last of their physical block
  (i.e. where `GICR_TYPER_Last` is set, derived from the 4-block layout the
  MADT reveals). It knows nothing about the FDT we emit.
- a **walker** that is a transcription of
  `gicthree.c:gicv3_assign_redistributors()`, carrying
  `synth_gicr_insert()`/`synth_gicr_coalesce()` verbatim, and permitted to
  consult the hardware only by reading TYPER at an address, exactly as
  `ddi_get64()` would.

That separation is what makes the outcome a prediction rather than an
assumption: the one model must reproduce the known-BAD number as well as the
known-good one.

```
$ gcc -std=gnu99 -Wall -o /tmp/t a6gic-test_gicr_regions.c && /tmp/t a6hw-graviton-MADT.bin
MADT: ngicc=64 distinct_bases=64 -> regions=4 stride=0x20000
  region[0] base=0xbc00080000 size=0x200000 ncpu=16
  region[1] base=0xbd00080000 size=0x200000 ncpu=16
  region[2] base=0xbe00080000 size=0x200000 ncpu=16
  region[3] base=0xbf00080000 size=0x200000 ncpu=16
hardware model: 64 redistributors, TYPER.Last set at:
    0xbc00260000 0xbd00260000 0xbe00260000 0xbf00260000

reg cells = 20 (1 GICD + 4 GICR pairs), array cap = 68

OLD single merged region base=0xbc00080000 size=0x1000000
OLD walker finds 16 (metal observed 0x10 = 16) -> REPRODUCED

NEW 4-region walker finds 64 redistributors (phantom frames=0)
VERIFY3U(64 >= max_ncpus 64) -> PASS

per-region walk (Last must fire at each region's end):
  region[0] -> 16 redistributors, phantom=0, last addr=0xbc00260000 Last=1
  region[1] -> 16 redistributors, phantom=0, last addr=0xbd00260000 Last=1
  region[2] -> 16 redistributors, phantom=0, last addr=0xbe00260000 Last=1
  region[3] -> 16 redistributors, phantom=0, last addr=0xbf00260000 Last=1

both-models check: region size alone caps each region at 16,
    so total=64 regardless of Last

single-cpu: regions=1 stride=0x20000 size=0x20000 OK
no-bases: regions=0 OK (emitter falls back)

ALL CHECKS PASSED (old path reproduces metal's 16; new path yields 64)
```

**The harness reproduces the metal's failure exactly.** The old merged region
declares 128 frames' worth of space, but the walk ends at the 16th
redistributor because that one sets `TYPER.Last` -- yielding precisely the 0x10
seen in the panic. The same model, unchanged, gives 64 for the new geometry.

An earlier version of this harness derived `TYPER.Last` from the *declared
region size* rather than the *physical block*, and so reported 128 for the old
path -- it could not reproduce the observation, which meant its 64 was not
earned. `TYPER.Last` is a property of the hardware, not of what the FDT
declares; modelling it correctly is what closes the proof.

Two further checks make the new-path result robust rather than lucky:

- `phantom frames = 0` -- every frame the walker counted has a redistributor
  physically behind it, so no region over-hangs into space that would be a
  bogus MMIO mapping on real hardware. (`hw_read_typer()` deliberately returns
  Last-clear for absent redistributors, the pessimistic choice: it lets a walk
  run on and keep counting, so this model cannot flatter the new path.)
- the per-region walk shows each region terminating **on a Last-setting
  redistributor** after exactly 16, so 64 is reached *because* Last fires four
  times, not by ignoring it. Region size alone would also cap each region at
  16, so the new geometry totals 64 under either model.

Degenerate maps (one cpu, no bases) are covered: no divide-by-zero, no
over-run, and the emitter's fallback still produces a valid single region.

## Status

- Root cause: **identified from real hardware tables**, candidate (b).
- Fix: **proven in logic** (harness reproduces old=16 and new=64) and
  **confirmed on real Graviton**: the `gicthree.c:1581` panic is gone and the
  boot proceeds past `scsi_vhci0`.
- Banner: **NOT reached.** The boot stalls silently after `scsi_vhci0 is
  /scsi_vhci`; next leg is device enumeration (NVMe/PCIe attach).

## Metal run 1: the diagnostic works, and it caught a bug in this fix

The rebuilt kernel booted on c6g.metal and the `[A6GIC]` lines reached the
console (`artifacts/a6gic2-metal-console-run1.txt`), confirming the raw
SPCR-UART route is the correct mechanism where `dboot_printf` was invisible:

```
Loading /platform/armv8/kernel/aarch64/unix...
Booting...
[A6GIC] ngicc=40 distinct_gicr_base=1 regions=1 stride=0x20000
[A6GIC] region[0] base=0xbc00080000 size=0x20000 ncpu=0x1
[A6GIC] gicr_base min=0xbc00080000 max=0xbc00080000
[A6KCON:BOP]
[A6KCON:BCONS]
```

`ngicc=40` is hex: 0x40 = 64 cpus, matching the MADT exactly. But
`distinct_gicr_base=1` was wrong -- it should have been 64. The coalescer got a
single base, so it emitted one region of one cpu.

**Cause: a pre-existing guard I preserved without re-examining.** The GICC arm
of `synth_scan_madt()` was wrapped in `if (!g->have_gicr)`, which was correct
when the code only needed *one* fallback base. `have_gicr` goes true on the
first GICC, so once the fix needed *every* base, that guard silently discarded
cpus 1..63. The flag was doing double duty: "a standalone GICR subtable exists"
and "some base is known".

Fix: split the two meanings. A new `have_gicr_subtable` means specifically that
a standalone GICR subtable supplied the regions, and the collection loop and the
region-derivation branch now test that instead of `have_gicr`.

The harness had not caught this because it called `synth_gicr_insert()`
unconditionally -- it tested the coalescer but not the scan guard feeding it. It
now mirrors the real guard and asserts that a box with per-cpu GICR bases yields
as many distinct bases as cpus. Verified the assertion actually fails when the
shipped guard is re-injected:

```
$ # with `if (!g.have_gicr)` restored
buggy: test_gicr_regions.c:277: main: Assertion `synth_gicr_ncpu_base > 1' failed.
$ # with the fix
ALL CHECKS PASSED (old path reproduces metal's 16; new path yields 64)
```

That is the lesson worth keeping: the harness proved the algorithm but not its
*input path*, so a correct coalescer was fed one base. A test that cannot fail
for the bug you shipped is not yet a test of the thing that broke.

### Where the boot stopped (run 2) -- and the missing patch

Run 2 emitted the correct 4-region FDT but still stopped after
`[A6KCON:BCONS]`, *earlier* than prior sessions had reached. That was a
regression of my own making, not a GIC problem: this rebuilt tree was missing
`a6-kcon-boot-uart-fr-poll-fix.patch`. Its `boot_uart.c` half was NOT in
`a6-cumulative-all-legs.patch` (only its `fakebop.c` half was), so `boot_uart.c`
still had the unbounded `while (!(FR & TXFE))` spin that hangs on Graviton's
PL011. Applying that patch restored console output past `bcons_init`.

**Lesson for the patch set:** `a6-cumulative-all-legs.patch` is NOT complete.
Rebuilding from a fresh gate needs, in addition: the FR-poll patch, the arena
one-line constant, the CERRWARN `-Wno-unused-but-set-parameter` addition, and
the `priv_const.c` prereq step.

## RESULT: the GIC blocker is CLEARED on real Graviton (run 3)

Run 3 carried the corrected multi-region fix plus the FR-poll patch
(`artifacts/a6gic3-metal-console-GIC-CLEARED.txt`):

```
[A6GIC] ngicc=40 distinct_gicr_base=40 regions=4 stride=0x20000
[A6GIC] region[0] base=0xbc00080000 size=0x200000 ncpu=0x10
[A6GIC] region[1] base=0xbd00080000 size=0x200000 ncpu=0x10
[A6GIC] region[2] base=0xbe00080000 size=0x200000 ncpu=0x10
[A6GIC] region[3] base=0xbf00080000 size=0x200000 ncpu=0x10
[A6GIC] gicr_base min=0xbc00080000 max=0xbf00260000
[A6KCON:BOP]
[A6KCON:BCONS]
module /platform/armv8/kernel/aarch64/unix: text at [0xfffffffffe02a000, ...]
module /kernel/aarch64/genunix: text at [0xfffffffffe699a20, ...]
module /platform/armv8/kernel/misc/aarch64/platmod: text at [...]
illumos Version arm64-gate-0-gb0e9cd2f8d 64-bit
DEBUG enabled
mem = 134217728K (0x2000000000)
Using default device instance data
SMBIOS not loaded (System does not export an SMBIOS table)
root nexus = Amazon EC2
pseudo0 at root
pseudo0 is /pseudo
scsi_vhci0 at root
scsi_vhci0 is /scsi_vhci        <-- PAST the old panic point
```

All numbers match the hardware: `ngicc=40` is hex (64 cpus),
`distinct_gicr_base=40` (64 distinct bases), 4 regions of `ncpu=0x10` (16),
spanning `0xbc00080000..0xbf00260000`.

**The panic is gone.** Every prior run died at `scsi_vhci0 at root` with
`assertion failed: num_redistributors >= max_ncpus (0x10 >= 0x40),
gicthree.c:1581`. This run prints `scsi_vhci0 is /scsi_vhci` and continues; the
console contains **zero** occurrences of `gicthree` or `num_redistributors`.
That is the multi-region FDT satisfying `VERIFY3U`, exactly as the harness
predicted (64 >= 64).

### Next blocker (precisely named, deliberately not fixed)

The boot then goes quiet after `scsi_vhci0 is /scsi_vhci`, with no panic and no
further device-tree output over ~25 minutes. `describe-instance-status` reported
`running / system ok / instance impaired`. **No `SunOS Release 5.11` banner was
reached, and none is claimed.**

The next leg is device enumeration past `scsi_vhci`: the NVMe/PCIe root-complex
attach that must follow before root-mount. The GIC is now *counted* correctly,
but interrupt distribution and the ITS/MSI wiring are what the first real device
exercises, and that is the natural suspect. Per instruction this was captured,
not fixed.

## Why the metal re-test is a separate leg

The `bene` account has **0 self AMIs and 0 self snapshots**: the arm64-gate
build tree, the cross toolchain, the nightly package repo, and the illumos
build-host AMI were all in the now-closed chiuso/mala/lala accounts. No
illumos/OmniOS AMI is public in us-east-2 either. Rebuilding `unix` therefore
requires provisioning an OmniOS host from the
`downloads.omnios.org/media/stable/omnios-r151058.cloud.raw.zst` image, then
`make download` + `make setup` (a multi-hour from-scratch cross gcc/binutils/
sysroot build), then nightly, then the image pipeline. Build-host provisioning
is the real blocker now, not the GIC.

When that host exists, the remaining path is unchanged and already documented
in `aarch64-image-rebuild-recipe.md`: `bldenv -d -T aarch64 env/aarch64` (the
`-T` flag is mandatory), regenerate `assym.h`, re-apply the gcc-14 CERRWARN
items from `a6-mem-plus-gcc14-build-fixes.patch`, stage `unix` into proto,
republish the kernel package, `build_image.sh`, `build_qemu.sh`, Linux-helper
transfer, arm64 UEFI AMI, one c6g.metal, `get-console-output`.

Expected next console output, in order: the `[A6GIC] regions=4` lines, then
past `gicthree` (no VERIFY3U panic), then `SunOS Release 5.11`, then device
probe and root-mount. **Snapshot the build volume and register a
`solnix-arm64-buildhost` AMI as soon as the cross toolchain works**, before
nightly -- so this toolchain build is never paid a third time.

## Durable artifacts

In `src/aarch64-arm64-gate-patches/`:
- `dboot_synth_fdt.c` -- the full file we carry, containing the fix.
- `a6-gic-multiregion-redistributors.patch` -- the fix as a diff.
- `a6hw-graviton-MADT.bin` -- the real c6g.metal MADT (ground-truth evidence).
- `a6gic-decode_madt.py` -- decodes it the way `synth_scan_madt` walks it.
- `a6gic-test_gicr_regions.c` -- runnable regression test of the region logic.
