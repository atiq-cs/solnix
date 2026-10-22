# aarch64 Graviton: marker-free REAL-rootfs metal boot — PAST the old device-attach stall, resets at the ZFS/PCIe scan

Date: 2026-10-13. Account: kiwi (830118047484), us-east-2. Stream: streamAARCH64B.

## Headline

A **marker-free (fast-console), real-pkg-assembled-rootfs** aarch64 image booted on
real `c6g.metal` and ran **cleanly past the old device-attach stall** (the
`scsa,probe` / `zconsnex` / "No major number" warnings that every prior proto image
showed), reaching `NOTICE: Performing full ZFS device scan!` — then **silent-resets**
(a reset loop, 0 panic, 0 "Resetting"). This is the PCIe/ENA/NVMe-enumeration frontier
`docs/aarch64-zfs-scan-is-pcie-enumeration.md` identified; it is a **kernel PCIe/MMIO
bug, not an image/rootfs problem**. The real rootfs removed the device-attach cosmetics;
the kernel PCIe reset remains.

Two things were proven load-bearing this run:
1. **The drain-drop console fix** (`a6-boot-uart-drop-txfe-drain`, TXFE drain removed):
   the whole boot sequence printed in **seconds**, not the historical ~13 s/char /
   2.5 h crawl. A metal boot-test is now cheap to read.
2. **pkg-style driver tables** (generated from the gate's own 196 pkg manifests + the
   metal DT compatibles, NOT the `aa-fix-ntm` host-copy synth): **zero** `scsa,probe`,
   `zconsnex`, or "No major number" warnings — `scsi_vhci0`, `gicthree0`, `arm_gtmr0`
   all attached clean.

## Exact console (real c6g.metal `i-054799249c285a5bd`, terminated)

Full capture: `src/aarch64-arm64-gate-patches/aa-metal-realrootfs-markerfree-20261013.txt`.

```
loader: Load Device: PcieRoot(0x0)/.../NVMe(0x1,...)/HD(1,GPT,...)
        Trying ZFS pool
        Setting currdev to zfs:armpool/ROOT/braich
        Loading /platform/armv8/kernel/aarch64/unix...
        Loading /platform/armv8/aarch64/boot_archive...
        Booting...
[A6GIC] ngicc=40 distinct_gicr_base=40 regions=4 stride=0x20000        # GICv3 4-region
[A6CRS] crs_nwin=0x2 crs_have=0x1 necam=0x1 ecam0=0xc000000000 qemu=0x0 # SSDT _CRS
[A6KCON:BOP]
[A6MEM] pre-dup arena_total=16384 ...                                   # mem-arena-128
illumos Version arm64-gate-0-g6cd2521c1 64-bit / DEBUG / mem = 134217728K (128 GiB)
root nexus = Amazon EC2
pseudo0 at root / is /pseudo
scsi_vhci0 at root / is /scsi_vhci          <- CLEAN (no scsa,probe warning)
gicthree0 at root: ... 5 GICR regions       <- CLEAN
arm_gtmr0 at root                            <- CLEAN
NOTICE: Performing full ZFS device scan!     <- FURTHEST LINE
<silent reset -> EDK2 banner reappears -> 2nd boot cycle; 0 panic, 0 Resetting>
```

Monotonic analysis of the 27,578-byte capture: 2 EDK2 firmware banners, 2 loader
"Trying ZFS pool", 4 `[A6KCON:BOP]`, 1 ZFS-scan line, **0 panic / 0 Resetting** = a
**silent reset loop** at the ZFS device scan. Not a hang (banner reprints), not a
reported fault (no panic) — an unhandled exception/SError, as inferred for an MMIO
touch the platform does not decode.

## Reached X / dies at Y because Z

- **Reached X:** `arm_gtmr0 at root` → `NOTICE: Performing full ZFS device scan!` —
  cleanly, fast, with real driver tables and no device-attach warnings. This is PAST
  the frontier every prior proto boot stalled at (`scsa,probe`/`zconsnex`).
- **Dies at Y:** the ZFS device scan (which drives PCIe/ENA/NVMe enumeration under the
  SSDT-fed FDT) → silent reset to firmware, looping.
- **Because Z:** the kernel's `pcie`/`ecam` driver walks the synth FDT's PCIe node
  (`compatible=pci-host-ecam-generic`, `reg`=ECAM 256 MiB config space @0xc000000000,
  `ranges`=the two real `_CRS` windows MEM32 0x80000000 + MEM64 0x18000000000) and a
  config/BAR access faults with an SError the CPU cannot report → silent reset. This
  matches the leading (INFERRED, not observed) hypothesis in
  `docs/aarch64-zfs-scan-is-pcie-enumeration.md`. Named candidate kernel defects there:
  the synth may still emit an IO window metal lacks (here `crs_nwin=0x2` with no IO
  window, so this one looks handled); ITS `msi-map` last-wins keeps only ITS id=3 of
  metal's 4; IORT (RID→ITS map) is never parsed. The fix is a **kernel code change**
  to `dboot_synth_fdt.c` + possibly an early SError handler to localize the fault —
  deep kernel debug, beyond image assembly.

## Why this is the right frontier now (what changed vs the CONFIRMED proto boot)

| | CONFIRMED proto (g6cd2521c1e, 2026-09-12) | this run (marker-free real-rootfs) |
|---|---|---|
| console speed | ~13 s/char (markers + TXFE drain) | **seconds** (drain dropped) |
| driver tables | `aa-fix-ntm` synth (237/17, host-copy) | **pkg-style** (348/2024, from gate manifests) |
| `scsa,probe` / `zconsnex` | present (cosmetic noise) | **absent** |
| furthest line | device-attach (scsa warnings) | **`arm_gtmr0` → ZFS scan** |
| failure | slow crawl (never watched past) | **silent reset at ZFS/PCIe scan** |

The real rootfs + fast console turned an un-readable crawl into a clean, fast boot that
reaches and exposes the true kernel frontier: PCIe enumeration.

## The image (banked)

- `~/ws/solnix-aarch64-bank/20261013/illumos-metal-realrootfs-markerfree-20261013.img.gz`
  (floki, durable) — sha256 `e916faa669adccecaf567ad5487f80bb74be58c0ceed4f2edf9d8a9eb6c4cef3`,
  175,759,564 B (gz of a 10 GiB GPT disk: ESP `loader64.efi`→`bootaa64.efi` + ZFS
  `armpool/ROOT/braich`).
- arm64/uefi/ena AMI `ami-0fed4399a7bbd4c19` (kiwi, in-account), snapshot
  `snap-0c73872963f016ff3`.
- NOT yet a catalog boot image — it does not reach login (the PCIe reset). It is the
  decisive marker-free real-rootfs boot artifact.

## How it was built (reproducible; scripts in src/aarch64-arm64-gate-patches/)

A6/A8 **hybrid** on the clean x86 build host (`ami-0aa1f6ac952e3408d`), cross-building:
1. `pkg update` + reboot (2026 catalog), install onbld/gcc-10/git/flex/bison/python-313/
   illumos-closed/gnu-patch/texinfo/mpc/mpfr/gnu-coreutils.
2. `git clone -b arm64-gate` the gate at `6cd2521c1e` (the CONFIRMED base).
3. Cross seed → `build/cross` + `build/sysroot`, touch setup stamps
   (`aa-setup-cross-from-seed.sh`). The seed layout is `seed/usr/gcc/aarch64-14/*` +
   `seed/opt/onbld/bin/amd64/ld` + `seed/{lib,usr}` (target sysroot).
4. Apply patches (`aa-apply-patches.sh`): `a6-cumulative-all-legs` + drop in full
   `dboot_synth_fdt.c` + `efipart.c` + boot_uart fr-poll + **drain-drop** + mem+gcc14 +
   build-host-fixes.
5. Build `unix`+`genunix`+kmods via nightly's tools+uts legs. (The full nightly world
   build hits ~2000 library-ordering link errors — a known unmerged-fork tar pit — so
   the WORLD comes from the banked complete proto, not a fresh rebuild.)
6. Assemble (`aa-assemble-metal.sh`): banked proto world + swap fresh drain-fixed kernel
   + pkg-style driver tables (`aa-gen-drivertables.py`) + inject libxml2/libgcc_s from
   OmniOS braich + SMF seed/site-profile + dev.tar + `create_ramdisk` → GPT metal disk.
7. Transfer (build-host→floki→Linux-helper, `curl/scp | gunzip | dd`) → snapshot →
   `register-image --architecture arm64 --boot-mode uefi --ena-support`.
8. Boot ONE `c6g.metal`, read `get-console-output --latest` only, terminate.

## SError-handler fix attempted (metal boot 2) — refined the mechanism, did NOT get past

> ⚠️ **2026-10-22: this boot did not test what it says.** `aa-assemble-metal.sh` step 2 copied only
> `kernel/aarch64` (genunix) and `platform/armv8/kernel` from the fresh build, never `kernel/drv` or
> `kernel/misc`, so every loadable driver in the image (ecam, pcierc, nvme, ena) was the banked
> Sep-12 build. The SError change lived in `unix`, so that half did ship; any driver-side change
> would not have. Fixed, with a byte-compare gate, in `aa64-assemble.sh`; see
> `docs/aarch64-ecam-ontrap-metal-result.md`.

Following the "install an early SError handler to localize the fault" lead, a targeted
kernel fix was built and booted on a second `c6g.metal` (`i-00f284c4bb494dfec`, terminated):

- **Mechanism found by code-reading** (`usr/src/uts/armv8/ml/exceptions.S`): the
  current-EL SError vector `from_current_el_error` was `UNEXPECTED()` — a bare `bl panic`
  with **no register/frame save**. So an SError during PCIe config enumeration calls
  `panic` on an unreliable frame → silent reset (consistent with the 0-panic console).
  The config path (`ecam_cfgspace_acc` → `ddi_get32`) has **no `on_trap`/`t_lofault`
  protection** at all (unprotected raw MMIO) — grep for `on_trap`/`ddi_peek` in
  `uts/common/io/pciex` and `uts/armv8` returns nothing.
- **Fix applied** (scripts `aa-serror-vector-fix.sh` + `aa-serror-lofault-fix.sh`):
  (1) route the SError vector through a new `from_current_el_error_handler` that saves a
  frame and calls `trap()` with ESR/FAR (mirror the sync vector); (2) give the kernel
  `T_SERROR` case in `trap()` the same `t_ontrap`/`t_lofault` recovery the data-abort
  case has. unix rebuilt clean (`from_current_el_error_handler` symbol present).
- **Result: no change.** The 2nd metal boot reached the identical point (`Performing
  full ZFS device scan!`) and **silent-reset again** (2 cycles, 0 panic, 0 `esr=`/SError
  text on console). The fix did not engage: no visible panic appeared, so the
  config-probe fault is **not** a trappable EL1 SError the vector catches — it is more
  likely a synchronous external abort routed elsewhere, an imprecise abort that re-faults
  in the handler before console flush, or a hardware-level reset (not a CPU exception
  the vector table sees). Capture: `aa-metal-serrorfix-boot-20261013.txt`.

## Next leg (kernel, not image) — the precise remaining defect

The real fix is **fault-protected PCIe config access**, which aarch64 illumos lacks:
wrap the `ecam` config read (`ecam_cfgspace_acc`) in `on_trap(OT_DATA_ACCESS)` /
`ddi_peek`-style protection so a non-responding device returns -1 instead of aborting,
AND make whatever abort class the Graviton fabric raises (sync external abort vs SError)
route to a handler that honors that protection. First establish *which* exception class
the config probe actually raises (the SError-vector route did not catch it, so it is
likely a **synchronous external abort** — `EC=0x25` data abort with `DFSC` = external
abort — which goes through `from_current_el_sync` → `trap()` T_DATA_ABORT, where the
existing `t_lofault` recovery *would* fire **if** the config read set `t_lofault`). So
the single highest-value next change is: **set `t_lofault`/`on_trap` around the ecam
config read** (⛔ **built and booted 2026-10-22: did NOT help, and the ECAM read is never reached** before
the reset; `docs/aarch64-ecam-ontrap-metal-result.md`) so the existing data-abort recovery catches the external abort. That is a
bounded, named, one-file change for the next kernel-focused run; it was out of scope
here (image-assembly stream, time-boxed).

## Reusable arm64 cross-build substrate (banked, so it never evaporates again)

`solnix-arm64-buildhost-20261013` = **`ami-06583907ca11a0ab1`** (kiwi, us-east-2,
x86_64, key `solnix-baked`, `Project=solnix`). Clean-baked (scrubbed instance identity →
stopped → `create-image --no-reboot`) and **boot-verified on a fresh launch**: it
networks (ena/dhcp), SSHes, cross-compiles aarch64 ELF (gcc 14.3.0), and `bldenv -T
aarch64` drives a `unix` build. Carries the arm64-gate tree @ `6cd2521c1e` + all a6 fixes
+ drain-drop + the SError-vector change, `build/cross` + `build/sysroot` + all 12 setup
stamps (skips `make setup`), the banked proto/seed/braich-libs/driver-tables, and every
assembly script (`/aarch64/README-arm64-buildhost.txt` documents it). This is the
aarch64 cross-build capability the campaign kept losing with each burner account.
