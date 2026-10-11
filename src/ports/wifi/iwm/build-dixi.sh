#!/bin/sh
# Build the iwm kernel module natively on dixi (the X1), from floki.
#
# 1. regenerate the patched OpenBSD sources here (dixi has no patch/python),
# 2. ship src/ports/wifi to dixi:/var/tmp/streamD/wifi,
# 3. gmake -f Makefile.illumos there with the solnix-dev toolchain,
# 4. check every undefined symbol of the module against the RUNNING kernel
#    (unix + genunix + the misc/mac it depends on), printing the unresolved.
#
# Usage: build-dixi.sh            (from anywhere on floki)
#   IWM_DIXI_DIR  where src/ports/wifi lands on dixi (default /var/tmp/streamD);
#                 point it at <clone>/src of a fresh git clone to build the
#                 committed tree: only the generated build/ files are new there.
#   IWM_DIXI_OUT  where the logs and symbol lists go (default IWM_DIXI_DIR)
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)
wp=$(cd -- "$here/.." && pwd)
host=gburd@192.168.1.124
dir=${IWM_DIXI_DIR:-/var/tmp/streamD}
out=${IWM_DIXI_OUT:-$dir}
dev=/nix/store/jlzzgm9v2i2495zzd1z27b9b6c54klaf-solnix-dev/bin
SSH="ssh -F /dev/null -i $HOME/.ssh/id_auth_ed25519 -o IdentitiesOnly=yes \
 -o IdentityAgent=none -o ControlMaster=no -o ControlPath=none -o BatchMode=yes \
 -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
 -o LogLevel=ERROR"

python3 "$here/gen-illumos-src.py"
"$wp/net80211/gen-illumos-src.sh" >/dev/null

tar -C "$wp/.." -cf - --exclude='*.o' --exclude='wifi/iwm/iwm' wifi |
    timeout -s KILL 120 setsid $SSH $host "mkdir -p $dir $out && cd $dir && tar xf -"

timeout -s KILL 900 setsid $SSH $host "
set -e
export PATH=$dev:\$PATH
cd $dir/wifi/iwm
# Always from clean: the Makefile has no header dependencies, and tar
# carries floki's mtimes onto dixi, whose clock differs (measured: dixi UTC
# 20:49 vs floki EDT 20:50 = files 4 h in the future), so make's timestamp
# logic cannot be trusted across the copy.
gmake -f Makefile.illumos clean > /dev/null
gmake -f Makefile.illumos -j4 > $out/iwm-build.log 2>&1 || { tail -30 $out/iwm-build.log; exit 1; }
tail -3 $out/iwm-build.log
ls -l iwm
# symbols the running kernel exports (global T/D/B/R/C)
for m in /platform/i86pc/kernel/amd64/unix /kernel/amd64/genunix /kernel/misc/amd64/mac; do
  nm -p \$m | awk '\$2 ~ /^[TDBRC]\$/ {print \$3}'
done | sort -u > $out/ksyms-unix-genunix-mac.txt
nm -p iwm | awk '\$2==\"U\" {print \$3}' | sort -u > $out/iwm-undef.txt
comm -23 $out/iwm-undef.txt $out/ksyms-unix-genunix-mac.txt > $out/iwm-unresolved.txt
echo \"undefined: \$(wc -l < $out/iwm-undef.txt)  unresolved vs running kernel: \$(wc -l < $out/iwm-unresolved.txt)\"
cat $out/iwm-unresolved.txt
# krtld rebinds a module global to the kernel's same-named symbol (kobj.c:3020);
# only the module linkage entry points may share a name with the kernel.
nm -p iwm | awk '\$2 ~ /^[TDBRC]\$/ {print \$3}' | sort -u > $out/iwm-defined.txt
comm -12 $out/iwm-defined.txt $out/ksyms-unix-genunix-mac.txt | grep -v -E '^(_init|_fini|_info)\$' > $out/iwm-collide.txt || true
echo \"kernel-name collisions: \$(wc -l < $out/iwm-collide.txt)\"; cat $out/iwm-collide.txt
# Load-order-independent gate: the linked module must export NOTHING but the
# kernel loader interface (_init/_fini/_info/_depends_on). This proves the
# iwm.mapfile reduction took effect and catches the OpenBSD-compat global
# cross-wiring defect even when the other compat module (i915) is not loaded.
# Same logic as scripts/check-compat-local.sh, inlined so the build is self-
# contained on dixi.
grep -v -E '^(_init|_fini|_info|_depends_on)\$' $out/iwm-defined.txt > $out/iwm-compat-local.txt || true
echo \"non-interface exported globals: \$(wc -l < $out/iwm-compat-local.txt)\"; cat $out/iwm-compat-local.txt
test ! -s $out/iwm-unresolved.txt && test ! -s $out/iwm-collide.txt && test ! -s $out/iwm-compat-local.txt
"
