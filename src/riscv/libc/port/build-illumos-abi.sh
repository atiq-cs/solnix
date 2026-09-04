#!/usr/bin/env bash
# build-illumos-abi.sh -- compile + self-check the illumos ABI entry points the
# riscv64 libc must supply for Rust std.
#
# WHAT: builds src/riscv/libc/port/illumos_abi.c with the riscv64 cross gcc into
# illumos_abi.o (a real libc.a member), verifies all 16 entry points are defined
# and that the object is EM_RISCV, then builds and RUNS the self-check
# (test-illumos-abi.c) both on the host and, if qemu-riscv64 is available, as a
# native riscv64 binary.
#
# WHY separate from the rp* phase build-libc.sh scripts: those reference
# node-local toolchain paths from since-wiped dev nodes (the reproducibility gap
# src/riscv/build-all.sh exists to close). This script takes the toolchain as a
# parameter so it runs anywhere.
#
# Usage:
#   RISCV_GCC=<dir-with-riscv64-*-gcc> ./build-illumos-abi.sh
# e.g. RISCV_GCC=$(dirname $(nix build --no-link --print-out-paths \
#        'nixpkgs#pkgsCross.riscv64-embedded.stdenv.cc')/bin/*gcc)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-/tmp/solnix-illumos-abi}"
mkdir -p "$OUT/include/sys"

: "${RISCV_GCC:?set RISCV_GCC to a directory containing a riscv64 *-gcc}"
GCC="$(ls "$RISCV_GCC"/riscv64-*-gcc 2>/dev/null | head -1)"
[ -x "$GCC" ] || { echo "no riscv64 gcc in $RISCV_GCC"; exit 1; }
NM="$(ls "$RISCV_GCC"/riscv64-*-nm 2>/dev/null | head -1)"
echo "gcc: $GCC"

# The reduced libc headers this TU needs. sys/types.h is extended here with the
# device-number types (dev_t/major_t/minor_t) and ssize_t, whose widths follow
# illumos <sys/types.h> (major_t/minor_t are uint_t, dev_t is ulong_t) so the
# __major/__minor/__makedev bit layouts match the real ABI.
for h in pwd.h string.h stdlib.h unistd.h stddef.h; do
	for d in "$HERE"/../../rp41/libc/include "$HERE"/../../rp40/libc/include \
	    "$HERE"/../../rp39/libc/include; do
		[ -f "$d/$h" ] && { cp "$d/$h" "$OUT/include/$h"; break; }
	done
done
cat > "$OUT/include/sys/types.h" <<'H'
#ifndef _SYS_TYPES_H
#define _SYS_TYPES_H
#include <stddef.h>
typedef long off_t;
typedef int pid_t;
typedef int mode_t;
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef long ssize_t;
/* Device-number types; widths per illumos <sys/types.h> (LP64). */
typedef unsigned int major_t;
typedef unsigned int minor_t;
typedef unsigned long dev_t;
#endif
H

CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wextra -Wno-unused-parameter \
	-I$OUT/include"

echo "--- compiling illumos_abi.c"
$GCC $CFLAGS -c "$HERE/illumos_abi.c" -o "$OUT/illumos_abi.o"

MACH="$(readelf -h "$OUT/illumos_abi.o" | awk -F: '/Machine/{print $2}' | xargs)"
echo "  machine: $MACH"
case "$MACH" in *RISC-V*) ;; *) echo "FAIL: not EM_RISCV"; exit 1 ;; esac

echo "--- checking all 16 entry points are DEFINED (T)"
MISSING=0
for s in ___errno stack_getbounds getexecname pset_info __posix_getpwuid_r \
    __major __minor __makedev __xnet_socket __xnet_socketpair __xnet_bind \
    __xnet_connect __xnet_sendto __xnet_getsockopt __xnet_getaddrinfo \
    __tls_get_addr; do
	if ${NM:-nm} "$OUT/illumos_abi.o" 2>/dev/null | grep -q " T $s\$"; then
		echo "  $s: defined"
	else
		echo "  FAIL: $s not defined"; MISSING=1
	fi
done
[ "$MISSING" -eq 0 ] || exit 1

# The self-check exercises logic, so it builds for the HOST (same C, and the
# behaviour is word-size-independent for these functions).
echo "--- host self-check"
cc -O1 -Wall -o "$OUT/t-abi" "$HERE/test-illumos-abi.c" "$HERE/illumos_abi.c" \
	-I"$OUT/include"
"$OUT/t-abi"

# And natively as riscv64 if a riscv64-linux gcc + qemu are around. This is the
# stronger check: same code, real target ISA.
RVLINUX="$(command -v riscv64-unknown-linux-gnu-gcc || command -v riscv64-linux-gnu-gcc || true)"
if [ -n "$RVLINUX" ] && command -v qemu-riscv64 >/dev/null 2>&1; then
	echo "--- native riscv64 self-check (qemu-riscv64)"
	"$RVLINUX" -O1 -Wall -o "$OUT/t-abi-rv64" "$HERE/test-illumos-abi.c" \
		"$HERE/illumos_abi.c" -I"$OUT/include"
	SYSROOT="$(dirname "$(dirname "$("$RVLINUX" -print-file-name=ld-linux-riscv64-lp64d.so.1)")")"
	qemu-riscv64 -L "$SYSROOT" "$OUT/t-abi-rv64"
else
	echo "--- skipping native riscv64 self-check (need a riscv64-linux gcc + qemu-riscv64)"
fi

echo "ILLUMOS_ABI_BUILD_DONE  ($OUT/illumos_abi.o)"
