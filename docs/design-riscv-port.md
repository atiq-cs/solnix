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

## 7. EXECUTION — we write the port (mandate 2026-07-28)

Reframed from "wait for upstream" to "solnix WRITES the first illumos RISC-V port."
Reference stack:
- **RISC-V Privileged Spec + SBI Spec** = the authority (ISA, CSRs, trap model, SBI ABI).
- **NetBSD sys/arch/riscv** = the closest BSD-licensed "how a real kernel wires
  riscv" reference (locore/pmap/trap/sbi/PLIC/CLINT). BSD-2-clause: study the
  design + riscv gotchas (Sv39 layout, CSR encodings, SBI convention), REIMPLEMENT
  in illumos idiom against the spec (don't copy incompatibly). Files to mine:
  riscv/{locore.S,cpu_switch.S,pmap_machdep.c,trap.c,riscv_machdep.c,sbi.c},
  include/{pte,sysreg,frame,pcb}.h, dev PLIC/CLINT.
- **richlowe/arm64-gate + IPD 24** = the "how illumos adds a new arch" precedent
  (uts/<arch> layout, gate/nightly, CTF, mapfiles, the toolchain-target dance).
- **Linux arch/riscv** = secondary cross-check for driver/DT specifics (K1/K3).

Phasing R-P1..R-P7 in .kiro/specs/solnix-riscv/. Each phase has a runnable QEMU
gate. R-P1 (toolchain target + riscv-gate scaffold) starts NOW; R-P2 is the first
`unix` banner in S-mode under OpenSBI on qemu virt (the real "first illumos riscv
kernel instruction" milestone).

---

## R-P2 — first illumos RISC-V kernel banner in S-mode under OpenSBI (DONE, 2026-07-28)

**MILESTONE MET.** The first illumos RISC-V kernel instruction has executed. A
minimal `unix` S-mode payload boots under OpenSBI on
`qemu-system-riscv64 -machine virt` and prints an illumos SunOS banner via the
SBI console. This is the historic "first illumos on RISC-V" gate and the
foundation for R-P3 (trap/MMU/interrupts).

Sources (`src/riscv/uts/`, archived to `solnix.io archive/riscv/` +
`~/ws/solnix-archive/riscv/`):
- `locore.S` — S-mode MD kernel entry (illumos locore idiom, adapted for riscv S-mode).
- `sbi.c` / `sbi.h` — SBI console layer (DBCN + legacy putchar, ecall ABI).
- `main.c` — C kernel entry; prints the banner (freestanding, no libc).
- `riscv.ld` — links `_start` at 0x80200000 (OpenSBI's default S-mode payload addr).
- `build-unix.sh` — freestanding build + timeout-wrapped OpenSBI boot.

### R-P2.1 The S-mode entry contract (established here — reusable for R-P3+)

OpenSBI (M-mode firmware / SBI runtime), after firmware init, jumps the S-mode
payload (our `unix`) per the OpenSBI/SBI boot convention:

| Item | Value | Notes |
|------|-------|-------|
| Privilege | **Supervisor (S-mode)** | M-mode is OpenSBI's; all firmware services via SBI ecall. We never touch mhartid/mstatus. |
| Load / jump addr | **0x80200000** | OpenSBI default S-mode payload address on qemu virt. OpenSBI firmware itself lives at 0x80000000..~0x80080000. Confirmed by OpenSBI's own `Domain0 Next Address: 0x80200000`. |
| `a0` | **boot hartid** | The boot hart's ID (0 on single-hart virt). |
| `a1` | **DTB phys addr** | Flattened devicetree blob. Confirmed: OpenSBI `Next Arg1: 0x87e00000` == the value our banner printed. |
| `satp` | **0 (bare)** | MMU off; VA == PA until the Sv39 HAT (R-P3). |
| `sstatus.SIE` | **clear** | S-mode interrupts off; we also mask `sie` and set a defensive `stvec` in locore. |

C entry prototype: `void main(unsigned long hartid, unsigned long dtb);`
locore preserves a0/a1 across stack+BSS setup (mirrors how uts/aarch64 preserves
the x0 DTB pointer into mlsetup).

### R-P2.2 The SBI console recipe (the illumos-correct S-mode path)

SBI ecall ABI: `a7 = EID`, `a6 = FID`, `a0..a5 = args`, `ecall` traps to M-mode,
returns `a0 = error`, `a1 = value`. Two console paths, DBCN preferred:

1. **DBCN debug console** (EID `0x4442434E`, FID 0 = console_write of
   `(len, addr_lo, addr_hi)`). The modern, non-deprecated path. We probe it via
   **SBI Base** (EID `0x10`, FID 3 = probe_extension); OpenSBI v1.5.1 on qemu
   virt reports it present, so this is the live path (banner shows
   `console path: SBI DBCN (0x4442434E)`).
2. **Legacy putchar** (EID `0x01`, char in a0, no FID) — universal fallback if
   DBCN is absent.

Raw NS16550A MMIO at 0x10000000 (as in `hello.S`) was NOT needed — the SBI path
worked first try, which is the correct S-mode idiom (the kernel asks firmware,
it does not poke the UART directly once under OpenSBI).

### R-P2.3 Result — SUCCESS (verbatim console)

```
SunOS Release 5.11 Version solnix-riscv64 (first illumos on RISC-V)
Copyright (c) solnix -- the first illumos RISC-V port (R-P2 bring-up)

riscv64 S-mode kernel entry reached under OpenSBI:
  boot hart id (a0) : 0
  devicetree  (a1)  : 0x0000000087e00000
  console path      : SBI DBCN (0x4442434E)

[R-P2] first illumos RISC-V kernel instruction executed. Parking boot hart.
[R-P2] next: R-P3 trap vector (stvec) + Sv39 HAT + timer -> mlsetup/main.
```

Full log: `artifacts/riscv-port/unix-qemu-boot.log` (also `solnix.io
archive/riscv/unix-qemu-boot.log`, fetch-verified HTTP 200, sha-matched).
Environment: dev box, qemu 10.1.5, OpenSBI v1.5.1 (qemu's bundled fw_dynamic),
riscv64-none-elf gcc 14.3.0 / binutils 2.44 (nixpkgs pkgsCross.riscv64-embedded).
Every qemu run was `timeout`-wrapped and detached (no wedge).

### R-P2.4 Next: R-P3 (trap + MMU + timer)

The R-P2 `locore.S` already installs a defensive `stvec` (Direct mode, points at
a `trap_park` halt). R-P3 replaces `trap_park` with a real trap vector:
- **Trap frame + dispatch:** save GPRs + `sstatus`/`sepc`/`scause`/`stval` on
  entry, decode `scause` (interrupt vs exception, cause code), call a C
  `trap()`; restore + `sret`. (NetBSD `riscv/locore.S` exception path + illumos
  `trap()` idiom.)
- **Sv39 HAT:** build a 3-level Sv39 page table, identity/kernel map, load
  `satp` (MODE=8 Sv39 + ASID + root PPN), `sfence.vma`. First real `hat_riscv`.
- **Timer:** read the `time` CSR (`rdtime`) for `gethrtime`; arm the next tick
  via SBI timer (EID `0x54494D45` "TIME", FID 0 = set_timer) — the SBI layer in
  `sbi.c` extends here.
- Together these let bring-up progress from the banner to a real
  `mlsetup`/`main` with traps handled and VM online (the R-P3 gate).

---

## R-P3 — trap vector + Sv39 paging + timer → mlsetup/main (DONE, 2026-07-28)

**Milestone R-P3 — DONE, all three gates verified on `qemu-system-riscv64
-machine virt` under OpenSBI (fw v2.0).** The first illumos RISC-V kernel now
takes S-mode traps, runs with **Sv39 virtual memory on**, delivers a timer
interrupt, and reaches an `mlsetup` → `main` split with VM/trap/timer online.
This is the seed of the real illumos boot sequence on riscv64.

New MD sources in `src/riscv/uts/`:

| File | What |
|------|------|
| `riscv_regs.h` | S-mode CSR + Sv39 definitions from the Priv Spec: `sstatus`/`sie`/`sip` bits, `scause` interrupt/exception codes, `satp` (MODE/ASID/PPN) encode macro, the Sv39 PTE bit layout (`V/R/W/X/U/G/A/D`), `PA_TO_PTE`/`PTE_TO_PA`, `VPN(va,level)`. The illumos-idiom analog of NetBSD `include/{sysreg.h,pte.h}`, reimplemented from the spec. |
| `asm_frame.h` | Trap-frame byte offsets shared by `trap.S`/`trap.c` (31 GPRs + `sepc`/`sstatus`/`scause`/`stval`; `TF_SIZE`=288, 16-aligned). |
| `trap.S` | `_trap_entry` (the `stvec` target, Direct mode, 4-aligned): saves x1..x31 + the four trap CSRs into a frame on the current stack, calls C `trap(tf)`, restores (writing back possibly-advanced `sepc`/`sstatus`), `sret`. |
| `trap.c` | `set_trap_vector()` (installs `stvec`), `trap()` dispatcher (decodes `scause`, prints `scause`/`sepc`/`stval`, names the cause; timer IRQ → `timer_intr`; expected probe fault → report+advance+resume; else park), and `trap_selftest()` (deliberate load-page-fault proof). |
| `hat_riscv.c` | `hat_boot_init()`: builds the Sv39 boot page table (real 3-level walk in `map_page`; gigapage leaves in `map_gigapage`), composes `satp`, `csrw satp`+`sfence.vma`, continues executing translated, and proves translation via a non-identity alias readback. First `hat_riscv`. |
| `timer.c` | `timer_prove_one_tick()` arms a one-shot via SBI `set_timer`, enables `STIE`+`SIE`, `wfi`s; `timer_intr()` prints the tick and disarms. Takes exactly one S-mode timer interrupt. |
| `main.c` | Reworked into `mlsetup(hartid,dtb)` (MD bring-up: trap vector → paging → self-test → timer → boot `cpu_t`) → `main()` (SunOS banner + subsystem-online status). |
| `sbi.c`/`sbi.h` | Extended with the SBI **TIME** extension (EID `0x54494D45`, FID 0 = `set_timer`) → `sbi_set_timer()`. |

### R-P3.1 The trap contract (established here — reusable for R-P4+)

On any S-mode trap the hardware writes `scause` (bit 63 = interrupt vs
exception; low bits = cause code), `sepc` (faulting/return PC), `stval` (aux,
e.g. faulting address), saves prior `SIE`/privilege into `sstatus.SPIE`/`SPP`,
clears `sstatus.SIE`, and jumps to `stvec` (Direct mode → `_trap_entry`).
`_trap_entry` builds a 288-byte frame (`asm_frame.h` = `struct regs`), calls
`trap(tf)`, then `sret` returns to `sepc`. **Instruction-length note:** RISC-V
faulting instructions do not auto-advance `sepc`; to resume past a fault the
handler decodes the length from the low opcode bits at `sepc`
(`(insn & 0x3) != 0x3` ⇒ 2-byte compressed, else 4-byte) — a hardcoded `+4`
lands mid-instruction when the faulting op is compressed (this was the one bug
found and fixed during bring-up).

### R-P3.2 The Sv39 boot map (established here — the VM foundation)

`satp` MODE=8 (Sv39), 39-bit VA, 3 levels, PTE `PPN = PA>>12` in bits [53:10].
The boot map installed before turning paging on:

1. **Identity gigapage** VA `0x0` → PA `0x0` (R/W): all qemu-virt low MMIO —
   CLINT `0x02000000`, PLIC `0x0c000000`, UART `0x10000000`.
2. **Identity gigapage** VA `0x80000000` → PA `0x80000000` (R/W/X): OpenSBI +
   the whole kernel image (loads at `0x80200000`). Because PC/sp/data live here
   VA==PA, enabling Sv39 does **not** move the kernel — it just starts
   translating, so execution continues seamlessly.
3. **Non-identity 4 KiB alias** VA `0x40000000` → PA of the kernel's first text
   page (R/X), built through a full 3-level walk. After paging is on the kernel
   reads a known byte through both the identity VA and this alias VA; a **MATCH**
   proves Sv39 really walks the tables (a satp=0 passthrough would fault at the
   alias VA, which has nothing physical behind it).

`sfence.vma` follows the `satp` write to flush stale TLB entries. The live boot
`satp` observed = `0x8000000000080224` (MODE=8, ASID=0, root PT PPN=`0x80224`,
i.e. root table PA `0x80224000` in the kernel BSS pool).

### R-P3.3 The timer contract (established here — seed of the clock)

The `time` CSR is the monotonic counter. One-shot arm = SBI `set_timer(now +
Δ)` (Δ≈100000 ticks ≈10 ms at qemu-virt's 10 MHz CLINT); OpenSBI programs
`mtimecmp` and pends the S-mode timer interrupt (STIP) at the deadline. Enable
`SIE.STIE` + `sstatus.SIE`, `wfi`; the trap fires `IRQ_S_TIMER` (code 5) →
`timer_intr()`. `MIDELEG=0x1666` confirms the S-mode timer interrupt is
delegated to us by OpenSBI. Disarm = `set_timer(~0)` (clears STIP per the SBI
spec) + mask `STIE`, giving exactly one tick. (The `sstc` extension is present
on this hart — direct `stimecmp` writes are an R-P4 optimization.)

### R-P3.4 Result — SUCCESS (verbatim console, the three gates)

```
[mlsetup] trap vector installed (stvec -> _trap_entry, Direct mode)
[hat] PAGING ON: Sv39 live, executing translated. satp=0x8000000000080224
[hat] alias readback: *(ident VA 0x0000000080200000)=0x0000000000000073 *(alias VA 0x0000000040000000)=0x0000000000000073  MATCH -> Sv39 translation verified
[trap] probe (expected): scause=0x000000000000000d (load page fault)
       sepc=0x00000000802005b0 stval=0x0000000040001000 sstatus=0x8000000200006100
[trap] self-test OK: trap taken, decoded, resumed.
[timer] tick #1 at time=0x00000000000ac332  (S-mode timer interrupt delivered)
[timer] one tick observed -> timer + interrupt path OK.
...
[R-P3] subsystem status:
       trap online   : yes
       VM online      : yes (Sv39 paging)
       timer online   : yes (1 tick)
[R-P3] VM online, trap online, timer online. First illumos RISC-V kernel reached main with paging.
```

- **Trap vector: YES.** Deliberate load from unmapped VA `0x40001000` →
  `scause=0xd` (load page fault) decoded with `sepc`/`stval`, resumed cleanly.
- **Sv39 paging on + executing: YES.** `PAGING ON ... satp=0x8000000000080224`
  printed *after* the `satp` write, and the alias-readback **MATCH** proves real
  multi-level translation (not passthrough).
- **Timer tick: YES.** One `IRQ_S_TIMER` delivered and handled (`tick #1`).
- **mlsetup/main: YES.** `locore → mlsetup → main`, banner + all-online status.

Full artifacts: `artifacts/riscv-port/rp3/` (`rp3-boot.log`, `unix`,
`unix.disasm`, `unix.sections`).

### R-P3.5 Next: R-P4

- **SMP:** release secondary harts via SBI **HSM** `sbi_hart_start` (the
  `hart_claimed` park loop in `locore.S` is already the receiving side); per-cpu
  stacks + `cpu_t`.
- **Cyclic clock:** turn the one-shot into a periodic clock (rearm each tick),
  wire `gethrtime` to the `time` CSR, start `hz` ticking.
- **External interrupts:** PLIC driver (claim/complete) + `SIE.SEIE`; the UART
  as a real interrupt-driven console instead of SBI DBCN polling.
- **Real HAT:** a proper `hat_riscv` (page alloc, `hat_memload`/`hat_unload`,
  ASIDs, a kernel VA split at a canonical high `KERNELBASE` instead of the
  identity map), and a physical page allocator.
- **Toward genunix:** `mlsetup` grows the boot `cpu_t` into the real dispatch
  seed; `main` starts calling MI startup.

## R-P4 — SMP (SBI HSM) + cyclic clock + PLIC + high-VA hat (DONE, 2026-07-28)

**Milestone R-P4 — DONE, all four sub-gates verified on `qemu-system-riscv64
-machine virt -smp 4` under OpenSBI (fw v1.5.1 / SBI v2.0).** Building on the
R-P3 trap/Sv39/timer foundation, the first illumos RISC-V kernel now:

1. brings up **secondary harts via SBI HSM** (SMP),
2. runs a **periodic (cyclic) clock** at 100 Hz with a `gethrtime` wired to the
   `time` CSR,
3. takes **external interrupts through the PLIC** (claim/complete), and
4. installs a **real high-VA kernel map** at a canonical `KERNELBASE`
   (`0xffffffc000000000`) backed by a physical page allocator.

These are the MD pieces genunix (R-P5) needs. New/updated MD sources in
`src/riscv/uts/`:

| File | R-P4 change |
|------|-------------|
| `sbi.c`/`sbi.h` | Added the SBI **HSM** extension (EID `0x48534D`): `sbi_hart_start(hartid, start_addr, opaque)` (FID 0) and `sbi_hart_get_status(hartid)` (FID 2), with the `SBI_HSM_STARTED/STOPPED/*_PENDING` state constants. |
| `locore.S` | Added `_secondary_start` (the SBI-HSM secondary entry): masks interrupts, adopts the per-cpu stack handed in `a1`, installs `stvec`→`_trap_entry`, loads the **shared** `kernel_satp`, `sfence.vma`, calls C `secondary_main(hartid)`. Added `kernel_satp` (`.data`, published by `hat_boot_init`) and a `secondary_stacks` BSS pool (7 × 16 KiB = MAXCPU−1). |
| `riscv_regs.h` | Added `KERNELBASE` (`0xffffffc000000000`, the base of the high canonical Sv39 hole, VPN[2]=256) and the qemu-virt MMIO bases `CLINT_BASE`/`PLIC_BASE`/`UART0_BASE` + `UART0_IRQ`=10. |
| `hat_riscv.c` | `hat_boot_init()` now publishes `kernel_satp` for secondaries. Added the R-P4 physical bump allocator (`hat_phys_init`/`hat_palloc`) over RAM above the kernel image, `hat_kmap_page()` (the hat_memload-analog: a 4 KiB map through the full 3-level walk + per-VA `sfence.vma`), and `hat_highva_prove()` (allocate a fresh page, map it at `KERNELBASE`, write a signature through the high VA, read it back through both the high VA and the page's identity VA). Boot table pool grown 4→6 (the high-VA walk needs a fresh L1+L0). |
| `timer.c` | Reworked from R-P3's one-shot into a **periodic** clock: `clock_start()` arms a self-rearming timer at `HZ`=100 (`TIMER_PERIOD` = timebase/HZ = 100000 `time`-ticks = 10 ms), `timer_intr()` bumps the tick counter and rearms one period ahead (drift-free from the last deadline), `gethrtime()` scales the `time` CSR (10 MHz timebase) to nanoseconds, `clock_prove(n)` runs ≥ n ticks and reports count + hrtime. |
| `plic.c` | **New.** The PLIC driver + external-interrupt path (see §R-P4.3). |
| `trap.c` | The `trap()` dispatcher now routes `IRQ_S_EXT` (scause code 9) → `plic_extintr()` (claim/dispatch/complete) alongside the existing `IRQ_S_TIMER` → `timer_intr()`. |
| `main.c` | `mlsetup` grew the R-P4 sequence (phys alloc + high-VA hat → SMP secondaries → PLIC → periodic clock). Added `secondary_main()` (secondary report-in), `start_secondaries()` (the SBI-HSM boot driver), the `cpu_online[]` bitmap + `ncpu_online` counter, and a test-and-set `console_lock` (amoswap acquire/release) to serialize multi-hart console output. `main()` prints the R-P4 subsystem status. |

### R-P4.1 SMP secondary-hart bringup (SBI HSM) — the contract

Under OpenSBI's default boot only the boot hart is released to the S-mode
payload; secondaries sit in the HSM **STOPPED** state in firmware. The boot
hart:

1. **probes** which harts exist with `sbi_hart_get_status(h)` for `h` in
   `0..MAXCPU` — a valid hartid returns a non-negative state, an out-of-range
   one returns a negative SBI error;
2. for each STOPPED hart other than itself, assigns a per-cpu 16 KiB stack and
   calls `sbi_hart_start(h, PA(_secondary_start), stacktop)`. The `opaque` arg
   (`a1`) delivers the stack top; `start_addr` is `_secondary_start`'s physical
   address, which equals its VA (identity-mapped kernel gigapage), so it is
   valid whether the hart is still in Bare mode or has loaded `satp`.

OpenSBI releases each secondary into `_secondary_start` in S-mode with
`a0`=hartid, `a1`=opaque, `satp`=0, `sstatus.SIE`=0. The secondary masks
interrupts, adopts its stack, installs `stvec`, loads the **shared**
`kernel_satp` (published by `hat_boot_init` before any secondary is started, so
every hart translates through the one root page table), `sfence.vma`, and calls
`secondary_main(hartid)` which reports "hart N online" under the `console_lock`
and increments `ncpu_online`. The boot hart waits (acquire-fenced poll on
`ncpu_online`) until all `started` secondaries report, then continues.

**Result (verbatim, `-smp 4`, boot hart 0):**
```
[smp] boot hart 0 starting secondaries via SBI HSM (EID 0x48534D)
[smp] hart_start hart 1 -> _secondary_start (stacktop 0x0000000080234000)
[smp] hart 1 online (secondary, satp=shared kernel PT, trap vector installed)
[smp] hart_start hart 2 -> _secondary_start (stacktop 0x0000000080238000)
[smp] hart 2 online (secondary, satp=shared kernel PT, trap vector installed)
[smp] hart_start hart 3 -> _secondary_start (stacktop 0x000000008023c000)
[smp] hart 3 online (secondary, satp=shared kernel PT, trap vector installed)
[smp] secondaries started=3 online-reported=3
```
`cpus online: 4 (1 boot + 3 secondary)`. **SMP: YES, 3 secondary harts.**
(qemu picks the boot hart nondeterministically across runs — 0 or 1 observed;
the driver probes/starts by HSM state, so it is boot-hart-agnostic.)

### R-P4.2 Periodic (cyclic) clock — the contract

The `time` CSR is the monotonic counter; qemu virt's CLINT runs at
`TIMEBASE_HZ` = 10 MHz (1 `time`-tick = 100 ns). The clock ticks at `HZ`=100, a
`TIMER_PERIOD` = `TIMEBASE_HZ/HZ` = 100000 `time`-ticks = 10 ms period. Arm =
`sbi_set_timer(deadline)`; on the timer trap `timer_intr()` bumps the counter
and advances `deadline += TIMER_PERIOD` (from the *last* deadline, not `now`, so
ticks do not drift with interrupt latency; if we fall behind, catch the deadline
up to `now + period`) and re-arms — `set_timer` clears the pending STIP as a
side effect, so the rearm is also the acknowledgement. `gethrtime()` = `time`
scaled to ns (split as `sec*1e9 + (rem*1e9)/freq` to avoid 64-bit overflow).

**Result:** `[clock] 10 ticks, hrtime=239057900 ns (elapsed 100235800 ns) ->
periodic clock running.` — 10 ticks in ~100.24 ms is exactly 100 Hz; the final
status line reads `11 ticks` because the clock kept ticking while the banner
printed, which is the proof it is genuinely periodic/self-rearming, not
one-shot. **Cyclic clock: YES.**

### R-P4.3 PLIC external interrupts — the contract

PLIC base `0x0c000000` (qemu virt). Register map: `priority[src]` = base+`src*4`;
`enable[ctx]` bitmap = base+`0x2000 + ctx*0x80`; `threshold[ctx]` =
base+`0x200000 + ctx*0x1000`; `claim/complete[ctx]` = base+`0x200004 +
ctx*0x1000`. Context numbering on qemu virt: hart H → M-mode ctx `2H`, S-mode
ctx `2H+1`; we run S-mode on the boot hart so **our context is 1**.

Init sets every source priority to 0 (disabled) and threshold 0 (accept any
priority > 0). `plic_enable(src, prio)` sets the source priority and its enable
bit. On an external interrupt the hart traps (`scause` = `IRQ_S_EXT`, code 9) →
`trap()` → `plic_extintr()`: read CLAIM (returns the pending source id and
de-asserts `sip.SEIP`), dispatch, write the id back to COMPLETE, loop until
CLAIM returns 0.

The self-test proves delivery **without interactive input**: enable the
NS16550A UART source (`UART0_IRQ`=10) at priority 1, enable `SIE.SEIE` +
`sstatus.SIE`, then enable the UART's transmit-holding-empty (THRE) interrupt —
the transmitter is idle at boot, so the UART raises its PLIC line immediately.

**Result:**
```
[plic] init: base=0x000000000c000000 S-context=1 threshold=0
[plic] enabled source 0x000000000000000a prio 0x0000000000000001
[plic] IRQ 0x000000000000000a claimed (S-mode external interrupt delivered via PLIC)
[plic] self-test OK: external IRQ 0x000000000000000a claimed + completed via PLIC.
```
**PLIC external IRQ: YES** (source 10 claimed + completed). This is the exact
path virtio/console/net drivers will use.

### R-P4.4 High-VA kernel HAT — the contract

Sv39 gives a 39-bit VA with a sign-extension rule (bits [63:39] = bit 38),
splitting valid VAs into a low half (`0x0..0x3f_ffffffff`) and a high half
(`0xffffffc0_00000000..`). illumos puts the kernel in the high half:
`KERNELBASE` = `0xffffffc000000000` (VPN[2]=256, first entry of the root
table's high half). A bump allocator (`hat_phys_init`/`hat_palloc`) hands out
zeroed 4 KiB physical pages from RAM above the kernel image (VA==PA in the
identity gigapage, so a phys address is directly usable to zero the page).
`hat_kmap_page(va, pa, perm)` installs a 4 KiB leaf through the shared root
table's full 3-level walk (allocating the intermediate L1/L0 tables) and
`sfence.vma`s the single VA.

`hat_highva_prove()`: `pa = hat_palloc()`; `hat_kmap_page(KERNELBASE, pa, RW)`;
write a signature through the high VA; read it back through both the high VA and
the page's identity VA.

**Result:**
```
[hat] phys page allocator: free RAM 0x0000000080253000 .. 0x0000000088000000 (0x0000000000007dad pages)
[hat] high-VA map: KERNELBASE 0xffffffc000000000 -> PA 0x0000000080253000 (RW)
[hat] wrote 0x5041474544554d50 via high VA; readback high=0x5041474544554d50 ident=0x5041474544554d50  MATCH -> high-VA translation verified
```
**High-VA hat map: YES** (fresh page mapped at `KERNELBASE` and verified through
the translation).

### R-P4.5 Result summary + honest scope

All four sub-gates PASS on `-smp 4`:
- SMP secondary harts online: **YES — 3** (via SBI HSM).
- Cyclic clock ticking: **YES** (periodic 100 Hz, `gethrtime` in ns).
- PLIC external IRQ claimed: **YES** (UART source 10 claimed + completed).
- High-VA hat map working: **YES** (`KERNELBASE` map + bump page allocator).

Full artifacts: `artifacts/riscv-port/rp4/` (`rp4-boot.log`, `unix`,
`unix.disasm`, `unix.sections`). Build: nixpkgs
`pkgsCross.riscv64-embedded` (riscv64-none-elf gcc 14.3.0, binutils 2.44),
freestanding `-mcmodel=medany`. Every qemu run was `timeout`-wrapped + detached
(nohup→log, sleep+check+kill); no foreground-wait, no wedge; stray-qemu checked
gone after each run.

**Deliberate R-P4 scope (documented ceilings, each an R-P5 upgrade path):**
- **phys allocator** is a one-way bump with a conservative RAM cap (qemu-virt
  128 MiB constant), not a DTB-probed `page_t`/freelist — R-P5 parses the FDT
  `/memory` node and builds the real page allocator with free.
- **clock** is the bare periodic heartbeat + `gethrtime`; no cyclic wheel,
  callout dispatch, or time-of-day — R-P5 adds the cyclic subsystem on top.
- **PLIC** self-test quiesces the UART source after the proof; the console is
  still SBI DBCN (polled). R-P5 makes the UART a real interrupt-driven console.
- **SMP** secondaries park in `wfi` with interrupts masked (no per-cpu dispatch
  or idle thread, no IPI use yet — the SBI IPI/`sfence` broadcast path is R-P5).
- **hat** has no ASIDs, no `hat_unload`, no VA allocator — one proving map.

### R-P4.6 Next: R-P5 (genunix)

- **Physical/virtual memory:** FDT `/memory` parse → real `page_t`/freelists;
  a kernel VA allocator over the `KERNELBASE` high range; `kmem` (slab) on top;
  `hat_memload`/`hat_unload`/ASIDs.
- **Cyclic subsystem:** the cyclic wheel + callout dispatch driven by the R-P4
  periodic clock; time-of-day.
- **Per-cpu dispatch:** turn the secondary `wfi` park into per-cpu idle threads
  + the dispatcher; SBI IPI (`sbi_send_ipi`) for cross-hart `sfence`/reschedule.
- **Console:** a PLIC-driven NS16550A console driver replacing SBI DBCN polling.
- **genunix link:** grow `mlsetup`'s boot `cpu_t` into the real `cpu_t[]`; have
  `main()` call MI startup (`startup()`, `main()` MI) toward mounting root.

---

## R-P5 — genunix seam: page_t/freelist + kmem + callout wheel + dispatcher/idle threads (DONE, 2026-07-28)

**Milestone R-P5 — DONE, all five gates verified on `qemu-system-riscv64
-machine virt` (`-smp 1` and `-smp 4`) under OpenSBI v1.5.1.** This is the
bridge from the machine-dependent (MD) kernel to the machine-independent (MI)
kernel: `main()` now calls a `startup()`-analog that brings genunix's
foundation online. Building on the R-P4 SMP/clock/PLIC/high-VA-hat foundation,
the first illumos RISC-V kernel now has:

1. **Physical page management** — a real `page_t[]` array + free list built
   over the RAM the DTB reports (replacing the R-P4 hardcoded 128 MiB bump).
2. **kmem/VA allocator** — a kernel VA arena over the `KERNELBASE` high range +
   a power-of-two-class slab `kmem_alloc`/`kmem_free`.
3. **Callout wheel** — a timer-tick-driven callout facility on the R-P4 100 Hz
   periodic clock (`callout_schedule`).
4. **Context switch + kernel threads + dispatcher** — a real RISC-V
   callee-saved context switch (`rv_swtch`), `kthread_t`, a round-robin run
   queue, cooperative `swtch`/`thread_yield`, and per-cpu idle threads.
5. **`startup()`-analog** — `main()` → `startup()` brings the above up in
   illumos order and the boot cpu becomes cpu0's idle thread.

New MI/MD sources in `src/riscv/uts/`:

| File | R-P5 role |
| --- | --- |
| `fdt.c` | **New.** Minimal flattened-devicetree reader. Parses the DTB (`a1`, big-endian) walking the struct block to the `/memory` node's `reg = <base size>`, honoring root `#address-cells`/`#size-cells` (riscv virt 2/2). Returns the real RAM extent. Verified against a live qemu `virt.dtb` (128 MiB) and by booting `-m 256M` → correctly reports 256 MiB (not a coincidence: the kernel reads the DTB). |
| `vm_page.c` | **New.** `page_t` (pfn + free link + state), a self-hosted `page_t[]` at the front of the RAM above the boot watermark, and a LIFO free list with `page_alloc`/`page_free` under a global spinlock. `physmem` exports the managed page count. |
| `kmem.c` | **New.** `heap_vmem` (a bump VA arena at `KERNELBASE+16 MiB`, 64 MiB VA window, page-backed on demand via `page_alloc`+`hat_kmap_page`), and power-of-two size classes (16..2048 B) with embedded-free-list single-page slabs. `kmem_alloc`/`kmem_free`; large (>2048 B) requests get page-multiple VA runs. |
| `swtch.S` | **New.** `rv_swtch(old, new)` saves/restores the RISC-V callee-saved set (`ra`, `sp`, `tp`, `s0-s11`) — the only state a cooperative switch must preserve, since caller-saved regs are already spilled around the C call. `rv_thread_start` trampoline launches a brand-new thread's `entry(arg)`. |
| `proc.c` | **New.** `kthread_t`, `thread_create` (kmem stack + seeded context so the first switch lands on `rv_thread_start`), a global FIFO run queue, `swtch`/`thread_yield`/`thread_exit`, `idle_body`, `dispatch_init_cpu` (the current context becomes cpu N's idle thread), and the A/B two-thread ping-pong proof. |
| `startup.c` | **New.** The `startup()`-analog: `startup_memlist` (FDT parse → `page_init`), `startup_vm` (`kmem_init`), `startup_cyclic` (callout proof), `startup_dispatch` (`dispatch_init_cpu(0)` + A/B proof). Hosts the shared `kputdec`/`kputhex` console helpers. |
| `timer.c` | Grew a **callout wheel**: a flat table walked O(n) each tick in `timer_intr`, firing any callout whose deadline (in ticks) has arrived; `callout_schedule(ms, fn, arg)` + the +50 ms self-test. |
| `hat_riscv.c` | `alloc_table()` now draws page-table pages from `page_alloc` once the R-P5 page layer is up (via `hat_page_layer_online()`), so the `KERNELBASE` VA allocator can map many pages beyond the 6-entry static boot pool. Added `hat_phys_watermark()` so `page_init` places the `page_t[]` above everything the boot allocator consumed. |
| `sbi.c` | Console `putchar` switched from **DBCN** (passes a buffer *address* OpenSBI reads back through the caller's address space) to **legacy putchar** (EID 0x01, char in a register). DBCN worked only while everything ran on the identity-mapped boot stack (VA==PA); R-P5 threads run on high-canonical kmem-VA stacks, where a DBCN char buffer is a VA OpenSBI's read path faults on. Legacy putchar is correct from any stack. |
| `plic.c` | Two fixes: (1) The self-test ISR now **masks the UART source before printing** the claim (and disables it at the PLIC + masks IER after the proof). With legacy putchar every console byte drives the UART TX, re-asserting THRE; printing *before* masking created a self-inflicted interrupt storm that livelocked under `-smp 4`. (2) The S-mode PLIC **context is now computed from the boot hartid** (`2*hartid+1`) via `plic_set_context()`, not hardcoded to 1 (hart 0) — and the claim-wait spins instead of `wfi`. R-P4's hardcoded context 1 + `wfi` wait stalled forever whenever the SMP boot-hart election picked a hart != 0 (the interrupt targeted a parked secondary's context, and `wfi` had no timer to wake it). Now deterministic for any boot hart (8/8 clean `-smp 4` runs across boot harts 0..3). |
| `main.c` | After the R-P4 status banner, `main()` sets `startup_ncpu` and calls `startup(dtb)` — the MD→MI seam — then reports the R-P5 status and parks the boot cpu (now cpu0's idle thread). |

### R-P5.1 Physical page management — the contract

- **Input:** the DTB RAM extent from `fdt_get_memory` and the boot watermark
  from `hat_phys_watermark()` (first PA above the kernel image + any boot
  `hat_palloc` pages). The two never overlap: boot page tables came from the
  static pool / below the watermark; every `page_alloc` page is above it.
- **Layout:** `page_t[]` is self-hosted at the front of the managed region
  (`arraypages` reserved), the rest goes on the free list.
- **API:** `page_alloc()` → zeroed PA (== identity VA), `page_free(pa)` (range +
  double-free checked), `page_freecount()`, `physmem`.
- **PROVE:** `physmem: 32172 pages (125 MB) managed` (128 MiB DTB) /
  `64940 pages (253 MB)` (`-m 256M`); `page_alloc/free self-test OK`.

### R-P5.2 kmem / VA allocator — the contract

- **VA arena:** bump over `[KERNELBASE+16 MiB, +80 MiB)`; each page handed out
  is backed by a `page_alloc` frame mapped R/W via `hat_kmap_page` (full 3-level
  Sv39 walk, per-VA `sfence.vma`).
- **Slab:** power-of-two classes 16..2048 B, one-page slabs, embedded free list.
  `> 2048 B` → page-multiple VA runs (their VA currently leaks on free —
  documented ceiling). `kmem_free` takes the size (illumos convention).
- **PROVE:** `kmem] alloc/free self-test OK (16/64/256/1500 B ... 64 B recycled)`.

### R-P5.3 Callout wheel — the contract

- A flat `callouts[16]` table; `timer_intr` fires any active callout with
  `timer_ticks >= c_expire_tick` (deactivate-before-call so a callout may
  reschedule). `callout_schedule(ms, fn, arg)` rounds ms up to ticks (HZ=100,
  10 ms granularity). Runs in the clock-ISR context.
- **PROVE:** `callout fired at +50ms (tick N) -> callout wheel OK`.

### R-P5.4 Context switch + dispatcher — the contract (the marquee)

- **`rv_context`:** `ra, sp, tp, s0-s11` (15 × 8 = 120 B) — exactly the RISC-V
  callee-saved set. Caller-saved regs need no save (the C call already spilled
  live ones). `rv_swtch` saves `*old`, loads `*new`, `ret`s into the new
  thread's `ra` (a fresh thread's `ra` = `rv_thread_start`, which calls
  `entry(arg)` with `s0`/`s1` seeded).
- **Dispatcher:** one global FIFO run queue + lock; `swtch()` picks the head (or
  the idle thread if empty); `thread_yield()` re-enqueues self and switches;
  `thread_exit()` switches away for good. `dispatch_init_cpu` makes the current
  context cpu N's idle thread.
- **CRITICAL BUG FOUND + FIXED:** GCC tail-call-optimized the
  `rv_swtch(&old, &new)` call in `swtch()` (last statement) into a `jr`, so
  `rv_swtch` saved the *caller's* `ra`/`sp` and silently wedged. Fix: a
  `__asm__ __volatile__("" ::: "memory")` barrier after the call forces a real
  `jalr` (frame kept, resume-here semantics correct). Verified in the disasm.
- **PROVE:** `thread A/B context-switch OK (A ran 3x, B ran 3x, yielded to each
  other via swtch)` — two kernel threads ping-ponging through `swtch` is real
  scheduling (stacks + PC + callee-saved state switch and resume correctly).

### R-P5.5 startup()-analog — the contract

- `main()` → `startup(dtb)`: `startup_memlist` → `startup_vm` → `startup_cyclic`
  → `startup_dispatch`, each running its gate self-test, then the completion
  banner. The boot cpu ends as cpu0's idle thread.
- **PROVE:** `startup complete: 4 cpus, physmem 32172 pages (125 MB), kmem
  online (8 heap pages), cyclic online, dispatch online.`

### R-P5.6 Result — SUCCESS (verbatim console, the five gates, `-smp 4`)

```
[startup] MI kernel bring-up (genunix seam, R-P5)
[startup] startup_memlist: physical memory
[startup] FDT /memory: base 0x0000000080000000 size 0x0000000008000000 (128 MiB) [from DTB]
[page] page_t array at PA 0x0000000080254000 (189 pages reserved), managing 32172 frames [0x0000000080254000..0x0000000088000000)
[page] free list: 31983 pages available
[startup] physmem: 32172 pages (125 MB) managed
[page] page_alloc/free self-test OK (4 pages alloc'd, zeroed, written, freed; freecount restored)
[startup] startup_vm: kernel VA + kmem
[kmem] heap VA arena 0xffffffc001000000 .. 0xffffffc005000000 (64 MiB VA, page-backed on demand); 8 size classes (16..2048 B)
[kmem] alloc/free self-test OK (16/64/256/1500 B alloc'd, written+verified, freed; 64 B recycled)
[startup] startup_cyclic: callout wheel on the 100 Hz clock
[callout] scheduled callout for +50 ms (5 ticks) at tick 11
[callout] callout fired at +50ms (tick 16) -> callout wheel OK
[startup] startup_dispatch: threads + swtch
[startup] boot cpu is now cpu0 idle thread; dispatcher online
[disp] creating kernel threads A + B, cooperative round-robin via swtch:
thread A: round 1 (ctx-switch to B)
thread B: round 1 (ctx-switch to A)
thread A: round 2 (ctx-switch to B)
thread B: round 2 (ctx-switch to A)
thread A: round 3 (ctx-switch to B)
thread B: round 3 (ctx-switch to A)
[disp] thread A/B context-switch OK (A ran 3x, B ran 3x, yielded to each other via swtch)
[startup] startup complete: 4 cpus, physmem 32172 pages (125 MB), kmem online (8 heap pages), cyclic online, dispatch online.
[R-P5] genunix seam online: page_t + kmem + callout wheel + dispatcher/idle threads.
```

All five gates PASS on `-smp 1` (deterministic) and `-smp 4` (8/8 clean runs
across boot harts 0..3 after the PLIC context + storm fixes). Full artifacts:
`artifacts/riscv-port/rp5/`
(`rp5-boot.log`, `unix`, `unix.disasm`, `unix.sections`, and every R-P5 source).
Build: nixpkgs `pkgsCross.riscv64-embedded` (riscv64-none-elf gcc 14.3.0,
binutils 2.44), freestanding `-mcmodel=medany`. Every qemu run was
`timeout`-wrapped + detached (nohup→log, sleep+check+kill); no foreground-wait,
no wedge; stray qemu confirmed gone after each run.

**Deliberate R-P5 scope (documented ceilings, each an R-P6 upgrade path):**
- **page:** LIFO free list + one global lock, no per-cpu magazines / NUMA
  freelists, no `page_t` vnode/offset/hash (frame descriptor only).
- **kmem:** power-of-two classes + single-page slabs + one global lock; no
  arbitrary object sizes, no per-cpu magazines/depot, no slab coloring; large
  (>2048 B) frees leak their VA (no vmem span free list yet).
- **callout:** O(n) flat-table scan per tick, fixed 16 slots, no hashed wheel,
  no time-of-day, no per-cpu cyclics.
- **dispatch:** ONE global runq + one lock, cooperative (yield-driven, not
  preemptive off the clock), **boot-cpu dispatch only** — secondaries still park
  in `wfi` (the A/B proof + idle threads run on cpu0). No priorities, no load
  balancing, no per-cpu runq, no `curthread` via `tp` in the trap path yet.
- **console:** legacy SBI putchar (polled); no NS16550A interrupt-driven driver.

### R-P5.7 The MD→MI interface contracts for R-P6

R-P6 links real genunix + device drivers + mounts root. The stable seams R-P5
establishes for it:

- **Memory:** `page_alloc()`/`page_free()`/`physmem` (the `page_t` layer) and
  `kmem_alloc()`/`kmem_free()` (the slab). genunix's `page_create_va` and
  `kmem_cache` grow on top of these; `hat_kmap_page`/`hat_phys_watermark` are
  the segkmem hooks.
- **Time:** `gethrtime()` (ns), the 100 Hz `timer_intr`, and
  `callout_schedule()` — the `timeout(9F)`/cyclic substrate.
- **Dispatch:** `thread_create()`, `swtch()`, `thread_yield()`, `thread_exit()`,
  `dispatch_init_cpu()`, and the `rv_context`/`rv_swtch` ABI — the `disp`/`swtch`
  substrate. R-P6: per-cpu runqs, clock-driven preemption, `curthread` via `tp`,
  secondaries running their idle threads + a scheduler tick.
- **Console:** `sbi_console_puts` (polled) is the `cn`/`putchar` seam; R-P6
  replaces it with a PLIC-driven NS16550A `console` driver (the PLIC
  claim/complete path is proven and quiesced-after-use).

### R-P5.8 Next: R-P6 (link genunix + drivers + root)

- **Link real genunix:** replace the bespoke `page`/`kmem`/`disp` seeds with the
  upstream MI subsystems, adapting them to these interface contracts; grow the
  boot `cpu_t` into the real `cpu_t[]` + per-cpu areas.
- **Device drivers:** a PLIC-driven **NS16550A console**, then **virtio-blk**
  and **virtio-net** on the qemu virt virtio-mmio transport (the PLIC external-
  IRQ path is ready).
- **Root filesystem:** DDI/DKI enough to attach virtio-blk, a root vfs, and
  mount root — the path to a usable userland.
- **SMP dispatch:** per-cpu run queues + clock-tick preemption + SBI IPI
  (`sbi_send_ipi`) for cross-hart reschedule / `sfence` broadcast; secondaries
  run their own idle threads and take the scheduler tick.
