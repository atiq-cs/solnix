# aarch64: the `scsi_vhci` stall — hypothesis REFUTED, GICv3 init now CLEARED

Two results, both from real c6g.metal:

1. The **byte-wide-GICD-write hypothesis** (`docs/aarch64-scsi-vhci-stall-lead.md`)
   is **REFUTED**. It was refuted statically, before any hardware spend.
2. With the GICv3 flag polls bounded and instrumented, the boot **passes the
   entire GICv3 init**, attaches `gicthree0` and `arm_gtmr0`, and stalls later at
   **`NOTICE: Performing full ZFS device scan!`** — a new, precisely-named blocker.

Notably the fix that moved the boot forward was **not** a correction of wrong
register behaviour. Nothing in the GIC was broken. See "what actually moved it".

## Part 1: why the byte-write hypothesis is wrong

The lead doc reasoned from `artifacts/aarch64-a5/qemu-console-a5.log`, where a
*working* QEMU boot emits ~3,864 `gic_dist_writeb: Bad offset ...` lines right
after `scsi_vhci0 is /scsi_vhci`. It inferred the kernel issues byte-wide writes
to `GICD_ICENABLER`/`ICPENDR`/`ICACTIVER`. Four independent checks say otherwise.

### 1. There is no byte accessor in the driver

`usr/src/uts/armv8/io/gicthree.c` (arm64-gate `b0e9cd2`) has only:

| line | accessor | width |
|---|---|---|
| 317 | `gicd_write4` -> `ddi_put32` | 32-bit |
| 330 | `gicd_write8` -> `ddi_put64` | 64-bit |

There is no `ddi_put8`-class GICD accessor at all. The quiesce sweep
(`gicthree.c:2180-2203`) is **already word-granular**, one write per 32 INTIDs:

```c
for (n = 32; n < gc->gc_maxsources; n += 32)
        gicd_write4(gc, GICD_ICENABLERn(n >> 5), 0xFFFFFFFF);
```

`gictwo.c` is the same (`gicd_write` = `ddi_put32`, `gictwo.c:266`; sweep at 968).

### 2. QEMU manufactures the bytes itself

`hw/intc/arm_gic.c` decomposes every wide MMIO write:

```
gic_dist_writel()  ->  gic_dist_writew() x2  ->  gic_dist_writeb() x4
```

So **one** 32-bit kernel store is logged as **four** `writeb` lines. The log
shows exactly that signature — runs of four consecutive byte offsets starting at
a word-aligned address:

```
1a4 1a5 1a6 1a7   2a4 2a5 2a6 2a7   3a4 3a5 3a6 3a7   1a8 1a9 1aa 1ab ...
```

`0x1a4 % 4 == 0`, and every offset in the log appears exactly twice (two sweep
passes). This is the fingerprint of word writes, not byte writes.

### 3. "Bad offset" is an interrupt-count bound, not a granularity complaint

Decoding the *first rejected offset* of every register group gives the same INTID:

| register | first bad offset | implied INTID |
|---|---|---|
| `GICD_ICENABLER`  | `0x1a4` | 288 |
| `GICD_ICPENDR`    | `0x2a4` | 288 |
| `GICD_ICACTIVER`  | `0x3a4` | 288 |
| `GICD_IPRIORITYR` | `0x520` | 288 |
| `GICD_ITARGETSR`  | `0x920` | 288 |
| `GICD_ICFGR`      | `0xc48` | 288 |

288 is exactly QEMU virt's interrupt count: `NUM_IRQS` 256 + 32 internal
(`hw/arm/virt.c:150`, `:1364`). QEMU's handler does `if (irq >= s->num_irq) goto
bad_reg;`. The kernel sweeps to `GICD_TYPER_LINES` (up to 1020); the model only
implements 288 lines, so every write above that INTID is out of range and logged.

Nothing is being rejected for *width*. Nothing that matters is being dropped
either: the writes that land on real INTIDs all succeed. And on Graviton those
lines physically exist — measured `maxsources=0x3df` (991) — so there is nothing
to reject there at all.

### 4. The two logs are different drivers

The QEMU log's next devinfo line after `scsi_vhci0` is:

```
gictwo0 at root: space 0x0 offset 0x8000000 and space 0x0 offset 0x8010000
```

QEMU virt runs the **GICv2** driver; Graviton runs **gicthree.c**. The comparison
was across two different code paths, so that log could never have evidenced the
metal stall regardless of what the offsets meant.

### The methodological lesson

"The working boot does X at exactly the point the broken one dies" is a
**correlation**. Here X was not even a kernel behaviour — it was an artifact of
how the *emulator logs* an ordinary, architecturally-correct write. Decode the
observation into a mechanism before treating it as a diagnosis.

## Part 2: the real defect — unbounded MMIO polls

`gicthree.c:303` (stock) waits for a GIC status flag with no bound:

```c
static inline void
reg_await_clear4(ddi_acc_handle_t hdl, caddr_t base, uint32_t reg, uint32_t mask)
{
        while (ddi_get32(hdl, (uint32_t *)(base + reg)) & mask)
                ;
}
```

Reached from three sites:

| site | register / flag | line |
|---|---|---|
| `gicd_drain_writes`  | `GICD_CTLR.RWP`            | 995 (called 2150, 2153, 2182) |
| `gicr_drain_writes`  | `GICR_CTLR.RWP`            | 1037 (called 1366, 1695) |
| `gicv3_awaken_cpu`   | `GICR_WAKER.ChildrenAsleep`| 1079 |

An unbounded spin is the right *shape* for the observed failure: silence with no
panic. A failed `VERIFY` would have printed. And this hardware had already been
caught not driving a status flag as specified — the PL011 TXFF/TXFE quirk that
required the bounded FR poll in `armv8/boot/boot_uart.c`.

### The fix

`src/aarch64-arm64-gate-patches/a6-gicd-bounded-await-and-markers.patch`

- Caps each poll at `GICV3_AWAIT_MAX` (10,000,000 reads).
- On expiry, prints the **site name, register, mask, last value read and region
  base**, then *returns and lets the boot continue*. A silent bound would only
  relocate the mystery; an announced one names the flag that never cleared.
- Report count capped at 8 (`GICV3_AWAIT_REPORT_MAX`) so 64 stuck redistributors
  cannot flood a slow console, while every call still returns.
- 17 `[A6GICD:*]` phase markers across `gicv3_init`, the redistributor walk, LPI
  setup and `gicv3_cpu_init_raw`, so the boot reports its position even if the
  stall turns out not to be in a spin at all.

Markers use `prom_printf`, which reaches the console through the
**already-bounded** `boot_uart_putchar` — so the diagnostic cannot reintroduce a
FIFO hang. (`prom_printf` is legal from a loadable module: `pcicfg.c:180` does the
same `extern`; `nm -u` confirms it resolves as an undefined symbol against `unix`.)

Proven off-target first — the property "this function always returns" cannot be
observed on a machine that hangs:

```
$ cc -std=gnu99 -Wall -o /tmp/t a6gicd-test_bounded_await.c && /tmp/t
ALL CHECKS PASSED (bounded await always returns; stuck flag reports its site; report cap holds)
```

The harness also pins the *old* code as genuinely unbounded (still spinning after
50,000,000 reads), so it fails for the bug being fixed, not merely passes for the fix.

## Part 3: the metal result

Full console: `artifacts/a6gicd-metal-console-GICV3-INIT-COMPLETE.txt`
(raw: `artifacts/a6gicd-metal-console-raw.txt`)

```
scsi_vhci0 at root
scsi_vhci0 is /scsi_vhci            <-- where every prior run went silent
[A6GICD:init-enter]
[A6GICD:walk1 nredist=0x40 nregions=0x4]
[A6GICD:walk2-done]
[A6GICD:redist-assigned]
[A6GICD:typer=0x17b041e maxsources=0x3df nredist=0x40]
[A6GICD:gicd-disabled]
[A6GICD:are-set]
[A6GICD:are-verified]
[A6GICD:spis-disabled]
[A6GICD:gicd-enabled]
[A6GICD:lpi idbits=0x10 propsz=0xe000 pendsz=0x2000 nredist=0x40]
[A6GICD:lpis-init]
[A6GICD:cpu0-awaken]
[A6GICD:cpu0-awake]
[A6GICD:cpu0-gicr]
[A6GICD:cpu0-lpis]
[A6GICD:init-done]
gicthree0 at root: space 0x0 offset 0xbc00000000 and space 0x0 offset 0xbc00080000
    and space 0x0 offset 0xbd00080000 and space 0x0 offset 0xbe00080000
    and space 0x0 offset 0xbf00080000
arm_gtmr0 at root
NOTICE: Performing full ZFS device scan!    <-- NEW stall point
```

**All 17 markers present. Zero `await-timeout` lines. Zero panics.**

### What this proves

- The GICv3 init path **completes** on real Graviton. Distributor disable, ARE_NS
  enable and readback, SPI quiesce, distributor enable, LPI tables for all 64
  redistributors, boot-CPU wake, GICR config, LPI enable — all clear.
- **No flag was actually stuck.** Every bounded poll returned inside its cap. The
  three suspect sites, in the ranking used before the run:
  1. `gicv3_awaken_cpu` / `GICR_WAKER.ChildrenAsleep` — **not stuck**
     (`cpu0-awaken` -> `cpu0-awake`).
  2. `gicr_drain_writes` / `GICR_CTLR.RWP` — **not stuck** (`cpu0-gicr`).
  3. `gicd_drain_writes` / `GICD_CTLR.RWP` — **not stuck** (`gicd-disabled`,
     `are-set`, `spis-disabled`).
- Hardware numbers all agree with the MADT-derived geometry: `nredist=0x40` (64),
  `nregions=0x4`, `maxsources=0x3df` (991 SPIs), `idbits=0x10` (65536 LPI INTIDs).
  `gicthree0` attaches with the GICD region plus all four redistributor regions.

### What actually moved the boot forward

Being honest about causality: the boot advanced, but **not** because a wrong
register access was corrected. Nothing in the GIC was misbehaving. The plausible
mechanisms, in order:

1. **The markers themselves.** 17 `prom_printf` calls inside `gicv3_init` add
   console I/O — and therefore delay and memory barriers — between GIC
   programming steps. If the real defect is a missing barrier or a settle-time
   assumption, print statements can mask it. This is the classic
   instrumentation-perturbs-the-bug case and it must be treated as the leading
   explanation until separated.
2. **The bound converting a long-but-finite wait into a bounded one.** If some
   poll needed more than a reasonable time but fewer than 10,000,000 reads, it
   would previously have looked like a hang on a slow console yet reported no
   timeout now.

Both are distinguishable by one cheap experiment: rebuild with the bounds kept
and the phase markers removed (or gated behind `prom_debug`). If the boot still
reaches the ZFS scan, the bound was load-bearing; if it goes silent again, the
markers were, and the true defect is a barrier/timing bug near the GIC writes.
**That experiment has not been run.** Until it is, "GIC init is fixed" is not a
claim this evidence supports — only "GIC init demonstrably completes, and no GIC
status flag is stuck" is.

Also unresolved: the console on this run was extremely slow (~2.5h from
`scsi_vhci0` to the ZFS scan, a few hundred bytes total). That is consistent with
the bounded FR poll spending its full cap on every character, which is itself
worth measuring.

## Part 4: the next blocker

```
NOTICE: Performing full ZFS device scan!
```

The boot stalls here. Confirmed stalled rather than slow: three successive
`get-console-output` calls over ~25 minutes returned identical bytes with only
the trailing timestamp advancing. `describe-instance-status`: `running / system
ok / instance impaired`. No panic, no further devinfo lines.

This is **past** GIC attach and is the first point requiring **real device
enumeration**: the NVMe/PCIe root complex, and therefore MSI/MSI-X delivery
through the ITS. In the QEMU boot the corresponding step is followed by
`simple-bus0`, the `viommionex*` nodes and `blkdev0`; here nothing follows.

Note the MADT reports **4 GICITS subtables**, and `gicv3_init_lpis` succeeded
(`propsz=0xe000`, `pendsz=0x2000` per redistributor), so LPI *tables* exist. What
has never been exercised is an actual ITS command queue, device/collection
mapping, and an MSI arriving. That is the natural next investigation — along
with the marker-vs-bound experiment above, which should come first because it is
nearly free and determines whether the GIC leg is genuinely closed.

Per instruction, this was captured and not chased.

## Durable artifacts

In `src/aarch64-arm64-gate-patches/`:
- `a6-gicd-bounded-await-and-markers.patch` — the fix + instrumentation (against
  `usr/src/uts/armv8/io/gicthree.c`).
- `gicthree.c` — the full patched file as built.
- `a6gicd-test_bounded_await.c` — host harness; proves the bounded poll always
  returns, reports its site, and honours the report cap.
- `a6gicd-bounded-await-test-output.txt` — its output.

In `artifacts/`:
- `a6gicd-metal-console-GICV3-INIT-COMPLETE.txt` — filtered console.
- `a6gicd-metal-console-raw.txt` — raw `get-console-output`.

## Build/test notes worth keeping

- **`gicthree` is a separate PSM driver module**, not part of `unix`
  (`ROOT_PSM_DRV_DIR`, `usr/src/uts/armv8/gicthree/`). A `unix` rebuild does not
  pick up a `gicthree.c` change. Build it with
  `bldenv -d -T aarch64 <gate>/env/aarch64` then `cd $SRC/uts/armv8/gicthree &&
  dmake -e all` (confirm the banner says `aarch64/DEBUG (cross)`).
  Its `OBJ64` (non-debug) variant fails on a missing `genunix` uniquify file;
  harmless, the image uses `debug64`.
- **Staging into proto is not sufficient.** `build_image.sh` installs from the
  nightly repo, so the package must be republished (`cd $SRC/pkg && dmake
  install`) or the image silently ships the old module. Verify by digest:
  `digest -a sha1 proto/.../gicthree` must exist under
  `packages/aarch64/nightly/repo.redist/file/<xx>/<hash>`.
- **Verify the fix is in the image before spending metal.** After the transfer,
  `sudo dd if=/dev/nvmeXn1 bs=1M skip=4096 count=4096 | strings -a | grep A6GICD`
  found both the markers and the manifest line carrying the expected hash and
  `pkg.size`. Cheap, and it catches a stale-module boot before it wastes hours.
- **Backgrounding on OmniOS**: `setsid` does not exist, and a bare
  `nohup cmd &` over ssh dies with the session. What works: write a `/tmp/x.sh`
  script file, then `nohup /tmp/x.sh > /tmp/x.log 2>&1 &`, and poll the log with
  separate short reads.
- `tools/build_image.sh` and `build_qemu.sh` are not executable and are ksh93:
  invoke as `ksh93 ./tools/build_image.sh`.
- `build_image.sh` destroys its `braich_image` dataset via an EXIT trap, so
  inspect the built root *before* it returns, or inspect `out/illumos.zfs`.
- The build host and the Linux transfer helper are in the same VPC: allow the
  build host's **private** /32 on :22 for the duration of the copy and revoke it
  afterwards, rather than any public rule. Transfer measured **90.6 MB/s**.
