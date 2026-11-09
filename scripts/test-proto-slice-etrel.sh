#!/usr/bin/env bash
# test-proto-slice-etrel.sh -- regression check for pkgs/illumos/mk-proto-slice.nix's RUNPATH loop: an ET_REL kernel module
# (which carries a .dynamic NEEDED = its depends_on list) must NEVER be elfedited, whichever od(1) is first on PATH. illumos
# /usr/bin/od zero-pads ("001"), GNU od does not ("1"); a string compare against 1 elfedited every module on an OI host with
# no /usr/gnu/bin/od and the kernel could not load them (lixi11, 2026-11-09). Runs ON illumos (elfdump/elfedit/ld).
#
# The loop under test is cut out of mk-proto-slice.nix itself (from `find "$out" -type f` to the relocfail check), so the
# test exercises the code the builder runs, not a copy. Fixtures, built here with the system ld:
#   mod.o  ET_REL with `-dy -r -N misc/kcf` (a NEEDED in an ET_REL, as the gate's kernel modules have)  -> must be SKIPPED
#   lib.so ET_DYN                                                                                         -> must be RELOCATED
# Each fixture runs once per od in the list: /usr/bin/od (illumos), any GNU od found (store coreutils, /usr/gnu/bin/od), and
# a fake od that re-pads illumos od's answer as "  000N" (a third padding style). Exit 0 iff every case behaves; a case that cannot fail is BAD.
set -u
here=$(cd "$(dirname "$0")" && pwd)
nix=${PROTO_SLICE_NIX:-$here/../pkgs/illumos/mk-proto-slice.nix}
[ "$(uname -s)" = SunOS ] || { echo "SKIP: needs illumos (elfdump/elfedit)"; exit 0; }
for t in /usr/bin/elfdump /usr/bin/elfedit /usr/bin/ld /usr/bin/od; do [ -x $t ] || { echo "FAIL: missing $t"; exit 1; }; done
T=$(mktemp -d /tmp/test-etrel.XXXXXX); trap 'rm -rf "$T"' EXIT
# the loop, verbatim: un-escape Nix's '' quoting of ${ (''${ -> ${)
awk '/find "\$out" -type f 2>\/dev\/null \| while read -r f; do/{p=1} p{print} p && /^ *\[ -e relocfail \]/{exit}' "$nix" \
  | sed "s/''\\\${/\${/g" > "$T/loop.sh"
grep -q 'dyn:runpath' "$T/loop.sh" && grep -q 'relocfail' "$T/loop.sh" || { echo "FAIL: could not cut the RUNPATH loop out of $nix"; exit 1; }
# fixtures
printf 'int solnix_test_mod = 1;\n' > "$T/m.c"; printf 'int solnix_test_lib(void) { return 1; }\n' > "$T/l.c"
cc=${CC:-$(command -v gcc || command -v cc)}
"$cc" -c -fPIC -o "$T/m0.o" "$T/m.c" && /usr/bin/ld -r -dy -N misc/kcf -o "$T/mod.o" "$T/m0.o" || { echo "FAIL: cannot build the ET_REL fixture"; exit 1; }
"$cc" -shared -fPIC -o "$T/lib.so" "$T/l.c" || { echo "FAIL: cannot build the ET_DYN fixture"; exit 1; }
/usr/bin/elfdump -d "$T/mod.o" | grep -q 'NEEDED.*misc/kcf' || { echo "FAIL: fixture mod.o has no NEEDED misc/kcf"; exit 1; }
# a third padding style: the real byte from illumos od, re-printed as "  0001" (4 digits, leading blanks)
mkdir -p "$T/bin3"; printf '#!/bin/sh\nv=$(/usr/bin/od "$@" | tr -d " \\n"); printf "  %%04d\\n" "$(expr "$v" + 0)"\n' > "$T/bin3/od"
chmod +x "$T/bin3/od"
[ "$("$T/bin3/od" -An -tu1 -j16 -N1 "$T/lib.so")" = "  0003" ] || { echo "FAIL: the padded fake od does not print   0003"; exit 1; }
ods="/usr/bin $T/bin3"
for g in /usr/gnu/bin/od /nix/store/*-coreutils-*/bin/od; do [ -x "$g" ] && "$g" --version 2>/dev/null | grep -q GNU && { ods="$ods $(dirname $g)"; break; }; done
rc=0 n=0
for d in $ods; do
  for fx in mod.o lib.so; do
    out="$T/out"; [ -d "$out" ] && find "$out" -mindepth 1 -delete; mkdir -p "$out/kernel/drv/amd64"
    cp "$T/$fx" "$out/kernel/drv/amd64/$fx"; chmod u+w "$out/kernel/drv/amd64/$fx"
    ( cd "$T" && PATH="$d:/usr/bin:/usr/sbin" out="$out" elfdump=/usr/bin/elfdump elfedit=/usr/bin/elfedit rp='$ORIGIN:/test' \
        bash -eu "$T/loop.sh" ) > "$T/log" 2>&1
    if cmp -s "$T/$fx" "$out/kernel/drv/amd64/$fx"; then got=skipped; else got=relocated; fi
    want=skipped; [ $fx = lib.so ] && want=relocated
    n=$((n+1))
    if [ $got = $want ]; then echo "ok   od=$d/od $fx $got"; else echo "BAD  od=$d/od $fx $got (want $want)"; cat "$T/log"; rc=1; fi
  done
done
[ $n -ge 6 ] || { echo "BAD: only $n cases ran"; rc=1; }
# the fixture must reproduce the bug: the pre-fix string compare elfedits mod.o under illumos od
sed 's/\[ "\$t" -eq 1 \] 2>\/dev\/null \&\& continue/[ "$t" = 1 ] \&\& continue/' "$T/loop.sh" > "$T/loop-old.sh"
if cmp -s "$T/loop.sh" "$T/loop-old.sh"; then echo "SKIP negative control: the cut loop has no arithmetic compare to revert (an old tree?)"; else
  out="$T/out"; find "$out" -mindepth 1 -delete; mkdir -p "$out/kernel/drv/amd64"; cp "$T/mod.o" "$out/kernel/drv/amd64/mod.o"
  ( cd "$T" && PATH="/usr/bin:/usr/sbin" out="$out" elfdump=/usr/bin/elfdump elfedit=/usr/bin/elfedit rp='$ORIGIN:/test' bash -eu "$T/loop-old.sh" ) > /dev/null 2>&1
  if cmp -s "$T/mod.o" "$out/kernel/drv/amd64/mod.o"; then echo "BAD: negative control: the string compare also skipped mod.o (the test cannot fail)"; rc=1
  else echo "ok   negative control: the old string compare with illumos od elfedits mod.o"; fi
fi
[ $rc = 0 ] && echo "test-proto-slice-etrel: PASS ($n cases + negative control)" || echo "test-proto-slice-etrel: FAIL"
exit $rc
