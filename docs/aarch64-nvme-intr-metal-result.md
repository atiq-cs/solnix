# aarch64 Graviton: nvme0 goes down because MSI-X is sent to the wrong ITS

Date: 2026-10-23. Account: kiwi (505435643998), us-east-2. Track: aa64c. Follows
`docs/aarch64-bridge-window-metal-result.md` (boot 2 there: `gicv3_its0` binds, then `(nvme0) down`, then
`vfs_mountroot` panic).

## Headline

1. **The hypothesis holds, decided by observation.** With nvme's log-only messages sent to the console, the
   admin IDENTIFY times out after 15 s, and nvme's own poll of the admin completion queue then finds the
   completion sitting there:
   `WARNING: nvme0: possible missed interrupt (1 completions found on admin CQ at timeout)`. The controller did
   the DMA and posted the CQE, and the MSI-X was never delivered. 3/3 boot cycles.
2. **Mechanism, from the firmware's IORT dumped on the same console:** PCI segment 0 routes RID -> SMMUv3
   `0xbcfde00000` -> ITS group {ITS id 0 = `0xbc00040000`}. The synthesized FDT keeps the *last* MADT
   translator (ITS id 3, `0xbf00040000`). So the ITS driver maps nvme's DeviceID on ITS 3 and programs the
   MSI-X doorbell `0xbf00050040`. On this platform PCIe MSIs are not routed to that ITS.
3. **Both IORT ID mappings are identity** (RC -> SMMUv3 and SMMUv3 -> ITS group: `in 0x0 count 0xffff -> out 0x0`,
   flags 0). DeviceID = RID, so the driver's `devid 0x1600` (nvme, 16:00.0) and `0x300` (ena, 03:00.0) are
   right. Only the choice of ITS is wrong.
4. **Boot 2 changes only the ITS choice** (dboot follows the IORT for segment 0), and **the root mounts on
   c6g.metal for the first time:** doorbell `0xbc00050040`, 0 nvme timeouts, `blkdev0 ... online`,
   `root on armpool/ROOT/braich fstype zfs`. 3/3 boot cycles.
5. **Next blocker:** right after root mount the console goes silent: the last line is `root on ...` (cycle 1) or
   `dld0 is /pseudo/dld@0` (cycles 2-3). No panic is printed, sshd never answers, and the box still resets on the
   ~13-14 min period. Where it stops is not measured. See "Next blocker".

| claim | status |
|---|---|
| The brief's preferred test (force nvme to FIXED) | **NOT AVAILABLE on this platform** (source + trace): the synth `pcie@` node has `#interrupt-cells` 1 and no `interrupt-map`, the DSDT `_PRT` is never parsed, and the ECAM trace reads `INTERRUPT_PIN` (0x3d) = 0 on every bridge and on ENA. `pci_intr_supported_types` adds FIXED only with IPIN != 0 *and* an `interrupts` property, so nvme was never offered FIXED. Forcing it would have hit `map_interrupt`, not tested the ITS |
| nvme's admin command completes but no interrupt arrives | **OBSERVED**, 3/3 cycles of boot 1 (`possible missed interrupt (1 completions found on admin CQ at timeout)`) |
| nvme got MSI-X through the ITS | **OBSERVED**: `MAPTI nvme0 devid 0x1600 event 0 lpi 8240 cpu 0 doorbell 0xbf00050040`, `admin intr type 0x4 of 0x4, 1 vector(s)` |
| The IORT routes PCIe MSIs to ITS 0, not ITS 3 | **OBSERVED** (IORT bytes on the console; 3 cycles over 2 boots merged, 552/552 bytes exact, 0 conflicts, ACPI checksum valid) |
| RID -> StreamID -> DeviceID is identity | **OBSERVED**, both hops |
| SMMUv3 is in bypass | **INFERRED, not read**: no illumos driver touches the SMMU, and the IDENTIFY CQE landed at the PA the driver programmed. `SMMU_CR0`/`SMMU_GBPA` were not read |
| Choosing the IORT's ITS fixes nvme | **OBSERVED** by A/B (boot 1 vs boot 2, dboot's ITS choice the only difference): `missed interrupt` 3/3 -> 0/3, `root on armpool/ROOT/braich` 0/3 -> 3/3 |
| Next blocker: silent after root mount, then reset | **OBSERVED** 3/3 cycles; location **UNKNOWN** |
| ITS 3 drops the write (vs delivering to the wrong place) | **NOT DISTINGUISHED**: the doorbell write either never reaches ITS 3 or is not translated for this DeviceID. Either way no LPI 8240 |

## Boot 1: observers only (no behaviour change)

Image: aa64b boot 2 rebuilt on a fresh build host (`pcierc` `50095ddb`, `ecam` `c3b33e42`, `driver_aliases`
`b2530338`, `name_to_major` `f4313e7a`, all matching aa64b) plus three observers:

* `nvme.c`: all 86 `"!` messages lose the `!`, so they reach the console. Plus one line naming the admin queue's
  interrupt type and vector count. `nvme` `970818de -> 883c8941`.
* `gicv3_its.c`: the attach summary goes from `!` to `?`. One `MAPTI <drv><n> devid .. event .. lpi .. doorbell ..`
  line per vector of a non-`pcieb` device, and a hexdump of the IORT that dboot copied (`[IORT] off: bytes`).
  `gicv3_its` `-> 2e3e8b13`.
* `dboot_synth_fdt.c`: copies the raw ACPI IORT (capped at 4 KiB) into a `solnix,acpi-iort` property on the `its@`
  node. Nothing else reads it. `unix` `5727f6ba -> 3332be0a`.

Why the IORT goes through the kernel and not a dboot raw-UART dump: dboot's `synth_uart_putc` spins up to 1e6 MMIO
reads per character, and the console speed at that stage on this UART was never measured.

c6g.metal `i-0a7662e0e882f85aa`, AMI `ami-08704efa0a2ac698e` (`snap-0b9fc562c5e294d63`), launched 09:48:59Z.
7 reads with `get-console-output --latest` from 09:53Z to 10:23Z, then terminated (35 min). There were 3 distinct
boot cycles (md5 `44b41837` c1-c3, `18862d5f` c4-c5, `ed2d8222` c6-c7). Each cycle has this tail:

```
gicv3_its0: GICv3 ITS: Devbits=18 IDbits=16 ITT_entry=4 HCC=0 max_colls=64 PTA=no doorbell PA 0xbf00050040
[IORT] 0000: 49 4f 52 54 28 02 00 00 ...                     (18 lines, 0x228 bytes)
...
nvme0: NVMe spec version 1.0
gicv3_its0: MAPTI nvme0 devid 0x1600 event 0 lpi 8240 cpu 0 doorbell 0xbf00050040
nvme0: admin intr type 0x4 of 0x4, 1 vector(s)
gicv3_its0: MAPTI ena0 devid 0x300 event 0 lpi 8241 cpu 0 doorbell 0xbf00050040
gicv3_its0: MAPTI ena0 devid 0x300 event 1 lpi 8242 cpu 0 doorbell 0xbf00050040
WARNING: nvme0: command 0/0 timeout, OPC = 0x6, CFS = 0, STATUS = 0x1
WARNING: nvme0: possible missed interrupt (1 completions found on admin CQ at timeout)
WARNING: nvme0: command 1/0 timeout, OPC = 0x8, CFS = 0, STATUS = 0x1
WARNING: nvme0: ABORT of command 0/0 timed out
WARNING: nvme0: IDENTIFY failed with sct = 0, sc = 0
WARNING: nvme0: failed to identify controller
/pcie@c000000000/pci@2,0/pci@0,0/pci@1,0/pciex1d0f,0@0,0 (nvme0) down
NOTICE: spa_import_rootpool: error 5
panic[cpu0]/thread=fffffffffe168000: vfs_mountroot: cannot mount root
```

How to read it. `nvme_wait_cmd()` (nvme.c) waits `nvme_admin_cmd_timeout` (15 s) and, on timeout, calls
`nvme_process_iocq()` on the admin CQ. A non-zero count means the controller had posted the completion with the
right phase. So: doorbell written, SQE fetched, IDENTIFY executed, CQE DMA'd to host memory, interrupt not
taken. The completion found by polling is then handled through the taskq, but the driver has already moved on
to ABORT. ABORT's own completion has no interrupt either, so it times out (60 s), and `nvme_ctrl_mark_dead` then
gives `down`. `CFS = 0, STATUS = 0x1` (RDY=1): the controller itself is healthy.

ena now gets MSI-X too (2 vectors on the same wrong ITS). ena polls its admin queue, so it would get further than
nvme, but its I/O interrupts would be lost the same way.

## The IORT, and the two ID-mapping hops (orchestrator's check)

The dump crosses a console that drops characters. `iort-merge.py` rebuilds it. A token of two hex digits is a
byte, four digits are two bytes whose separating space was lost, one digit is a byte with a lost digit (unknown).
A line is used only if it decodes to exactly 32 bytes (8 for the last), and only from captures holding all 18 lines.
Placement goes by line index, because printed offsets are damaged too. Boot 1 c1 + c4, then boot 2 c6
(three cycles, different drops): 54 lines, **552 of 552 bytes exact, 0 conflicts, ACPI checksum valid**
(`test/iort-metal-measured.bin`). The hop answer was already fixed by c1 + c4 alone (542 bytes). Negative control:
one exact byte corrupted in one capture is reported as a conflict. Boot 1 c6 lost 3 whole lines (15/18). On the
first run it produced 44 false conflicts, because placement by line index went wrong, so such captures are now
skipped. Decoded (offsets into the table):

| node | type | content |
|---|---|---|
| 0x30 / 0x48 / 0x60 / 0x78 | ITS group | ITS id 0 / 1 / 2 / 3 |
| 0x90 | SMMUv3 `0xbcfde00000` | map in 0x0 count 0xffff -> out 0x0, flags 0, ref 0x30 (ITS 0) |
| 0xe8 | SMMUv3 `0xbdfde00000` | ... -> ref 0x48 (ITS 1) |
| 0x140 | SMMUv3 `0xbefde00000` | ... -> ref 0x60 (ITS 2) |
| 0x198 | SMMUv3 `0xbffde00000` | ... -> ref 0x78 (ITS 3) |
| 0x1f0 | PCI root complex, segment 0, ATS 0, CCA 1 | map in 0x0 count 0xffff -> out 0x0, flags 0, **ref 0x90** |

MADT translators (from `a6pcie-c6gmetal-firmware-tables.txt`): id 0 `0xbc00040000` ... id 3 `0xbf00040000`.

**Case: both hops identity.** RID == StreamID == DeviceID. The driver's DeviceID needs no change, and boot 2's
single variable is the ITS choice. The synth `msi-map` (`0 -> ITS, 0, 0x10000`) is already the right translation
for this table.

**SMMUv3 bypass:** the RC's traffic goes through SMMUv3 `0xbcfde00000`. illumos has no SMMU driver, so whatever
state firmware left it in is still in force. IDENTIFY's data and CQE arrived at the physical addresses the driver
programmed, so DMA is untranslated. Not read from the SMMU's registers.

## Boot 2: the ITS the IORT names

One change from boot 1, `dboot_synth_fdt.c` only (`aa64c-iort-its.diff`). The MADT scan keeps every translator
(TranslationId, base). `synth_pick_pci_its()` walks the IORT from the segment-0 root complex through its first
range mapping (any SMMU node in between) to an ITS group, takes that group's first id, and uses the matching MADT
base for the `its@` node, which pcie's `msi-map` points at. With no IORT, or an unusable one, it keeps the old
last-wins choice. Composing per-hop ID offsets into `msi-map` is left out, marked `shortcut:` in the source, because
this platform measures identity.

Unit test on floki (host `cc`, the walk compiled verbatim out of the patched file, checked equal to the host-built
diff): `test/t_iort.c` over `test/iort-metal.bin`. That was first the 542-byte table with 2 bytes inferred from
structure, then rerun on the fully measured 552-byte table (the two differ only at 0x100, which is off the walk path):
metal seg 0 -> id 0 PASS; seg 1 -> none PASS; RC repointed at SMMU 0x198 -> id 3 PASS (the answer follows the
table); bad signature / truncated / self-loop -> none PASS. Sabotage control: a walk that always returns id 3
FAILS the first case. ASan+UBSan clean, 8/8. (One early run segfaulted: the harness was run from the wrong
directory and `fopen` returned NULL. The harness now checks for that.)

`unix` `3332be0a -> 06282bbc`. `nvme`, `gicv3_its`, `ecam`, `pcierc` and the tables are the same as boot 1
(boot_archive checked).

c6g.metal `i-04a8e0aba68123167`, AMI `ami-04d27849ebcc57904` (`snap-08fec59f045bdd893`), launched 10:45:21Z.
10 reads with `get-console-output --latest` from 10:50Z to 11:16Z, then terminated (31.5 min). There were 3 boot
cycles (md5 `8b58148f` c1-c5 10:50-10:59Z, `0dee538a` c6-c9 11:03-11:12Z, `d256cce4` c10 11:16Z).

Cycle 1 (m2-c1), the tail:

```
gicv3_its0: GICv3 ITS: Devbits=18 IDbits=16 ITT_entry=4 HCC=0 max_colls=64 PTA=no doorbell PA 0xbc00050040
...
nvme0: NVMe spec version 1.0
gicv3_its0: MAPTI nvme0 devid 0x1600 event 0 lpi 8240 cpu 0 doorbell 0xbc00050040
nvme0: admin intr type 0x4 of 0x4, 1 vector(s)
gicv3_its0: MAPTI nvme0 devid 0x1600 event 0 lpi 8240 cpu 0 doorbell 0xbc00050040
gicv3_its0: MAPTI nvme0 devid 0x1600 event 1 lpi 8241 cpu 0 doorbell 0xbc00050040
Block device: blkdev@1,0, blkdev0
blkdev0 is /pcie@c000000000/pci@2,0/pci@0,0/pci@1,0/pciex1d0f,0@0,0/blkdev@1,0
/pcie@c000000000/pci@2,0/pci@0,0/pci@1,0/pciex1d0f,0@0,0/blkdev@1,0 (blkdev0) online
gicv3_its0: MAPTI ena0 devid 0x300 event 0 lpi 8242 cpu 0 doorbell 0xbc00050040
gicv3_its0: MAPTI ena0 devid 0x300 event 1 lpi 8243 cpu 0 doorbell 0xbc00050040
NOTICE: Original /devices path (/pseudo/lofi@1:b) not available; ZFS is trying an alternate path (/pcie@c000000000/pci@2,0/pci@0,0/pci@1,0/pciex1d0f,0@0,0/blkdev@1,0:b)
NOTICE: vdev_disk_open /dev/dsk/c7t1d0s1: update devid from '<none>' to 'id1,kdev@D1D0F-Amazon_Elastic_Block_Store______________-vol089189af18c2bf8e4-1/b'
root on armpool/ROOT/braich fstype zfs
```

The admin queue now runs on MSI-X: IDENTIFY completes, nvme sets up its I/O queues (second vector, event 1), and
blkdev attaches. ZFS finds the pool by the blkdev path, because the image's stored boot path is the lofi
default, and imports the root. Cycles 2 and 3 attach in a different order (`gicv3_its0` before the ECAM walk ends,
lpi 8193/8194, nvme before ena) and print two more lines after `root on`: `pseudo-device: dld0` /
`dld0 is /pseudo/dld@0`. Not one cycle prints a panic, `cpuN:`, an SMF line, or a login prompt.

## Next blocker: silent after root mount, then the periodic reset

| | cycle 1 | cycle 2 | cycle 3 |
|---|---|---|---|
| nvme timeouts / missed interrupt | 0 / 0 | 0 / 0 | 0 / 0 |
| `root on armpool/ROOT/braich fstype zfs` | yes | yes | yes |
| last line | `root on ...` | `dld0 is /pseudo/dld@0` | `dld0 is /pseudo/dld@0` |
| panic printed | no | no | no |
| silent for | >= 9 min (10:50:01 -> after 10:59:21) | >= 9 min (11:03 -> 11:12) | (terminated) |

* **The reset still happens with nothing panicking:** new cycles appear between 10:59:21 and 11:03:24 and between
  11:12:24 and 11:16:40, which is the same ~13-14 min period as every earlier metal boot. So the reset is not
  caused by the panic or the panic path. Previous docs proposed "a platform watchdog firing on a CPU parked at
  the panic". That hypothesis is weakened, but a watchdog that nobody services is still possible: the GTDT
  watchdog entries are still not decoded.
* **EC2 view:** instance status `impaired` (reachability check failed) during cycle 1, system status `impaired` later.
  ssh to the public IP timed out. So ena/DHCP/sshd were never up, or the kernel never reached them.
* **Where it stops is not measured.** The line `dld0 is /pseudo/dld@0` comes from `strplumb_init()` attaching
  `dld`, the first entry of `strplumb_modlist` (common/io/strplumb.c, called from main() right after
  `vfs_mountroot()`). The absence of `ip0`... lines after it means nothing, because ip/tcp/udp do not call
  `ddi_report_dev`. Candidates from source, unranked and untested:
  1. `consconfig()` runs next. `plat_stdoutpath()` -> `plat_ttypath()` (armv8/io/consplat.c) wants an attached
     `ns16550a` instance for the console tty, and this image deliberately binds none to the console UART (the
     10-22 A/B: binding it ended console output). If the kernel cannot build a console stream, later output (SMP
     `cpuN:` lines, SMF) may have nowhere to go, and the box could be running but silent. ssh is down too, so this
     alone does not explain everything.
  2. A hang in strplumb, consconfig, `release_bootstrap()` or `start_other_cpus()`. The first secondary-CPU bring-up
     on metal happens here, and QEMU's next line after `root on` is the SMP `cpuN:` banner.
* **Cheapest decisive next step:** one boot with the console tty question taken out of the picture, i.e. a
  `prom_printf` breadcrumb (the boot UART path, which works) at the entry of `consconfig()`,
  `release_bootstrap()`, `start_other_cpus()` and `exec_init()`, plus one at the end of `strplumb()`. It is an
  observer, ~5 lines. The last breadcrumb printed names the stage.

## Second bug, recorded (not fixed here)

`ena.c:1269`: `ena_cleanup_device_init()` calls `list_destroy(&aq->ea_cmd_ctxs_free)` while
`ena_create_cmd_ctx()` (ena_admin.c:80) has put `ENA_ADMINQ_DEPTH` contexts on it. A failed attach after
"device initialization" therefore trips `list.c:88` on DEBUG kernels (aa64b boot 1). The fix is to drain both
lists (`list_remove_head` until empty) before the two `list_destroy` calls. That path no longer runs now that MSI-X
allocation succeeds, so it could not be exercised on metal in this track.

## Reset

Boot 1: 3 cycles in 35 min, each ending at the `vfs_mountroot` panic. Boot 2: 3 cycles in 31.5 min with **no
panic at all**. The period is unchanged (~13-14 min) in both. See "Next blocker".

## Artifacts

floki `~/solnix-bank/ami/aarch64-6cd2521c1e-nvmeintr-20261023/` (`sha256sum -c SHA256SUMS` 44/44 OK; `RAW.sha256`
for the raw images, each = the EBS `dd` readback on the build host):

| what | file | sha256 |
|---|---|---|
| boot 1 image (observers) | `aa64-nvmeobs-20261023.img.gz` | gz `936d2d44...`, raw `05d71dab...` |
| boot 2 image (+ IORT ITS choice) | `aa64-iortits-20261023.img.gz` | gz `33008a46...`, raw `8093fcf4...` |
| observer patcher + diffs | `aa64c-observers.py`, `aa64c-observers-tracked.diff` (nvme.c, gicv3_its.c), `aa64c-dboot-iort.diff` | in SHA256SUMS |
| the fix | `aa64c-iort-its.py`, `aa64c-iort-its.diff` (dboot_synth_fdt.c, on top of the observer) | in SHA256SUMS |
| unit test | `test/t_iort.c`, `test/iort_walk.inc`, `test/iort-metal-measured.bin` (552/552 bytes from 3 cycles, checksum valid) | |
| console tools | `iort-merge.py` (rebuilds the IORT from damaged dumps), `iort-decode.py`, `poll.sh` | |
| build/assemble | `bh-base.sh`, `bh-obs.sh`, `bh-b2.sh`, `bh-gzdd.sh`, `aa64-assemble-aa64c{1,2}.sh`, `bh-verify-c{1,2}.sh` | |
| consoles | `metal1-console-i-0a7662e0e882f85aa-c{1,4,6,7}.*`, `metal2-console-i-04a8e0aba68123167-c{1,5,6,9,10}.*` | |
| AMIs (in-account only) | `ami-08704efa0a2ac698e`/`snap-0b9fc562c5e294d63`, `ami-04d27849ebcc57904`/`snap-08fec59f045bdd893` | |

Repo (uncommitted): `src/aarch64-arm64-gate-patches/nvme-intr-20261023/` (patchers, diffs, scripts, test, 6 consoles,
`ids.txt`).

Built on a fresh cross host from `ami-0de86d0e2f52c0fed` (c5.4xlarge `i-0028b2ddd3b6ff203`). The aa64b base was
reproduced first and its shas matched (`pcierc` `50095ddb`, `ecam` `c3b33e42`, `unix` `5727f6ba`). Shas:

| module | aa64b boot 2 | boot 1 | boot 2 |
|---|---|---|---|
| `unix` | `5727f6ba` | `3332be0a` | `06282bbc` |
| `nvme` | `970818de` | `883c8941` | `883c8941` |
| `gicv3_its` | (n/a) | `2e3e8b13` | `2e3e8b13` |
| `ecam` / `pcierc` | `c3b33e42` / `50095ddb` | same | same |
| `driver_aliases` / `name_to_major` | `b2530338` / `f4313e7a` | same | same |

Each image's boot_archive was unpacked and its module shas compared equal to the build outputs.

Instances: build host `i-0028b2ddd3b6ff203`, metal `i-0a7662e0e882f85aa` and `i-04a8e0aba68123167`. All
terminated, with volumes DeleteOnTermination (verified gone, below). No SG or keypair was created. The orchestrator
allowed 2 extra metal boots for the AMI step if login was reached. They were not used, because login was not
reached.
