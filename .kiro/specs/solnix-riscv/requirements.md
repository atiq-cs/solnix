# solnix RISC-V (riscv64) port — Requirements

**Mandate:** write the illumos RISC-V port. solnix will be the FIRST and ONLY
illumos distribution with RISC-V support. This is not a "wait for upstream" track
— we create it. Reference: NetBSD `sys/arch/riscv` (mature, BSD-licensed — study
structure/algorithms, reimplement in illumos idiom against the RISC-V Privileged
Spec which is the authority), plus richlowe/arm64-gate + illumos IPD 24 as the
"how illumos adds a new arch" precedent.

## Scope & honesty

This is a genuine multi-phase kernel port (the gap analysis in
`docs/design-riscv-port.md` estimates ~2–3.5 engineer-years to a QEMU-virt
multi-user boot). We execute it in buildable phases, each with a runnable gate,
never claiming more than boots. Target hardware progression: QEMU `virt` (bring-up)
→ SpaceMiT K1/K3 boards → the maintainer's real `rv` RISC-V host.

## Requirements

- **R1 (toolchain target):** a `riscv64-unknown-solaris2.11` cross gcc + binutils,
  and the Solaris link-editor (`sgs`/`ld`) taught RISC-V relocations (R_RISCV_*).
  Prerequisite for everything. (We already have a `riscv64-unknown-elf` cross gcc
  as the starting point — retarget it.)
- **R2 (uts/riscv MD kernel):** locore/hart-bringup (S-mode under OpenSBI),
  trap/exception (scause/sepc/stval), MMU/HAT (Sv39/Sv48 page tables, sfence.vma),
  interrupts (PLIC + CLINT/ACLINT; AIA later for K1), timer (time CSR / SBI timer),
  SMP (SBI HSM). Modeled on NetBSD riscv + uts/aarch64.
- **R3 (boot path):** OpenSBI (M-mode firmware) → a riscv64 illumos loader (EFI or
  a direct SBI-payload) → `unix` in S-mode. QEMU virt first.
- **R4 (SBI layer):** OpenSBI ecall wrappers — console, timer, HSM (hart start),
  IPI, system reset — the illumos↔firmware interface.
- **R5 (CTF + mapfiles + build glue):** ctfconvert/ctfmerge for riscv64 ELF,
  the mapfiles, and a `riscv-gate` (nightly/tools) that builds `unix` + genunix +
  the MD modules.
- **R6 (userland):** libc/crt/rtld for riscv64-solaris (needs R1 + R2 headers),
  then the `pkgs.solnix.*` world for `riscv64-solaris` (mirrors aarch64 A3).
- **R7 (lib.systems + world slices):** wire `riscv64-solaris` fully (the draft
  patch 0004 reserves the name) + build/cache the riscv64 world slices.
- **R8 (boot milestone):** riscv64 illumos boots under `qemu-system-riscv64
  -machine virt` to single-user, then multi-user-server, then ssh (mirror the
  aarch64 A4→A6 arc). Then K1/K3 hardware; then the `rv` host.

## Non-goals (initially)

- GPU/accelerator, non-virt SoC drivers beyond what K1/K3 need for console+storage+net.
- Perfect performance; correctness + boot first.
- mdb/kmdb/dtrace for riscv (defer; ~4–6 mo on top).

## Phasing (each phase = a runnable gate)

- **R-P1:** toolchain target (riscv64-unknown-solaris2.11 gcc/binutils + ld relocs)
  + `riscv-gate` scaffold. Gate: cross-compile a trivial riscv64-solaris .o.
- **R-P2:** `uts/riscv` locore + SBI console → **first `unix` prints a banner in
  S-mode under OpenSBI on qemu virt** (the "hello from the illumos riscv kernel").
- **R-P3:** trap + MMU/HAT (Sv39) + timer → reach `mlsetup`/`main`, VM online.
- **R-P4:** PLIC/CLINT interrupts + SMP (SBI HSM) → multi-hart, clock ticks.
- **R-P5:** genunix link + driver attach (virtio-blk/net over the riscv virt) +
  root mount → single-user.
- **R-P6:** userland (libc/crt/rtld) + SMF → multi-user-server → ssh.
- **R-P7:** K1/K3 board support (AIA, SoC drivers) → real hardware; the `rv` host.
