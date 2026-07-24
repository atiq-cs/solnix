#!/usr/bin/env bash
# gate-c-hello.sh — GATE C of docs/design-gate-derivation.md: prove a hello-world
# compiles+links+runs against the SLICED libc (illumos.libc store path from GATE
# B), not the raw proto and not the seed. Run ON the illumos build host.
#
#   ./gate-c-hello.sh <illumos-libc-store-path>
#
# Uses host gcc-10 (compiler; same gcc the seed was extracted from, design §3.1)
# + the Solaris ld it drives, with -L/-R pointing at the sliced libc's amd64 dir.
# The binary's RUNPATH is baked to the store libc; LD_DEBUG=libs must show
# libc.so.1 resolving from the /nix/store illumos-libc path.
set -euo pipefail

LIBC="${1:?usage: gate-c-hello.sh <illumos-libc-store-path>}"
GCC=/usr/gcc/10/bin/gcc
WORK=/var/tmp/gate-c
mkdir -p "$WORK"; cd "$WORK"

LIBDIR="$LIBC/lib/amd64"          # runtime libc + siblings live here
USRLIB="$LIBC/usr/lib/amd64"      # crt objects + .so link symlinks
INC="$LIBC/usr/include"

[ -f "$LIBDIR/libc.so.1" ] || { echo "FATAL: no sliced libc at $LIBDIR/libc.so.1" >&2; exit 1; }

cat > hello.c <<'EOF'
#include <stdio.h>
int main(void){ puts("hello from solnix sliced libc"); return 0; }
EOF

echo "=== compile + link against sliced libc ($LIBC) ==="
# -nostdinc + -isystem: use ONLY the sliced headers.
# -B $USRLIB: find the sliced crt1/crti/crtn.o.
# -L: sliced libc search dir.  -Wl,-R: bake RUNPATH to the store libc.
# ld.so.1 interpreter also comes from the sliced tree.
"$GCC" -m64 \
  -nostdinc -isystem "$INC" \
  -B "$USRLIB" \
  -L "$LIBDIR" -L "$USRLIB" \
  -Wl,-R,"$LIBDIR" \
  hello.c -o hello

echo "=== elfdump -d hello: NEEDED + RUNPATH ==="
/usr/bin/elfdump -d hello | egrep -i 'NEEDED|RUNPATH|RPATH|INTERP' || true

echo "=== run ==="
./hello

echo "=== LD_DEBUG=libs: where does libc.so.1 resolve? ==="
LD_DEBUG=libs ./hello 2>&1 | egrep -i 'libc\.so\.1|find object|default|/lib/amd64' | head -20

echo
echo "=== VERDICT ==="
resolved="$(LD_DEBUG=libs ./hello 2>&1 | egrep -i 'libc\.so\.1' | egrep -i 'found|=>|:' | head -1)"
if LD_DEBUG=libs ./hello 2>&1 | grep -q "$LIBC/lib/amd64/libc.so.1"; then
  echo "GATE C PASS: libc.so.1 resolved from sliced store path $LIBC"
else
  echo "GATE C CHECK: inspect LD_DEBUG output above; libc must come from $LIBC"
fi
