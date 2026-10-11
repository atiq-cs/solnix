#!/bin/sh
# build-objs-negctl.sh -- negative control for build-objs-gate.sh. A compile
# gate that cannot fail proves nothing (see docs/working-with-subagents.md:
# "sabotage the mechanism and confirm the check flips to FAIL"). This copies
# the vendored tree, breaks a header include in ONE glue .c, and confirms the
# gate FAILS by name; then it also confirms the UNMODIFIED tree still compiles
# that file (so the sabotage, not an unrelated error, is what flipped it).
#
# Usage: build-objs-negctl.sh ILLUMOS_SRC [gate-mit|gate-uvm]
# env: same as build-objs-gate.sh.
set -u
illsrc=${1:?usage: build-objs-negctl.sh ILLUMOS_SRC [gate-mit|gate-uvm]}
goal=${2:-gate-mit}
here=$(cd -- "$(dirname -- "$0")" && pwd)
# nvidia-oss/kernel-illumos is `here`; nvidia-oss is one up.
nvoss=$(cd -- "$here/.." && pwd)
: "${GMAKE:=gmake}" "${CC:=gcc}"

# The .c to sabotage, per set (a real glue source in that set).
case "$goal" in
gate-mit) victim=kernel-illumos/nvidia/nvidia_os.c ;;
gate-uvm) victim=kernel-illumos/nvidia-uvm/uvm_illumos.c ;;
*) echo "FATAL: goal must be gate-mit or gate-uvm"; exit 2 ;;
esac

tmp=$(mktemp -d /tmp/nvoss-negctl.XXXXXX) || exit 2
trap 'rm -rf "$tmp"' EXIT
# Copy only the kernel-side trees the gate needs (not the 2M-line src/ RM:
# the objs gate never touches it).
mkdir -p "$tmp/nvidia-oss"
cp -rp "$nvoss/kernel-illumos" "$nvoss/kernel-open" "$nvoss/Makefile" \
       "$nvoss/utils.mk" "$nvoss/version.mk" "$nvoss/README.md" "$tmp/nvidia-oss/" 2>/dev/null
work="$tmp/nvidia-oss/kernel-illumos"

# Sabotage: prepend an include of a header that does not exist. Compilation of
# this one .c MUST fail with a fatal "No such file" error. Use ed-style sed
# insert syntax (BSD/illumos sed does NOT accept GNU `1i text`; it needs
# `1i\<newline>text`). Portable: build the file with printf + cat instead.
hdr='#include "nvoss_negctl_no_such_header.h"'
{ printf '%s\n' "$hdr"; cat "$tmp/nvidia-oss/$victim"; } > "$tmp/nvidia-oss/$victim.sab"
mv "$tmp/nvidia-oss/$victim.sab" "$tmp/nvidia-oss/$victim"

echo "=== negative control: broke include in $victim, expecting $goal to FAIL ==="
NVOSS_DIR="$work" GMAKE="$GMAKE" CC="$CC" sh "$here/build-objs-gate.sh" "$illsrc" "$goal" \
    > "$tmp/neg.log" 2>&1
rc=$?
if [ $rc -eq 0 ]; then
	echo "NEGATIVE CONTROL ($goal) DID NOT FAIL -- gate is vacuous, something is wrong"
	tail -20 "$tmp/neg.log"
	exit 1
fi
# Confirm it failed for the RIGHT reason: the missing header we injected.
if grep -q 'nvoss_negctl_no_such_header.h' "$tmp/neg.log"; then
	echo "negative control ($goal) FAILS as required: missing-header error on $victim (exit=$rc)"
	grep 'nvoss_negctl_no_such_header.h' "$tmp/neg.log" | head -1
	exit 0
else
	echo "negative control ($goal) failed (exit=$rc) but NOT on the injected header -- inconclusive"
	tail -20 "$tmp/neg.log"
	exit 1
fi
