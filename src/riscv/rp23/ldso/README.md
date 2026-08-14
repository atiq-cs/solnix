# R-P23.2 -- riscv64 ld.so.1: reduced reloc engine + the full-process path

## What R-P23 delivered (the reduced milestone)

`rp23/ldso/rtld_riscv.c` is the CORE of illumos `ld.so.1` for riscv64: the
runtime relocation loop `elf_reloc_riscv()`, the exact inner switch of rtld's
`elf_reloc()` for the riscv64 relocation types, resolving at load time:

- `R_RISCV_RELATIVE` (3): `*(base + r_offset) = base + r_addend` (B + A) --
  fix an absolute pointer for the object's real load base.
- `R_RISCV_JUMP_SLOT` (5): `*(base + r_offset) = sym_value` -- bind a PLT/GOT
  slot to the resolved symbol; done eagerly here (as under `LD_BIND_NOW`).
- `R_RISCV_64` (2): `S + A` absolute 64-bit data.

It runs as a freestanding S-mode payload under `qemu-system-riscv64 -machine
virt` (OpenSBI), relocates a synthetic object image at a nonzero base, binds a
GOT slot to a "libgcc_s-shaped" symbol, CALLS through it, and dereferences the
RELATIVE-fixed pointer -- proving the reloc math end to end. Output:

```
[ld.so.1] R_RISCV_JUMP_SLOT: PASS (GOT slot bound + called through -> sentinel)
[ld.so.1] R_RISCV_RELATIVE: PASS (base+addend pointer relocated + dereferenced)
```

CRIB: the `elf_reloc()` RELATIVE/JUMP_SLOT formulas are illumos
`usr/src/cmd/sgs/rtld/common/_elf.c` + the machine-specific `rtld/<mach>/`
reloc code (amd64/sparc shape, riscv64 modeled on the psABI); the `R_RISCV_*`
numbers + formulas are `uts/common/sys/elf_riscv.h` + the RISC-V psABI.

## Why the full DYNAMIC hello does not run yet

Running the R-P21 `hello.dyn` (DT_NEEDED libgcc_s.so.1) as a real process needs
the pieces `ld.so.1` sits on top of, none of which exist for riscv64 yet:

1. A live kernel PROCESS model: `exec()` maps the a.out + the interpreter
   (`ld.so.1`), builds the aux vector (AT_PHDR/AT_BASE/AT_ENTRY/AT_NULL), and
   transfers to the interpreter entry in U-mode. The R-P23 kernel skeleton
   reaches mlsetup+banner but has no exec/proc/syscall path (that is R-P24+;
   the full R-P1..R-P16 kernel in `src/riscv/uts` has exec, but was not built
   with the native solaris toolchain).
2. `ld.so.1` self-relocation from `_rt_boot` (its own RELATIVE relocs before it
   can call any function), then mapping the executable's PT_LOAD segments and
   each DT_NEEDED, running each object's RELA/JMPREL, and the lazy-PLT trampoline
   (`elf_rtbndr` -> `elf_bndr`).
3. A riscv64 `_rt_boot.s` / `elf_rtbndr.s` (the rtld MD asm: bootstrap
   self-reloc + the PLT resolve trampoline that saves a0..a7 + the caller
   frame, calls the C binder, and tail-jumps to the resolved target).
4. libc + libgcc_s actually present as riscv64 shared objects on a root fs the
   kernel can read (the R-P22 `libgcc_s.so.1` is a shape/version-script demo,
   not a full riscv64 libgcc).

The reduced engine proves the one hard MD-correctness kernel of (2): the
riscv64 RELATIVE + JUMP_SLOT reloc math + calling through a bound slot. The
static-hello path (R-P22.2b, `hello_static`, no `ld.so.1`) remains the
supported way to run a riscv64-solaris exe the moment the kernel syscall path
is live.

## The full-process path (for R-P24+)

- Port `usr/src/cmd/sgs/rtld/common/` (setup.c, analyze.c, _elf.c) +
  `rtld/riscv64/` (the MD reloc + `_rt_boot.s`/`elf_rtbndr.s`). Model
  `rtld/aarch64/` (richlowe arm64-gate) or `rtld/amd64/` for the MD split.
- Wire the reduced `elf_reloc_riscv()` here in as the riscv64 `rtld`
  active-reloc loop.
- Bring the kernel exec path (map interp, aux vector, U-mode entry) online
  under the native toolchain (R-P24 grows the R-P23 kernel skeleton toward it).
- Then `hello.dyn` runs: kernel exec -> ld.so.1 self-reloc -> map libgcc_s ->
  bind JUMP_SLOT -> jump to `_start`.
