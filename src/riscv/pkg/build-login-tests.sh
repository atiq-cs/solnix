#!/usr/bin/env bash
# build-login-tests.sh -- the rvlogin kernel-piece test programs (raw ecalls) into $OUT.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="${OUT:-$HOME/scratch/rvlogin/out}"
for t in rndtest ${EXTRA_TESTS:-}; do "$HERE/solnix-cc" -O2 -Wall -o "$OUT/$t" "$HERE/tests/$t.c"; done
echo LOGIN_TESTS_DONE
