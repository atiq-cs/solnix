# aarch64 Graviton: the console stops when PCIe enumeration closes the bridge window in front of the console UART

Date: 2026-10-22. Account: kiwi (505435643998), us-east-2. Track: aa64. Two c6g.metal boots, 30 min each.
Supersedes the "Next mechanism" section of `docs/aarch64-ecam-ontrap-metal-result.md`.

## Headline

The serial-attach hypothesis is **half right**. With the one `ns16550a "arm,pl011"` line removed from
`driver_aliases`, the box gets past `NOTICE: Performing full ZFS device scan!` for the first time:
`ecam0` attaches and ECAM config space is read. The silent reset loop is **not** fixed. It keeps the
same ~12-13 min period.

A second boot traced every ECAM access. In all 3 reset cycles the console stops at the same access:

> **#146: a 16-bit WRITE to bdf 00:02.0, register 0x20 (type-1 Memory Base).**
> The last access that completed is **#145: an 8-bit read of 00:02.0 register 0x1c (I/O Base), value 0x90.**

00:02.0 is the root port whose memory window, as firmware left it, is **0x80000000-0x83ffffff**. The
console UART lives inside that window: the SPCR names it **PCI 1d0f:8250 at 15:00.0**, MMIO **0x83e00000**.
The aarch64 `add_ppb_props()` unconditionally rewrites every bridge window to the "disabled" value
(`PPB_DISABLE_MEMRANGE_BASE 0x9ff00000`). Access #146 is the first write of that sequence on 00:02.0.
Once the base goes above the limit, the bridge stops forwarding 0x83e00000, and every later console
write goes nowhere. So the kernel cuts the path to its own console. Nothing after that point can be
seen, and that includes whatever finally resets the box.

| claim | status |
|---|---|
| ns16550a attach on the console UART ends console output at the scan line | **CONFIRMED** by A/B: 10-22 image (with alias) stops at the scan line, 2/2 cycles; same image without the alias prints `ecam0 at root` and the first ECAM access, 3/3 cycles |
| ns16550a attach causes the reset | **REFUTED**: without the alias the box still resets on the same period, 3/3 cycles |
| gicv3_its attach is the second candidate | **MOOT**: the image's `driver_aliases` has **0** `arm,gic-v3-its` entries, so `its@` can never bind `gicv3_its` (true on the 10-22 image as well) |
| ECAM access aborts (EC 0x25) | **REFUTED again**: 146 accesses, `rec=0`, `otc=0`, every completed access returned |
| Console dies at the write that disables 00:02.0's memory window, the window holding the console UART | **OBSERVED** 3/3 cycles; the same disable on 00:00.0 (window without the UART) did not stop output |
| What resets the box | **UNKNOWN**: it happens after the console is gone. The watchdog idea is still inferred, not observed |

## Boot 1: ns16550a not bound (the brief's smallest change)

**Change, exactly:** the 10-22 recipe (`src/aarch64-arm64-gate-patches/aa64-assemble.sh`) with step 3
copying `aa-driver_aliases-nopl011.txt` in place of `aa-driver_aliases-pkgstyle.txt`. That file is the
pkgstyle table minus line 1465, `ns16550a "arm,pl011"` (2024 -> 2023 lines, sha256 `7d8becc6...`). No kernel
rebuild: `unix` and every module come from the 10-22 proto tree on the banked build host, which has not
been rebuilt since (fresh `unix` sha `5727f6ba...`, `ecam` `fcc05dc2...`; assemble gate `stale kmods: 0`).
The synthesized `serial@83e00000` node is still emitted; with no alias it stays unbound. The boot_archive
was unpacked after assembly: its `etc/driver_aliases` is the nopl011 file, with 0 `arm,pl011`.

Why this and not removing the `serial@` node: it needs no rebuild of dboot, and it leaves the boot
console path (`boot_uart.c`, which takes the SPCR base directly) untouched.

c6g.metal `i-036c2e11ac8ebbea4`, AMI `ami-0a2567965c5754ed6`, launched 16:37:47Z. I read the console only
with `get-console-output --latest`, 5 polls over 30 min (16:42, 16:46, 16:51, 16:56, 17:08Z), then
terminated the instance. From the scan line to the reset, identical in all 3 cycles:

```
arm_gtmr0 at root
NOTICE: Performing full ZFS device scan!
ecam0 at root: space 0x0 offset 0xc000000000
ecam0 is /pcie@c000000000
ramdisk0 at root
ramdisk0 is /ramdisk
[AAECAM] first cfg access 0:0.0 reg=0x0
[AAECAM] n=1 ms=0 maxus=290 rec=0 otc=0 last=0:0.0
Tianocore/EDK2 firmware version RELEASE 4.19.9          <- reset, no panic
```

Counts in the final capture (42,861 B): EDK2 banners 3, scan lines 3, `ecam0 at root` 3, `[AAECAM]` 6
(first + n=1 per cycle), `panic`/`esr=` 0.

Negative control: `src/aarch64-arm64-gate-patches/aa-metal-ecamfix-boot-20261022.txt`. That is the same
kernel and modules with the alias present: 2 cycles, each ending at the scan line, 0 `ecam0`, 0 `[AAECAM]`.
The one-line table change is the only difference, so it is what moves the boot from the scan line to
the first ECAM access.

## Why gicv3_its was not tested

`src/aarch64-arm64-gate-patches/aa-gen-drivertables.py` collects aliases from `pkg/manifests/*.p5m`
only. The aarch64 platform drivers are declared in `system-kernel-platform.aarch64.inc`, which a
`.p5m` pulls in through `<include ...>`, and the script never reads it. Of the 50 aliases in that file,
44 are missing from the image table: `gicv3_its "arm,gic-v3-its"`, `gicv2m "arm,gic-v2m-frame"` and 42
`cpudrv` CPU compatibles. The 6 that are present (`ns16550a "arm,pl011"`, `ecam`, `gicthree`, `gictwo` x2,
`arm_gtmr`) are there only because the script's `metal_aliases` hard-codes them.
So `its@` has never bound a driver on metal, and boot 2 went to a better-justified measurement.
(Not fixed here. It is a real defect: the ITS is needed for MSI later.)

## Boot 2: per-access ECAM trace

**Instrument:** `aa-ecam-trace.py` on top of `aa-ecam-diag.py`. In `ecam_cfgspace_acc()`, the same path
that printed `[AAECAM]`, it prints `[E>n b:d.f r=reg s=size w=write]` before and `[E<n v=value us=...]`
after each of the first 2048 accesses. `us` includes printing the `[E>` line (~200 us of console time),
so it measures the console, not the access. Only `ecam` was rebuilt (sha `c3761512...`, in the
boot_archive); the image is otherwise boot 1's.

c6g.metal `i-050f2e5b708b60e0e`, AMI `ami-08321c2eb5d42c0d3`, launched 17:35:36Z, 6 polls over 30.5 min,
then terminated. 3 cycles, and **every cycle's last line is `[E>146 0:2.0 r=20 s=2 w=1]`**, with no
`[E<146]`. The console drops characters, as in every earlier metal log, so the records below are read
from the three cycles together. `metal2-key-records.txt` holds every variant seen.

| # | access | value | meaning |
|---|---|---|---|
| 0-2 | 00:00.0 r=0/2/e reads | 1d0f / 0200 / 01 | root port 1d0f:0200, type-1 header |
| 50 | 00:00.0 r=0x22 read16 | 85f0 | MEM limit -> 0x85ffffff |
| 51 | 00:00.0 r=0x20 read16 | 8400 | MEM base 0x84000000 (ENA side; matches Linux `0000:01: resource 1 [mem 0x84000000-0x85ffffff]`) |
| 59-62 | 00:00.0 r=0x20/22/24/26 WRITE16 | 9ff0/1000/9ff0/1000 | `add_ppb_props` disables 00:00.0 windows. **Output continues** |
| 64-65 | 00:00.0 r=0x28/0x2c WRITE32 | 0 | PMEM upper 32 bits |
| 137 | 00:02.0 r=0x22 read16 | 83f0 | MEM limit -> 0x83ffffff |
| 138 | 00:02.0 r=0x20 read16 | 8000 | MEM base 0x80000000: **window 0x80000000-0x83ffffff contains the UART at 0x83e00000** |
| 140-142 | 00:02.0 r=0x24/0x28/0x2c reads | 1 / 180 / 180 | PMEM 64-bit, upper 0x180 (0x18000000000 window) |
| 143-144 | 00:02.0 r=0x1c/0x1d WRITE8 | 90 / 10 | I/O window disable |
| **145** | **00:02.0 r=0x1c read8** | **90** | **last access that completed** |
| **146** | **00:02.0 r=0x20 WRITE16** | (no `[E<`) | **MEM base <- 0x9ff0; console output ends** |

**Where the UART is.** The metal SPCR (`a6pcie-c6gmetal-firmware-tables.txt`, bytes 0x40-0x4b) decodes to
PCI vendor 1d0f, device 8250, bus 0x15, dev 0, fn 0, segment 0. Linux's `lspci -tv` on the same instance
type places `Amazon.com, Inc. Device 8250` at 15:00.0 under `00:02.0-[13-34]`. Its BAR is the SPCR base
0x83e00000, inside 00:02.0's window from #137-#138.

**Negative control in the same boot:** 00:00.0 gets the identical disable writes (#59-#65), and output
continues for 80 more accesses. Its window (0x84000000-0x85ffffff) does not contain the UART. What sets
00:02.0 apart is the UART behind it.

**Mechanism, and how much of it was observed.** The write at #146 and the end of output were observed,
3/3. That the write itself kills the console follows from the PCI bridge rules: a type-1 bridge whose
Memory Base is above its Memory Limit forwards no memory transactions, so 0x83e00000 stops reaching
15:00.0. One link is unproven: whether `[E<146]` was produced and lost, or whether the CPU stalled in the
write. Either way the console is dead from #146 on, so this boot cannot say what happens next.

**Source.** `usr/src/uts/aarch64/io/pciex/pcierc/pci_boot.c` `add_ppb_props()` (lines 2222-2253) reads
the firmware windows, labels them `FWINIT ... (ignored)`, and always writes the disable values. The
x86 copy (`usr/src/uts/intel/io/pci/pci_boot.c` 3208-3255) keeps a firmware window when the bridge's
Memory Access Enable is set and its base is non-zero, and disables it only otherwise. In this case the
aarch64 behaviour is wrong for any SBBR machine whose console sits behind a PCIe bridge.

## What resets the box: still unknown

The console dies at #146, about 30 ms after the scan line. The reset follows ~12 min later. Nothing in
between is visible. Possible causes, none of them observed:

* enumeration continues and later hangs or faults on something else (with no console, a panic prints
  nothing);
* the disabled window also takes away something the platform needs;
* a watchdog fires on the hang. The GTDT is present on metal but its watchdog entries were never
  decoded.

## Next step (not run: the 2-boot budget is spent)

Keep firmware bridge windows the way the x86 `add_ppb_props()` does: when `PCI_COMM_MAE` is set and the
base is non-zero, add the window to the bus's avail/used lists and do not rewrite it. Do the same for
the I/O window under `PCI_COMM_IO`. Check that the later `fix_ppb_res()`/`pci_reprogram()` pass also
leaves the window in place, and that the 8250 BAR is not moved (`add_bar_reg_props` also says
`FWINIT ... (ignored)`). Then boot once more with the trace kept, to see enumeration finish or show the
next blocker with the console still alive.

A cheaper check of the mechanism, if wanted first: skip the three `set_ppb_res(..., DISABLE)` calls for
the bridge whose secondary/subordinate range contains the SPCR bdf (bus 0x15). If the trace then runs past
#146, the mechanism is confirmed.

Independent of that: `aa-gen-drivertables.py` should also read `*.aarch64.inc`, or the 44 platform
aliases (ITS, v2m, cpudrv) stay missing.

## Artifacts

| what | where | sha256 |
|---|---|---|
| boot 1 image (nopl011) | floki `~/solnix-bank/ami/aarch64-6cd2521c1e-serialattach-20261022/aa64-nopl011-20261022.img.gz` | gz `32245136...`, raw `8b99e75d...` |
| boot 2 image (nopl011 + trace) | same dir, `aa64-ecamtrace-20261022.img.gz` | gz `bc235333...`, raw `18aedefa...` |
| consoles | same dir, `metal1-console-i-036c2e11ac8ebbea4.{txt,json}`, `metal2-console-i-050f2e5b708b60e0e.{txt,json}` | in `SHA256SUMS` |
| scripts | same dir: `aa-driver_aliases-nopl011.txt`, `aa64-assemble-nopl011.{sh,diff}`, `aa-ecam-trace.py`, `bh-trace-build.sh`, `ecam-fix+diag+trace.diff` | in `SHA256SUMS` |
| AMIs (in-account only) | `ami-0a2567965c5754ed6`/`snap-061e051d00be5e373`, `ami-08321c2eb5d42c0d3`/`snap-0eff206043fd74de1` | |

Bank read-back: `sha256sum -c SHA256SUMS` 16/16 OK. Both `.img.gz` decompress to the raw sha, which also
equals the dd readback on the EBS volume each AMI was snapshotted from.

Instances: build host `i-021c0fa71602223bf` (from `ami-0de86d0e2f52c0fed`; c5.9xlarge, switched to
c5.4xlarge after InsufficientInstanceCapacity on restart), metal `i-036c2e11ac8ebbea4` and
`i-050f2e5b708b60e0e`. All terminated, with every volume DeleteOnTermination. No keypair or SG was created.
