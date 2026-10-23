#!/usr/bin/env bash
# build-all-pkgs.sh -- (re)build the sysroot, the check init, and every package, in order.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HOME/scratch/rvpkg/out}"; mkdir -p "$OUT"
bash "$HERE/build-sysroot.sh"
"$HERE/solnix-cc" -O2 -Wall -o "$OUT/pkginit" "$HERE/tests/pkginit.c"
"$HERE/solnix-cc" -O2 -Wall -o "$OUT/hello" "$HERE/tests/hello.c"
"$HERE/solnix-cc" -O2 -Wall -o "$OUT/sigtest" "$HERE/tests/sigtest.c"
"$HERE/solnix-cc" -O2 -Wall -o "$OUT/fstest" "$HERE/tests/fstest.c"
"$HERE/solnix-cc" -O2 -Wall -o "$OUT/pipetest" "$HERE/tests/pipetest.c"
"$HERE/solnix-cc" -O2 -Wall -o "$OUT/kpipeprobe" "$HERE/tests/kpipeprobe.c"
# negative control: the same test against a glue that passes signal numbers through
"$HERE/solnix-cc" -O2 -DSOLNIX_NO_SIGXLATE -c "$HERE/solnix-libc/glue.c" -o "$OUT/glue-noxlate.o"
SOLNIX_GLUE="$OUT/glue-noxlate.o" "$HERE/solnix-cc" -O2 -o "$OUT/sigtest-nc" "$HERE/tests/sigtest.c"
bash "$HERE/build-zlib.sh"
bash "$HERE/build-sbase.sh"
for p in ${EXTRA_PKGS:-}; do bash "$HERE/build-$p.sh"; done
echo ALL_PKGS_DONE
