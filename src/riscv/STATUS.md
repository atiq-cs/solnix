# RISC-V (riscv64) port — STATUS

**Phase reached: R-P18** (toolchain TARGET retarget + krtld/sgs reloc coverage)
— DONE (config + reloc tables + proofs; full gcc-as-solaris rebuild is the
documented long pole, launched). R-P17 (cross toolchain + BSD-cribbed
psABI/ISA headers) and R-P1..R-P16 (kernel bring-up) are below / in
`docs/design-riscv-port.md`.

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
