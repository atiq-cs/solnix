#!/usr/bin/env bash
# build-sysroot.sh -- assemble the solnix riscv64 userland sysroot ON THE BOARD (lixr):
#   include/          newlib 4.5.0 headers (the pinned libc of the uts NEWLIBTEST gate)
#   include/solnix/   the compat headers in solnix-libc/include (searched first)
#   lib/libc.a libm.a newlib 4.5.0 (copied from the riscv64-none-elf-gcc-14.3.0 toolchain;
#                     the same bytes NEWLIBTEST links)
#   lib/libsolnix.a   glue.c (the OS port, every entry tagged) + newlib's own POSIX regex
#                     (its libc.a ships regcomp/regexec UNDEFINED-but-unbuilt)
#   lib/crt0.o lib/glue.o lib/solnix.ld
# Inputs: NEWLIB (dir with include/ lib/), NEWLIB_SRC (newlib source tree), UTS (src/riscv/uts).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NEWLIB="${NEWLIB:-$HOME/scratch/rvpkg/newlib}"
NEWLIB_SRC="${NEWLIB_SRC:-$HOME/ws/rvpkg/dl/newlib-4.5.0.20241231}"
UTS="${UTS:-$HOME/ws/rvpkg/src/riscv/uts}"
SR="${SOLNIX_SYSROOT:-$HOME/scratch/rvpkg/sysroot}"
CC="$HERE/solnix-cc"
# The newlib copy comes from a read-only nix store: drop its modes so reruns can overwrite.
mkdir -p "$SR/include/solnix" "$SR/lib" "$SR/obj"
[ -d "$SR/include" ] && chmod -R u+w "$SR"
cp -r --no-preserve=mode "$NEWLIB/include/." "$SR/include/"
cp -r --no-preserve=mode "$HERE/solnix-libc/include/." "$SR/include/solnix/"
cp --no-preserve=mode "$NEWLIB/lib/libc.a" "$NEWLIB/lib/libm.a" "$SR/lib/"
# W^X two-segment variant of uts/user/newlib.ld (same base + symbols): see its header.
cp "$HERE/solnix-libc/solnix-pkg.ld" "$SR/lib/solnix.ld"
export SOLNIX_SYSROOT="$SR"
"$CC" -c "$HERE/solnix-libc/crt0.S" -o "$SR/lib/crt0.o"
# GLUE_DEFS=-DSOLNIX_NO_VFD (rvsh): no userland fd table -- the kernel's fd table is the
# only one (needs the rvsh kernel: pipe refs released, fd 0-2 through the table, fds kept
# across exec). Empty = rvpkg's userland-fd-table STUB, for the rvpkg kernel.
"$CC" -O2 -Wall ${GLUE_DEFS:-} -c "$HERE/solnix-libc/glue.c" -o "$SR/lib/glue.o"
P="$NEWLIB_SRC/newlib/libc/posix"
for f in regcomp regexec regerror regfree collate collcmp fnmatch; do
	"$CC" -O2 -w -I"$P" -D_GNU_SOURCE -c "$P/$f.c" -o "$SR/obj/$f.o"
done
"$CC" -O2 -Wall -c "$HERE/solnix-libc/net.c" -o "$SR/obj/net.o"	# rvlogin: sockets, select, resolver
rm -f "$SR/lib/libsolnix.a"
ar rcs "$SR/lib/libsolnix.a" "$SR/obj/"*.o
echo "libsolnix.a: $(ar t "$SR/lib/libsolnix.a" | tr '\n' ' ')"
echo SYSROOT_DONE "$SR"
