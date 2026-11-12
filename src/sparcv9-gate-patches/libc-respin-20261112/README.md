# sparcv9 libc respin: OpenIndiana's libc.so.1 rebuilt with the memset_s fix (2026-11-12, sv9libc)

`pkgs/illumos/sparcv9/gate.nix`'s proto tarball is OpenIndiana Hipster 2026.04's packages at SUNWcs 0.5.11-2025.0.0.21764. Its
`lib/sparcv9/libc.so.1` has the memset_s bug in `../memset_s-20261111/`, so every libsodium signature check crashes. This
directory rebuilds that one file from public sources, matching OI's own build, with only Fix A
(`../memset_s-20261111/libc-memset_s-wrapper.diff`) changed. The tarball is otherwise byte-identical: same member list, order,
modes and mtimes.

## What OI built (measured, not assumed)
OI's package manifest names illumos-gate commit OpenIndiana/illumos-gate `31d3d510d0d442d3e0ff619d2c80269ab236be55`. The binary
is not that commit as published:
- It has five functions the commit lacks: `fdclose`, `dprintf`, `vdprintf`, `strerrorname_np` and `strerrordesc_np`. All five
  are in version `ILLUMOS_0.40`, where upstream has 0.54, 0.55 and 0.44. The proto's `stdio.h` and `string.h` are 31d3d510 plus
  exactly those upstream hunks.
- `localtime.c` has `state_is_posix` (illumos 17497), and the proto ships no `usr/include/tzfile.h` (illumos 17347).
- It was compiled with illumos gcc 4.4.4 (`/opt/gcc/4.4.4`), not gcc 10. Evidence: OI's onbld `make` has RUNPATH
  `/opt/gcc/4.4.4/lib`, and the libc keeps leaf functions under `-fPIC`, which gcc 10 and 13 never do with the gate's flags.
- The C code was compiled with `-xarch=sparcvis` (cw: `-mcpu=ultrasparc -mvis`). Plain gcc 4.4.4 doesn't reproduce OI's
  `catclose`/`finite`; with sparcvis it does, instruction for instruction.

## The patches (apply with `patch -p1` to `git archive 31d3d510d0 usr/src`, then the memset_s wrapper)
| patch | upstream illumos | what |
|---|---|---|
| 0001 | faadcf7eb2 (16452) | strerrordesc_np / strerrorname_np (libc + head hunks) |
| 0002 | b1c37be59f (16506) | fdclose |
| 0003 | 34b5c75ae1 (16151/16505) | dprintf / vdprintf |
| 0004 | e496dfa829 (17344/17347) | tzcode 2025a: libc's localtime.c/time_data.c and head/tzfile.h |
| 0005 | d35c3d74c3 (17497) | POSIX TZs and tzname[] |
| 0006 | none (OI-only) | the 5 symbols in ILLUMOS_0.40 as OI's binary has them; vdprintf.o in the sparc/sparcv9 PORTPRINT |
Each upstream patch carries only that commit's libc/head hunks; their mapfile-vers hunks are replaced by 0006. Applying the
series plus Fix A gives exactly the 14 files the shipped build used.

## Build (zone lixu, 3.3 min, nice 19)
`sv9libc-build.sh` + `inner.sh` + `sv9libc.env`. `sv9libc.env` is `usr/src/tools/env/illumos.sh` with oi-userland's
`components/openindiana/illumos-gate/Makefile` seds, plus these overrides:
- gcc 4.4.4 as the primary compiler, with upstream's pre-14158 per-version gating of `-fno-ipa-icf`, `-fno-clone-functions` and
  `-fno-aggressive-loop-optimizations`, which gcc 4.4.4 rejects;
- `-xarch=sparcvis`;
- the system ld.

Host packages: OI's `developer/build/onbld@0.5.11-2025.0.0.21764` (cw, ctf tools, dmake), `developer/illumos-gcc@4.4.4`, and
`developer/as` (Sun as, the gate's sparc assembler).

`$ROOT` is seeded from the hosted proto, plus the zone's `/usr/platform/sun4{u,v}/include` and 7 unpackaged headers that the
gate's `install_h` would have put there. Only the 64-bit libc and its six sparcv9 `symcap.o` are built.

## Gate (`sv9libc-cmp.py` OI vs new: PASS) and the explained differences
- **Equal to OI's libc:** SONAME, the 81 version definitions, and all 2636 `.dynsym` symbols (type, binding, visibility,
  version, size). Every `.symtab` FUNC/OBJT size is equal too, except the allowed differences below.
- **Function by function** (`sv9libc-explain2.py`), across 3240 functions:
  - 2140 have identical instruction text.
  - 1097 differ only in immediates, all of them from layout. Every function moved by +0x40 or +0x60, from the one new
    RELATIVE relocation and sort entry plus the 28-byte `__memset_fill`. All 1107 `%l7` GOT-base pairs still reach
    `_GLOBAL_OFFSET_TABLE_` (unchanged at 0x26c000), and the 44 GOT-relative label offsets shift by exactly their label's
    displacement. Nothing is left unexplained.
  - Instruction-level differences are only in `memset_s` (Fix A) and in `memrchr`. ld placed the PIC thunk after `memrchr`
    in OI's libc and after `__memset_fill` in ours; `memrchr`'s symbol size is 96 bytes in both.
- **`___SUNW_dof` is 7616 vs 7560 bytes.** The DOF that `dtrace -G` builds names 18 temporaries `$dtrace<pid>.`; OI's pid had
  8 digits and ours 5 (18 × 3 bytes, 8-byte aligned). The DOF has the same 9 sections and the same probe tables.
- **Fix A works on the real library:**
  - `../memset_s-20261111/plt-noreloc-scan.py` is clean on the new libc. OI's libc fails it: `__memset_vp` = PLT `_memset`
    with no relocation.
  - `__memset_vp` now has an `R_SPARC_RELATIVE`.
  - A libsodium sign/verify test gives rc 0 with the new libc; with OI's it gives rc 139.
- **Control:** the same tree built with gcc 10, as the env file has it, fails the gate with 3815 differences. Without the
  backports, it lacks the 5 symbols.

## Repack (`sv9libc-repack.sh`)
The control repack of the unchanged proto reproduces `b3eb6eeb…796c` byte for byte. Two packs with the new libc are
byte-identical: `a05663c2e5bd0747379a14d5b3dbdea6d637b8d7956dba1de89a883e25ad26f1`, 13136669 B. Banked with every input and
the evidence at floki `/scratch/solnix-bank/sv9libc-20261112/` (SHA256SUMS, read back).
