# RISC-V (riscv64) port — STATUS

**Phase reached: R-P21** (a REAL gate-shaped sgs libld `machrel.riscv.c` wired
into `ld_reloc_local` + `ld_do_activerelocs` against the `_libld.h`
`Rel_desc`/`Sym_desc`/`Ofl_desc` interfaces, with the %pcrel_hi/%pcrel_lo
pairing upgraded from the R-P20 O(n) list to a real hash table; a hand-linked
shared `libgcc_s.so.1` (EM_RISCV ET_DYN) + the first DYNAMIC riscv64-solaris
hello; and a bigger genassym-DRIVEN riscv64 MD set partial-linked (`ld -r`) to
one EM_RISCV `unix` object) -- DONE (all three sub-tasks, re-runnable proofs).
R-P20 (sgs %pcrel pairing + GOT/PLT alloc, csu crt + first hello ELF, larger uts
unit), R-P19 (riscv64-solaris toolchain finished + sgs MACH descriptor + first
EM_RISCV uts object), R-P18 (toolchain TARGET retarget + krtld/sgs reloc
coverage), R-P17 (cross toolchain + BSD psABI/ISA headers) and R-P1..R-P16
(kernel bring-up) are below / in `docs/design-riscv-port.md`.

---

## R-P21 — gate sgs machrel.riscv.c (htab pairing) + libgcc_s.so.1 (dynamic hello) + bigger MD partial-link

Substrate: fred v3 (root@52.88.62.49), the intact R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>`) + R-P17 `riscv64-unknown-elf` binutils.
Crib sources on host: binutils-2.44 `bfd/elfnn-riscv.c` (pcrel pairing, PLT/GOT
layout) + `ld/` (emulation regen); illumos `/usr/gcc/*/lib/libgcc-unwind.map`
(version-script shape); the illumos sgs `machrel.amd64.c`/`machrel.sparc.c`
SHAPE (from knowledge -- gate not checked out on host) for the backend wiring.
Proof: `rp21/rp21-milestone-check.sh` (all 3, re-runnable green).

### R-P21.1 gate sgs machrel.riscv.c + real hash-table %pcrel pairing — DONE
- `rp21/sgs/machrel.riscv.c`: the R-P20 standalone pieces folded into ONE
  gate-shaped backend that compiles against a `_libld.h` shim
  (`rp21/sgs/_libld_shim.h`, field-order-faithful `Rel_desc`/`Rel_aux`/
  `Sym_desc`/`Sym_aux`/`Gotndx`/`Os_desc`/`Is_desc`/`Ofl_desc` trimmed to what
  the backend touches).  Four gate entry points, same names/roles as the
  amd64/sparc backends:
  - `ld_reloc_local()` -- per input reloc: classify via `reloc_table[]`, and if
    GOT/PLT assign the slot on the referenced `Sym_desc` (idempotent -- many
    refs share ONE slot) growing `ofl_gotcnt`/`ofl_pltcnt`;
  - `ld_assign_got_ndx()` -- find/assign a symbol's GOT slot per `Gotref`;
  - `ld_do_activerelocs()` -- the output pass: computes the RISC-V value
    (S+A, or S+A-P for PCREL) and routes flat data to a byte store, INSREL
    types to the field splice, and the %pcrel_hi/%pcrel_lo pair through the
    record-HI / defer-LO / resolve-by-HI-address model;
  - `ld_riscv_finish_pcrel()` -- resolves the deferred LOs.
- **HTAB upgrade (the R-P20 gate)**: `rp21/sgs/riscv_pcrel_htab.h` replaces the
  R-P20 O(n) list scan with a chained (open) hash table keyed by the auipc-site
  address -- power-of-two buckets, Knuth multiplicative hash, grow+rehash at
  ~0.75 load -- so a %pcrel_lo resolves O(1) even with thousands of pairs. The
  htab hangs off `Ofl_desc.ofl_riscv_pcrel` for the file being relocated.
- Self-test (`-DMACHREL_SELFTEST`): ld_reloc_local classifies + assigns
  idempotent GOT/PLT slots (2 GOT refs -> 1 slot, 2 CALL_PLT -> 1 entry;
  header-biased .plt/.got.plt offsets 32/16); ld_do_activerelocs drives a real
  `Rel_desc` set and the pcrel pair (through the htab, resolved in the finish
  pass) is **byte-identical to GNU ld** (`0x00001797`/`0x0a878793` for the
  R-P19.3 pair) reconstructing S-P; a dangling %pcrel_lo is rejected; the htab
  scales to 1000 pairs with O(1) lookup -- PASS.
- **CRIB**: `ld_reloc_local`/`ld_assign_got_ndx`/`ld_do_activerelocs`/
  `ld_perform_outreloc` SHAPE + the `Sym_desc`/`Gotndx`/`Rel_desc` field names
  from illumos-gate `usr/src/cmd/sgs/libld/common/machrel.amd64.c` +
  `machrel.sparc.c` + `include/_libld.h`; the pcrel pairing algorithm + PLT/GOT
  layout from binutils-2.44 `bfd/elfnn-riscv.c`; the RISC-V Calculation +
  immediate encodings from the psABI. (Gate not on host: the shim reproduces
  the gate structs so the backend is a drop-in for the real `_libld.h`.)

### R-P21.2 hand-linked shared libgcc_s.so.1 + first DYNAMIC hello — DONE
- The R-P20 long pole. gcc target libs are `--disable-shared` (only static
  `libgcc.a`, 138 objects). Instead of a full `--enable-shared` rebuild (needs
  a real libc for `SHLIB_LINK`), **hand-linked `libgcc_s.so.1` from `libgcc.a`
  + a GCC_3.0 version script** (`rp21/libgcc_s/libgcc_s.ver`, 214 exported
  symbols generated from the archive's defined symbols; crib: illumos
  `libgcc-unwind.map` + gcc `libgcc-std.ver.in`).
- **One binutils blocker fixed**: the R-P17 `riscv64-unknown-elf` binutils had
  `elf64lriscv` `config.has_shared = false` (bare-metal newlib leaves
  `GENERATE_SHLIB_SCRIPT` unset), so `ld -shared` errored `-shared not
  supported` (ld/lexsup.c:1365) with no `.xs` script. Regenerated ONLY that
  emulation (added `GENERATE_SHLIB_SCRIPT=yes`/`GENERATE_PIE_SCRIPT=yes` to the
  emulparams, re-ran genscripts, relinked just `ld-new`) -> `has_shared = true`
  + the shared/PIE ldscripts; installed as
  `toolchain/bin/riscv64-unknown-elf-ld-shared`. NOT a full binutils rebuild.
  Recipe in `rp21/libgcc_s/README.md`.
- `libgcc_s.so.1`: **EM_RISCV ELF64 ET_DYN**, SONAME `libgcc_s.so.1`, all 214
  symbols versioned `@@GCC_3.0` (`--allow-shlib-undefined` for the libc deps
  malloc/memcpy/memset/mprotect/... resolved from libc.so.1 at runtime).
- **Dynamic hello**: R-P20 hello.c + crt linked against `-lgcc_s` with
  `--dynamic-linker /usr/lib/ld.so.1` -> EM_RISCV, INTERP `/usr/lib/ld.so.1`,
  NEEDED `libgcc_s.so.1` -- the first DYNAMIC riscv64-solaris userland exe
  (R-P20 produced the first STATIC one).
- **CRIB**: version-script shape from illumos `/usr/gcc/*/lib/libgcc-unwind.map`
  + gcc `libgcc/libgcc-std.ver.in` (GCC_3.0 global / local *); the emulation
  regen args verbatim from `build/binutils/ld/Makefile` GENSCRIPTS.

### R-P21.3 bigger genassym-driven MD set -> EM_RISCV partial-link — DONE
- Replaced hand-maintained `.S` offsets with **genassym output**:
  `rp21/uts/riscv64/mach_swtch.S` (rv_swtch/rv_savectx: the R-P5 context switch,
  every `struct rv_context`/`label_t` field via the genassym `rv_context_c_*` /
  `LABEL_*` macros in `assym.h`, not `#define C_RA 0`) + `mach_locore.S`
  (rv_trap_entry: a trap prologue building a `struct regs` frame at the
  generated `regs_r_*` offsets). Both cross-assemble to EM_RISCV.
- **Partial link (`ld -r`)**: `mach_locore.o` + `mach_swtch.o` + `mach_cpu.o`
  (the R-P20 machdep slice) -> one **EM_RISCV ET_REL** `unix_riscv64.o`
  preserving the full kernel reloc set (CALL_PLT x3, PCREL_HI20/LO12 pairs,
  HI20/LO12, BRANCH/RVC_BRANCH, ADD32/SUB32/SET6/SUB6, 32_PCREL, RELAX/ALIGN)
  -- the milestone: a multi-object MD partial-link exercising exactly the
  relocs the R-P21.1 sgs backend resolves.
- **Full link** with `mach_externs.o` (rv_trap/rv_lofault/cpu_list/
  hart_online_mask stubs): `ld -Ttext=0x10000 -e rv_trap_entry` resolves EVERY
  reloc -> EM_RISCV ET_EXEC, zero relocs; disassembly shows `jal <rv_trap>`
  (CALL_PLT), the auipc/addi pcrel pair to `rv_lofault`, and `jal <rv_swtch>`
  all resolved.
- **CRIB**: the ASSYM/OFFSET mechanism from the R-P20 genassym unit + illumos
  `uts` genassym + BSD `sys/arch/riscv/riscv/genassym.cf`; the switch/trap-save
  bodies from the R-P3/R-P5 MD tree (RISC-V LP64 conv, NetBSD `cpu_switch.S`
  idiom); the "MD .S references C layout only through <assym.h>" discipline is
  standard illumos kernel build practice.

### `/root/riscv-port/rp21/` contents
`sgs/{_libld_shim.h, reloc_riscv.h, riscv_pcrel_htab.h, machrel.riscv.c,
machrel_riscv_insn.c (from rp20), machrel_selftest}`;
`libgcc_s/{libgcc_s.so.1, libgcc_s.so->.1, libgcc_s.ver, README.md}`;
`hello/{hello.o, crt{1,i,n}.o, hello.dyn}`;
`uts/riscv64/{genassym.c, genassym.sh, genassym.s, assym.h, mach_swtch.S,
mach_locore.S, mach_cpu.c, mach_externs.c, *.o, unix_riscv64.o,
unix_riscv64.exec, sys/*.h}`; `rp21-milestone-check.sh` (all 3, re-runnable).
Shared-capable linker installed as `toolchain/bin/riscv64-unknown-elf-ld-shared`.
Repo copies under `src/riscv/{sgs/{_libld_shim.h, reloc_riscv.h,
riscv_pcrel_htab.h, machrel.riscv.c}, libgcc_s/{libgcc_s.ver, README.md},
uts/riscv64/{mach_swtch.S, mach_locore.S, mach_externs.c, assym.h}}` +
`src/riscv/rp21-milestone-check.sh`.

### Next: R-P22
1. **Build the sgs backend inside a real (or stubbed) sgs tree** so `ld` selects
   `ld_targ_riscv` for EM_RISCV: drop `machrel.riscv.c` + the mach descriptor
   (`ld_targ_riscv`, R-P19.3) into `usr/src/cmd/sgs/libld/common/` against the
   true `_libld.h`, add the EM_RISCV case to `ld_config_target()`, and link a
   riscv64 object with the illumos `ld` itself (not GNU ld) -- then retire the
   GNU-ld crutch.
2. **libc bring-up toward a self-hosting userland**: a minimal riscv64-solaris
   libc (crt + the syscalls the R-P8/R-P9 userland used) so the dynamic hello
   actually RUNS under `ld.so.1` (needs the riscv64 `ld.so.1` MD reloc engine
   -- the R-P16 krtld doreloc/kobj_reloc already covers the reloc math).
3. **Grow the MD partial-link toward a linkable `unix`**: add more genassym-
   driven units (real locore + trap + swtch + a machdep + the R-P17-20 headers)
   and link a larger EM_RISCV `unix.o` set in the gate `uts/riscv64` layout.

---

## R-P20 — sgs %pcrel pairing + GOT/PLT alloc, csu crt + first hello ELF, larger uts unit

Substrate: fred v3 (root@52.88.62.49). The R-P19 install-time gcc `bin/` wrapper
was gone (only binutils symlinks + libgcc.a survived), but the R-P18/19 build
tree `build/gcc-sol-cfg3/gcc/xgcc` is intact and reports
`riscv64-unknown-solaris2.11`; drove it directly as `xgcc -B<gcc>` (no rebuild).
Crib source on host: binutils-2.44 `bfd/elfnn-riscv.c` (pcrel pairing + PLT/GOT
layout) and the R-P1..R-P16 illumos riscv64 MD tree (struct layouts for
genassym). Proof: `rp20/rp20-milestone-check.sh` (all 3).

### R-P20.1 sgs %pcrel_hi/%pcrel_lo pairing + GOT/PLT allocation — DONE
- `rp20/sgs/machrel_riscv_pcrel.c`: the RISC-V PC-relative address PAIRING.
  RISC-V splits a 32-bit pcrel address across `auipc %pcrel_hi20` and a
  following `addi/load %pcrel_lo12` that references the HI *by label* -- the
  LO's reloc symbol resolves to the AUIPC address, not the target, so its low
  12 bits must come from the SAME (S+A-P) value the HI computed. Exact binutils
  two-pass model: (1) `ld_riscv_record_pcrel_hi()` computes value=S+A-addr,
  applies the HI immediate, records `{HI_addr -> value}`; (2)
  `ld_riscv_record_pcrel_lo()` defers the LO, remembering the HI address (its
  resolved symbol value); (3) `ld_riscv_resolve_pcrel_lo()` finds the HI by that
  address and splices the HI's stored value into the LO immediate, so
  HI(rounded high20)+LO(sext low12)==S+A-P. Diagnostics (missing HI, addend on
  GOT_HI20, addend-crosses-high-part overflow) match binutils. Self-test: S-PC
  reconstruct across auipc/addi, LO resolved from recorded HI, missing-HI
  rejected, and byte-identical GNU-ld bytes `0x00001797`/`0x0a878793` for the
  R-P19.3 pair -- PASS.
- `rp20/sgs/machrel_riscv_gotplt.c`: GOT/PLT slot allocation for CALL_PLT /
  GOT_HI20 / JUMP_SLOT. RV64 layout from binutils (GOT_ENTRY_SIZE=8,
  PLT_HEADER_SIZE=32, PLT_ENTRY_SIZE=16, GOTPLT_HEADER_SIZE=16); idempotent
  per-symbol slots, header-biased offsets, `.plt/.got.plt/.got` sizing, and
  emitters for the 4-insn PLT entry stub (auipc t3 / ld t3 / jalr t1,t3 / nop)
  + the 8-insn header trampoline. Self-test: idempotent+monotonic slots,
  binutils sizes/offsets, PLT stub decodes + its pcrel hi/lo reconstructs the
  `.got.plt` target -- PASS.
- **CRIB**: `riscv_pcrel_{hi,lo}_reloc` structs + record/resolve algorithm from
  binutils-2.44 `bfd/elfnn-riscv.c` (~1962-2170, 2877-2930); PLT/GOT layout +
  `riscv_make_plt_{header,entry}` (~296-410). Gate `Rel_desc`/`Target`/htab
  wiring documented inline (this uses an O(n) list, marked as the upgrade
  point).

### R-P20.2 csu crt (crt1/crti/crtn) + first riscv64-solaris hello ELF — DONE
- `rp20/csu/{crt1,crti,crtn}.s`: riscv64 C runtime. `crt1.s` `_start`:
  terminate the frame chain, set `gp` from `__global_pointer$` (relaxation
  off), pull argc/argv/envp into a0/a1/a2 per psABI, 16-align sp, then
  `call _init; call main`, then `exit(2)` (SYS_exit=1 via `ecall`) with main's
  return -- freestanding, no libc. `crti/crtn` open/close `_init`/`_fini` (SVR4
  csu split; riscv64 addi sp,-16 / sd ra,8(sp) frame). All EM_RISCV.
- `rp20/hello/hello.c` -> `ld -static -e _start` with crt1/crti/hello/crtn +
  libgcc.a -> valid **EM_RISCV ELF64 ET_EXEC** entry `_start`, ZERO relocs.
  `_start` disassembles to gp-setup + jal _init + jal main + li a7,1;ecall; the
  gp-relative auipc/addi pcrel pair to `__global_pointer$` resolved -- the
  first riscv64-solaris userland executable.
- **full libgcc_s.so.1: NOT this phase (R-P21 long pole).** R-P17/18 gcc was
  `--disable-shared` (`enable_shared = no` in the libgcc Makefile), so
  `all-target-libgcc` only builds static `libgcc.a` (138 members, present).
  `libgcc_s.so.1` needs `--enable-shared` reconfigure + full rebuild AND a real
  libc (Solaris `SHLIB_LINK` pulls `-lc`), neither of which exists yet.
  Documented as the R-P21 gate; static libgcc.a suffices for the linkable-exe
  milestone.
- **CRIB**: initial-stack layout + a0=argc/a1=argv/a2=envp from RISC-V psABI
  "Program Startup" + glibc/newlib Scrt1; `.option norelax; lla gp,
  __global_pointer$` from psABI + gcc riscv startup; crt open/close split +
  "call _init; call main; exit" from illumos csu (amd64/aarch64 crt1.s);
  SYS_exit=1 + `ecall` from the illumos syscall convention.

### R-P20.3 larger uts unit — genassym + machdep cpu-init — DONE
- `rp20/uts/riscv64/genassym.c` + `genassym.sh`: the illumos riscv64 kernel
  asm-offset generator. MD .S (locore/trap/swtch/setjmp) reach into C structs
  by numeric offset (`sd ra,C_RA(a0)`, TF_* frame, LABEL_* in label_t), today
  hand-maintained + `_Static_assert`-guarded. genassym.c compiles the ACTUAL
  `struct regs`/`struct rv_context`/`label_t` and, via inline-asm
  `ASSYM(name, offsetof(...))` in a `.assym` section, emits the compiler's real
  offsets; `genassym.sh` extracts `assym.h`. Cross-compiled to **EM_RISCV**
  ET_REL. Generated offsets EXACTLY match the hand-maintained
  swtch.S/asm_frame.h/machtypes.h (regs_r_ra=0, regs_r_sp=8, rv_context_c_ra=0,
  c_satp=120, c_lofault=128, LABEL_SP=8, regs_SIZE=280) -- genassym validates
  (and would replace) the hand offsets. Freestanding pipeline (compiler folds
  offsetof; no runnable libc) -- the classic gate/BSD genassym trick.
- `rp20/uts/riscv64/mach_cpu.c` (+ `externs.c`): a machdep slice (per-cpu
  online, install stvec, account a switch, a dispatch table) exercising the
  load-bearing reloc set: **R_RISCV_CALL_PLT** (x2 cross-TU calls),
  **PCREL_HI20+PCREL_LO12** pairs + HI20/LO12 absolute pairs (external data via
  auipc/addi), BRANCH/RVC_BRANCH, ADD32/SUB32/SET6/SUB6. Cross-compiled to
  EM_RISCV; cross-`ld -Ttext=0x10000 -e cpu_online` with the externs stub
  resolves EVERY reloc -> EM_RISCV ET_EXEC, zero relocs; the CALL_PLT to
  `rv_swtch` and the auipc/addi pcrel pairs to
  `cpu_list`/`trap_entry`/`hart_online_mask` all disassemble resolved. The
  R-P19 mod stub grown to a multi-TU unit that links toward the kernel and
  exercises exactly the relocs R-P20.1 resolves.
- **CRIB**: the OFFSET/SIZE/ASSYM mechanism from illumos uts genassym.c +
  sys/assym.h and BSD `sys/arch/riscv/riscv/genassym.cf`; struct layouts from
  the R-P1..R-P16 MD tree (`regs.h`, `proc.c`, `sys/machtypes.h`); the
  per-cpu/stvec shape from that MD tree + the RISC-V privileged spec.

### `/root/riscv-port/rp20/` contents
`sgs/{machrel_riscv_pcrel.c, machrel_riscv_gotplt.c, machrel_riscv_insn.c
(from rp19), pcrel_selftest, gotplt_selftest}`; `csu/{crt1,crti,crtn}.s + .o`;
`hello/{hello.c, hello.o, hello.elf}`; `uts/riscv64/{genassym.c, genassym.sh,
genassym.{s,o}, assym.h, mach_cpu.c, externs.c, mach_cpu.o, externs.o,
kunit_riscv64.{o,exec}, mod_riscv64.c, sys/*.h}`; `rp20-milestone-check.sh`
(all 3, re-runnable). Crt objects also installed into
`sysroot-riscv-sol/usr/lib/{crt1,crti,crtn}.o`. Repo copies under
`src/riscv/{sgs,csu,hello,uts/riscv64}/` + `src/riscv/rp20-milestone-check.sh`.

### Next: R-P21
1. **Fold the sgs pieces into a real gate `machrel.riscv.c`** against the true
   `usr/src/cmd/sgs/include/_libld.h` `Rel_desc`/`Target` types: swap the
   standalone shims for the gate structs, wire the pcrel-pairing hash (keyed by
   `Rel_desc->rel_roffset`) + GOT/PLT allocator into `ld_do_activerelocs` /
   `ld_allocate_got` / `ld_perform_outreloc`, and build inside a real (or
   stubbed) sgs tree so `ld` selects `ld_targ_riscv` for EM_RISCV.
2. **Shared libgcc_s.so.1 (the R-P20 long pole)**: bring up a minimal
   riscv64-solaris libc (or a stub `-lc` with the symbols `SHLIB_LINK` needs),
   reconfigure gcc `--enable-shared`, complete `all-target-libgcc` to produce
   `libgcc_s.so.1`; then link a *dynamic* hello.
3. **Grow the uts unit toward a linkable `unix`/`genunix`**: replace `assym.h`'s
   hand offsets in the real `.S` files with genassym output, then cross-compile
   + link a bigger MD set (locore + swtch + trap + a machdep) as an EM_RISCV
   kernel image in the gate layout.

---

## R-P19 — riscv64-solaris toolchain finished + sgs MACH descriptor + first uts object

Substrate: fred v3 (root@52.88.62.49), the R-P18 all-gcc-solaris build tree
(`/root/riscv-port/build/gcc-sol-cfg3/`), the R-P17 `riscv64-unknown-elf`
binutils 2.44, and binutils-2.44 `bfd/` as the reloc-math crib source.

### R-P19.1 all-gcc-solaris finished + riscv64-solaris libgcc.a — DONE
- **Long-pole `make all-gcc` (riscv64-unknown-solaris2.11) finished.** Two real
  build blockers found + fixed in `gcc/config/riscv/sol2.h`
  (`rp19/config-riscv-sol2.h`, appended to R-P18's header):
  (a) the generic `config/sol2.cc` `solaris_output_init_fini()` emits
  `.init/.fini` entries via `ASM_OUTPUT_CALL`, which the RISC-V ELF backend
  never defines (only i386/sparc sol2.h do) — added an `ASM_OUTPUT_CALL` for
  RISC-V (`\tcall\t` + `assemble_name`, the `call` pseudo, R_RISCV_CALL_PLT);
  (b) `#undef MULTILIB_DEFAULTS` so the common sol2.h `{ "m64" }` wins over
  riscv/riscv.h without a redefinition warning. `cc1` links, `make all-gcc`
  exits 0, `-dumpmachine` = `riscv64-unknown-solaris2.11`, GCC 14.3.0.
- **Minimal sysroot + libgcc bootstrap** (`rp19/rp19-sysroot-libgcc.sh`,
  idempotent). The solaris triple had no in-tree binutils, so the build-tree
  `gcc/as` + `gcc/collect-ld` wrappers had empty `ORIGINAL_*_FOR_TARGET` and
  ran `exec "" -march=...` — pointed them at the R-P17 `riscv64-unknown-elf`
  as/ld (psABI is identical; only the OS triple differs) and published
  `riscv64-unknown-solaris2.11-{ar,ranlib,...}` on PATH. Added four BOOTSTRAP
  stub headers (`sys/mman.h`, `sys/types.h`, `unistd.h`, `stdlib.h`) the
  Solaris `enable-execute-stack-mprotect.c` references, plus the minimal
  `/usr/include/sys/{isa_defs,machtypes,elf_riscv}.h` sysroot (the R-P17 MD
  headers). `gmake libgcc.a` builds the 138 compiler-runtime objects (soft
  int/float, clz/ctz, muldi3, ...) — skips the Solaris gmon/profiling extra
  that needs full libc. Installed at
  `toolchain-sol/lib/gcc/riscv64-unknown-solaris2.11/14.3.0/libgcc.a` (5.6 MB,
  138 EM_RISCV members). PROOF: `rp19/rp19-toolchain-check.sh`.
- **CRIB**: `ASM_OUTPUT_CALL` shape from gcc `i386/sol2.h` + `sparc/sol2.h`,
  adapted to the RISC-V `call` mnemonic. The as/ld-wrapper + PATH bootstrap is
  standard cross-gcc practice (a target reusing another's binutils for an
  identical psABI).

### R-P19.2 sgs libld MACH descriptor + RISC-V instruction-field reloc encoders — DONE
- `rp19/machrel_riscv_insn.c`: the `FLG_RE_INSREL` encoder `ld_reloc_riscv_insn()`
  — splices a computed value into the U/I/S/B/J immediate slots of a 32-bit
  instruction (and CB/CJ/CI slots of a 16-bit RVC instruction) exactly as
  binutils `perform_relocation()` does: ENCODE the value into the field layout,
  read-modify-write `word = (word & ~dst_mask) | (enc & dst_mask)`, LE store.
  Handles HI20/LO12_I/LO12_S (+ TPREL/PCREL/GOT/TLS HI/LO variants),
  CALL/CALL_PLT (auipc U-part + jalr I-part, 64-bit splice), JAL, BRANCH,
  RVC_BRANCH/JUMP/LUI. HI/LO split via `RISCV_CONST_HIGH_PART`. Self-test
  round-trips every field type against the binutils EXTRACT macros — PASS.
- `rp19/machrel_riscv_dispatch.c`: `ld_do_reloc_riscv()` — the reloc-apply core
  the MACH descriptor + krtld `do_reloc()` reduce to. Consults the R-P18
  classification table (`sgs_reloc_table_riscv[]`), computes the RISC-V
  Calculation (S+A, or S+A-P for PC-relative), and routes INSREL types to the
  encoder, flat data types to a byte store, and link-time markers to a no-op.
  ADD/SUB/SET/SUB6 are correctly in-place modify (not overwrite), cribbed from
  binutils `riscv_elf_add_sub_reloc`. Self-test: flat64 / 32_PCREL / HI20+LO12
  pair / ADD32+SUB32 / RELAX no-op — PASS.
- `rp19/machtarget_riscv.c`: `ld_targ_riscv` — the EM_RISCV `Target` descriptor
  skeleton (Target_mach: EM_RISCV/ELFCLASS64/ELFDATA2LSB/pagesize; the M_R_*
  dynamic reloc identities: RELATIVE=3 / JUMP_SLOT=5 / COPY=4 / TLS_*64;
  null/fill func bytes) with `t_mr` wiring the classification table +
  `ld_do_reloc_riscv`. This is the record `ld_config_target()` returns for
  `e_machine == EM_RISCV`. Self-test: descriptor identity + reloc applied
  THROUGH the `t_mr.mr_do_reloc` pointer — PASS.
- **BYTE-IDENTICAL to GNU ld**: on the R-P19.3 object the INSREL encoder
  produces exactly `auipc a5,0x1 = 0x00001797` + `addi a5,a5,168 = 0x0a878793`
  for the `riscv64_boot_label` PCREL_HI20/LO12 pair — the same bytes GNU ld
  emitted, verified in `rp19-milestone-check.sh` R-P19.3d.
- **CRIB**: `ENCODE_{U,I,S,B,J}TYPE_IMM` / `ENCODE_C{B,J,I}TYPE_IMM` / `RV_X` /
  `RISCV_CONST_HIGH_PART` from binutils-2.44 `include/opcode/riscv.h`; the
  per-reloc encode dispatch + CALL `U | I<<32` packing + the RMW store +
  get/put_insn 16/32/64 LE model from `bfd/elfnn-riscv.c perform_relocation()`;
  `dst_mask == ENCODE_xTYPE_IMM(-1U)` from `bfd/elfxx-riscv.c` howto_table[];
  ADD/SUB math from `riscv_elf_add_sub_reloc`. The Target/Rel_entry/FLG_RE_*
  shape follows the illumos sgs machrel.<arch>.c convention.

### R-P19.3 first illumos uts/riscv64 EM_RISCV object — DONE
- `rp19/uts/riscv64/` gate-layout tree: `mod_riscv64.c` (a trivial loadable
  module: a `label_t` save-area store, `_init/_fini/_info`) compiled `_KERNEL`
  / freestanding against the R-P17 illumos riscv64 MD headers spliced into
  `sys/{isa_defs,machtypes,elf_riscv,feature_tests}.h`. Compile-time asserts
  pin the ISA contract (LP64, `_LITTLE_ENDIAN`, `_ALIGNMENT_REQUIRED`,
  `_MAX_ALIGNMENT==16`, `label_t == 16 XLEN slots`) so a wrong data model fails
  the BUILD.
- Built by BOTH the R-P17 `riscv64-unknown-elf` gcc AND the new
  `riscv64-unknown-solaris2.11` gcc → a valid **EM_RISCV (243) ELF64-LSB
  ET_REL** illumos kernel object. It emits exactly the reloc set this port must
  resolve: `R_RISCV_CALL_PLT(19)`, `R_RISCV_PCREL_HI20(23)`,
  `R_RISCV_PCREL_LO12_I(24)`, `R_RISCV_RELAX(51)`, plus ADD32/SUB32/SET6/SET8/
  SUB6/32_PCREL — all in-bounds in the R-P18 doreloc table, all classified +
  applied by the R-P19.2 pieces.
- **Link-apply proof**: cross-`ld -Ttext=0x80000000 -e _init` resolves every
  reloc → an EM_RISCV ET_EXEC entry 0x80000062, zero relocs remaining; the
  applied auipc/addi disassembles to `0x800010b8 <riscv64_boot_label>`.
- **CRIB**: the MD headers are the R-P17 BSD-cribbed set (NetBSD
  `sys/arch/riscv` psABI/register roles); the modlinkage/`_init/_fini/_info`
  shape is the illumos kmod convention.

### `/root/riscv-port/rp19/` contents
`machrel_riscv_insn.c`, `machrel_riscv_dispatch.c`, `machtarget_riscv.c`,
`machrel.riscv.c` + `reloc_riscv_table.h` (from R-P18), `config-riscv-sol2.h`
(updated), `rp19-milestone-check.sh` (sgs + uts proofs), `rp19-toolchain-check.sh`
(gcc + libgcc proofs), `rp19-sysroot-libgcc.sh` (idempotent bootstrap),
`uts/riscv64/{mod_riscv64.c, mod_riscv64.o, mod_riscv64.linked, sys/*.h}`,
the self-test binaries. Host toolchain:
`toolchain-sol/` (riscv64-unknown-solaris2.11 gcc + libgcc.a + bin symlinks),
`sysroot-riscv-sol/usr/include/sys/*.h`. Repo copies under `src/riscv/sgs/`,
`src/riscv/gcc/`, `src/riscv/uts/riscv64/`, `src/riscv/rp19-*.sh`.

### Next: R-P20
1. Fold the standalone `machrel_riscv_insn.c` + `machrel_riscv_dispatch.c` +
   `machtarget_riscv.c` into a real `usr/src/cmd/sgs/libld/common/machrel.riscv.c`
   against the gate `_libld.h` `Rel_desc`/`Target` types, and add the
   `%pcrel_hi`/`%pcrel_lo` pairing + GOT/PLT slot allocation the classification
   flags mark (the scaffolding this bootstrap deferred).
2. Grow the bootstrap sysroot toward a real one: build illumos csu
   (crt1/crti/crtn) for riscv64 and the minimal libc headers so
   `all-target-libgcc` completes fully (incl. the Solaris gmon/unwind extras)
   and shared objects link.
3. Cross-compile a larger uts/riscv64 unit (locore/genassym or a real driver)
   through the retargeted toolchain + the folded sgs machrel, toward a linkable
   `unix`/`genunix` in the gate layout.

---

## R-P18 — the R1 hard part: reloc coverage + the solaris triple

Three concrete sub-tasks, all landed with re-runnable proofs. Substrate: fred
v3 (root@52.88.62.49), the R-P17 toolchain (`riscv64-unknown-elf` binutils
2.44 + gcc 14.3.0) + the 58-entry `sys/elf_riscv.h`.

### R-P18.1 krtld/sgs `doreloc.c` reloc_table 12 -> 58 — DONE
- `src/riscv/uts/krtld/doreloc.c`: `reloc_table[R_RISCV_NUM]` grown from the
  12 dynamic relocs (stopped at `R_RISCV_TLS_TPREL64`) to the FULL 58-entry
  psABI table (0..57). Each entry carries `re_fsize` + `FLG_RE_*`. Data relocs
  (32/64/RELATIVE/JUMP_SLOT, TLS *64, ADD/SUB/SET 8..64, SUB6, 32_PCREL) are
  flat byte stores (real sizes, added to the `do_reloc()` value switch);
  RISC-V instruction-field relocs (BRANCH/JAL/CALL/CALL_PLT/*_HI20/*_LO12_*/
  RVC_*) + link-time markers (RELAX/ALIGN/*_ADD/GNU_VT*) are `FLG_RE_NOTSUP`
  size 0 (handled by the link-editor's instruction-field path, never the flat
  do_reloc byte writer).
- `src/riscv/uts/krtld/elf_riscv.h`: `R_RISCV_NUM` 12 -> 58 + the full type
  defines (BRANCH(16)..32_PCREL(57)), so `reloc_table[rtype]` is in-bounds for
  the CALL_PLT(19)/HI20(26)/LO12_I(27)/RELAX(51) that gcc actually emits (the
  old 12-entry table OOB-read on all four).
- **CRIB**: sizes/pc_relative/special-fn per reloc from binutils-2.44
  `bfd/elfxx-riscv.c` howto_table[] (extracted on the node); reloc numbers +
  the NOTREL/NOTSUP split convention from the existing illumos 12-entry table +
  the RISC-V psABI "Calculation" column.

### R-P18.2 gcc `riscv64-unknown-solaris2.11` triple — DONE (config + configures)
- `config.sub`: NO CHANGE — stock gcc-14.3.0 already canonicalizes
  `riscv64-unknown-solaris2.11` cleanly (proven, rc=0): both `riscv64` and
  `solaris2` are known, the combination validates.
- `gcc/config.gcc`: added the `riscv*-*-solaris2* | riscv*-*-illumos2*)` stanza
  (before `loongarch*-*-linux*`), wiring the sol2 tm_file chain
  `elfos.h ${cpu_type}/sysv4.h riscv/elf.h riscv/sol2.h ${cpu_type}/sol2.h`,
  `tmake_file += riscv/t-riscv t-sol2 riscv/t-sol2`,
  `native_system_header_dir=/usr/include`, `with_tls=trad`, forced
  `.init_array`. Delta documented in `rp18/config.gcc.riscv-solaris.md`.
- `gcc/config/riscv/sol2.h` (`rp18/config-riscv-sol2.h`): arch-solaris tm
  header — `TARGET_SUN_TLS`, undef the Newlib LIB/STARTFILE/ENDFILE from
  riscv/elf.h (the common sol2.h supplies the Solaris crt1/crti/crtn model),
  `elf64lriscv` ld emulation, ARCH64_SUBDIR "64".
- `gcc/config/riscv/t-sol2`: 64-bit-only, no-multilib stub.
- **PROOF** (`rp18/gcc-triple-proof.txt`): `configure
  --target=riscv64-unknown-solaris2.11` rc=0 AND `make configure-gcc` rc=0 —
  the gcc subdir's resolved tm_file chain contains exactly
  `elfos.h -> riscv/sysv4.h -> riscv/elf.h -> riscv/sol2.h -> config/sol2.h`,
  and `configargs.h` records the solaris triple. config.gcc fully accepts +
  elaborates the target.
- **BUILD FIXES FOUND + APPLIED** (two config.gcc corrections):
  (a) first `all-gcc` failed at `s-gtype` with "No rule to make target
  config/riscv/sysv4.h" -- `${sol2_tm_file_head}` is `elfos.h
  ${cpu_type}/sysv4.h` and riscv ships no `config/riscv/sysv4.h`; fixed by
  naming `elfos.h` directly (riscv/elf.h + elfos.h cover the SVR4/ELF base).
  (b) second `all-gcc` failed at `s-gtype` with `config/riscv/sol2.h specified
  more than once` -- `${sol2_tm_file_tail}` is `${cpu_type}/sol2.h sol2.h`, so
  the stanza's explicit `riscv/sol2.h` was a duplicate; dropped it. Final
  stanza tm_file: `elfos.h ${tm_file} riscv/elf.h ${sol2_tm_file_tail}`.
  `build/gcc-sol-cfg3/` clears configure + s-gtype with 0 errors and is
  compiling the riscv backend / cc1.
- **LONG POLE** (running, not gating this phase): the full `make all-gcc`
  rebuild-as-solaris (log `logs/gcc-sol-allgcc3.log`). libgcc needs a Solaris
  sysroot (crt + /usr/include) that does not exist yet; `all-gcc` (cc1 +
  prereqs) is compiling. R-P19 finishes libgcc once the first crt/headers exist.
- **CRIB**: the stanza shape from gcc-14.3.0's own `riscv*-*-freebsd*` /
  `riscv*-*-linux*` + the `x86_64-*-solaris2*` / `sparc*-*-solaris2*` arch
  stanzas; `riscv/sol2.h` from the richlowe/gcc arm64-gate `aarch64/sol2.h`
  pattern (the existing solnix aarch64-unknown-solaris2.11 target) + gcc
  `i386/sol2.h`.

### R-P18.3 Solaris ld (sgs) `R_RISCV_*` — DONE
- `src/riscv/sgs/machrel.riscv.c` + `reloc_riscv_table.h`: the standalone
  EM_RISCV sgs/libld reloc CLASSIFICATION table (58 entries) — the sgs-side
  companion to doreloc's byte-store table. Per reloc: GOT / PLT / PC-relative /
  TLS / instruction-field / link-time-marker flags + container size, so libld
  routes CALL_PLT (PLT), GOT_HI20 (GOT), PCREL_* (pcrel instruction field),
  RELAX (link-time marker) correctly instead of faulting on unclassified types.
  In the gate this becomes `usr/src/cmd/sgs/libld/common/machrel.riscv.c`.
- `src/riscv/uts/krtld/kobj_convrelstr.c`: `conv_reloc_RISCV_type()` extended
  from 6 names to all 58 — the reloc-name mapping sgs `ld` + krtld use for
  diagnostics. Before, CALL_PLT/HI20/LO12_I/RELAX printed as bare integers.
- **CRIB**: reloc GOT/PLT/PCREL/TLS/instruction-field classification from
  binutils-2.44 `bfd/elfxx-riscv.c` (pc_relative + special_function) +
  `bfd/elfnn-riscv.c` relocate_section dispatch + the RISC-V psABI; names from
  binutils/psABI; the `Rel_entry`/`FLG_RE_*` shape from the illumos sgs
  convention.

### R-P18.4 end-to-end reloc proof — PASS (`rp18/rp18-reloc-check.sh`, re-runnable)
Compiles C on the R-P17 cross gcc; it emits `R_RISCV_CALL_PLT(19)`,
`R_RISCV_HI20(26)`, `R_RISCV_LO12_I(27)`, `R_RISCV_RELAX(51)` (all beyond the
old 12). The script then proves each is (1) in-bounds in the 58-entry doreloc
table [old table OOB], (2) named by `conv_reloc_RISCV_type()` [old stub: 3 of 4
bare numbers], (3) classified by the sgs machrel table (CALL_PLT=PLT,
GOT_HI20=GOT, PCREL_HI20=pcrel, RELAX=link-time marker). `ALL R-P18 RELOC
PROOFS PASSED`.

### `/root/riscv-port/rp18/` contents
`doreloc.c`, `elf_riscv.h` (krtld, R_RISCV_NUM=58), `kobj_convrelstr.c`,
`machrel.riscv.c`, `reloc_riscv_table.h`, `config-riscv-sol2.h`,
`config.gcc.riscv-solaris.md`, `gcc-triple-proof.txt`, `rp18-reloc-check.sh`
(+ `verify.c`/`verify_names.c`/`verify_sgs.c`). Repo copies under
`src/riscv/uts/krtld/`, `src/riscv/sgs/`, `src/riscv/gcc/`.

### Next: R-P19
1. Finish the `make all-gcc` solaris-triple compiler build (log
   `logs/gcc-sol-allgcc.log`); then bootstrap a minimal riscv64 Solaris sysroot
   (crt1/crti/crtn + a stub `/usr/include`) so `make all-target-libgcc`
   completes and `-dumpmachine` = `riscv64-unknown-solaris2.11`.
2. Wire `machrel.riscv.c` + `reloc_riscv_table.h` into a real
   `usr/src/cmd/sgs/libld` mach descriptor (EM_RISCV dispatch) + implement the
   RISC-V instruction-field relocation encoders (B/J/U/I/S-type + RVC + the
   PCREL_HI20/LO12 pair fixup) that the `FLG_RE_INSREL` entries defer to.
3. Splice `sys/isa_defs.h` + `sys/machtypes.h` into a real `uts/riscv64` gate
   tree and cross-compile a first illumos-flavored riscv64 object with the
   solaris triple, linking it through the extended reloc handling.

---

## R-P17 and earlier (history)

## 1. Cross toolchain — BINUTILS + GCC stage-1 BUILT; EM_RISCV + reloc-coverage PROVEN.

### binutils 2.44 `--target=riscv64-unknown-elf` — DONE (~4 min)
- Source: ftp.gnu.org/gnu/binutils/binutils-2.44.tar.xz, sha256
  `ce2017e059d63e67ddb9240e9d4ec49c2893605035cd60e92ad53177f4377237` (verified).
- Built with the native OI gcc 14.3.0, `--disable-nls --disable-werror
  --disable-gdb --disable-sim --with-system-zlib`.
- Installed at `/root/riscv-port/toolchain/bin/riscv64-unknown-elf-{as,ld,
  readelf,objdump,objcopy,nm,ar,ranlib,strip,...}` (16 tools).

### EM_RISCV proof — PASS (the R1 milestone's binutils half)
`/root/riscv-port/psabi-reloc-check.sh` (runnable, re-runs the whole proof):
- cross-**as** `-march=rv64gc -mabi=lp64d` assembles a .o →
  `readelf -h` Machine = **RISC-V**, ELF64 LSB; raw `e_machine = 243`
  (**EM_RISCV**), confirmed independently by the host's own readelf.
- cross-**ld** links it → EXEC, Machine **RISC-V**, entry 0x80000000.
- objdump disassembles rv64gc incl. compressed insns + `ecall`.
- Result line: `PASS: cross-as + cross-ld produce EM_RISCV (243) objects`.

### gcc 14.3.0 stage-1 (`riscv64-unknown-elf`, rv64gc/lp64d) — DONE (~26 min)
- Source: ftp.gnu.org/gnu/gcc/gcc-14.3.0/gcc-14.3.0.tar.xz (xz-integrity verified;
  extracts to BASE-VER 14.3.0). `contrib/download_prerequisites` pulled
  gmp-6.2.1/mpfr-4.1.0/mpc-1.2.1/isl-0.24 (all OK).
- `--without-headers --with-newlib --enable-languages=c --disable-multilib
  --with-arch=rv64gc --with-abi=lp64d --disable-shared --disable-threads`.
- **illumos break hit + fixed** (the exact one design-riscv-port.md §2.3
  documents): gcc 14's in-tree **gettext** fails on illumos (gnulib
  `getlocalename_l` conflict). Fix applied: stripped the in-tree `gettext`
  symlink AND neutered the top-level Makefile `*-gettext` targets to no-ops
  (`--disable-nls` cross cc does not need gettext; `all-gcc`'s only direct prereq
  is `configure-gcc`). Rebuild via `rebuild-gcc.sh` then completed cleanly.
- **Installed**: `/root/riscv-port/toolchain/bin/riscv64-unknown-elf-gcc`
  (`-dumpmachine` = `riscv64-unknown-elf`, GCC 14.3.0) + `libgcc.a` built for
  `riscv64-unknown-elf/14.3.0` (the target backend compiled its own runtime =
  the backend works). Full toolchain 968 MB.
- **Reloc-coverage proof — PASS**: `psabi-reloc-check.sh` compiles C on the cross
  gcc, `objdump -dr`s the object, and asserts EVERY emitted `R_RISCV_*` is
  defined in `sys/elf_riscv.h`. Emitted (rv64gc, TLS LE): `R_RISCV_CALL_PLT,
  R_RISCV_RELAX, R_RISCV_TPREL_ADD, R_RISCV_TPREL_HI20, R_RISCV_TPREL_LO12_I,
  R_RISCV_TPREL_LO12_S` — all covered. Result: `PASS: every gcc-emitted R_RISCV_*
  is defined in sys/elf_riscv.h` / `ALL CHECKS PASSED`. Log:
  `artifacts/riscv-port/rp17/proof.log`.

---

## 2. illumos riscv64 MD headers (BSD-cribbed) — WRITTEN + syntax-checked

New under `src/riscv/uts/sys/` (persisted to host `/root/riscv-port/portsrc/`):

| file | what | crib provenance |
|------|------|-----------------|
| `sys/elf_riscv.h` | the **COMPLETE** RISC-V ELF psABI reloc set (0..57, `R_RISCV_NUM=58`) + ELF64 PLT/GOT machine defines. Replaces the n-hys fork's 12-entry table (which real gcc output overruns). | NetBSD `sys/arch/riscv/include/elf_machdep.h` (psABI reloc numbers are OS-independent) reconciled with GNU/binutils names |
| `sys/isa_defs.h` | the riscv64 stanza for `<sys/isa_defs.h>` — LP64D, `_LITTLE_ENDIAN`, alignment set, `_CHAR_IS_SIGNED`, `_ALIGNMENT_REQUIRED=1`, no `_MULTI_DATAMODEL`. The arch-selection block the gate must grow (like the `__amd64`/`__aarch64` stanzas). | RISC-V psABI + illumos sibling-arch stanzas; endianness/elfsize cross-checked vs NetBSD elf_machdep.h |
| `sys/machtypes.h` | `lock_t`, `label_t` (setjmp save area: ra/sp/gp/tp/s0-s11 = 16 slots), NCPU/MAXCPU. | NetBSD `reg.h` register-role block (calling convention is OS-independent) |

**Why elf_riscv.h matters (empirically shown):** a `gcc -c` on this port's own
cross toolchain emits `R_RISCV_CALL_PLT(19)`, `R_RISCV_PCREL_HI20(23)`,
`R_RISCV_PCREL_LO12_I(24)`, `R_RISCV_RELAX(51)` — **none** in the n-hys
12-reloc set. The Solaris link-editor (sgs) and krtld `do_reloc()` must know the
full table; this header supplies it. Static asserts (R_RISCV_NUM==58,
CALL_PLT==19, PCREL_HI20==23, RELAX==51, JMP_SLOT alias) PASS.

Checks run + PASS on host:
- `gcc -E -D__riscv -D__riscv_xlen=64 sys/isa_defs.h` → preprocess OK.
- `gcc -fsyntax-only relchk.c` (the elf_riscv static asserts) → PASS.
- `psabi-reloc-check.sh` → EM_RISCV proof PASS (reloc-coverage SKIP until gcc).

## 3. BSD reference mirror — `src/riscv/bsd-ref/netbsd/`

Fetched NetBSD-current `sys/arch/riscv/include/{elf_machdep,reg,mcontext,frame,
asm}.h` as reference-only crib sources (not compiled, not shipped), with a
`README.md` mapping each illumos MD file to its BSD crib. **TODO (like the
pending NetBSD-drm mirror):** obtain a pinned NetBSD-current `sys/arch/riscv`
mirror as the authoritative reference; FreeBSD `sys/riscv` is the secondary
cross-check.

---

## 4. What R-P1..R-P16 already achieved (context — DONE, in the design doc)

The kernel bring-up is remarkably far along (all under QEMU virt via the
`pkgsCross.riscv64-embedded` bare-metal toolchain, sources in `src/riscv/uts/`):
- R-P2 first `unix` S-mode banner under OpenSBI; R-P3 trap+Sv39+timer; R-P4
  SMP(HSM)+cyclic clock+PLIC+high-VA hat; R-P5 page_t/kmem/callout/dispatcher;
  R-P6..R-P12 virtio+root-mount+fork/exec/wait+shell+signals+pipes+writable FS;
  R-P13 AIA(APLIC+IMSIC); R-P14/R-P15 SpaceMiT K1 board bring-up (dw-apb-uart,
  SDHCI, flashable U-Boot→OpenSBI→solnix image); R-P16 runtime board-detect
  (ONE image boots qemu-virt AND physical K1).
- R-P16-prestage imported n-hys CDDL sources (krtld reloc engine, CMO, FDT
  of_utils, FPU ctxop, EMAC template) — `src/riscv/uts/R-P16-IMPORT-MANIFEST.md`.

## 5. QEMU-virt substrate (from design-sparc-riscv-qemu.md + design-riscv-port.md)
- `qemu-system-riscv64 -machine virt` under OpenSBI is the proven boot substrate
  (R-P2..R-P16 all gate on it). The bare-metal bring-up toolchain is nixpkgs
  `pkgsCross.riscv64-embedded` (riscv64-none-elf). The NEW `riscv64-unknown-elf`
  toolchain here (built from source on the illumos host) is the seed that R1
  re-targets to `riscv64-unknown-solaris2.11` once a sysroot exists.

---

## Next phase + how to resume

**R-P18 (toolchain target retarget) — the R1 hard part still open:**
1. Add the `riscv64-unknown-solaris2.11` OS stanza to `config.gcc`/`config.sub`
   (crib the aarch64-solaris config from richlowe/gcc) — this is the real R1
   toolchain-target work; `riscv64-unknown-elf` here is the proven starting point.
2. Teach the **Solaris link-editor (sgs)** `R_RISCV_*` relocs using the full
   table in `sys/elf_riscv.h` + the n-hys `krtld/doreloc.c` reloc engine.
   CONCRETE GAP FOUND: n-hys's `reloc_table[R_RISCV_NUM]` in
   `src/riscv/uts/krtld/doreloc.c` has only the 12 dynamic relocs and STOPS at
   `R_RISCV_TLS_TPREL64`; indexing `reloc_table[rtype]` for the CALL_PLT(19) /
   PCREL_HI20(23) / RELAX(51) that gcc emits is an OUT-OF-BOUNDS read. R-P18 must
   grow that table to the full 58 entries (formulas in the BSD `nb_elf_machdep.h`
   comments) and bump the local `krtld/elf_riscv.h` `R_RISCV_NUM` from 12 to 58
   to match `sys/elf_riscv.h`.
3. Splice the `sys/isa_defs.h` riscv64 stanza + `sys/machtypes.h` into a real
   `uts/riscv64` gate tree (they compile standalone now).

**Resume the toolchain build:**
```
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
ssh root@52.88.62.49
cd /root/riscv-port
./psabi-reloc-check.sh              # re-run the EM_RISCV proof
tail -f logs/gcc-build2.log          # gcc stage-1 progress
./rebuild-gcc.sh                     # (idempotent) finish gcc if interrupted
```

## Persisted files
- Host `/root/riscv-port/`: `toolchain/` (binutils installed), `build/`,
  `src/` (binutils+gcc tarballs+trees), `logs/`, `proof/`, `portsrc/` (the MD
  headers), `bsd-ref/netbsd/` (crib sources), `build-binutils.sh`,
  `build-gcc.sh`, `rebuild-gcc.sh`, `psabi-reloc-check.sh`, this `STATUS.md`.
- Repo `src/riscv/uts/sys/{elf_riscv,isa_defs,machtypes}.h`,
  `src/riscv/bsd-ref/{README.md,netbsd/*.h}` — for the orchestrator's commit.
