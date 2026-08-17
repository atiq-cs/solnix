#!/usr/bin/env bash
# Zero-phantom audit for the solnix GGML_HIP host-dispatch proof.
# Every undefined dynamic symbol must resolve to the solnix libamdhip64 (C6),
# a real illumos lib (libc/libstdc++/libgcc_s/libm/libpthread/librt/libdl), or
# the compiler-runtime crt (_ITM_* / __start_crt_compiler -- weak, resolved by
# crt at final link; the same non-phantom class the C4/C5/C6 .so audits document).
set -u
BIN=${1:-/root/llama-hip/ggml-hip-host-dispatch-proof}
HIPLIB=${2:-/root/hip-build/libamdhip64.so.5}
GCCDIR=${3:-/usr/gcc/14/lib/amd64}

undef() { nm -pD "$1" 2>/dev/null | awk '$2=="U"{print $3}' | sort -u; }
exports() { nm -pD "$1" 2>/dev/null | awk '$2=="T"||$2=="W"{print $3}' | sort -u; }

HIP=$(exports "$HIPLIB")
LIBC=$(exports /lib/64/libc.so.1)
STDCPP=$(exports "$GCCDIR/libstdc++.so.6")
GCC=$(exports "$GCCDIR/libgcc_s.so.1")

# crt symbols emitted by every gcc-linked binary; weak / resolved by crt.
CRT="_ITM_registerTMCloneTable _ITM_deregisterTMCloneTable __start_crt_compiler __cxa_finalize"

phantom=0; total=0; hipc=0
for s in $(undef "$BIN"); do
  total=$((total+1))
  if   echo "$HIP"    | grep -qx "$s"; then hipc=$((hipc+1))
  elif echo "$LIBC"   | grep -qx "$s"; then :
  elif echo "$STDCPP" | grep -qx "$s"; then :
  elif echo "$GCC"    | grep -qx "$s"; then :
  elif echo "$CRT"    | grep -qw "$s"; then :
  else echo "  PHANTOM: $s"; phantom=$((phantom+1)); fi
done

echo "undef total: $total ; resolve-to-libamdhip64: $hipc ; phantom: $phantom"
if [ "$phantom" -eq 0 ]; then
  echo "zero-phantom OK: all undef resolve to solnix libamdhip64 / illumos libs / crt"
  exit 0
else
  echo "FAIL: $phantom phantom symbol(s)"; exit 1
fi
