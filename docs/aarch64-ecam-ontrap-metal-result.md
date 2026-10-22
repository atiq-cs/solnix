# aarch64 Graviton: the ECAM `on_trap` fix does not stop the reset loop, and the ECAM read is never reached

Date: 2026-10-22. Account: kiwi (505435643998), us-east-2. Stream: streamAA64.

## Headline

`aa-ecam-ontrap-fix.sh` (committed e9be6e5, never booted until now) was built into `unix` plus the
`ecam` driver, along with a diagnostic. Then it was booted on a real `c6g.metal`. **The silent reset loop
at `NOTICE: Performing full ZFS device scan!` is unchanged.** The diagnostic shows the reason: in two
full reset cycles, **`ecam_cfgspace_acc()` never ran**. It prints a line on its first config access,
and that line never appeared.

The previous mechanism was "an unprotected ECAM config read raises an EC 0x25 data abort that
`on_trap` would recover". That is **refuted as the cause of the reset**: the reset happens before
any PCIe config access. The fix stays in the tree as correct hardening. It is not the fix for this
bug.

| claim | status |
|---|---|
| ECAM config read aborts, `on_trap` recovers it | **REFUTED**: 0 `[AAECAM]` lines in 2 cycles; the read never happens |
| `aa-ecam-test_ontrap.c` "ALL CHECKS PASS" (e9be6e5) | **was never true**: the test was undefined behaviour (hung at -O2, failed at -O0); fixed |
| The 2026-10-13 metal images tested fresh drivers | **FALSE**: `aa-assemble-metal.sh` shipped the banked Sep-12 drivers (see "Instrument bug") |
| Reset period | ~12-13 min per cycle (scan line ~00:59Z, next banner by 01:13Z) |

## Console evidence (c6g.metal `i-06729f50676ec9979`, AMI `ami-0860577830045539a`)

Full capture: `src/aarch64-arm64-gate-patches/aa-metal-ecamfix-boot-20261022.txt`. Read only with
`get-console-output --latest`, four polls over 14 min, then terminated. From the scan line to the
end of the capture:

```
arm_gtmr0 at root
NOTICE: Performing full ZFS device scan!
Tianocore/EDK2 firmware version RELEASE 4.19.9          <- reset, no panic, no message
Press ESCAPE for boot options ....WARNING: acpiuart: no compatible MMIO UARTs
... loader ... Booting...
[A6GIC] ngicc=40 ... [A6CRS] crs_nwin=0x2 ... ecam0=0xc000000000 ...
illumos Version arm64-gate-0-g6cd2521c 64-bit / DEBUG enabled / mem = 134217728K
root nexus = Amazon EC2 / pseudo0 / scsi_vhci0 / gicthree0 at root ... / arm_gtmr0 at root
NOTICE: Performing full ZFS device scan!                <- end of buffer, cycle 2
```

Counts over the 28,489-byte capture: EDK2 banners **2**, scan lines **2**, `[AAECAM]` **0**,
`panic`/`esr=` **0**. No ESR or ELR ever reaches the console, so none can be quoted.

## The instrument, and why its silence is a measurement

`src/aarch64-arm64-gate-patches/aa-ecam-diag.py` sits on top of the fix:

* `trap.c`: both `on_trap(OT_DATA_ACCESS)` recovery branches record `ec`/`esr`/`far` and a count.
* `ecam.c`: `ecam_cfgspace_acc` is wrapped. It prints `[AAECAM] first cfg access b:d.f reg=` on
  the first call, details for the first 4 recoveries, and count/elapsed/max-latency every 1024
  accesses.

The image really carried it. This was checked after the boot, on the build host:

* the image's `kernel/drv/aarch64/ecam` has the 3 `[AAECAM]` format strings;
* the **boot_archive** (what the kernel loads before root) contains `ecam`, byte-identical to the
  image copy and with the strings. `unix` is identical too;
* the assemble gate `stale kmods: 0` byte-compared every fresh kernel module against the image.

`cmn_err` output does reach this console at this stage: the `NOTICE: Performing full ZFS device
scan!` line is itself a `cmn_err` call, and the `xxx0 at root` lines before it print. So the silence
means `ecam_cfgspace_acc` was never entered. The residual caveat is a console takeover killing
output between the NOTICE and the first config access. That would also have to hide every
`xxx0 at root` line for the drivers in between, and none appeared.

## Instrument bug found on the way: earlier metal images shipped stale drivers

The first boot of this run (`i-072c293abac81f2f9`, image raw sha `6c2eef91...`) also reset-looped
with 0 `[AAECAM]`. The image turned out to carry **no** `[AAECAM]` string at all.
`aa-assemble-metal.sh` step 2 copies the fresh `unix`, the fresh `kernel/aarch64` (genunix) and
`platform/armv8/kernel`, but **not** `kernel/drv` or `kernel/misc`. Every loadable driver
(ecam, pcierc, nvme, ena) was the banked Sep-12 build. So that boot was only a baseline repro.
The 2026-10-13 SError-fix boot had the same flaw for drivers (its change was in `unix`, so it did
ship).

Fixed in `src/aarch64-arm64-gate-patches/aa64-assemble.sh`. It copies the whole fresh `kernel/`
and `platform/` trees, then refuses to build the image unless every fresh module is byte-identical
in the image root. The negative control was real: the first run of the gate failed on 6
`platform/RaspberryPi,4` and `QEMU,virt` modules that the old recipe never copied.

## `aa-ecam-test_ontrap.c` never passed

As committed, the self-test modelled `on_trap()` as a C function that calls `setjmp` and returns,
so the later `longjmp` targets a dead frame. Measured: at `-O2` it **hung** (killed by timeout),
at `-O0` it **failed** `VAL16(&r) == PCI_EINVAL8`. The kernel's `on_trap` ends in `b setjmp`, a
tail call, so `setjmp` records the caller's frame. The test now uses a macro, which gives the same
semantics. It passes at -O0 and -O2 on floki and the OI host. Negative control `-DBREAK_RECOVERY`
(drop the all-1s assignments) fails with rc 134 on both.

## Next mechanism (named, not measured; no third metal boot was spent)

The reset happens after `cmn_err("Performing full ZFS device scan!")` and before the first ECAM
config access. In that window, `preroot_walk_block_devices()` calls
`ndi_devi_config(ddi_root_node(), ...)`. That attaches the remaining root children in FDT order,
and `dboot_synth_fdt.c` emits them as `its@` (under the GIC), then `serial@`, then `pcie@`. None of
`gicv3_its0`, `ns16550a0`/`ns16550a1` or `ecam0` has ever printed on metal. Two candidates come
before ECAM, ranked by what the source shows:

1. **`ns16550a` attach of the live console UART.** The synth emits the SPCR console as
   `serial@83e00000`, `compatible = "arm,pl011"`, which binds `ns16550a`. Its attach calls
   `ns16550_reset()`, which writes `UARTCR = 0` (UART disabled) and then reprograms CR/LCR_H/IFLS.
   Its polled `ns16550putchar` spins `while (!tx_is_ready)` on FR.TXFF with no cap.
   `boot_uart.c` needed a bounded FR poll and a removed TXFE drain *because Graviton's UART does not
   drive these flags the SBSA way* (`a6-boot-uart-drop-txfe-drain`). The kernel console driver has
   neither fix. A wedge here also kills the console, which would explain both the silence and the
   lack of a panic.
2. **`gicv3_its` attach.** It disables the ITS and spins on `GITS_CTLR.Quiescent`, and the command
   queue spins on `GITS_CREADR`. Both loops are bounded by `drv_usecwait` timeouts. The synth keeps
   only ITS id 3 of the four (`0xbf00040000`, last-wins). Less likely, because its loops are bounded
   and it would `dev_err` before giving up.

A hang alone would not reset the box. The ~12-13 min period with no message suggests a platform
watchdog firing on a wedged CPU or a dead console. That is inferred, not observed.

**Cheapest decisive next step:** one boot with the `serial@` node removed from the synth FDT (or
`ns16550a` stripped from `driver_aliases` for `arm,pl011`). If the box then gets past the scan, or
prints `[AAECAM] first cfg access`, candidate 1 is it. If not, do the same for `its@`. Each step
costs one metal boot and no new instrumentation.

## Build host (step 1 of the brief), banked

* AMI **`ami-0de86d0e2f52c0fed`** (solnix-arm64-buildhost-20261022), fresh launch verified for
  network and a `bldenv -T aarch64` `unix` rebuild. Details and the known userland-link gap are in
  `docs/solnix-buildhost-ami.md`.
* Off-account: floki `~/solnix-bank/toolchain/arm64-buildhost-20261021/`, holding `root-be.zfs.gz`
  `c7b6ad3c...`, `bpool-aarch64.zfs.gz` `14441503...` and `bpool-build.zfs.gz` `667c494d...`,
  all read back and compared, plus MANIFEST and scripts.
* The first bake (`ami-00631734ae92729b4`, deregistered) was wrong: the 10 G image volume rode
  into it. On a fresh launch that volume took bpool's cached `c3t1d0` path, so bpool FAULTED.
  Fixed by baking root + bpool only and adding `site/aa64-bpool` (`zpool import -d /dev/dsk`).
* Disclosed: during that diagnosis two `zpool import` calls were run on the fresh verify host
  over ssh, detached with `nohup` and `timeout`. Both returned at once with "invalid vdev
  configuration". The rule says never; it was broken and is recorded here.

## Images and ids

| what | id / path | sha256 |
|---|---|---|
| metal image (fix + diag, fresh drivers) | floki `~/solnix-bank/ami/aarch64-6cd2521c1e-ecamfix-20261022/aa64-ecamfix2-20261022.img.gz` | gz `3bc593cb...`, raw `80cb6a8a...` |
| its AMI (in-account only) | `ami-0860577830045539a` / `snap-0f496fdaf4efa305d` | |
| build-host AMI | `ami-0de86d0e2f52c0fed` / `snap-0832682ded96f50db`, `snap-074e9735626a895cc` | |

All instances terminated: `i-0c846de60abe3b7b3`, `i-072c293abac81f2f9`, `i-06729f50676ec9979`,
`i-0df933043b88e4229`, `i-06b59fdf5e7debcf7`. Every volume is gone. No keypair or SG was created.
