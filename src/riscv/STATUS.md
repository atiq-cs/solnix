# RISC-V (riscv64) port — STATUS

**Phase reached: R-P17** (toolchain + psABI/reloc/ISA-header consolidation) — COMPLETE.
Prior phases R-P1..R-P16 (kernel bring-up through the physical-K1 flashable
image + runtime board-detect) are DONE and documented in
`docs/design-riscv-port.md`. R-P17 is a bounded, host-independent CODE phase:
re-establish a working riscv64 cross toolchain on the fred build node and lay
down the illumos MD psABI/ISA headers the toolchain track (R1) and krtld/sgs
depend on — BSD-cribbed where the definitions are ISA/psABI (OS-independent).

Date substrate: fred v3 (root@52.88.62.49), illumos SunOS i386
(illumos-fb435c17bd), native OpenIndiana gcc 14.3.0 + GNU binutils, 16 CPU /
64 GB / 90 GB free. All builds ran detached (nohup -> log). Not git-committed
(orchestrator commits).

---

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
