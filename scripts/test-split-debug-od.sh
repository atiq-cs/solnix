#!/usr/bin/env bash
# test-split-debug-od.sh -- regression check for pkgs/illumos/split-debug-od.sh's ELF test (x86 store-only builds): an ET_DYN with .debug_info must be
# split whichever od(1) is first on PATH. illumos /usr/bin/od zero-pads (-tu2 of 3 prints "00003"), GNU od does not ("3"), and a
# string compare against 3 split nothing under illumos od: the package shipped an empty debug output and kept its DWARF
# (lixi11, 2026-11-09; the same od trap as test-proto-slice-etrel.sh). Runs ON illumos.
#
# The e_type test is cut out of the script itself (the `t=...od...` line and the `if` that reads it), so this exercises the
# builder's code. Each od in the list (illumos, any GNU od found, a re-padding fake) must classify a fixture lib.so as 3 and a
# text file as not-ELF. Negative control: the pre-fix comparison (`[ "$t" = 3 ]`) must FAIL under illumos od.
set -u
here=$(cd "$(dirname "$0")" && pwd)
sd=${SPLIT_DEBUG_SH:-$here/../pkgs/illumos/split-debug-od.sh}
[ "$(uname -s)" = SunOS ] || { echo "SKIP: needs illumos"; exit 0; }
T=$(mktemp -d /tmp/test-sdod.XXXXXX); trap 'find "$T" -depth -delete' EXIT
tline=$(grep -E '^ *t=""; \[ "\$m" = 7f454c46 \] && t=\$\(od ' "$sd") || { echo "FAIL: cannot find the e_type line in $sd"; exit 1; }
cond=$(grep -E '^ *if \{ \[ "\$t" ' "$sd" | sed 's/ && "\$READELF".*$//; s/^ *if //') || true
[ -n "$cond" ] || { echo "FAIL: cannot find the e_type test in $sd"; exit 1; }
cc=${CC:-$(command -v gcc || command -v cc)}
printf 'int f(void) { return 1; }\n' > "$T/l.c"; "$cc" -g -shared -fPIC -o "$T/lib.so" "$T/l.c" || { echo "FAIL: no fixture"; exit 1; }
printf 'not an elf\n' > "$T/txt"
# a third padding style for decimal output only (-tu/-td): the value re-printed as "  000003"; hex (-tx1, the magic) passes through
mkdir -p "$T/bin3"; printf '#!/bin/sh\ncase "$*" in *-tu*|*-td*) v=$(/usr/bin/od "$@" | tr -d " \\n"); printf "  %%06d\\n" "$(expr "$v" + 0)";; *) exec /usr/bin/od "$@";; esac\n' > "$T/bin3/od"; chmod +x "$T/bin3/od"
ods="/usr/bin $T/bin3"; for g in /usr/gnu/bin $(ls -d /nix/store/*-coreutils-9*/bin 2>/dev/null | head -1); do [ -x "$g/od" ] && ods="$ods $g"; done
run() {  # run <od dir> <file> <condition>: prints split|skip
  ( export PATH="$1:/usr/bin"; f=$2; m=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n'); eval "${tline#"${tline%%[! ]*}"}"; if eval "$3"; then echo split; else echo skip; fi )
}
bad=0
for o in $ods; do
  a=$(run $o "$T/lib.so" "$cond"); b=$(run $o "$T/txt" "$cond")
  [ "$a" = split ] && [ "$b" = skip ] && echo "ok   od=$o: lib.so $a, txt $b" || { echo "BAD  od=$o: lib.so $a, txt $b"; bad=1; }
done
nc=$(run /usr/bin "$T/lib.so" '[ "$t" = 2 ] || [ "$t" = 3 ]')
[ "$nc" = skip ] && echo "ok   negative control: the old string compare skips lib.so under illumos od" || { echo "BAD  negative control: the old compare split under illumos od ($nc): this test cannot fail"; bad=1; }
[ $bad = 0 ] && echo PASS || { echo FAIL; exit 1; }
