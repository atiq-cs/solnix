#!/bin/bash
# bh-chain-g.sh : assemble the aa64g base image -> verify boot_archive == proto -> raw sha + gzip
exec >/build/chain-g.log 2>&1
date
bash /build/patches/aa64g-assemble.sh; echo ASM_RC=$?; tail -2 /build/assemble-aa64g.log
grep -q ASSEMBLE-OK /build/assemble-aa64g.log || { echo CHAIN_FAIL_ASM; exit 2; }
bash /build/patches/bh-verify-g.sh; cat /build/verify-g.log
grep -q MISMATCH /build/verify-g.log && { echo CHAIN_FAIL_VERIFY; exit 3; }
cd /build/out && digest -a sha256 aa64g-base.img > aa64g-base.raw.sha256 && gzip -1 -c aa64g-base.img > aa64g-base.img.gz && digest -a sha256 aa64g-base.img.gz
cat aa64g-base.raw.sha256; ls -la aa64g-base.img*
echo "=== CHAIN_G_DONE $(date) ==="
