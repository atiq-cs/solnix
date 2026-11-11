# sparcv9 memset_s: the missing relocation (2026-11-11, sv9mz2)

On SPARC, `memset_s(3C)` jumps to the link-time address of memset's PLT entry, so every libsodium signature check crashes
(nix verify, substitution, cache-submit's is_pub). The relocation is dropped by illumos ld, not by gcc. This happens in OI's
/lib/sparcv9/libc.so.1 and in our proto slice `r3hv3zc8…-libc`.

## Mechanism
- `usr/src/lib/libc/port/gen/memset_s.c`: `static void *(*const volatile __memset_vp)(...) = (memset);`. gcc emits
  `R_SPARC_64 .rela.data.rel memset`.
- On sparc, memset is a symbol-capabilities function (libc links the `capabilities/sun4u*/sun4v*` symcap.o objects).
- `libld/common/relocate.c:1668` (ld_process_sym_reloc) sends every non-local reference to a capabilities FUNC through
  `ld_reloc_plt()`. In a shared object that emits a RELATIVE only for R_SPARC_PLT32/PLT64 (relocate.c:994, IS_ADD_RELATIVE).
  Anything else goes through `ld_add_actrel()`, and `ld_do_activerelocs()` writes `ld_calc_plt_addr()` (machrel.sparc.c:1183),
  the link-time PLT address, with no output relocation.
- The ld bug is not SPARC-specific. Measured on amd64 too: the same model crashes the same way. x86 libc is safe only
  because it has no symbol capabilities.

## Files
| file | what |
|---|---|
| `libld-capfunc-absreloc.diff` | Fix B (ld): in a shared object, only a PC-relative reference to a capabilities function takes the PLT path. An absolute one becomes a symbolic R_SPARC_64/32 / R_AMD64_64, and ld.so.1's cap_match() binds it to the best instance. |
| `libc-memset_s-wrapper.diff` | Fix A (libc): point `__memset_vp` at a local wrapper that calls memset. Correct with the unpatched ld. |
| `plt-noreloc-scan.py` | Finds a word in a writable section that equals a PLT entry's address and has no relocation. Exits 1 on a finding. |

The repro scripts, outputs and A/B are banked at floki /scratch/solnix/sv9mz/evidence/ (SHA256SUMS). The upstream draft is
floki /tmp/solnix-reports-for-maintainer/20261111-illumos-sparc-memset_s-reloc.md.

## Measured (zone lixu: OI 31d3d510d0, ld 5.11-1.1790; and dixi x86)
- Model: a capabilities `myset` and a `static const volatile` pointer to it, in a .so.
  - System ld, sparcv9: no relocation at the pointer, Memory fault rc 267.
  - System ld, -m32: the pointer is a link-time address inside the executable.
  - System ld, amd64: the same fault, rc 267.
  - Control without capabilities: R_SPARC_64 / R_AMD64_64, rc 0.
- libld.so.4 hand-built from OI 31d3d510, stock and patched, run with `LD_ALTEXEC` (the stock one is the rebuild control):
  - The stock build matches the system ld (relocations and .dynsym, 5 variants).
  - Patched, all capability variants (-Bdirect, no -Bdirect, protected scope, -m32): R_SPARC_64/32 and rc 0. The pointer
    reaches the sun4u capability instance.
  - Without capabilities nothing changes. Relinking libld.so.4 itself gives a byte-identical .so from the stock and the
    patched ld.
- Fix A on the model, with the system ld: RELATIVE, rc 0, and the scanner is clean.
- Scanner over 995 OI sparc .so: the only real hits are `__memset_vp` in the 64-bit and 32-bit libc. libmd, libsoftcrypto,
  libsodium and libcrypto are clean. Over 415 x86 .so: 0 hits.
- explicit_bzero is fine: it calls memset with a PC-relative call to its JMP_SLOT.

## Not done
- No libc.so.1 has been rebuilt with either fix. That needs a sparcv9 libc build of the OI tree (onbld and gcc-10 in zone
  lixu): the plan is floki /scratch/solnix/sv9mz/LIBC-RESPIN-PLAN.md.
- The gate's elf-tests were not run.
