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
#       -- the illumos-only entry points rust `std`/`libc` reference that a Linux
#          glibc does not provide. Harvested from the real link, then CORRECTED
#          by `nm --undefined-only` on the built riscv64 rlibs (see the accuracy
#          note below). Sixteen symbols:
#
#          ___errno  __posix_getpwuid_r  getexecname  pset_info stack_getbounds
#          __major  __minor  __makedev  __tls_get_addr
#          __xnet_bind  __xnet_connect  __xnet_getaddrinfo  __xnet_getsockopt
#          __xnet_sendto  __xnet_socket  __xnet_socketpair
#
# ACCURACY NOTE (matters if you re-derive this list): an earlier version of this
# script listed TWELVE symbols, taken from linker stderr. That was incomplete in
# two ways, both since verified:
#   * `__major`/`__minor`/`__makedev` come from the libc CRATE rather than std,
#     so a probe binary that never touches them links without them.
#   * `__tls_get_addr` is supplied by glibc's ld.so on a Linux cross host, so
#     the link resolves it silently. On illumos our ld.so.1 must provide it.
# Also note the linker TRUNCATES its undefined-symbol report (238 lines collapse
# to a partial list), which is how `__xnet_bind` briefly looked unnecessary.
# ALWAYS harvest with `nm --undefined-only` on the std/libc rlibs, not from
# linker stderr.
#
# WHERE THESE ACTUALLY LIVE ON ILLUMOS (they are NOT all libc):
#   libc:      ___errno __posix_getpwuid_r getexecname pset_info
#              stack_getbounds __major __minor __makedev __tls_get_addr
#   libSOCKET: all seven __xnet_* (usr/src/lib/libsocket/socket/weaks.c etc.)
#
# WHY it matters: this file names the EXACT illumos ABI surface the solnix
# riscv64 userland must supply for Rust (and therefore COSMIC) to run natively.
# The REAL implementations of the achievable subset now live in
# src/riscv/libc/port/illumos_abi.c; the full audit, with a REAL/STUB/MISSING
# verdict and the kernel-syscall status per symbol, is in
# docs/riscv64-libc-rust-abi-gap.md.
#
# NOTE: the stubs below are non-functional BY DESIGN (link-proof, not a runtime
# libc). Any binary linked against them fails the moment it calls one. Do not
# mistake this file for an implementation -- link against
# src/riscv/libc/port/illumos_abi.c for real behaviour.
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

/*
 * Referenced by the libc CRATE (dev_t encode/decode), so a probe binary that
 * never calls them can link without these.
 */
long __major(void) { return -1; }
long __minor(void) { return -1; }
long __makedev(void) { return -1; }

/*
 * Dynamic-TLS resolver. On a Linux cross host glibc's ld.so provides this, which
 * is why it can be missing from a harvested list; on illumos ld.so.1 must.
 */
void *__tls_get_addr(void *ti) { (void)ti; return 0; }
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
