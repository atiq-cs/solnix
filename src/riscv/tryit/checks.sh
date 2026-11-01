#!/usr/bin/env bash
# checks.sh KERNEL RUNS -- tryit1: regression run of the default (non-demo) kernel: pkg/check-all.sh's suites with
# the cross-built userland, plus the pty/ctty tests (ptytest ctytest ptyglue intwait) from tryit's changes to pty.c.
set -u; K=$1; N=${2:-1}; R="$(cd "$(dirname "$0")/.." && pwd)"; P=$R/pkg
cd $HOME/w; mkdir -p logs/all
for t in pkginit hello sigtest fstest pipetest brktest zhog uptrtest kpipeprobe ptytest ctytest ptyglue intwait; do
	[ -f $OUT/$t ] || $P/solnix-cc -O2 -Wall -o $OUT/$t $P/tests/$t.c || echo "BUILD FAIL $t"
done
$P/solnix-cc -O2 -DSOLNIX_NO_SIGXLATE -c $P/solnix-libc/glue.c -o $OUT/glue-noxlate.o
SOLNIX_GLUE=$OUT/glue-noxlate.o $P/solnix-cc -O2 -o $OUT/sigtest-nc $P/tests/sigtest.c
for r in $(seq 1 $N); do
	for s in ${SUITES:-libc zlib dash less fs login}; do
		st=$(mktemp -d); bash $P/stage-$s.sh $st >/dev/null 2>&1
		ck=$P/tests/$s.checks; [ $s = login ] && { cat $P/tests/pty.checks $P/tests/cty.checks $P/tests/ptyglue.checks $P/tests/intwait.checks > /tmp/login-$$.checks; ck=/tmp/login-$$.checks; }
		in=""; [ -f $P/tests/$s.stdin ] && in=$P/tests/$s.stdin
		out=$(H=$HOME/w/hostsb-bin UNIX=$K QEMU=$(command -v qemu-system-riscv64) STDIN_FILE="$in" TMO=360 bash $P/run-checks.sh $st $ck logs/all/$s-$r.log 2>&1)
		echo "run $r suite $s: failed=$(printf '%s\n' "$out" | sed -n 's/^CHECKS FAILED: //p') passed=$(printf '%s\n' "$out" | grep -c -E '^CHECK (PASS|XFAIL-OK) ')"
		printf '%s\n' "$out" | grep -E '^CHECK FAIL' | sed 's/^/    /'
		find $st -delete
	done
done
echo CHECKS_DONE
