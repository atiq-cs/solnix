#!/bin/sh
# make-riscv64-illumos-syslib-shim.sh -- build the link-time shim that lets the
# custom `riscv64gc-unknown-illumos` Rust target LINK before a real illumos
# riscv64 libc exists.
#
# WHAT it makes:
#   $OUT/lib/lib{socket,posix4,nsl,umem,sendfile,lgrp,ssp,resolv,md,mp}.so
#       -- empty riscv64 shared objects standing in for the illumos-only
#          libraries the target's late-link-args/libc crate name. (This is the
#          same technique docs/aarch64-cross-rust.md used for aarch64 via
#          /tmp/aa-syslibs, applied to riscv64.)
#   $OUT/lib/libillumosshim.so
#       -- the twelve illumos-LIBC-ONLY entry points rust `std` references that
#          a Linux glibc does not provide. This list was HARVESTED from the real
#          link, not guessed, and it is the complete set for std as of rustc
#          nightly (2026-09) / libc 0.2.189:
#
#          ___errno  __posix_getpwuid_r  __xnet_bind  __xnet_connect
#          __xnet_getaddrinfo  __xnet_getsockopt  __xnet_sendto  __xnet_socket
#          __xnet_socketpair  getexecname  pset_info  stack_getbounds
#
# WHY it matters: this file names the EXACT illumos-libc ABI surface the solnix
# riscv64 userland must supply for Rust (and therefore COSMIC) to run natively.
# When the real riscv64 illumos libc lands, DELETE libillumosshim and link
# against it -- the stubs here return -1 and are for link-proof only.
#
# NOTE: the stubs are non-functional by design (link-proof, not a runtime libc).
# Any binary linked against them will fail at runtime the moment it calls one.
#
# Usage: OUT=/tmp/rv-syslibs CROSS=riscv64-linux-gnu- ./make-...sh
set -eu
OUT="${OUT:-/tmp/rv-syslibs}"
CROSS="${CROSS:-riscv64-linux-gnu-}"
CC="${CC:-${CROSS}gcc}"

mkdir -p "$OUT/lib"
echo 'static int _stub;' > "$OUT/stub.c"

# The illumos-only LIBRARIES (no symbols needed -- the linker just wants the file).
for l in socket posix4 nsl umem sendfile lgrp ssp resolv md mp; do
	$CC -shared -fPIC -o "$OUT/lib/lib$l.so" "$OUT/stub.c"
done

# The illumos-LIBC-ONLY SYMBOLS rust std needs (harvested from the real link).
cat > "$OUT/illumos_libc_shim.c" <<'C'
/*
 * WHAT: the illumos-libc-only entry points rust std references on illumos.
 * WHY:  glibc has no equivalent, so a Linux-hosted cross link fails without
 *       them. These are LINK-PROOF stubs: they return -1 and must be replaced
 *       by the real illumos riscv64 libc.
 */
#include <errno.h>

int *___errno(void) { return &errno; }

long __posix_getpwuid_r(void) { return -1; }
long __xnet_bind(void) { return -1; }
long __xnet_connect(void) { return -1; }
long __xnet_getaddrinfo(void) { return -1; }
long __xnet_getsockopt(void) { return -1; }
long __xnet_sendto(void) { return -1; }
long __xnet_socket(void) { return -1; }
long __xnet_socketpair(void) { return -1; }
long getexecname(void) { return -1; }
long pset_info(void) { return -1; }
long stack_getbounds(void) { return -1; }
C
$CC -shared -fPIC -o "$OUT/lib/libillumosshim.so" "$OUT/illumos_libc_shim.c"

echo "shim built in $OUT/lib:"
ls "$OUT/lib"
cat <<EOF

Use with:
  RUSTFLAGS="-L native=$OUT/lib -C link-arg=-lillumosshim" \\
  RUSTC_BOOTSTRAP=1 cargo +nightly build --release \\
    -Zjson-target-spec -Zbuild-std=std,panic_abort \\
    --target .../riscv64gc-unknown-illumos.json
EOF
