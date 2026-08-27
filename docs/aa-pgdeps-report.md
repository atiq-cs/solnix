# aarch64 PostgreSQL build-dependency cross-build (A7 groundwork)

Goal: ensure the aarch64-solaris PG build-dependency set is cross-built and verified so the aarch64 PG
build-farm animal is provisionable the moment A6-hw lands a bootable Graviton. Node: i-0fd2f53a5a23410df /
18.118.139.214 (x86 illumos cross-build host), LEFT RUNNING.

## TL;DR

- The x86 -> aarch64-solaris cross-build baseline REPRODUCED and BUILDS from source (not just eval).
- PG's key link deps cross-build + verify EM_AARCH64: **zlib** (static `.a` + shared `.so`) and full
  **openssl 3.6.3** (bin + `libssl.so.3` + `libcrypto.so.3`, aarch64 armv8 crypto asm). readline + ncurses
  come shared from the solnix cache. **bison** (a build tool) cross-builds to an aarch64 `ET_EXEC`.
- **KEY CHECK (step 3) PASSED:** a PG-representative C file (atomics/CAS, pthreads, memory barriers, 64-bit
  ints) cross-compiles to an aarch64-solaris `.o` AND links to a full dynamic `ET_EXEC`. The aarch64 build
  environment builds C the way PG needs.
- **Native gcc: ABSENT.** The seed gcc is an x86 cross compiler (EM_AMD64) that emits aarch64. A NATIVE
  aarch64 PG buildfarm animal needs a native aarch64 gcc built ON the animal (post-A6). Cross-build works now.
- **ELFOSABI:** stdenv/GNU-ld cross builds emit **ELFOSABI_NONE + EM_AARCH64**; cache-built readline/ncurses
  `.so` are **ELFOSABI_SOLARIS + EM_AARCH64**. Both valid; OSABI byte is a toolchain-consistency item.

## Environment reproduced

- Cross-eval driver: `pkgs/illumos/phase3/aarch64-overlays/entry-aa-fin-x.nix` (the productionized entry with
  `cxxNomapCc`; the node's older `/root/entry-aa-fin.nix` lacks it and fails shared links).
- Seed cross toolchain FOD: `/nix/store/jzs3dzzfx0p4q4vnzdaq8dh7shyhq2w3-illumos-seed-aarch64-73466454`
  (cross GCC 14.3.0 + GNU binutils ld + aarch64 sysroot; `-dumpmachine = aarch64-unknown-solaris2.11`).
- Build space: root zpool was undersized (~7.5G of a 100G disk -- the VTOC-doesn't-span-disk gotcha). Fixed
  by attaching a 60G EBS volume (`vol-0e361d88e0bb0f681`), rebooting, `zpool create bfpool c2t1d0`, and moving
  `/nix` onto it (54G free). Root slice NOT live-grown.

## PG-dep leaves cross-built (each EM_AARCH64-verified)

| dep | kind | store path | ELF verify |
|-----|------|------------|-----------|
| zlib 1.3.2 (static) | `libz.a` | `aibfbnavn1ihn7cw9w23s6h9zkzjhxaa-zlib-...-1.3.2-static` | deflate.o: EM_AARCH64 ELFCLASS64 ET_REL ELFOSABI_NONE |
| zlib 1.3.2 (shared, x-entry) | `libz.so.1.3.2` | `b4hd1pf7qqkyy3ynxhksw93azaa71vyr-zlib-...-1.3.2` | EM_AARCH64 ET_DYN ELFOSABI_NONE, no phantom undefs |
| openssl 3.6.3 (bin) | `bin/openssl` | `z1ripppdly3brhl50rk2qvmp7fnys3ca-openssl-...-3.6.3-bin` | EM_AARCH64 ET_EXEC ELFOSABI_NONE; interp /lib/ld.so.1; NEEDED libssl/libcrypto/libsocket/libnsl/libdl/libgcc_s/libc |
| openssl 3.6.3 (lib) | `libssl.so.3`, `libcrypto.so.3` | `z7c8b71wgxzpgnzs3a1apb5snqwwzyw3-openssl-...-3.6.3` | EM_AARCH64 ET_DYN ELFOSABI_NONE; libcrypto armv8 asm objs |
| bison 3.8.2 | `bin/bison` | `8jflc580537q18pafscxfaxdvdwcysqd-bison-...-3.8.2` | EM_AARCH64 ET_EXEC ELFOSABI_NONE; interp /lib/ld.so.1; NEEDED libm/libgcc_s/libc |
| readline 8.3p3 | `libreadline.so.8` | `0g17mirirg4c3yhnc0fnnmi3gl9mdgh0-readline-...-8.3p3` (cache) | EM_AARCH64 ET_DYN **ELFOSABI_SOLARIS** |
| ncurses 6.6 | `libncursesw.so.6.6` | `d62aqb059sb6v3f85d6x3kafg8gi2wpn-ncurses-...-6.6` (cache) | EM_AARCH64 ET_DYN **ELFOSABI_SOLARIS** |

Not built (bounded / optional): **libxml2** (`--with-libxml`) evals + starts but drags a large NATIVE
x86_64-solaris buildPackages rebuild chain (bash-interactive etc.) -- not an aarch64 wall; PG builds fine
`--without-libxml`. **icu** (`--without-icu` -- IPS ICU on the x86 animal is v4.6 < 55 anyway). flex/perl/gmake
sit on the same proven cross path.

## THE KEY CHECK -- step 3: PG-representative C cross-compile + link (PASSED)

`pg_port_probe.c` exercises the C surface PostgreSQL's `src/port` + `src/backend/port/atomics` use: `<stdio.h>`
`<sys/types.h>` `<stdint.h>` `<unistd.h>`, pthreads (2 worker threads bumping a shared atomic), GCC atomic
builtins (`__atomic_fetch_add`, `__atomic_compare_exchange_n` -- PG's arch atomics on gcc), a memory barrier
(`__atomic_thread_fence`), 64-bit ints + printf width macros.

```
$ aarch64-unknown-solaris2.11-gcc -O2 -c pg_port_probe.c -o pg_port_probe.o
  -> EM_AARCH64  ELFCLASS64  ET_REL  ELFOSABI_NONE
$ aarch64-unknown-solaris2.11-gcc -O2 pg_port_probe.c -o pg_port_probe -lpthread
  -> ELF 64-bit LSB executable aarch64, dynamically linked
  elfdump -e : EM_AARCH64  ELFCLASS64  ET_EXEC  ELFOSABI_NONE
  .interp    : /lib/ld.so.1
  NEEDED     : libpthread.so.1  libgcc_s.so.1  libc.so.1
  nm -u      : every U is a versioned import (@SUNW_*/@GCC_*) satisfied by a NEEDED lib
               or a weak compiler symbol -- NO phantom undefs
```

The aarch64 cross-toolchain compiles AND links a PG-representative C program end to end to a correct aarch64
illumos dynamic executable. This proves the aarch64 PG build capability ahead of the animal.

## Native aarch64 gcc: ABSENT (cross-only)

```
$ file .../illumos-seed-aarch64.../usr/gcc/aarch64-14/bin/aarch64-unknown-solaris2.11-gcc
  ELF 64-bit LSB executable AMD64        <- x86 host binary
$ file .../libexec/gcc/aarch64-unknown-solaris2.11/14.3.0/cc1
  ELF 64-bit LSB executable AMD64        <- x86 host binary
```

The gcc driver AND the cc1 backend are **EM_AMD64** -- they RUN on x86 and EMIT aarch64. There is no native
aarch64 gcc. Consequence for the buildfarm:

- **Cross role (today):** the x86 animal cross-produces aarch64 artifacts. Provisionable now.
- **Native role (post-A6):** a native aarch64 PG buildfarm animal (gcc running ON aarch64) needs a native
  aarch64 gcc/binutils bootstrapped ON the booted animal (the arm64-gate `make illumos` + a native gcc build).
  Not done. The cross-built aarch64 `bison`/`gmake`/`flex` binaries DO run on the animal; the compiler is the
  gap.

## ELFOSABI: SOLARIS vs NONE

- **Cross builds via the stdenv/GNU-ld path (zlib, openssl, bison, the step-3 exe): ELFOSABI_NONE +
  EM_AARCH64.** The seed carries ONLY a GNU ld capable of aarch64 (the seed's "Solaris ld" is an x86-host
  binary that rejects `EM_AARCH64: unsupported ELF machine type`). GNU ld stamps OSABI_NONE.
- **Cache-built readline/ncurses `.so`: ELFOSABI_SOLARIS + EM_AARCH64** (with `EAV_SUNW_CURRENT`) -- an
  artifact of how the earlier baseline was linked.
- Both are valid aarch64 illumos ELF: interp `/lib/ld.so.1`, correct `EM_AARCH64`, resolve the aarch64
  illumos system libs. The OSABI-byte difference is a toolchain-consistency item (IPD 24 is predraft; native
  x86 illumos is ELFOSABI_SOLARIS). Not a build blocker; track before claiming ABI parity.

## Two cross-link nuances (both cracked / bounded)

1. **libgcc-unwind.map shared-link wall** (docs/aarch64-cxx-wall-fix.md). Seed gcc's built-in `*link:` spec
   emits `-M %slibgcc-unwind.map` (a Solaris symbol-scope mapfile) for every shared link, but collect2 execs
   GNU ld, which reads the mapfile as a linker script and dies "file format not recognized / syntax error".
   FIXED by `cxxNomapCc` in `entry-aa-fin-x.nix`: a `-specs=` override that drops the `-M %s..map` clauses
   from `*link:` (the mapfiles only restrict libgcc-unwinder symbol visibility; dropping is harmless). After
   this, all `.so` links succeed.
2. **libnsl filter phantom undefs.** `apps/openssl` links `-lnsl`; the seed's `libnsl.so` is a filter that
   re-exports `mp_*@SUNW_1.1` / `MD5*@SUNW_1.1` from `libmp` / `libmd`. `libmd.so` is ABSENT from the seed
   sysroot, and GNU ld resolves a shared lib's own undefined symbols eagerly -> error. FIXED with
   `--allow-shlib-undefined` (now baked into `aa-openssl-target-overlay.nix`); the symbols resolve at runtime
   via the illumos filter chain. Upgrade path: add `libmd.so` to the aarch64 seed sysroot.

## New / updated overlay entries -> the fork

- `pkgs/illumos/phase3/aarch64-overlays/aa-openssl-target-overlay.nix` -- UPDATED: added
  `NIX_LDFLAGS += --allow-shlib-undefined` (the libnsl filter phantom-undef fix) with a NOTE naming the
  ceiling (missing libmd.so) and upgrade path. This overlay now fully builds openssl 3.6.3 as aarch64-solaris
  via `entry-aa-fin-x.nix` (the openssl `solaris64-aarch64-gcc` Configure-target injection was already in the
  file; the `--allow-shlib-undefined` addition is what lets the `apps/openssl` executable link).

## What the aarch64 PG build-farm animal needs (supplement to build-farm-animal-provisioning.md)

Written into docs/build-farm-animal-provisioning.md (the "aarch64 PostgreSQL build-dependency set" section):
the cross-eval entry, the verified dep store paths, the native-toolchain gap, the ELFOSABI status, the two
cross-link nuances, and the build-space gotcha. Bottom line: the aarch64 PG **link deps are cross-built and
verified**; a native aarch64 PG animal (post-A6) additionally needs a **native aarch64 gcc built on the
animal**.
