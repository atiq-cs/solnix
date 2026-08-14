# riscv64-solaris libgcc_s.so.1 (R-P21.2)

Hand-linked shared libgcc for riscv64-solaris, the R-P20 gate.  The R-P17/18
gcc target libs were built `--disable-shared`, so only static `libgcc.a` (138
objects) exists.  Rather than a full `--enable-shared` gcc rebuild (long pole,
and it needs a real libc for `SHLIB_LINK`), `libgcc_s.so.1` is hand-linked from
the existing `libgcc.a` objects plus a GCC_3.0 version script.

## The one binutils blocker

The R-P17 `riscv64-unknown-elf` binutils was configured WITHOUT shared-object
support: its `elf64lriscv` emulation has `config.has_shared = false`
(`GENERATE_SHLIB_SCRIPT` unset for bare-metal newlib targets), so `ld -shared`
errors `-shared not supported` (ld/lexsup.c:1365) and there is no `.xs` shared
linker script.

Fix (regenerate ONE emulation + relink ONLY ld, not all binutils):

    # 1. enable the shared/PIE scripts for the riscv emulparams
    echo GENERATE_SHLIB_SCRIPT=yes >> src/binutils-2.44/ld/emulparams/elf64lriscv.sh
    echo GENERATE_PIE_SCRIPT=yes   >> src/binutils-2.44/ld/emulparams/elf64lriscv.sh
    # 2. regenerate eelf64lriscv.c + the .xs/.xd ldscripts (genscripts args
    #    taken verbatim from build/binutils/ld/Makefile GENSCRIPTS)
    cd build/binutils/ld
    sh $SRC/ld/genscripts.sh $SRC/ld <libdir> <prefix> <exec_prefix> \
        x86_64-pc-solaris2.11 riscv64-unknown-elf riscv64-unknown-elf \
        .deps "<libpath>" "elf64lriscv elf32lriscv elf64briscv elf32briscv" \
        "<native_lib_dirs>" no yes elf64lriscv riscv64-unknown-elf
    # -> config.has_shared = true; ldscripts/elf64lriscv.xs created
    # 3. relink just ld
    gmake eelf64lriscv.o ld-new
    cp ld-new toolchain/bin/riscv64-unknown-elf-ld-shared

## Hand-link libgcc_s.so.1

    # version script: export the compiler-runtime + _Unwind_* under GCC_3.0
    # (crib: illumos /usr/gcc/*/lib/libgcc-unwind.map + gcc libgcc-std.ver.in;
    #  generated here from the actual defined symbols in libgcc.a)
    ld-shared -shared -soname libgcc_s.so.1 -o libgcc_s.so.1 \
        --version-script libgcc_s.ver \
        --whole-archive libgcc.a --no-whole-archive \
        --allow-shlib-undefined
    #   (--allow-shlib-undefined: the libc deps abort/malloc/memcpy/memset/
    #    mprotect/getpagesize/sysconf/strlen resolve from libc.so.1 at runtime)

Result: EM_RISCV ELF64 ET_DYN, SONAME libgcc_s.so.1, 214 symbols @@GCC_3.0.

## Dynamic hello

    ld-shared -e _start --dynamic-linker /usr/lib/ld.so.1 -L. \
        -o hello.dyn crt1.o crti.o hello.o crtn.o -lgcc_s libgcc.a \
        --allow-shlib-undefined

-> EM_RISCV, interp /usr/lib/ld.so.1, NEEDED libgcc_s.so.1: the first DYNAMIC
riscv64-solaris userland executable (R-P20 produced the first STATIC one).
