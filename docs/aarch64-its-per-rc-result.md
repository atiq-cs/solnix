# aa64g: one ITS per root complex (instance-store NVMe on c6gd.metal), the diagnostics out, bash

Track aa64g, 2026-10-27. Accounts: kiwi (437803535746) in us-west-2 and us-east-1, plus solnix-ami (788352824872).
Brief: /scratch/solnix/briefs/aa64g.md, then a goal update: publish a Graviton AMI so dixa can be recreated
(/scratch/solnix/aa64g/dixa-recreate.md).

## The ITS fix

**Mechanism** (dixa's messages.0, decoded):
- The IORT (`test/iort-dixa.bin`, 608 B, checksum valid) has two PCI root complexes:
  - segment 0 -> SMMUv3 @0x90 -> ITS 0;
  - segment 2 -> SMMUv3 @0x140 -> ITS 2.
- dboot emitted one `its@` node, segment 0's, and every `pcie@` msi-map pointed at it. So nvme1/nvme2 on `/pcie@e000000000`
  (segment 2) were programmed with ITS 0's doorbell, and their MSI-X was lost.

**The kernel needed no change.** `map_msi()` resolves each `pcie@`'s msi-map phandle to its own ITS dip, and `gicv3_its` keeps
per-instance soft state. Only dboot had to change.

**The change** (`patches/p1-dboot-rc-its.py` + `p1-rc-its.c`, on aa64c's segment-0 rule):
- MCFG `PciSegment` is kept per ECAM window.
- `synth_rc_its(g, seg)` walks the IORT for any segment.
- The default `its@` stays segment 0's, with phandle 2, the same name and the same reg.
- One more `its@` node is emitted per other ITS that an MCFG segment uses. It gets its phandle from the node counter, so a
  segment-0-only platform gets the same phandles as before.
- Each `pcie@` msi-map names its own segment's ITS.

**Unit test** (`test/t_rcits.c`, `test/run.sh`, `test/run.log`). It is built from the walk and `synth_rc_its` extracted verbatim
from the patched file, with ASan+UBSan.

| case | new code | OLDCODE (every RC gets segment 0's ITS, the old rule) |
|---|---|---|
| dixa segment 0 -> ITS 0 | PASS | PASS |
| **dixa segment 2 -> ITS 2** | PASS | **FAIL (ITS 0)** |
| dixa segment 1 absent -> none | PASS | FAIL |
| c6g.metal segment 0 -> ITS 0 | PASS | PASS |
| c6g.metal segment 2 absent | PASS | FAIL |
| bad signature | PASS | PASS |

The verdict is PASS: the new code passes 6/6 and the negative control fails 3/6. The test was re-run on the final file, after p7.

**On metal:**
- c6gd.metal, all 6 launches (k1 g1 g2 sa1 sa2 ue1):
  - `gicv3_its0` has doorbell 0xbc00050040 and `gicv3_its1` has 0xbe00050040;
  - nvme1/nvme2 have 64 LPIs each, with 0 `missed interrupt`;
  - `format` lists both 1.73 TB instance stores;
  - zpool create, write, scrub (0 errors) and destroy work on c2t1d0 and c3t1d0.
- c6g.metal (c6, ue1g): one ITS, its@bc00040000 with doorbell 0xbc00050040, the same as aa64c/aa64f. Segment 0 is unchanged.

## Diagnostics: removed and kept

The kernel is gate HEAD plus fixes. Every edited file is first reset to a clean base (`patches/bh-aa64g-k.sh`). The 8 rebuilt
modules contain 0 diagnostic strings (grepped for AA64E/AA64F/AAECAM/[IORT]/MAPTI/A6*/[E>/solnix,acpi; the one hit is the root
compatible `solnix,acpi-synth`).

**Removed:**
- b1-04 (DAIF samples), b1-05 ([AA64F-MAP]/[AA64F-LLQ]), and b1-06's per-event [AA64F-KSERR] print.
- All aa64e observers:
  - the machdep UART writer, the heartbeat, the stage marks and the GTDT reader;
  - the `|D|`/`|W|` echoes;
  - the main.c S1..S14 marks and the mp_startup `>N <N` marks;
  - the ena attach-step prints and state pointers, and ena_dma's log-to-console;
  - the dboot `solnix,acpi-gtdt` property;
  - aa64e-b2's UNEXPECTED register dump and trap ring.
- The aa64c observers: nvme's `!` removal and admin-intr line, gicv3_its's MAPTI lines and [IORT] hexdump, and the dboot
  `solnix,acpi-iort` property.
- The aa64b [AAECAM] / [E>n] ECAM trace, and the `aa_ot_*` globals in trap.c (p4, p5).
- The A6 prints: fakebop's [A6KCON:*] and [A6MEM] (p6), and dboot's raw-UART [A6GIC]/[A6CRS] lines with their helpers (p7).
- The aa64e/aa64f image extras: the diag SMF service and the manifest-import console tee (`patches/aa64g-assemble.sh`).

**Kept, as fixes:**
- b1-01..03 (DAIF.A) and b2-01 (rootnex Normal-NC).
- The bridge windows (pci_boot.c), and ITS-from-IORT, now per root complex.
- The ECAM on_trap recovery.
- The kernel SError trap cases. die() already panics with `BAD TRAP: type=2f (#SERROR SError interrupt) ... esr=`, which is the
  part of b1-06 the orchestrator kept, so no code was needed for it.
- The memlist arena at 128 pages, the boot_uart FR poll, efipart chunked reads, kobj alignment, and dboot's ACPI synth.

**The console path after consconfig is fixed properly** (p2, p3), with no observer kept:
- `sysp_putchar()` falls back to the boot (SPCR) PL011 when no polled putchar exists. The UART goes through a kernel device
  mapping made in `prom_io_use_kernel()`.
- `wcuwsrv()` with no tem sends the text to `console_puts()`, where it used to free it.
- It has no tags, counters or heartbeat, and a real console driver (tem, asy) still wins.
- **Measured:** SMF lines, `WARNING: Reboot required` and `<host> console login:` now reach `get-console-output` on every metal
  boot. On aa64e they were `|W|` drops.

## bash

- `pkgs/illumos/aarch64/src.nix` gains readline 8.2 (on the store ncurses) and bash 5.2.37 (`--with-installed-readline`).
  bash is in systemToplevel, and `default.nix` exports both (`diffs/aa64g-solnix.diff`, 64 lines).
- Two fixes, both measured:
  - readline's shobj-conf picked SunPro's `-K pic`, because `$CC` is named `cc64`. The fix gives CC a `gcc` name.
  - stage0 nix's fetchurl needed `NIX_SSL_CERT_FILE` (dev box only).
- The image (`aa64g-img.sh`) sets root's login shell to `/run/current-system/sw/bin/bash` only if sw/bin has bash. gburd's would
  be set too, but the image has no gburd user. `/etc/shells` is absent on illumos and was left so.
- toolrun gets 13/13 on every launch: the 11 tools, plus interactive bash with readline emacs mode on, plus bash as root's shell.

## The image and AMIs

- **Base image (kernel only):** raw 3b1b1013. **Image 1:** raw c9719058, which adds the toplevel
  `rd3hf7wj..-solnix-system-aarch64` (drv gch7zki2, 33 paths) on top of base.
- The drv hashes equal aa64nix's: nix vbkdpcia, gate x21pzrsc. Only readline, bash and the toplevel were built.
- **solnix-ami:** `ami-04aac43c39f0f1c51` in us-west-2, snapshot `snap-0aeb615e60e6ed050`. Copies:
  - us-east-1 `ami-033513d87a591a75a` / `snap-08090e05b4aa1ed95`;
  - us-east-2 `ami-0b6b59a4b1a37ccb0` / `snap-077a938c090bd76fc`;
  - eu-west-1 `ami-089c89a4d4911304f` / `snap-010f432b3d3e2228d`;
  - eu-central-1 `ami-041232c4cf05b5fe9` / `snap-0ef5ebf815ec423f2`.
- All are private, and the kiwi launch shares were removed from us-west-2 and us-east-1.

**Boot evidence** (all fresh, hands-off launches; checks in `evidence/`). The four goal checks are CHECK1, 2, 4 and the registry
fetch; every launch that reached login passed them, with REGISTRY_FETCH_OK 9ba643493e75.

| launch | AMI | type | login | goal checks | tools+bash | NVMe |
|---|---|---|---|---|---|---|
| k1 | base | c6gd | cycle 2 | (no nix) | - | PASS |
| g1, g2 | kiwi image 1 | c6gd | cycle 2 | PASS | 13/13 | PASS |
| sa1 | solnix-ami | c6gd | **cycle 3** | PASS | 13/13 | PASS |
| sa2 | solnix-ami | c6gd | cycle 2 | PASS | 13/13 | PASS |
| c6 | solnix-ami | c6g | cycle 2 | PASS | 13/13 | 1 ITS, as before |
| ue1g | us-east-1 copy | c6g | cycle 2 | PASS | 13/13 | - |
| ue1 | us-east-1 copy | c6gd | **cycle 3** | PASS | 13/13 | PASS |

## New blocker, recorded and not fixed: ena admin timeout on c6gd

- **Seen:** on sa1 and ue1, cycle 2, right after nvme1/nvme2 attach:
  `ena0: timed out waiting for admin response` / `failed to create Tx CQ 17` (or `Rx CQ 18`) / `attach sequence failed`.
- **Consequence:** a `list.c:88` panic, which is the known ena cleanup bug. The box reset about 12 minutes later, and cycle 3
  passed everything.
- **Rate:**
  - c6gd.metal: 2 of 6 launches;
  - c6g.metal: 0 of 3 here, and 0 of 7 in aa64nix.
- **Cause:** unknown, and the mechanism was not observed. It is not caused by the ITS change: ena is on segment 0's ITS, as
  before.

## Other findings

- **The bank's aa64nix export is truncated:**
  - The file is `aa64-system3-closure.nixexport.gz` (sha 32d85ae8) in `aarch64-6cd2521c1e-nix-20261026/`.
  - It has 81 entries and no terminator, so `nix-store --import` stops with "unexpected end-of-file". `gzip -t` and a sha
    readback cannot catch this.
  - `patches/nixexport-check.py` detects it.
  - Replaced by `aa64g-system-closure.nixexport.gz`: 114 paths, EXPORT_OK.
- **us-east-1 capacity:** c6gd.metal returned `InsufficientInstanceCapacity` in every us-east-1 AZ for about 22 min, and a launch
  then got through in 1b.
- **A pre-existing warning:** `Out of range register specification from device node <pciexclass,010802>` appears 14x per c6gd
  boot. dixa's old kernel shows it 4x. It is harmless here and was not investigated.

## Where things are

- Diffs, not committed:
  - `/scratch/solnix/aa64g/diffs/aa64g-gate-tracked.diff` (gate vs HEAD);
  - `diffs/aa64g-dboot.diff`;
  - `diffs/aa64g-solnix.diff` (repo, vs ca78653);
  - the patchers in `/scratch/solnix/aa64g/patches/`.
- Bank (`SHA256SUMS` 129/129 OK, raw images read back):
  - `~/solnix-bank/ami/aarch64-6cd2521c1e-aa64g-20261027/`;
  - `~/solnix-bank/toolchain/arm64-buildhost-aa64g-20261027/` (incremental 7feca310, equal to the host's).
