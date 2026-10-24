#!/usr/bin/env bash
# stage-fs.sh <stage-dir> -- the sbase root plus directory trees for fs.checks. All checks run
# in ONE boot and mutations persist, so every mutating check gets its own copy of the tree
# (t = read-only reference; m r1 r2 v1 v2 e = one per mutating check). run-checks.sh puts
# every directory in the ustar root as a '5' entry, so the guest sees exactly this tree.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$1"
bash "$HERE/stage-sbase.sh" "$S"
cp "$OUT/dash" "$S/bin/dash"
mkdir -p "$S/t/a/b" "$S/t/c"
printf 'one\n' > "$S/t/f1"; printf 'two two\n' > "$S/t/a/f2"
printf 'three three three\n' > "$S/t/a/b/f3"; printf 'four\n' > "$S/t/c/f4"
for d in m r1 r2 v1 v2 e; do cp -r "$S/t" "$S/$d"; done
