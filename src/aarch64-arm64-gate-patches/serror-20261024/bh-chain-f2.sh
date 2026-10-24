#!/bin/bash
# bh-chain-f2.sh : assemble (boot-2 assembler, unchanged) -> verify boot_archive -> gzip+dd to img1 + readback
exec >/build/chain-f2.log 2>&1
date
bash /build/patches/aa64f-assemble-b2.sh; echo ASM_RC=$?; tail -2 /build/assemble-aa64e2.log
grep -q ASSEMBLE-OK /build/assemble-aa64e2.log || { echo CHAIN_FAIL_ASM; exit 2; }
bash /build/patches/bh-verify-f2.sh; cat /build/verify-f2.log
grep -q MISMATCH /build/verify-f2.log && { echo CHAIN_FAIL_VERIFY; exit 3; }
bash /build/patches/bh-gzdd.sh aa64f-b2-20261024 vol03ab4eccb18491256; tail -6 /build/gzdd-aa64f-b2-20261024.log
echo "=== CHAIN_F2_DONE $(date) ==="
