# Phase A6-phandle — ACPI-path synth-FDT completeness: prom_emul → device enum → root-on-ZFS → SMF

Build node i-0d24c0ec7a9a0e109 (18.216.236.141, m5.4xlarge) left **running**.
No git commit (orchestrator commits). No SG/0.0.0.0/0 changes.

## TL;DR

| Item | Result |
|---|---|
| **prom_emul :63 blocker** | `get_phandle()` `VERIFY3P(prop != NULL)` — prom_emul uses the FDT `phandle` property as the *node identity* (root/child/sibling/parent all call `get_phandle`), so **every** node the tree walk touches must carry a unique `phandle`. Synth only had GIC=1, ITS=2. **Fixed:** emit a unique `phandle` (counter from 3) on root/chosen/psci/cpus/each-cpu/memory/timer/serial/each-pcie. |
| **Next blocker (ecam ranges)** | `panic: ecam0: No ranges property` in `pcierc:find_resource`. The pcie node lacked `ranges`. **Fixed:** emit the standard PCI `ranges` (`<child(3) parent(2) size(2)>`) with the fixed QEMU-virt IO/MEM32/MEM64 windows (MCFG only gives the ECAM config base; the outbound windows live in the DSDT `_CRS` which the synth does not parse). |
| **Next blocker (root device)** | `Cannot mount root on /pseudo/lofi@1:b fstype zfs` / `spa_import_rootpool: error 5`. No virtio-blk disk bound → ZFS fell back to the ramdisk lofi. Cause: the synth FDT had **no `virtio,mmio` nodes**, so `viommionex` never probed the boot disk. **Fixed:** emit the 32 fixed QEMU-virt virtio-mmio slots (`0xa000000 + n*0x200`, SPI `16+n` edge-rising, `dma-coherent`) — the same layout QEMU's own DTB carries. Bumped `SYNTH_FDT_MAX` 8192 → 16384 to fit. |
| **ACPI path result** | **BOOTS.** prom_emul walks the whole tree → full device enumeration (`gicthree0`, `gicv3_its0`, `arm_gtmr0`, `ns16550a1`, `ecam0`/pcie, virtio-mmio) → `blkdev0 is /virtio_mmio@a003c00/vioblk@.../blkdev@0,0 online` → **`root on armpool/ROOT/braich fstype zfs`** → SMF milestones (filesystem/root, filesystem/usr, network/*, identity, devices) → **`Hostname: braich`**. **Zero panics.** |
| **FDT path** | **No regression.** Same phandle-fixed unix on `run-gicv3-usernet.sh`: `gicthree0`/`arm_gtmr0`/`blkdev0 online` → `root on armpool/ROOT/braich fstype zfs` → SMF milestones → `Hostname: braich`. Zero panics. (FDT uses QEMU's real DTB, which already has phandles, so the synth changes cannot affect it — confirmed empirically.) |
| **Exact next item** | After multi-user SMF start, `svc:/system/boot-archive` detects the on-disk boot_archive is out of sync with its computed cache and self-heals (`WARNING: Reboot required. The system has updated the cache of files (boot archive)`), triggering a reboot. This is **benign SMF boot-archive auto-update**, a test-harness artifact of hand-staging the archive — **not** a kernel/synth-FDT defect. Left as-is (no code fix needed). |

## The three synth-FDT fixes (all in `dboot_synth_fdt.c`, persisted)

1. **phandle on every node** — `get_phandle()` (`prom_emul_fdt.c:63`) VERIFYs a `phandle`
   prop and returns it as the `pnode_t`; `promif_rootnode/childnode/nextnode/get_parent`
   all route through it, and `promif_walk_dev` visits the whole tree. Added a
   `synth_alloc_phandle()` counter (starts at `SYNTH_PHANDLE_FIRST = 3`, reserving
   1/2 for GIC/ITS which are referenced as interrupt-/msi-parent) and a
   `synth_emit_phandle()` helper called on every node. Only `phandle` is needed
   (prom_emul does not read `linux,phandle`).

2. **pcie `ranges`** — `find_resource()`/`populate_bus_res()` in `pcierc/pci_boot.c`
   panic (`No ranges property`) without it. Emitted 3 windows in `pci_ranges_t`
   layout (`child_high` = `0x01/02/03000000` for IO/MEM32/MEM64):
   `IO child 0 / parent 0x3eff0000 / size 0x10000`,
   `MEM32 0x10000000 / 0x10000000 / 0x2eff0000`,
   `MEM64 0x80_00000000 / 0x80_00000000 / 0x80_00000000` — the fixed QEMU-virt map,
   verified against QEMU's own `dumpdtb`.

3. **virtio-mmio nodes** — 32 `virtio,mmio` nodes at `0xa000000 + n*0x200`, size
   `0x200`, `interrupts = <GIC_SPI (16+n) EDGE_RISING>`, `dma-coherent`. `viommionex`
   binds `virtio,mmio` and probes each slot; the boot disk lands on
   `virtio_mmio@a003c00`. Matches QEMU's generated DTB exactly (which is why the FDT
   path already found the disk).

### NOTE ceilings marked in-source

Both the pcie `ranges` and the virtio-mmio block are **QEMU-virt-fixed** address maps,
not derived from ACPI. On real SBBR/Graviton the PCIe outbound windows come from the
root-bridge DSDT `_CRS`, and there is no virtio-mmio at all (boot disk is NVMe/virtio
over PCIe). Both are tagged with `NOTE:` comments naming the ceiling and the
upgrade path (parse DSDT `_CRS` in `dboot_conf_acpi`; gate/drop the virtio-mmio block
behind a QEMU-virt detection when moving to hardware).

## Validation (console evidence, QEMU)

- **ACPI (`run-acpi.sh`, EDK2 UEFI presenting ACPI):**
  `dboot: synthesised FDT from ACPI (2 cpus, gicd=0x8000000 gicr=0x80a0000 +its, 1 pcie rc)`
  → `gicthree0`/`gicv3_its0`/`arm_gtmr0`/`ns16550a1`/`ecam0`/virtio-mmio bind →
  `blkdev0 is /virtio_mmio@a003c00/vioblk@a003c00/blkdev@0,0 online` →
  `root on armpool/ROOT/braich fstype zfs` → SMF milestones → `Hostname: braich`.
  Log: node `/tmp/a6-acpi-console3.log` (0 panics).
- **FDT (`run-gicv3-usernet.sh`, QEMU DTB):** identical device attach + root-on-zfs +
  SMF + `Hostname: braich`. Log: node `/tmp/a6-fdt-console.log` (0 panics).

## Build/stage recipe (node)

```
# build + install unix (dboot embeds the synth blob via dboot_image)
bash /tmp/mkunix.sh          # bldenv -T aarch64 ../env/aarch64 'cd uts/armv8/unix && dmake -j8'
bash /tmp/instunix.sh        # dmake install -> proto/root_aarch64/.../unix
# stage into disk (ZFS + odc boot_archive with fresh unix at both platform paths)
lofiadm -la illumos-disk.img; zpool import -d /dev/dsk -R /a armpool -f
mount -F zfs armpool/ROOT/braich /a/root
bash /tmp/stage-phandle.sh   # cp unix -> /platform/{armv8,ARMH,sbbr}/...; rebuild odc archive + sha1 hash
umount /a/root; zpool export armpool; lofiadm -d /dev/dsk/c2t1d0p0
sh run-acpi.sh   # (ACPI)   or   run-usernet.sh w/ QEMU_SCRIPT_MACHINE=virt,gic-version=3 (FDT)
```
Note: `run-gicv3-usernet.sh` `exec "${SHELL}"` fails under a non-interactive ssh
(empty `$SHELL`) — invoke `run-usernet.sh` directly with `QEMU_SCRIPT_MACHINE` set.

## Files

- **Fix:** `usr/src/uts/armv8/dboot/dboot_synth_fdt.c` (node) — persisted to
  `src/aarch64-arm64-gate-patches/dboot_synth_fdt.c` (full file) and
  `src/aarch64-arm64-gate-patches/a6-phandle-synth-fdt.patch` (unified diff).
- Progress log: node `/tmp/a6-phandle-progress.txt`; console logs
  `/tmp/a6-acpi-console3.log` (ACPI success), `/tmp/a6-fdt-console.log` (FDT no-regress).
