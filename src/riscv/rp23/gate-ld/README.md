# R-P23.3 -- real native illumos `ld`: ldmin + the gate-integration steps

## What R-P23 delivered

`rp23/gate-ld/ldmin.c` is a MINIMAL native illumos `ld` driver that links a
REAL EM_RISCV object through the sgs backend with NO GNU ld in the reloc path:

1. opens a real `.o` (assembled by the `riscv64-unknown-solaris2.11`
   toolchain) with libelf/gelf -- the same ELF access layer `libld` uses;
2. SELECTS the EM_RISCV backend as the native ld does:
   `ld_config_target(EM_RISCV)` -> `ld_targ = ld_targ_riscv` (R-P22.1);
3. reads `.text` + its `.rela.text` + symtab, builds the `libld` `Rel_desc[]`
   active-reloc descriptors, resolves each symbol value (S), picks a link
   address;
4. drives the relocation THROUGH `ld_targ.t_mr.mr_do_activerelocs` (the
   selected backend's `ld_do_activerelocs` -> `machrel.riscv.c`);
5. writes the relocated `.text` image.

The self-check assembles the SAME source, links it with GNU ld at the SAME
address, and diffs the relocated `.text`: **byte-identical**
(`auipc a5,%pcrel_hi(target)` -> `0x00000797`, `addi a5,a5,%pcrel_lo` ->
`0x01078793`, resolving the pcrel pair to `target` at 0x80200010, exactly like
GNU ld). The illumos backend performed the link.

```
[ldmin] selected illumos backend ld_targ_riscv (m_mach=EM_RISCV) for t_pcrel.o
[ldmin] relocation driven THROUGH ld_targ.t_mr.mr_do_activerelocs, no GNU ld
  BYTE-IDENTICAL to GNU ld
```

CRIB: the "select target by e_machine, walk SHT_RELA + symtab, build Rel_desc,
run the backend's do_activerelocs" flow is illumos `usr/src/cmd/sgs/libld/
common/{libld.c,relocate.c}` + `machrel.<mach>.c`; libelf/gelf is the illumos
ELF access library; the `Rel_desc`/`Target` layout is the R-P22 sgs shims.

## Scope (honest)

ldmin is the reloc-OUTPUT pass over one section, not the whole link-editor. It
does not do: multi-section/multi-object layout, symbol resolution across
objects + libraries, GOT/PLT section synthesis into the output, dynamic-section
+ program-header generation, mapfile/versioning, or `-z` options. It proves the
part that the R-P21/22 backend owns -- the riscv64 reloc math + backend
dispatch -- runs against real toolchain output, not a synthetic image, and
matches GNU ld byte-for-byte.

## Full gate `ld` integration steps (for when the gate tree is available)

The gate `usr/src/cmd/sgs` is NOT checked out on this host. To build a REAL
`ld` ELF that links riscv64 natively:

1. Check out `usr/src/cmd/sgs` (libld, libelf, librtld, ld, ...).
2. Drop the R-P21/22 backend into `libld/common/`:
   - `machrel.riscv.c` (rename to the gate's `machrel.riscv.c`), including the
     pcrel htab (`riscv_pcrel_htab.h`) + insn splicer (`machrel_riscv_insn.c`,
     folded into `doreloc_riscv.c` alongside the krtld `doreloc.c`).
   - the `ld_targ_init_riscv()` from `target.c` next to `ld_targ_init_x86_64()`
     / `ld_targ_init_sparc()`; delete the shims (`_libld_shim.h`,
     `target_shim.h`, `reloc_riscv.h`) -- the real gate `_libld.h` +
     `sys/elf_riscv.h` (already in `uts/common/sys`) supply those types.
3. Add `case EM_RISCV: ld_targ_init_riscv(); break;` to the gate's
   `ld_config_target()` (`libld/common/libld.c`) and the ELFCLASS64 machine
   table.
4. Add `libld/riscv64/` (the per-class Makefile that builds machrel.riscv.c +
   doreloc_riscv.c into the class-specific `libld`), modeled on
   `libld/amd64/`.
5. Build sgs (`dmake install` in `usr/src/cmd/sgs`); the resulting `ld` links
   an EM_RISCV `.o` via `machrel.riscv.c`, and `crle`/`ld.so.1` gain riscv64.
6. Retire the GNU-ld crutch entirely: the kernel `unix` (R-P23.1) + the static
   hello (R-P22.2b) then link with the native `ld`, not the R-P17 binutils ld.

The R-P22.1 `target.c` + this ldmin driver already exercise steps 2-3 at the
selection + reloc-dispatch level; step 4-6 are the gate-tree build mechanics.
