#!/bin/sh
# build-objs-gate.sh -- OFF-HARDWARE compile gate for the vendored NVIDIA
# illumos port. Runs on an illumos host (needs gcc, GNU binutils gld/gobjcopy,
# ctfconvert, and an illumos-gate source tree for ILLUMOS_SRC headers). It
# compiles every glue .c to .o via the upstream `objs` machinery -- NO
# nv-kernel.o, NO RM link, NO GPU. A green gate means every glue .c compiled
# clean against the given illumos headers.
#
# License-segregated (see gate.mk):
#   gate-mit  (default)  nvidia + nvidia_modeset + nvidia_i2c  = MIT, zero GPL.
#   gate-uvm  (opt-in)   nvidia_uvm                            = GPLv2 (CUDA).
#
# Usage:
#   build-objs-gate.sh ILLUMOS_SRC [gate-mit|gate-uvm|gate-all]
# env: NVOSS_DIR (default: dir two up from this script), GMAKE (gmake),
#      CC (gcc), JOBS (nproc or 4).
#
# Prints, per requested set:  compiled N of M glue .o clean; lists any failures
# with the exact first error. Exits non-zero if any .c fails to compile.
set -u
illsrc=${1:?usage: build-objs-gate.sh ILLUMOS_SRC [gate-mit|gate-uvm|gate-all]}
goal=${2:-gate-mit}
here=$(cd -- "$(dirname -- "$0")" && pwd)
# this script lives at .../nvidia-oss/kernel-illumos/ next to gate.mk
: "${NVOSS_DIR:=$(cd -- "$here" && pwd)}"
: "${GMAKE:=gmake}" "${CC:=gcc}"
: "${JOBS:=$( (nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4) )}"

[ -d "$illsrc/usr/src/uts/common" ] || {
	echo "FATAL: ILLUMOS_SRC=$illsrc has no usr/src/uts/common (not an illumos-gate tree)"; exit 2; }
command -v "$GMAKE" >/dev/null || { echo "FATAL: $GMAKE not found"; exit 2; }

cd "$NVOSS_DIR" || exit 2

run_set() {
	g=$1
	echo "=== $g (ILLUMOS_SRC=$illsrc, CC=$CC, -j$JOBS) ==="
	# -k: keep going so we count ALL failures, not just the first.
	$GMAKE -k -j"$JOBS" -f gate.mk "$g" ILLUMOS_SRC="$illsrc" CC="$CC" \
	    > "/tmp/nvoss-$g.log" 2>&1
	rc=$?
	# Count .o actually produced vs .c the goal targets.
	# The upstream rules write .o under _out/SunOS_x86_64/.
	produced=$(find _out -name '*.o' 2>/dev/null | wc -l | tr -d ' ')
	# Failures: compiler lines with 'error:' plus the file.
	fails=$(grep -E ': error:|Error [0-9]' "/tmp/nvoss-$g.log" | head -40)
	echo "exit=$rc  objects produced under _out: $produced"
	if [ -n "$fails" ]; then
		echo "--- FAILURES ($g) ---"
		# Show each failing .c with its first error line.
		grep -E '\.c:[0-9]+:[0-9]+: (error|fatal error):' "/tmp/nvoss-$g.log" \
		    | sed 's|.*/||' | sort -u | head -60
		echo "--- (full log: /tmp/nvoss-$g.log) ---"
	else
		echo "no compile errors in $g"
	fi
	return $rc
}

rc=0
case "$goal" in
gate-all)
	$GMAKE -f gate.mk clean >/dev/null 2>&1
	run_set gate-mit || rc=1
	run_set gate-uvm || rc=1
	;;
*)
	$GMAKE -f gate.mk clean >/dev/null 2>&1
	run_set "$goal" || rc=1
	;;
esac
exit $rc
