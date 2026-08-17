#!/usr/bin/env bash
# audit-undef-rocr.sh -- zero-phantom audit for libhsa-runtime64.so (ROCr core).
# Every undefined dynamic symbol must resolve to a real illumos library:
#   libhsakmt (the HSA thunk), libc/libpthread/libdl/librt (POSIX),
#   libelf (the code-object ELF reader), libsendfile (sendfile), or the C++
#   ABI runtime (libstdc++/libgcc_s). Any symbol that resolves nowhere is a
#   phantom and fails the audit -- same doctrine as libhsakmt / RADV / ANV.
set -u
SO=${1:-/root/rocr-build/libhsa-runtime64.so.1}
LIBHSAKMT=/root/drm-port/rocm/build/libhsakmt.so.1
LIBSTDCPP=$(g++ -print-file-name=libstdc++.so.6)
LIBGCC=$(g++ -print-file-name=libgcc_s.so.1)
LIBS="$LIBHSAKMT $LIBSTDCPP $LIBGCC \
  /lib/64/libc.so.1 /lib/64/libpthread.so.1 /lib/64/libdl.so.1 \
  /lib/64/librt.so.1 /lib/64/libelf.so.1 /lib/64/libsendfile.so.1"

# _ITM_* and __tls_get_addr are compiler/TLS runtime hooks resolved by the
# process's crt/ld at final image bind; treat as known-real (as libhsakmt did).
CRT_OK="_ITM_registerTMCloneTable _ITM_deregisterTMCloneTable __tls_get_addr"

nm -pD "$SO" | awk '$2=="U"{print $3}' | sort -u > /tmp/rocr_undef_all.txt
total=$(wc -l < /tmp/rocr_undef_all.txt)
phantom=0
while read -r s; do
  case " $CRT_OK " in *" $s "*) continue;; esac
  found=0
  for L in $LIBS; do
    [ -f "$L" ] || continue
    if nm -pD "$L" 2>/dev/null | awk -v x="$s" '$3==x && $2!="U"{f=1} END{exit !f}'; then
      found=1; break
    fi
  done
  if [ "$found" = 0 ]; then echo "PHANTOM: $s"; phantom=$((phantom+1)); fi
done < /tmp/rocr_undef_all.txt

echo "----"
echo "total undef: $total   phantom: $phantom"
if [ "$phantom" = 0 ]; then
  echo "zero-phantom OK: all undef resolve to real illumos libs (libhsakmt/libc/libstdc++/libgcc_s/libelf/librt/libsendfile)"
else
  echo "AUDIT FAILED: $phantom phantom undef(s)"; exit 1
fi
