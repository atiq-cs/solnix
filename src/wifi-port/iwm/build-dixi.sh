#!/bin/sh
# Build the iwm kernel module natively on dixi (the X1), from floki.
#
# 1. regenerate the patched OpenBSD sources here (dixi has no patch/python),
# 2. ship src/wifi-port to dixi:/var/tmp/streamD/wifi-port,
# 3. gmake -f Makefile.illumos there with the solnix-dev toolchain,
# 4. check every undefined symbol of the module against the RUNNING kernel
#    (unix + genunix + the misc/mac it depends on), printing the unresolved.
#
# Usage: build-dixi.sh            (from anywhere on floki)
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)
wp=$(cd -- "$here/.." && pwd)
host=gburd@192.168.1.124
dir=/var/tmp/streamD
dev=/nix/store/jlzzgm9v2i2495zzd1z27b9b6c54klaf-solnix-dev/bin
SSH="ssh -F /dev/null -i $HOME/.ssh/id_auth_ed25519 -o IdentitiesOnly=yes \
 -o IdentityAgent=none -o ControlMaster=no -o ControlPath=none -o BatchMode=yes \
 -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
 -o LogLevel=ERROR"

python3 "$here/gen-illumos-src.py"
"$wp/net80211-openbsd/gen-illumos-src.sh" >/dev/null

tar -C "$wp/.." -cf - --exclude='*.o' --exclude='wifi-port/iwm/iwm' wifi-port |
    timeout -s KILL 120 setsid $SSH $host "mkdir -p $dir && cd $dir && tar xf -"

timeout -s KILL 900 setsid $SSH $host "
set -e
export PATH=$dev:\$PATH
cd $dir/wifi-port/iwm
# Always from clean: the Makefile has no header dependencies, and tar
# carries floki's mtimes onto dixi, whose clock differs (measured: dixi UTC
# 20:49 vs floki EDT 20:50 = files 4 h in the future), so make's timestamp
# logic cannot be trusted across the copy.
gmake -f Makefile.illumos clean > /dev/null
gmake -f Makefile.illumos -j4 > $dir/iwm-build.log 2>&1 || { tail -30 $dir/iwm-build.log; exit 1; }
tail -3 $dir/iwm-build.log
ls -l iwm
# symbols the running kernel exports (global T/D/B/R/C)
for m in /platform/i86pc/kernel/amd64/unix /kernel/amd64/genunix /kernel/misc/amd64/mac; do
  nm -p \$m | awk '\$2 ~ /^[TDBRC]\$/ {print \$3}'
done | sort -u > $dir/ksyms-unix-genunix-mac.txt
nm -p iwm | awk '\$2==\"U\" {print \$3}' | sort -u > $dir/iwm-undef.txt
comm -23 $dir/iwm-undef.txt $dir/ksyms-unix-genunix-mac.txt > $dir/iwm-unresolved.txt
echo \"undefined: \$(wc -l < $dir/iwm-undef.txt)  unresolved vs running kernel: \$(wc -l < $dir/iwm-unresolved.txt)\"
cat $dir/iwm-unresolved.txt
# krtld rebinds a module global to the kernel's same-named symbol (kobj.c:3020);
# only the module linkage entry points may share a name with the kernel.
nm -p iwm | awk '\$2 ~ /^[TDBRC]\$/ {print \$3}' | sort -u > $dir/iwm-defined.txt
comm -12 $dir/iwm-defined.txt $dir/ksyms-unix-genunix-mac.txt | grep -v -x -E '_init|_fini|_info' > $dir/iwm-collide.txt || true
echo \"kernel-name collisions: \$(wc -l < $dir/iwm-collide.txt)\"; cat $dir/iwm-collide.txt
test ! -s $dir/iwm-unresolved.txt && test ! -s $dir/iwm-collide.txt
"
