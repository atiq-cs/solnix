# BSD riscv64 reference sources (crib provenance)

These are **reference-only** copies of the mature BSD riscv64 ports, kept as the
crib source for the illumos machine-dependent (MD) layer — the same pattern
solnix used for the ena NIC (cribbed from FreeBSD) and the desktop DRM plan
(crib NetBSD drmkms). They are **not** compiled into solnix and **not** shipped;
the illumos MD files under `src/riscv/uts/` reimplement these in the illumos
ddi/kernel idiom against the OS-independent RISC-V ISA spec.

## What is cribbed where

| illumos MD file (solnix)         | BSD crib source                                   | what is near-verbatim (ISA/psABI, OS-independent) |
|----------------------------------|---------------------------------------------------|---------------------------------------------------|
| `src/riscv/uts/sys/elf_riscv.h`  | `netbsd/nb_elf_machdep.h` (NetBSD elf_machdep.h)  | the full `R_RISCV_*` reloc table 0..57 + EM_RISCV, ELFDATA2LSB, ARCH_ELFSIZE — pure psABI |
| `src/riscv/uts/sys/machtypes.h`  | `netbsd/nb_reg.h`                                 | the callee-saved GPR set that `label_t` must save (ra/sp/gp/tp/s0-s11) — pure calling convention |
| `src/riscv/uts/sys/isa_defs.h`   | `netbsd/nb_elf_machdep.h` (endianness/elfsize)    | little-endian LP64D, 64-bit native, char-signed — psABI facts |
| `src/riscv/uts/riscv_regs.h` (existing) | (spec + `nb_mcontext.h`/`nb_frame.h`)      | S-mode CSR bits, Sv39 PTE layout, scause codes — RISC-V Privileged Spec |

## Files here (fetched from NetBSD-current `src/sys/arch/riscv/include/`)

- `netbsd/nb_elf_machdep.h` — the complete RISC-V ELF psABI reloc set (the crib
  that showed the n-hys illumos fork's 12-entry `elf_riscv.h` was insufficient;
  real gcc emits R_RISCV_CALL_PLT/PCREL_HI20/PCREL_LO12_I/RELAX which are >11).
- `netbsd/nb_reg.h` — struct reg (GPR/FPREG context) + the RISC-V register-role
  comment block (validates the illumos `label_t` layout).
- `netbsd/nb_mcontext.h` — user signal/ucontext register state (crib for a
  future illumos `mcontext_t`/`sendsig` — the port's `sendsig.c` is n-hys-staged).
- `netbsd/nb_frame.h` — trap frame (crib for `asm_frame.h`/`struct regs`).
- `netbsd/nb_asm.h` — assembler macros (crib for `sys/asm_linkage.h`).

## TODO: obtain a pinned NetBSD-current source mirror

Like the pending NetBSD-drm mirror for the desktop track, a **pinned
NetBSD-current `sys/arch/riscv` mirror** should be obtained as the authoritative
reference (these five files were fetched ad hoc from
`raw.githubusercontent.com/NetBSD/src/trunk`). FreeBSD `sys/riscv` is the
secondary cross-check (same ISA, different kernel idiom). The RISC-V Privileged
Spec + ELF psABI remain the ultimate authority; BSD is the "how a real kernel
wires it" reference, reimplemented in illumos idiom.
