# Design: illumos RISC-V (riscv64) port — gap analysis & bring-up plan (step 1)

Status: **exploratory bring-up, step 1 of a multi-year effort.** This is the
deliverable for the RISC-V track (Phase 5, `docs/roadmap.md`;
`.kiro/steering/architectures.md` "Very high risk — multi-year kernel work").

**Honest headline: illumos has NO RISC-V port.** No `uts/riscv`, no riscv
kernel, no CTF/mapfiles for riscv, no `riscv64-*-solaris` toolchain target
in-gate or in any known fork. "Bootstrap RISC-V via QEMU" is NOT a packaging
task — it means *writing* a port: HAL/locore/trap/interrupt/MMU/clock, a
toolchain target, drivers, CTF, a boot path. QEMU only *tests* that port once it
exists. This document does the three things that ARE achievable now:

1. **Prove the test substrate** (DONE): a riscv64 cross toolchain + a bare-metal
   machine-mode "hello" booting under `qemu-system-riscv64 -machine virt`. This
   is the harness the future port will use. See §2.
2. **Gap analysis + port plan** (this doc): using the aarch64 port
   (`richlowe/arm64-gate` + illumos **IPD 24**) as the closest model, enumerate
   concretely what an illumos riscv64 port requires, component by component, with
   effort estimates and how richlowe/arm64-gate did each. See §3–§5.
3. **A `riscv64-solaris` lib.systems draft** (DONE, marked not-buildable): mirror
   the `aarch64-solaris` double the aarch64 agent added to the fork. See §6.

Verified on 2026-07-27. Substrate proof ran locally (dev box: qemu 10.1.5,
riscv64-none-elf gcc 14.3.0 / binutils 2.44 from the pinned nixpkgs
`pkgsCross.riscv64-embedded`). Cross toolchain on the ouch build host: see §2.3.

---

## 1. Why this is a "write the port" track, not a "boot it in QEMU" track

The distinction that governs the whole track (from
`docs/design-sparc-riscv-qemu.md`):

> QEMU-on-EC2 answers "where do we build/boot," not "does an OS exist to boot."

| Arch | illumos port? | QEMU machine | "bootstrap" = |
|------|---------------|--------------|---------------|
| x86_64 | yes (in-gate) | native EC2 | DONE (boots) |
| aarch64 | yes (out-of-tree, active — richlowe) | `virt` (GICv2) | integrate the port |
| SPARCv9 | yes (in-gate, bit-rotting) | `sun4u` | revive + build-triage |
| **RISC-V** | **NO port at all** | `virt` (best-in-class) | **write the port first**, then QEMU-test |

QEMU's `qemu-system-riscv64 -machine virt` is arguably the *best* emulation
target of any of the four ISAs. That is not the gap. The gap is the entire OS
port. The aarch64 port (the closest precedent) took **years** and a formal
illumos IPD; a from-scratch riscv64 port with no existing HAL to crib from is
comparable or larger in kernel scope, though RISC-V's cleaner privileged spec
and QEMU virt's simplicity make the *bring-up* phase easier than ARM's.

**Do not represent riscv64 as bootstrappable "just via QEMU."** The correct
step-1 outcome is: a proven substrate + this plan. That is what this delivers.

---

## 2. The proven substrate (DONE)

### 2.1 Bare-metal machine-mode "hello" on qemu virt

Sources (`src/riscv/`):
- `hello.S` — machine-mode entry. Parks all harts but hart 0, writes a string to
  the virt NS16550A UART THR at **0x10000000**, then powers off via the SiFive
  **test finisher** at **0x100000** (`0x5555` = PASS/poweroff). rv64imac + zicsr
  (CSR reads for `mhartid`).
- `hello.ld` — links `_start` at the virt RAM base **0x80000000** (where harts
  begin executing under `-bios none -kernel`).
- `build-hello.sh` — `as -march=rv64imac_zicsr -mabi=lp64` → `ld -T hello.ld` →
  boot under `qemu-system-riscv64 -machine virt -nographic -bios none -kernel`.

### 2.2 Result — SUCCESS

```
$ qemu-system-riscv64 -machine virt -nographic -bios none -kernel hello.elf
hello from machine mode: riscv64 qemu virt substrate OK
```
Full log: `artifacts/riscv/hello-qemu-boot.log`. ELF + disassembly confirm the
UART store to `0x10000000` and the finisher store to `0x100000`. This proves,
end to end, that **cross-toolchain → riscv64 ELF → qemu virt → UART output**
works — the exact chain the future port's earliest `unix` boot will exercise.

`-bios none` means "no OpenSBI": our ELF is the first thing the harts run, in
**machine mode**. A real illumos port would instead run in **supervisor mode**
under OpenSBI (M-mode firmware), reaching the UART via SBI console calls or a
direct MMIO driver — but the substrate (toolchain + qemu virt + UART) is
identical, which is the point of this smoke test.

### 2.3 Cross toolchains

Two toolchains, two purposes:

- **`riscv64-none-elf` (bare-metal, substrate)** — used for the hello above.
  Source: nixpkgs `pkgsCross.riscv64-embedded` (gcc 14.3.0 / binutils 2.44),
  already pinned, cached from cache.nixos.org. This is sufficient for all
  bare-metal bring-up smoke tests and early kernel work (no libc needed).
- **`riscv64-unknown-elf` on the ouch build host** — a native illumos-hosted
  riscv64 cross gcc/binutils, built detached via `scripts/oi-job.sh` on an ouch
  OI builder (the hosts already carry gcc 10/13/14 + onbld). riscv64 gcc/binutils
  cross is well-supported upstream (`--target=riscv64-unknown-elf`), so this is a
  standard `configure && make` cross build, not research. This is the substrate
  that will *later* be re-targeted to `riscv64-unknown-solaris2.11` once
  `uts/riscv` + a sysroot exist (the hard part — §3).

  Status: **BUILT + VERIFIED** at `/export/riscv-toolchain` on ouch-w8-13
  (990 MB, 26 riscv64 tools): `riscv64-unknown-elf-gcc (GCC) 14.3.0`, GNU
  binutils 2.44, `-dumpmachine`=`riscv64-unknown-elf`, compiles C to `ELF 64-bit
  LSB relocatable RISC-V`; its `xgcc` built libgcc's riscv `save-restore.S` /
  `muldi3.S` / `div.S` (target backend confirmed). Built detached via
  `scripts/oi-job.sh` (final job DONE:0). Two illumos-specific breaks were fixed
  and baked into `scripts/riscv-toolchain-build.sh`: (a) gcc 14.2.0's in-tree
  gettext fails on illumos (gnulib `getlocalename_l` conflict) → use 14.3.0 +
  strip in-tree gettext; (b) Solaris `/usr/bin/tar` mangles the gcc tarball's GNU
  pax headers → extract via python3 `tarfile`.
  NOTE: the assigned host `ouch-w8-13` first came up network-impaired (ENA/DHCP:
  `configure_v4_lease: cannot set IP address on ena0`); a `reboot-instances`
  cleared it (Inst=ok) — the orchestrator never blocked on the dead SSH, it did
  the offline deliverables (§2.2, §3–§6) while the host recovered. Not terminated.

**Neither toolchain is a `riscv64-solaris` toolchain.** That target does not
exist and cannot exist until `uts/riscv` provides headers, crt objects, a libc,
and the Solaris link-editor learns riscv64 relocations (§3.2, §3.8).

---

## 3. Gap analysis: what an illumos riscv64 port requires

Modeled on the aarch64 port. For each component: what it is, what richlowe's
arm64-gate did, the riscv64 delta, and an effort estimate. Estimates are
engineer-months of focused kernel work by someone fluent in illumos internals;
they are order-of-magnitude, not a bid.

### 3.1 `uts/riscv` — the machine-dependent kernel tree — **the bulk**

illumos kernel is split `uts/common` (MI) + `uts/<arch>` (MD) +
`uts/<platform>`. aarch64 added `uts/aarch64` + `uts/armv8` (platform) +
`uts/rpi4`, `uts/qvirt`, etc. riscv64 needs an equivalent `uts/riscv` +
`uts/riscv64` platform dir(s) for `virt`, and later K1/K3.

| Sub-component | What it is | aarch64 precedent | riscv64 delta | Effort |
|---|---|---|---|---|
| **locore / startup** | first supervisor-mode instructions, hart bring-up, stack/BSS, jump to `mlsetup`/`main` | `uts/aarch64/ml/locore.s`, EL1 setup, DTB pointer in x0 | S-mode entry from OpenSBI, `a0`=hartid `a1`=DTB; secondary harts via SBI HSM | 2–3 mo |
| **MMU / HAT** | virtual memory: page tables, TLB, `hat_*` layer | aarch64 `hat_aarch64`, 4-level 48-bit VA | **Sv39/Sv48/Sv57** page tables, `sfence.vma`, ASIDs; write a new `hat_riscv`. Cleaner than ARM (no TTBR0/1 split nuance) but still a from-scratch HAT | 3–5 mo |
| **trap / exception** | trap vector, save/restore, syscall path, fault dispatch | `uts/aarch64` vbar + exception vectors | `stvec` trap vector, `scause`/`sepc`/`stval` decode, ecall syscall path, page-fault → `trap()` | 2–3 mo |
| **interrupts** | interrupt controller driver + `psm`-equivalent | GICv2 driver (`uts/aarch64`), GICv3 = "No" in IPD 24 | **PLIC** (external) + **CLINT/ACLINT** (timer/IPI) for virt; **AIA (APLIC/IMSIC)** for modern SoCs like K1 | 2–3 mo |
| **clock / timer** | system clock, `gethrtime`, cyclics | ARM generic timer (`cntpct`) | `time` CSR + `rdtime`, SBI timer (`sbi_set_timer`) or CLINT `mtimecmp` | 1 mo |
| **CPU / hart mgmt** | `cpu_t` setup, SMP start, idle, `mach_cpu_*` | PSCI-based secondary start | **SBI HSM** (`sbi_hart_start`) for secondary harts; hart↔cpu mapping | 1–2 mo |
| **context switch / thread** | `swtch`, thread/lwp register save area, `setjmp`/resume | aarch64 `swtch.s`, register save | riscv64 GPR + `sstatus`/`sepc` save area; FPU (`fcsr`, f-regs) lazy save; **RVV vector state** (K1 has RVV1.0 — big, see §5.1) | 2–3 mo |
| **atomic / lock primitives** | `atomic.h`, membar, `mutex`/`rwlock` backends | ARM LSE/LL-SC atomics, `dmb`/`dsb` | RISC-V **A extension** (`amo*`, `lr/sc`), `fence` variants for membar | 1 mo |
| **byteorder / MD headers** | `<sys/machparam.h>`, `<sys/mach*.h>`, reg.h, frame.h, privregs.h | full `uts/aarch64/sys/*` | full `uts/riscv/sys/*` set from scratch | 1–2 mo |
| **DDI/DKI glue, bus_ops, rootnex** | device tree → devinfo, DMA, register mapping | aarch64 devicetree (EBBR/IR), simple-bus rootnex | riscv64 devicetree (same FDT format — mostly reusable), rootnex/DMA for virt | 1–2 mo |

**Subtotal (kernel MD core, virt-only): ~16–27 engineer-months.** This is the
irreducible heart of the port and has no shortcut.

### 3.2 Toolchain target `riscv64-unknown-solaris2.11` — **medium**

aarch64 uses **`aarch64-unknown-solaris2.11`**, GCC 14.3.0 from `richlowe/gcc`
(branch `il-14_3_0-arm64`), GNU `as` + the **Solaris link-editor** (not GNU ld):
`--without-gnu-ld --with-ld=$CROSS/opt/onbld/bin/amd64/ld`, LP64-only,
no-multilib.

riscv64 delta:
- gcc/binutils already support `riscv64-unknown-elf` and `riscv64-*-linux`
  upstream; a **`*-solaris2.11`** riscv64 target does NOT exist. Add a
  `config.gcc` / `config.sub` OS stanza (crib the aarch64-solaris config from
  `richlowe/gcc`) — mechanical but real.
- The **Solaris `ld` (sgs)** must grow riscv64 relocation support
  (`R_RISCV_*`): `usr/src/cmd/sgs` in the (future) gate. GNU ld already does
  riscv64; the *Solaris* link-editor does not. This is a genuine chunk of work
  and gates everything that links (crt, libc, unix).
- ABI: LP64D (double-float) is the RISC-V server ABI; K1 supports it. TLS model,
  `char` signedness, `__riscv`/`__riscv_xlen==64` predefined macros.
- **Effort: 2–4 mo** (gcc/binutils config stanzas ≈ weeks; Solaris-ld riscv64
  relocs ≈ 1–2 mo; iteration against the first libc/crt builds).

### 3.3 CTF for riscv64 — **medium**

illumos CTF (Compact C Type Format) is generated by `ctfconvert`/`ctfmerge` over
DWARF and embedded in kernel + user objects; `mdb`/`dtrace` depend on it. It is
largely arch-independent (operates on DWARF), but:
- `ctf` tooling must handle riscv64 ELF machine type (`EM_RISCV`) and the
  register/DWARF numbering for stack unwinding.
- `mdb`/`kmdb` need a riscv64 disassembler + `mdb_isautil`/proc backend
  (aarch64 shipped *without* mdb/kmdb/dtrace initially — IPD 24 notes them
  missing). Plan the same: **defer mdb/kmdb/dtrace**, build a cross `gdb` as the
  stand-in (arm64-gate does exactly this).
- **Effort: CTF-embed working ≈ 1 mo; a real riscv64 mdb/kmdb/dtrace ≈ 4–6 mo,
  DEFERRED** past first boot (matches aarch64).

### 3.4 libc + crt + rtld — **medium**

`libc.so.1`, `crt1/crti/crtn.o`, `values-*.o`, and `ld.so.1` (rtld) all have MD
pieces: `libc/port` is MI, but `libc/riscv` needs setjmp/longjmp, `_start`,
`makecontext`/`swapcontext`, TLS (`__tls_get_addr`), atomic/membar, syscall trap
stubs, and the `ld.so.1` MD relocation engine (riscv64 dynamic relocs, PLT/GOT
layout, `DT_RISCV_*`).
- aarch64: `libc/aarch64`, `ld.so.1` aarch64 reloc engine, `/lib/64 -> .` compat.
- riscv64: same shape, new `libc/riscv` + rtld riscv64 relocs. LP64D, `/lib/64
  -> .` (no `amd64/` ISA subdir, exactly like aarch64 — IPD 24 userland search
  paths `/lib /usr/lib`).
- **Effort: 3–4 mo.**

### 3.5 Boot path — **low–medium (virt), medium–high (K1/K3)**

**QEMU virt:** the standard RISC-V boot chain is
**OpenSBI (M-mode firmware) → U-Boot (S-mode, SPL optional) → EFI → kernel**.
- aarch64 does: `u-boot → (ATF) → illumos EFI loader (loader64.efi →
  EFI/BOOT/bootaa64.efi) → unix`.
- riscv64 virt: **OpenSBI** (qemu ships a default `-bios opensbi`) provides the
  SBI runtime the kernel calls for console/timer/IPI/HSM. U-Boot v2025.x has
  solid riscv64 `qemu-riscv64_smode` support and EFI boot. The illumos loader
  would need a **riscv64 EFI stub** (`bootriscv64.efi`) — new, but the loader is
  largely MI + a small MD entry (crib aarch64's `bootaa64.efi`).
- **Effort (virt): 1–2 mo** for OpenSBI+U-Boot+EFI-stub → `unix` handoff, once
  `unix` exists.

**SpaceMiT K1/K3:** real hardware boot is materially harder — vendor U-Boot fork,
board DTBs, SoC-specific clock/PMIC/DDR init in the boot firmware, and the K1's
non-upstreamed bits. See §5.

### 3.6 Devicetree / platform description — **low**

RISC-V virt and the SpaceMiT boards are **devicetree** (FDT), the *same* format
aarch64 already consumes (EBBR/IR, not ACPI). illumos's aarch64 FDT ingest
(`uts` fdt parsing) is largely reusable for riscv64. No ACPI needed for virt/K1.
- **Effort: 0.5–1 mo** (mostly reuse; riscv64-specific `cpus`/`interrupt-parent`
  bindings for PLIC/CLINT/AIA).

### 3.7 Drivers for the substrate — **low (virt)**

virt exposes: NS16550A UART (already have a driver — `uts/common` 16550), virtio
(blk/net/rng/console — illumos has virtio drivers), goldfish RTC, PLIC/CLINT.
- **Effort (virt): ~1 mo** to wire existing MI drivers to the riscv64
  interrupt/DMA glue. K1/K3 drivers are the expensive part (§5).

### 3.8 Mapfiles / build glue / nightly `-T riscv` — **low–medium**

- Link-editor **mapfiles** (versioning, `SUNW_*` symbol versions) are mostly MI;
  a few MD mapfiles (libc, ld.so.1) need riscv64 entries.
- `usr/src/Makefile*`, `uts/Makefile.riscv`, `env` file for
  `nightly -T riscv`, `tools` (bldenv, install, sgs) riscv64 awareness.
- A build **harness** analogous to `richlowe/arm64-gate` (a `riscv-gate`):
  `make download/setup/illumos`, cross gcc + binutils + Solaris-ld + a sysroot.
  The sysroot chicken-and-egg (aarch64 solved via an OmniOS `braich` prebuilt
  aarch64 userland) has **no riscv64 equivalent** — there is no illumos riscv64
  userland to pkgrecv. First libc must be built against its own just-built
  headers (a proper 2-stage bootstrap), which is more painful than aarch64 had it.
- **Effort: 1–2 mo** for build glue; the missing-sysroot bootstrap adds
  iteration risk.

### 3.9 Summary table

| Component | Effort (eng-months) | Defer past first boot? |
|---|---|---|
| `uts/riscv` MD kernel core (§3.1) | 16–27 | no (this IS the port) |
| Toolchain `riscv64-*-solaris` (§3.2) | 2–4 | no |
| libc + crt + rtld (§3.4) | 3–4 | no |
| Boot path — virt (§3.5) | 1–2 | no |
| Devicetree (§3.6) | 0.5–1 | no |
| Drivers — virt (§3.7) | ~1 | no |
| Mapfiles / build glue / harness (§3.8) | 1–2 | no |
| CTF embed (§3.3) | ~1 | no |
| **First QEMU-virt multi-user boot** | **~26–42** | — |
| mdb / kmdb / dtrace (§3.3) | 4–6 | **yes** |
| GICv3-equivalent AIA/IMSIC polish, SMMU/IOMMU | 3–5 | yes |
| K1/K3 real hardware (§5) | 6–12+ | yes |

**Bottom line: ~2–3.5 engineer-years to a rough QEMU-virt multi-user boot**
(single expert, matching the aarch64 timeline), plus more for hardware + tooling.
This is a Phase-5 research/upstream track, exactly as the roadmap says.

---

## 4. How richlowe/arm64-gate structured a new illumos arch (the model)

From `docs/design-aarch64-bootstrap.md` + the arm64-gate harness. A riscv64
effort should mirror this shape one-for-one:

1. **A separate build harness repo** (`richlowe/arm64-gate`) with a `Makefile`
   driving `download / setup / illumos` — NOT edits scattered in the gate. The
   riscv64 analog: a `riscv-gate` harness.
2. **A gate branch** (`richlowe/illumos-gate@arm64-gate`) that merges
   illumos/master regularly and carries `uts/aarch64`, `libc/aarch64`, sgs
   aarch64 relocs, `env/aarch64`. riscv64: a `riscv-gate` branch carrying
   `uts/riscv`, `libc/riscv`, sgs riscv relocs, `env/riscv`.
3. **Forked toolchain repos**: `richlowe/gcc` (`il-14_3_0-arm64`) +
   `richlowe/binutils-gdb` with the `*-solaris2.11` target. riscv64: same, adding
   the riscv64-solaris config stanzas.
4. **A prebuilt sysroot to bootstrap userland linking** — aarch64 pulled OmniOS
   `braich`. **riscv64 has none** → 2-stage self-bootstrap (§3.8).
5. **A formal IPD** — aarch64 is **IPD 24** (Soome/Lowe/van der Westhuizen). A
   riscv64 port should open an IPD early to fix the ABI (LP64D, `/lib/64 -> .`,
   `uname -p riscv64` / `uname -m` value, triple) before code hardens.
6. **A QEMU test harness** — arm64-gate ships `qemu-setup/testsuite.exp`
   (expect(1) driver, os-tests/libc-tests/... across CPU models). riscv64: the
   §2 substrate is the seed of this; extend to run real suites once userland boots.
7. **Cross-build on an amd64 illumos host** (dmake/CTF/Solaris-ld are illumos
   binaries; only the *target* is riscv64). Same as aarch64 — the ouch OI
   builders are the right host; a Linux host cannot run this build.
8. **Nix side is small and mostly kernel-keyed** — a `riscv64-solaris` double +
   `riscv64-illumos` example + riscv64 proto slices; almost everything in
   `lib/systems` is `isSunOS`-keyed and already correct (§6). The Nix work is
   Tier-1a "re-express the gate outputs as slices," not the hard part.

---

## 5. SpaceMiT K1 / K3 and the host "rv" (eventual hardware)

QEMU virt is the *bring-up* target; real silicon is the *truth* (as UltraSPARC
is for SPARC and RPi4 is for aarch64). The maintainer has a real RISC-V host
named **"rv"** for later hardware validation — it slots in exactly where RPi4
sits in the aarch64 plan: after QEMU-virt multi-user boots, port to real
hardware.

### 5.1 SpaceMiT K1 (8-core RVA22 + RVV1.0)

- **CPU:** 8× SpaceMiT X60 cores, **RVA22** profile + the **RVV 1.0** vector
  extension (256-bit). Boards: BananaPi BPI-F3, MuseBook, Milk-V Jupiter, etc.
- **Port impact:**
  - **RVV1.0 vector state** is the single biggest K1-specific kernel item:
    `vlenb`, `vtype`, 32 vector regs — lazy save/restore in context switch, signal
    frame layout, `ucontext` extension, and a decision on kernel-mode vector use.
    This is a large, error-prone chunk (§3.1 context-switch row) — DEFER RVV
    beyond first boot; boot with vector *disabled* (`sstatus.VS=Off`), add later.
  - **AIA / interrupts:** K1 uses a PLIC-like controller; modern RISC-V trends to
    **APLIC + IMSIC (AIA)**. Confirm K1's actual controller from its DT; virt's
    PLIC driver may or may not transfer.
  - **SoC glue:** clock tree (CCU), PMIC, DDR init, eMMC/SD, USB, Ethernet,
    display — all vendor-specific. Most live in U-Boot/OpenSBI (boot firmware);
    the kernel needs at least storage + console + net drivers. **6–12 eng-months**
    of driver work for a usable K1, on top of the MI port.
  - **Upstream status:** K1 Linux support is largely out-of-tree/vendor (SpaceMiT
    BSP); expect to read their U-Boot/OpenSBI forks, not mainline, for board init.

### 5.2 SpaceMiT K3

- Successor/higher-tier SoC (more cores, higher clocks; details vendor-published
  and moving). Same porting story as K1 at the ISA level (RVA2x + RVV), with a
  distinct SoC glue set (clock/PMIC/DDR/peripherals). Treat as "second board":
  once K1 boots, K3 is incremental board-bring-up (new DTB + driver deltas), not
  a new architecture.

### 5.3 How "rv" fits

- **rv = the real-hardware validation host**, the RISC-V analog of "boot on RPi4."
  Sequence: (1) QEMU virt multi-user boot (the §3 milestone), (2) port to
  whatever SoC "rv" is (likely a K1-class board), (3) real-hardware smoke test on
  rv. Only after a real board boots to multi-user SMF may any doc say "riscv64
  supported" (steering rule). Until then: **planned, not supported.**
- Practically, rv can also serve as a **native riscv64 build accelerator** later
  (like a Graviton box for aarch64 builds), but the cross-build-on-amd64-illumos
  model (§4.7) does not require it.

---

## 6. lib.systems `riscv64-solaris` draft (DONE — NOT yet buildable)

Mirrors the `aarch64-solaris` double the aarch64 agent added to the fork
(`solnix-pkgs/patches/0001-lib-systems-x86_64-solaris.patch`). Draft patch:
**`solnix-pkgs/patches/0004-lib-systems-riscv64-solaris-DRAFT.patch`** —
clearly marked not-buildable (there is no riscv64 toolchain target, no proto, no
`pkgs.illumos.riscv64.*`; wiring the double only lets `lib.systems` *name* the
platform).

Verified facts behind the draft (evaluated against the patched fork nixpkgs,
rev 7f81d69):
- `riscv64` cpu **already exists** upstream (`lib/systems/parse.nix`:
  `riscv64 = { bits=64; significantByte=littleEndian; family="riscv"; }`).
- `riscv64-unknown-solaris2.11` **already elaborates cleanly today** on the fork,
  BEFORE any riscv-specific change, because the fork's `parse.nix`
  `hasPrefix "solaris"` clause and the `isSunOS`-keyed `elaborate` gaps
  (libc=illumos-libc, linker=solaris, uname=SunOS) are arch-independent:

  ```
  config  = riscv64-unknown-solaris2.11
  cpu     = riscv64      isSunOS = true    kernel = solaris
  libc    = illumos-libc linker  = solaris uname  = SunOS
  double  = riscv64-solaris  (derived by parse.doubleFromSystem)
  ```
- The ONLY missing wiring: `"riscv64-solaris"` is **not** in the hardcoded
  `doubles.nix` `all` list (x86_64 + aarch64 are). The draft adds it, plus a
  `riscv64-illumos = { config = "riscv64-unknown-solaris2.11"; }` example.

**Emphatically not buildable:** `pkgsCross.riscv64-solaris.stdenv` cannot build
anything — there is no `riscv64-unknown-solaris2.11` gcc/binutils target, no
libc/crt/sysroot, no `pkgs.illumos.riscv64.*` proto slices. The double is a
*name reservation* so the plumbing is ready the day a real port produces a proto
(exactly the "designed multi-arch from day one" intent in
`.kiro/steering/architectures.md`).

---

## 7. Honest assessment

- **Delivered (step 1):** a proven riscv64 test substrate (cross toolchain +
  qemu-virt bare-metal hello, `artifacts/riscv/`), this concrete gap analysis +
  port plan, and a not-buildable `riscv64-solaris` lib.systems draft.
- **NOT delivered, NOT claimed:** any booting illumos on riscv64. There is no
  port. Nothing in this track boots an OS, and no doc/commit should say
  "riscv64 supported" until a real board boots to multi-user SMF (steering rule).
- **Effort to a rough QEMU-virt multi-user boot:** ~2–3.5 engineer-years for a
  single expert, matching the aarch64 precedent — dominated by `uts/riscv`
  (§3.1), the toolchain target + Solaris-ld relocs (§3.2), and libc/rtld (§3.4).
- **Realistic path:** open an illumos IPD, stand up a `riscv-gate` harness
  mirroring `richlowe/arm64-gate`, cross-build on the ouch amd64 illumos hosts,
  QEMU virt first, then a K1-class board (host "rv"). Champion/contribute
  upstream; this is community-scale work, not a solnix packaging task.

The good news, identical to the aarch64 finding: the substrate is settled (cross
on amd64 illumos → qemu virt, proven in §2), the Nix side is a small
kernel-keyed diff already validated (§6), and QEMU virt is the best emulation
target of the four ISAs. The entire risk is concentrated in one place — writing
the kernel port — which is exactly where it should be, and is honestly a
multi-year effort.
