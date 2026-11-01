#!/usr/bin/env bash
# gates-ab.sh N K1 T1 K2 T2 -- tryit1: interleaved gate boots of two kernels, N each (judge by rate).
set -u; N=$1; H="$(cd "$(dirname "$0")" && pwd)"
for i in $(seq 1 $N); do
	bash $H/gates.sh $2 $3-$i 1 2>&1 | grep '^gates\|MISSING' | tr '\n' ' '; echo
	bash $H/gates.sh $4 $5-$i 1 2>&1 | grep '^gates\|MISSING' | tr '\n' ' '; echo
done
echo AB_DONE
