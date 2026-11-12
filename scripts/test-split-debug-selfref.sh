#!/usr/bin/env bash
# test-split-debug-selfref.sh -- regression check for pkgs/illumos/split-debug-od.sh's self-reference rule (glibdbg, 2026-11-11;
# wave8 folded split-debug-selfref.sh into it). Runs ON illumos.
#
# An unsandboxed `nix-store --check` builds at a scratch out path and Nix rewrites the scratch hash back to the real one in the
# output's bytes. A hash inside a zlib-compressed DWARF section can't be rewritten, so a -debug whose DWARF names its own out
# DIFFERS on every --check (glib's libgio/libglib: GIO_MODULE_DIR as a DW_OP_implicit_value). The fixture: one source, compiled in
# two dirs named after two same-length "out hashes" S and R (DW_AT_comp_dir names them), split by the script, then S's .debug has
# S->R rewritten the way Nix does it. PASS = the rewritten .debug equals R's. Negative control: the same through a sabotaged copy
# (it always compresses) must differ, and a fixture that names no out hash must still come out compressed, also when $man holds
# shell text (cargo-build.sh's $man is its man-install script, not an output path).
set -u
here=$(cd "$(dirname "$0")" && pwd)
sd=${SPLIT_DEBUG_SH:-$here/../pkgs/illumos/split-debug-od.sh}
[ "$(uname -s)" = SunOS ] || { echo "SKIP: needs illumos"; exit 0; }
BU=${BU:-$(ls -d /nix/store/*-solnix-seed-build-tools/bin 2>/dev/null | head -1)}; [ -x "$BU/gobjcopy" ] || BU=/usr/gnu/bin
[ -x "$BU/gobjcopy" ] && [ -x "$BU/greadelf" ] && [ -x "$BU/gstrip" ] || { echo "FAIL: no gobjcopy/greadelf/gstrip (set BU)"; exit 1; }
SED=${SED:-$BU/sed}; [ -x "$SED" ] || SED=/usr/gnu/bin/sed; "$SED" --version 2>/dev/null | grep -q GNU || { echo "FAIL: no GNU sed (binary-safe rewrite; set SED)"; exit 1; }
cc=${CC:-$(command -v gcc || command -v cc)}; [ -n "$cc" ] || { echo "FAIL: no C compiler"; exit 1; }
T=$(mktemp -d /tmp/test-sdsr.XXXXXX); trap 'cd /; find "$T" -depth -delete' EXIT; cd "$T" || exit 1
S=s0000000000000000000000000000000 R=r1111111111111111111111111111111 DS=d0000000000000000000000000000000 DR=e1111111111111111111111111111111
printf '#include <stdio.h>\nconst char *moddir(void) { return MODDIR; }\n' > f.c
# split <script> <out hash> <debug hash> [<srcdir>]: compile in ./sdsr-tst/<h>-fix/src (11-char prefix, so ${out:11:32} = h), split
split() {
  o=./sdsr-tst/$2-fix d=./sdsr-tst/$3-fix-debug; mkdir -p "$o/lib" "${4:-$o/src}"; cp f.c "${4:-$o/src}/"
  # -g3: the build dir (with the hash) lands in .debug_str as a macro too, a section big enough that gobjcopy compresses it
  # -o relative: illumos ld names an STT_FILE symbol after the -o path as given (WAVE7 B8), so only the DWARF names the dir
  ( cd "${4:-$o/src}" && "$cc" -g3 -O2 -shared -fPIC -DMODDIR="\"$(pwd)\"" -o libf.so f.c && mv libf.so "$T/$o/lib/" ) \
    || { echo "FAIL: no fixture"; exit 1; }
  : > "$T/fail"; /usr/bin/bash "$1" "$o" "$d" testkey "$BU" "$T/fail"
  [ -s "$T/fail" ] && { echo "FAIL: $1 reported: $(head -3 "$T/fail")"; exit 1; }
  ls "$d"/lib/debug/.build-id/*/*.debug
}
compressed() { "$BU/greadelf" -SW "$1" 2>/dev/null | grep ' \.debug_info ' | grep -q ' C '; }
bad=0; ok() { echo "ok   $1"; }; no() { echo "BAD  $1"; bad=1; }
od_sh=$T/sabotaged.sh; "$SED" 's/0) keep=1;;/0) keep=0;;/' "$sd" > "$od_sh"   # the control: never keeps a .debug uncompressed
cmp -s "$sd" "$od_sh" && { echo "FAIL: the sabotage did not change $sd (anchor gone)"; exit 1; }
for v in fix:"$sd" control:"$od_sh"; do
  a=$(split "${v#*:}" $S $DS) || exit 1; b=$(split "${v#*:}" $R $DR) || exit 1
  LC_ALL=C "$SED" "s/$S/$R/g; s/$DS/$DR/g" "$a" > rewritten   # what Nix does to a --check output (hash parts only)
  if cmp -s rewritten "$b"; then same=1; else same=0; fi
  case ${v%%:*} in
    fix) [ $same = 1 ] && ok "fix: S's .debug, hash-rewritten, equals R's" || no "fix: the rewritten .debug differs from R's"
         compressed "$b" && no "fix: a .debug naming its out is still compressed" || ok "fix: a .debug naming its out is uncompressed";;
    control) [ $same = 0 ] && ok "negative control: the sabotaged copy's compressed .debug differs after the rewrite" \
               || no "negative control: the sabotaged copy's .debug survives the rewrite: this test cannot fail";;
  esac
  find ./sdsr-tst -depth -delete
done
mkdir -p plain; c=$(split "$sd" $S $DS "$T/plain") || exit 1
compressed "$c" && ok "a .debug that names no out hash stays compressed" || no "a .debug that names no out hash came out uncompressed"
find ./sdsr-tst -depth -delete; mkdir -p plain2
c=$(man='install -Dm644 doc/x.1 "$out/share/man/man1/x.1"' split "$sd" $S $DS "$T/plain2") || exit 1
compressed "$c" && ok "\$man as shell text (cargo-build.sh) leaves a plain .debug compressed" || no "\$man as shell text made a plain .debug uncompressed"
[ $bad = 0 ] && echo PASS || { echo FAIL; exit 1; }
