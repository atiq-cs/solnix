#!/usr/bin/env bash
# audit-undef-hip.sh -- zero-phantom audit for libamdhip64.so.5 (the HIP core,
# AOT dispatch path) on illumos x86_64. Every undefined dynamic symbol must
# resolve to a real illumos library, ROCr (hsa_*), or libhsakmt (hsaKmt*).
# amd_comgr_* must be ZERO (comgr is dlopen'd at runtime, never link-time --
# the AOT path never triggers the JIT). Same doctrine as audit-undef-rocr.sh.
set -u
LIB="${1:-/root/hip-build/libamdhip64.so.5}"
ROCR=/root/rocr-build/libhsa-runtime64.so.1
KMT=/root/drm-port/rocm/build/libhsakmt.so.1

nm -pD "$LIB" 2>/dev/null | awk '$2=="U"{print $3}' | sort -u > /tmp/hip-undef.txt
TOTAL=$(wc -l < /tmp/hip-undef.txt)

# Real illumos provider libs (defined-symbol tables)
provs=""
for l in /lib/64/libc.so.1 /lib/64/libm.so.1 /lib/64/libpthread.so.1 \
         /lib/64/libdl.so.1 /lib/64/librt.so.1 /lib/64/libelf.so.1 \
         /usr/gcc/14/lib/amd64/libstdc++.so.6 /usr/gcc/14/lib/amd64/libgcc_s.so.1 \
         "$ROCR" "$KMT"; do
  [ -f "$l" ] && provs="$provs $l"
done
# collect all defined (T/W/D/B/R/i) symbols from providers + our own deps
: > /tmp/hip-provided.txt
for l in $provs; do
  nm -pD "$l" 2>/dev/null | awk '$2!="U"{print $3}'
done | sort -u >> /tmp/hip-provided.txt
sort -u /tmp/hip-provided.txt -o /tmp/hip-provided.txt

# crt/TLS symbols the final process image binds (not in any .so we ship) --
# same allow-list ROCr / libhsakmt used. The _ZTH* entries are GCC's per-TLS
# __tls_init thunks for HIP's own thread-locals (hip::g_lastError/g_device):
# they are emitted WEAK-undefined in every referencing TU and bind to the
# defining object internally -- the same class as __tls_get_addr, not a phantom.
CRT_OK='^_ITM_(de)?registerTMCloneTable$|^__tls_get_addr$|^__cxa_finalize$|^_edata$|^_end$|^__bss_start$|^_ZTHN?[0-9]'

PHANTOM=0
COMGR=$(grep -c 'amd_comgr' /tmp/hip-undef.txt)
: > /tmp/hip-phantom.txt
while read -r s; do
  [ -z "$s" ] && continue
  if grep -qxF "$s" /tmp/hip-provided.txt; then continue; fi
  if echo "$s" | grep -qE "$CRT_OK"; then continue; fi
  PHANTOM=$((PHANTOM+1)); echo "$s" >> /tmp/hip-phantom.txt
done < /tmp/hip-undef.txt

echo "undef total   : $TOTAL"
echo "hsa_* (ROCr)  : $(grep -c '^hsa_' /tmp/hip-undef.txt)"
echo "hsaKmt(thunk) : $(grep -c '^hsaKmt' /tmp/hip-undef.txt)"
echo "amd_comgr link: $COMGR  (must be 0 -- comgr is runtime-dlopen only)"
echo "phantom       : $PHANTOM"
if [ "$PHANTOM" -eq 0 ] && [ "$COMGR" -eq 0 ]; then
  echo "zero-phantom OK: all undef resolve to real illumos libs / ROCr / libhsakmt; no comgr/LLVM link dep"
else
  echo "PHANTOMS:"; cat /tmp/hip-phantom.txt
fi
