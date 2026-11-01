# aarch64 Graviton: keeping the firmware's PCIe bridge windows keeps the console alive; the next blockers are MSI, then the NVMe root disk

Date: 2026-10-23. Account: kiwi (505435643998), us-east-2. Track: aa64b. Two c6g.metal boots, about 30 min each.
Follows `docs/aarch64-serial-attach-metal-result.md`, where the console stopped at ECAM access #146.

## Headline

1. **The bridge-window fix works.** The aarch64 `pci_boot.c` now keeps a memory window and BARs that firmware
   programmed and enabled, as the x86 code does. The console survives all of PCIe enumeration: 28-34k ECAM
   accesses, `rec=0`, 52 `pcieb` attach, `nvme0: NVMe spec version 1.0`. Before the fix, output ended at access
   #146 in 3/3 cycles.
2. **Boot 1's next blocker:** no MSI controller. The image's `driver_aliases` had no `gicv3_its` alias. `ena0`
   fails its attach, and ena's cleanup path then trips a DEBUG assertion:
   `panic ... assertion failed: list->list_head.list_next == node, file: ../../../common/list/list.c, line: 88`.
3. **Boot 2** used the fixed driver tables and nothing else changed. `gicv3_its0 at gicthree0`, and the 108
   `could not attach MSI controller` warnings go to 0. The next blocker is the root disk: `nvme0 ... down`, then
   `spa_import_rootpool: error 5`, then `panic ... vfs_mountroot: cannot mount root`.
4. Every boot still ends in a panic, and the box still resets on a ~12-13 min period. It now prints a panic
   before each reset. The reset itself is still not explained; see "Reset" below.

| claim | status |
|---|---|
| Disabling 00:02.0's window cuts the console | **CONFIRMED by the fix**: with the window kept, output continues past #146 to the end of enumeration, in every captured cycle of both boots (3 + 3) |
| Console UART BAR stays put | **OBSERVED**: 15:00.0 is BAR-sized twice (12 `[E~ muted 4 1500]` lines in each capture), and output resumes after each |
| ena fails for lack of MSI | **OBSERVED** in boot 1: `could not attach MSI controller` x108, `ena0: the ena driver only supports MSI-X interrupts`, `attach sequence failed: interrupt allocation (5)` |
| gicv3_its alias fixes MSI controller attach | **OBSERVED** by A/B (boot 1 vs boot 2, tables are the only difference): `gicv3_its0 at gicthree0`, warnings 108 -> 0 |
| list.c:88 panic is ena's failure path | **SOURCE** (not stack-traced): `list_destroy()` ASSERT in `ena_cleanup_device_init()` on a non-empty cmd-ctx list. Not fixed here (one variable per boot) |
| nvme goes down because MSI-X is not delivered | **HYPOTHESIS**: nvme's failure messages are `!` (log only) and do not reach the console. See "Boot 2" |
| what resets the box | **UNKNOWN**: the panic parks the CPU, and the reset follows minutes later |

## The change (one source file)

`usr/src/uts/aarch64/io/pciex/pcierc/pci_boot.c`, diff `pci_boot-keep-fw-windows.diff`. The x86 logic was ported
into three places. Fixing only `add_ppb_props` would not have been enough, because the later passes reassign
everything from the root `_CRS`:

* `add_ppb_props()`: when the bridge has Memory Access Enable set and a non-zero base, its MEM/PMEM window goes
  into the secondary bus's avail list and the parent's used list, and is not rewritten. Only windows that firmware
  left unconfigured are disabled. I/O windows keep the old behaviour (disabled): Graviton has no I/O space, and
  the trace shows the I/O disable on 00:02.0 (#143-#144) did not stop the console.
* `fix_ppb_res()`: skip MEM/PMEM reprogramming of a bridge unless its parent was reprogrammed, memory decode is
  off, or both windows are disabled (the x86 `reprogram_mem` test). If the bridge is reprogrammed, mark
  `mem_reprogram`.
* `add_bar_reg_props()`: in CONFIG_INFO, a non-zero firmware memory BAR is moved from avail to used. In
  CONFIG_NEW, a BAR is only reallocated if it is unassigned or its bus was reprogrammed.

Without the second and third changes, `fix_ppb_res` handles secbus 1 (the ENA side) first and takes
0x80000000 from the root window, and the CONFIG_NEW pass re-claims the UART's BAR. Both would move the console
again.

Built on the cross host from `ami-0de86d0e2f52c0fed`: `pcierc` `da139826... -> 50095ddb...`, `unix` unchanged
(`5727f6ba...`, same as the control). The boot_archive was unpacked and its `pcierc`, `ecam` and `unix` shas
compared equal to the build outputs.

### Observer adjustment (ECAM trace)

The ECAM trace (`aa-ecam-trace.py`) is kept. One addition, `aa-ecam-trace-mute.py`: BAR sizing clears MAE on
the device being sized, and when that device is the console UART, trace lines printed in that window go to a UART
that is not decoding. The trace now mutes from a COMMAND write with MAE clear until the next COMMAND write with
MAE set, and then prints `[E~ muted N bdf]`. `ecam` `fcc05dc2... -> c3b33e42...`. The mute lines in the
captures are 7x `300` (03:00.0 ENA), 12x `1500` (15:00.0 UART) and 10x `1600` (16:00.0 NVMe).

## Boot 1: bridge-window fix only

Image: the 10-22 trace recipe (`aa64-assemble-aa64b.sh` = `aa64-assemble-trace.sh` with only the log name
changed). `driver_aliases` is the control's `aa-driver_aliases-nopl011.txt` (sha `7d8becc6...`), so the only
variable against the 10-22 trace boot is `pcierc` plus the trace mute. c6g.metal `i-0424e6cc6d274efe0`,
AMI `ami-04d719d0dbf3114fc`, launched 03:59:52Z. 10 reads with `get-console-output --latest` from 04:02 to
04:30Z, then terminated.

The 64 KB console window holds only the tail of a boot, because the trace is longer than that. So the `#146`
region and the EDK2 banner are not in any capture. The proof that #146 was passed is everything after it: the
trace reaches n=28672, the whole `pci@2,0` subtree is enumerated, and `pcieb20`-`pcieb51` attach under it.
The tail, the same in every capture:

```
pcieb51 is /pcie@c000000000/pci@2,0/pci@0,0/pci@1f,0
nvme0: NVMe spec version 1.0
WARNING: ecam0: could not attach MSI controller          (x7 here, 108 in total)
[AAECAM] n=28672 ms=1371 maxus=454 rec=0 otc=0 last=3:0.0
WARNING: ecam0: could not attach MSI controller
WARNING: ena0: the ena driver only supports MSI-X interrupts
WARNING: ena0: attach sequence failed: interrupt allocation (5)

panic[cpu0]/thread=ffff800138e0ac20: assertion failed: list->list_head.list_next == node, file: ../../../common/list/list.c, line: 88

Warning - stack not written to the dump buffer

skipping system dump - no dump device configured
```

**Negative control:** the 10-22 trace boot (`serial-attach-20261022/consoles/metal2-c5.txt`). It has the same
`unix`, the same tables and the old `pcierc`, and output ends at `[E>146 0:2.0 r=20 s=2 w=1]` in 3/3 cycles.

**Mechanism of the panic, from source.** `list.c:88` is `ASSERT(list->list_head.list_next == node)` in
`list_destroy()`. ena's attach fails at "interrupt allocation" because `map_msi()` cannot attach the ITS
(`armv8/os/ddi_impl.c:1406/1429`: `could not attach MSI controller`). The rollback then runs
`ena_cleanup_device_init()`, which does `list_destroy(&aq->ea_cmd_ctxs_free)` (`ena.c:1269`). That list still
holds the `ENA_ADMINQ_DEPTH` contexts that `ena_create_cmd_ctx()` put on it. This is a real second bug in ena's
failure path, and it is recorded here, not fixed. The ena cleanup should empty the free list (or call
`ena_release_all_cmd_ctx` plus a drain) before `list_destroy`. The stack was not captured, so "it is this
`list_destroy`" is read from source, not observed.

## Boot 2: plus the fixed driver tables

One change from boot 1: `driver_aliases`/`name_to_major` regenerated by the fixed `aa-gen-drivertables.py`
(below). `name_to_major` is byte-identical to the control (`f4313e7a...`). `driver_aliases` (`b2530338...`)
= the control table + 44 lines (`gicv3_its "arm,gic-v3-its"`, `gicv2m "arm,gic-v2m-frame"`, 42 `cpudrv`) and
nothing removed. Verified in the unpacked boot_archive: `its=1 v2m=1 cpudrv=42 pl011=0`, with `pcierc`/`ecam`/`unix`
the same as boot 1. c6g.metal `i-074dae05f3b35e9e1`, AMI `ami-0baefab31b097a946`, launched 04:54:25Z. 9 reads with
`get-console-output --latest` from 04:57 to 05:25Z, then terminated. There were 3 boot cycles (new cycles at
05:11Z and 05:25Z), each with the tail below (3/3).

```
gicv3_its0 at gicthree0
...
pcieb51 is /pcie@c000000000/pci@2,0/pci@0,0/pci@1f,0
nvme0: NVMe spec version 1.0
[AAECAM] n=33792 ms=1503 maxus=465 rec=0 otc=0 last=16:0.0
/pcie@c000000000/pci@2,0/pci@0,0/pci@1,0/pciex1d0f,0@0,0 (nvme0) down
NOTICE: Cannot read the pool label from '/pseudo/lofi@1:b'
NOTICE: spa_import_rootpool: error 5
Cannot mount root on /pseudo/lofi@1:b fstype zfs

panic[cpu0]/thread=fffffffffe168000: vfs_mountroot: cannot mount root

Warning - stack not written to the dump buffer

ereport.io.service.lost ena=5f566f6bdf00001 detector=[ version=0 scheme="dev"
 devce-path="/pcie@c000000000/pci@20/pci@0,0/pci1,0/pciex1d0f,@0,0" ]   (characters dropped by the console)
```

`could not attach MSI controller`: 0 (boot 1: 108). There is no `ena0` line, because root mount fails first, and
ena would attach later from the real root.

**What is and is not known about nvme0.** `(nvme0) down` is `ddi_report_dev`'s status for a node whose
device is DOWN, and `ereport.io.service.lost` is `ddi_fm_service_impact(DDI_SERVICE_LOST)`, which nvme raises when
it marks the controller dead. Every nvme message on that path (`!command %d/%d timeout`, `!controller not ready`,
`!unable to reset controller`, `!failed to set up initial interrupt`) carries `!`, so it goes to the log, not
the console. In time: the read at 04:57:19Z ends at the version line, and the read at 04:58:30Z has `down`.
Now that the ITS binds, nvme takes MSI-X first (`nvme.c` ~4648) and issues admin commands with
`nvme_admin_cmd_timeout = 15` s. A 15 s timeout followed by an abort timeout and `mark_dead` fits that window.
**Hypothesis: MSI-X through the ITS is set up but not delivered.** It is unverified. The decisive next check,
not run, is one boot with nvme forced to FIXED interrupts (`/kernel/drv/nvme.conf`), or with the `!` messages
routed to the console (e.g. `-B` `msgbuf` to console, or dropping the `!` on the nvme attach path). If the disk
then comes up, the ITS/MSI-X path is the next blocker.

## Reset

Both boots still reset on the ~12-13 min period seen before. Boot 1: c1-c4 unchanged from 04:02 to 04:13Z,
c5 (04:17Z) a new boot with different dropped characters and the same panic, and the same again at c9 (04:28Z).
Boot 2: new cycles first seen at 04:58Z, 05:11:35Z (after 05:06:35) and 05:25:42Z (after 05:21:32), i.e. a
~13-14 min period. So the box panics within about 2 min of power-on, stays parked at the
panic, and something resets it about 10 min later. The panic parks the CPU in the debug path with
no dump device, so a platform watchdog firing on a halted CPU fits. That is still inferred, not observed: the
GTDT watchdog entries were never decoded.

## aa-gen-drivertables.py (task 4)

`aa-gen-drivertables.diff`:
* also reads `pkg/manifests/*.aarch64.inc`, because the `.p5m` files pull the per-arch driver actions in through
  `<include system-kernel-platform.$(ARCH).inc>`, and the aarch64 platform drivers are declared only there;
* **does not** bind `ns16550a` to `arm,pl011`. The `.inc` declares that alias, and the script's `metal_aliases`
  hard-coded it. Both are now dropped, with a comment, because the console handover to `ns16550a` is not fixed
  (the 10-22 A/B: that attach ends console output).

Negative control: the unmodified script, run on the build host, regenerates the committed
`aa-driver_aliases-pkgstyle.txt` byte-identical. The fixed script's output differs from that by +44 lines and -1
(`ns16550a "arm,pl011"`), and `name_to_major` is unchanged.

## Artifacts

floki `~/solnix-bank/ami/aarch64-6cd2521c1e-bridgewin-20261023/` (`sha256sum -c SHA256SUMS` all OK, `RAW.sha256`
for the raw images):

| what | file | sha256 |
|---|---|---|
| boot 1 image | `aa64-bridgewin-20261023.img.gz` | gz `dd71f07d...`, raw `3984709a...` (= EBS dd readback) |
| boot 2 image | `aa64-bridgewin-its-20261023.img.gz` | gz `284df02e...`, raw `177d704f...` (= EBS dd readback) |
| gate diff (pci_boot + ecam trace/mute) | `aa64b-gate.diff`, `pci_boot-keep-fw-windows.diff`, `ecam-trace+mute.diff` | in SHA256SUMS |
| scripts | `aa-ecam-trace-mute.py`, `bh-build-b.sh`, `aa64-assemble-aa64b{,2}.sh`, `bh-verify-ba{,2}.sh`, `poll.sh` | |
| driver-table generator + output | `aa-gen-drivertables.{py,diff}`, `aa-{driver_aliases,name_to_major}-gen-fixed.txt` | `b2530338...`, `f4313e7a...` |
| consoles | `metal1-console-i-0424e6cc6d274efe0-c{1,5,10}.*`, `metal2-console-i-074dae05f3b35e9e1-c{2,6,9}.*` (3 cycles each) | |
| logs | `build-aa64b.log`, `assemble-aa64b.log`, `assemble-aa64b2.log` | |
| AMIs (in-account only) | `ami-04d719d0dbf3114fc`/`snap-016a875c58c8e13f3`, `ami-0baefab31b097a946`/`snap-06294ddf72b491bba` | |

Instances: build host `i-09e78b714d940d9f6` (c5.4xlarge from `ami-0de86d0e2f52c0fed`), metal `i-0424e6cc6d274efe0`
and `i-074dae05f3b35e9e1`. All terminated, with volumes DeleteOnTermination. No SG or keypair was created.
