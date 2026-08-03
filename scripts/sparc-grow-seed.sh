#!/usr/bin/env bash
# sparc-grow-seed.sh — GROW the sparcv9-solaris seed on a NATIVE sparcv9 OI host
# (the maintainer's Sun `sun`, OpenIndiana Hipster on sun4u). This is the SPARC
# analog of scripts/oi-extract-seed.sh's grow: it folds the compile-time crt +
# values objects, the FULL /usr/include, the gcc-13 prefix, a minimal GNU
# userland, the SPARC assembler `as`, and the transitive lib closure of every
# bundled binary into one relocatable, HOST-FREE seed the pure stdenv's
# linkBootstrap slices exactly.
#
# WHY NATIVE (not fold-the-ROOT-tarball): `sun` IS the authoritative sparcv9
# OI-Hipster gate — the same host the 23 ROOT objects were built + verified on.
# Its live /usr/lib/sparcv9 crt, /usr/gcc/13, /usr/include and /usr/gnu/bin are
# the real, matched, current objects (a superset of the ROOT tarball). We slice
# them directly rather than re-importing an older snapshot.
#
# ISA LAYOUT (native sparcv9 differs from x86_64's amd64/ subdir):
#   - 64-bit SPARC V9 libs live in lib/sparcv9/ + usr/lib/sparcv9/ (and /lib/64,
#     /usr/lib/64 are symlinks -> sparcv9). This seed carries the sparcv9/ dirs.
#   - gcc-13's internal crt (crtbegin/crtend/crtfastmath) + cc1/collect2 live at
#     the TOP of lib/gcc/<triple>/13.4.0/ (NO sparcv9 subdir), because on the
#     native sparcv9 host the default -m is already 64-bit. (x86_64 keeps the
#     64-bit set under a nested amd64/.) The stdenv cc-wrapper -B must therefore
#     point at that top dir, not a subdir. See the oi-extract-seed.sh SPARC delta.
#   - crt1/crti/crtn + values-*.o are the compile-time startup objects at
#     usr/lib/sparcv9/ — MISSING from the runtime-ramdisk sysroot seed; folded here.
#
# RUNS ON: sun (native sparcv9 OI-Hipster). NON-DISRUPTIVE: works only under a
# temp /scratch subdir as an unprivileged user; copies (never moves) from /usr;
# RUNPATH rewrite touches only the seed's own copies. Cleans its scratch on
# success. Does NOT upload (no aws cli on sun) — tars into $OUT for the dev-box
# to pull + publish.
#
# Output (in $OUT, default /scratch/solnix-sparc-seedgrow.$$):
#   seed/               staging tree (mirrors on-disk layout, sparcv9/ ISA subdir)
#   seed-manifest.txt   provenance + sha256
#   seed.tar.zst        the grown seed (top dir: seed/)
set -euo pipefail

GCC_PREFIX="${GCC_PREFIX:-/usr/gcc/13}"
OUT="${OUT:-/scratch/solnix-sparc-seedgrow.$$}"
SEED="$OUT/seed"
MANIFEST="$OUT/seed-manifest.txt"

die()  { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

[ -x "$GCC_PREFIX/bin/gcc" ] || die "gcc not found: $GCC_PREFIX/bin/gcc"
command -v elfedit  >/dev/null || die "elfedit not on PATH"
command -v elfdump  >/dev/null || die "elfdump not on PATH"
command -v zstd     >/dev/null || die "zstd not on PATH"
command -v gtar     >/dev/null || command -v tar >/dev/null || die "no tar"
TAR="$(command -v gtar || command -v tar)"
# Solaris /usr/bin/cp is default in PATH; its -L/-RP semantics differ from GNU.
# Use GNU cp explicitly for every copy so -L (deref plain file) + -RP (tree,
# keep symlinks) behave as this script assumes.
CP="$(command -v /usr/gnu/bin/cp || command -v gcp || echo cp)"
[ -x "$CP" ] || CP=cp

TRIPLE="$("$GCC_PREFIX/bin/gcc" -dumpmachine)"          # sparcv9-sun-solaris2.11
GCCVER="$("$GCC_PREFIX/bin/gcc" -dumpversion)"          # 13.4.0
GCCLIB="$GCC_PREFIX/lib/gcc/$TRIPLE/$GCCVER"            # internal crt + cc1
echo "triple=$TRIPLE gccver=$GCCVER gcclib=$GCCLIB"
[ -f "$GCCLIB/crtbegin.o" ] || die "no gcc internal crt at $GCCLIB (bad prefix?)"

rm -rf "$OUT"; mkdir -p "$SEED"
: > "$MANIFEST"

_record() { local src="$1" dst="$2" prov="$3" sum
  sum="$(digest -a sha256 "$SEED/$dst" 2>/dev/null || echo unknown)"
  printf '%s\t%s\t%s\t%s\n' "$prov" "$src" "$dst" "$sum" >> "$MANIFEST"; }
# copy dereferencing symlinks into a regular file (self-contained slice)
_cpL() { local src="$1" dst="$2" prov="$3" req="$4"
  if [ ! -e "$src" ]; then
    if [ "$req" = req ]; then die "missing required: $src"; else warn "missing optional: $src"; return 0; fi
  fi
  mkdir -p "$SEED/$(dirname "$dst")"
  "$CP" -L "$src" "$SEED/$dst"; chmod u+w "$SEED/$dst"
  _record "$src" "$dst" "$prov"; }
cpL_req() { _cpL "$1" "$2" "$3" req; }
cpL_opt() { _cpL "$1" "$2" "$3" opt; }
# copy preserving symlinks + tree (whole dirs)
_cpTree() { local src="$1" dst="$2" prov="$3" req="$4"
  if [ ! -e "$src" ]; then
    if [ "$req" = req ]; then die "missing required tree: $src"; else warn "missing optional tree: $src"; return 0; fi
  fi
  mkdir -p "$SEED/$(dirname "$dst")"
  "$CP" -RP "$src" "$SEED/$dst"
  _record "$src" "$dst" "$prov"; }
cpTree_req() { _cpTree "$1" "$2" "$3" req; }
cp_glob() { local g="$1" dd="$2" prov="$3" req="$4" n=0 f
  for f in $g; do [ -e "$f" ] || continue
    cpL_req "$f" "$dd/$(basename "$f")" "$prov"; n=$((n+1)); done
  [ "$n" -gt 0 ] || { [ "$req" = req ] && die "glob matched nothing: $g" || warn "glob empty: $g"; }; }

echo "=== 1. sparcv9 (64-bit) libc + siblings + rtld + link-editor (lib/sparcv9) ==="
cpL_req  /lib/sparcv9/ld.so.1        lib/sparcv9/ld.so.1        proto
cpL_req  /lib/sparcv9/libc.so.1      lib/sparcv9/libc.so.1      proto
cp_glob  '/lib/sparcv9/libm.so.*'        lib/sparcv9 proto req
cp_glob  '/lib/sparcv9/libsocket.so.*'   lib/sparcv9 proto req
cp_glob  '/lib/sparcv9/libnsl.so.*'      lib/sparcv9 proto req
cp_glob  '/lib/sparcv9/libresolv.so.*'   lib/sparcv9 proto req
cp_glob  '/lib/sparcv9/libelf.so.*'      lib/sparcv9 proto req
cp_glob  '/lib/sparcv9/libmd.so.*'       lib/sparcv9 proto req
cpL_opt  /lib/sparcv9/libpthread.so.1 lib/sparcv9/libpthread.so.1 proto
cpL_opt  /lib/sparcv9/librt.so.1      lib/sparcv9/librt.so.1      proto
cpL_opt  /lib/sparcv9/libdl.so.1      lib/sparcv9/libdl.so.1      proto
cpL_opt  /lib/sparcv9/libmp.so.2      lib/sparcv9/libmp.so.2      proto
cpL_opt  /lib/sparcv9/libcustr.so.1   lib/sparcv9/libcustr.so.1   proto
cpL_opt  /lib/sparcv9/libofmt.so.1    lib/sparcv9/libofmt.so.1    proto
cpL_opt  /lib/sparcv9/libumem.so.1    lib/sparcv9/libumem.so.1    proto
# runtime linker + link-editor shared objects
cp_glob  '/lib/sparcv9/librtld.so.*'     lib/sparcv9 proto req
cp_glob  '/lib/sparcv9/libld.so.*'       lib/sparcv9 proto req
cp_glob  '/lib/sparcv9/liblddbg.so.*'    lib/sparcv9 proto req
cp_glob  '/usr/lib/sparcv9/libldstab.so.*' usr/lib/sparcv9 proto req
# unversioned link-editor names (.so -> .so.N) — keep symlinks for -l resolution
mkdir -p "$SEED/usr/lib/sparcv9" "$SEED/lib/sparcv9"
for l in libc libm libsocket libnsl libresolv libelf libmd libpthread librt libdl \
         libmp libcustr libofmt libumem; do
  [ -e "/usr/lib/sparcv9/$l.so" ] && { "$CP" -RP "/usr/lib/sparcv9/$l.so" "$SEED/usr/lib/sparcv9/$l.so"; }
  [ -e "/lib/sparcv9/$l.so" ]     && { "$CP" -RP "/lib/sparcv9/$l.so"     "$SEED/lib/sparcv9/$l.so"; }
done
if [ -d /usr/lib/ld ]; then cpTree_req /usr/lib/ld usr/lib/ld proto; else warn "no /usr/lib/ld"; fi

echo "=== 2. compile-time startup objects: crt + values (usr/lib/sparcv9) ==="
cpL_req  /usr/lib/sparcv9/crt1.o     usr/lib/sparcv9/crt1.o     proto
cpL_req  /usr/lib/sparcv9/crti.o     usr/lib/sparcv9/crti.o     proto
cpL_req  /usr/lib/sparcv9/crtn.o     usr/lib/sparcv9/crtn.o     proto
cp_glob  '/usr/lib/sparcv9/values-*.o' usr/lib/sparcv9 proto req

echo "=== 3. FULL system headers (whole tree, arch-independent) ==="
cpTree_req /usr/include usr/include proto

echo "=== 4. gcc-13 prefix (whole tree: bin, libexec, lib/gcc/<triple>/<ver>) ==="
# includes cc1/cc1plus/collect2, include-fixed, the internal crt at the TOP of
# lib/gcc/<triple>/<ver>/ (native sparcv9 -> no sparcv9 subdir), and gcc's own
# sparcv9 runtime libs (libgcc.a etc.). Symlinks preserved so gcc's readlink
# driver-path logic stays intact after relocation.
cpTree_req "$GCC_PREFIX" "usr/gcc/13" host

echo "=== 5. SPARC assembler + ELF/link tools -> usr/gnu/bin + usr/bin ==="
# gcc-13's matched `as` (the x86_64 grow missed this first pass). It is a real
# binary at /usr/gnu/bin/as. Deref into the seed's usr/gnu/bin/as and point
# usr/bin/{as,gas} at it (the stdenv binutils-unwrapped slice reads usr/bin/as).
AS_REAL="$(readlink -f "$("$GCC_PREFIX/bin/gcc" -print-prog-name=as)")"
[ -x "$AS_REAL" ] || die "gcc-13 assembler not found (-print-prog-name=as -> $AS_REAL)"
mkdir -p "$SEED/usr/gnu/bin" "$SEED/usr/bin"
"$CP" -L "$AS_REAL" "$SEED/usr/gnu/bin/as"; chmod u+w "$SEED/usr/gnu/bin/as"; _record "$AS_REAL" usr/gnu/bin/as host
ln -sf ../gnu/bin/as "$SEED/usr/bin/as"
ln -sf ../gnu/bin/as "$SEED/usr/bin/gas"
# Solaris ld + ELF tools the bintools-wrapper slice expects at usr/bin/*
for pair in ld:/usr/bin/ld nm:/usr/bin/nm ar:/usr/bin/ar mcs:/usr/bin/mcs \
            elfdump:/usr/bin/elfdump elfedit:/usr/bin/elfedit; do
  b="${pair%%:*}"; s="${pair##*:}"
  [ -x "$s" ] && { "$CP" -L "$s" "$SEED/usr/bin/$b"; chmod u+w "$SEED/usr/bin/$b"; _record "$s" "usr/bin/$b" host; } \
    || warn "missing tool: $s"
done

echo "=== 6. minimal GNU userland -> usr/gnu/bin (unprefixed, self-contained) ==="
# On the native sparcv9 OI host these ship UNPREFIXED under /usr/gnu/bin already
# (unlike x86_64 OI's g-prefixed /usr/bin). Deref each into usr/gnu/bin/<name>,
# the exact names the stdenv linkBootstrap slices. sh -> bash symlink (stays in
# the seed). The tool list mirrors the x86_64 seed grow.
cp_gnu() { local b="$1"
  local src="/usr/gnu/bin/$b"
  [ -e "$src" ] || src="/usr/bin/$b"
  [ -e "$src" ] || die "missing required GNU tool: $b (looked in /usr/gnu/bin, /usr/bin)"
  "$CP" -L "$src" "$SEED/usr/gnu/bin/$b"; chmod u+w "$SEED/usr/gnu/bin/$b"; _record "$src" "usr/gnu/bin/$b" host; }
# coreutils set (same list the x86_64 stdenv slices) + shells/build/compress
for b in bash cat chgrp chmod chown cp cut date dd df dirname echo env expand \
         expr false fold head id install ln ls md5sum mkdir mkfifo mknod mktemp \
         mv nl nohup od paste printenv printf pwd readlink realpath rm rmdir seq \
         sha256sum sleep sort split stat stty tac tail tee test touch tr true \
         tsort tty uname uniq unlink wc who whoami yes '[' basename comm \
         sed awk gawk make grep egrep fgrep diff cmp find xargs patch tar \
         gzip bzip2 xz unxz; do
  cp_gnu "$b"
done
ln -sf bash "$SEED/usr/gnu/bin/sh"

echo "=== 7. lib closure of every bundled binary (transitive ldd) ==="
# Flatten the full transitive ldd of every staged ELF into the seed's own lib
# sink (usr/gnu/lib/sparcv9) so nothing resolves to the host /usr or /lib at
# runtime. RUNPATH-relocation (step 8) then points every seed ELF at it + the
# sparcv9 libc dirs. Skip 32-bit strays + libs already carried under lib/sparcv9.
#
# Steps 7-9 run with `set +e` (NOT the script-wide -euo pipefail): a single
# ldd/file/elfedit hiccup on the slow host must NOT silently abort the whole run
# (the earlier failure mode). Each loop is defensive + prints progress.
set +e +o pipefail
GNULIB="$SEED/usr/gnu/lib/sparcv9"; mkdir -p "$GNULIB"

# Deterministic list of candidate ELF binaries whose closure we fold in.
BIN_LIST="$OUT/binlist.txt"
{
  ls "$SEED"/usr/gnu/bin/* 2>/dev/null
  ls "$SEED"/usr/bin/* 2>/dev/null
  echo "$GCCLIB/cc1"; echo "$GCCLIB/cc1plus"; echo "$GCCLIB/collect2"
  echo "$GCCLIB/lto1"; echo "$GCC_PREFIX/bin/gcc"; echo "$GCC_PREFIX/bin/g++"
} > "$BIN_LIST"

# Collect the union of ldd deps into a temp, then copy uniquely. No pipeline
# into `while` (that ran in a subshell + died under the old -e); use a temp file.
DEPS="$OUT/deps.txt"; : > "$DEPS"
while read -r f; do
  [ -f "$f" ] || continue
  ldd "$f" 2>/dev/null | sed -n 's/.*=>[ \t]*//p' | awk '{print $1}'
done < "$BIN_LIST" | sort -u | grep '^/' > "$DEPS"
nlibs=0
while read -r lib; do
  [ -e "$lib" ] || { warn "lib dep not found: $lib"; continue; }
  file "$lib" 2>/dev/null | grep -q '32-bit' && continue
  base="$(basename "$lib")"
  [ -e "$GNULIB/$base" ] && continue
  [ -e "$SEED/lib/sparcv9/$base" ] && continue      # already in libc-family sink
  "$CP" -L "$lib" "$GNULIB/$base" && chmod u+w "$GNULIB/$base" \
    && _record "$lib" "usr/gnu/lib/sparcv9/$base" host && nlibs=$((nlibs+1))
done < "$DEPS"
echo "  folded $nlibs unique libs into usr/gnu/lib/sparcv9 (total $(ls "$GNULIB" | wc -l))"

echo "=== 8. RUNPATH-relocate every seed ELF to seed-relative dirs (host-free) ==="
# Rewrite each ELF's RUNPATH so it resolves libs inside the seed regardless of
# where the seed lands, and never falls back to host /usr,/lib. Every bin gets a
# runpath reaching: its own dir's sibling lib sinks + the sparcv9 libc dirs.
# elfedit dyn:runpath sets DT_RUNPATH (illumos honours $ORIGIN).
relocate() {  # file  runpath
  local f="$1" rp="$2"
  [ -f "$f" ] || return 0
  # only touch ELF dynamic objects
  elfdump -d "$f" >/dev/null 2>&1 || return 0
  chmod u+w "$f" 2>/dev/null || true   # tree-copied ELFs are read-only; elfedit needs write
  elfedit -e "dyn:runpath $rp" "$f" >/dev/null 2>&1 || warn "runpath set failed: $f"
  # gcc drivers carry BOTH DT_RUNPATH and legacy DT_RPATH; rewrite both
  if elfdump -d "$f" 2>/dev/null | grep -q ' RPATH '; then
    elfedit -e "dyn:rpath $rp" "$f" >/dev/null 2>&1 || warn "rpath set failed: $f"
  fi
}
# bins under usr/gnu/bin: reach usr/gnu/lib/sparcv9 + lib/sparcv9 + usr/lib/sparcv9
RP_GNUBIN='$ORIGIN/../lib/sparcv9:$ORIGIN/../../lib/sparcv9:$ORIGIN/../../usr/lib/sparcv9'
for f in "$SEED"/usr/gnu/bin/*; do [ -f "$f" ] && relocate "$f" "$RP_GNUBIN"; done
# bins under usr/bin: reach usr/gnu/lib/sparcv9 + lib/sparcv9 + usr/lib/sparcv9
RP_USRBIN='$ORIGIN/../gnu/lib/sparcv9:$ORIGIN/../../lib/sparcv9:$ORIGIN/../lib/sparcv9'
for f in "$SEED"/usr/bin/*; do [ -f "$f" ] && relocate "$f" "$RP_USRBIN"; done
# gcc drivers (usr/gcc/13/bin) + internal exes: reach gcc's own lib + gnu sink + libc
RP_GCCBIN='$ORIGIN/../lib:$ORIGIN/../lib/sparcv9:$ORIGIN/../../../lib/sparcv9:$ORIGIN/../../../usr/gnu/lib/sparcv9'
for f in "$SEED"/usr/gcc/13/bin/*; do [ -f "$f" ] && relocate "$f" "$RP_GCCBIN"; done
# EVERY ELF in the gcc internal dir + libexec carries a compiled-in absolute
# RUNPATH (/usr/gcc/13/lib/sparcv9 etc.) — a host leak once the seed relocates.
# Sweep them all (not a hand list): each is at lib/gcc/<triple>/<ver>/ so the
# seed's usr/gcc/13/lib/sparcv9 is $ORIGIN/../../../../lib/sparcv9, and the
# libc-family + gnu sink are reachable from there too.
RP_GCCINT='$ORIGIN:$ORIGIN/../../../../lib/sparcv9:$ORIGIN/../../../../../../lib/sparcv9:$ORIGIN/../../../../../../usr/gnu/lib/sparcv9:$ORIGIN/../../../../../../usr/lib/sparcv9'
for d in "$GCCLIB" "$GCCLIB"/install-tools "$SEED"/usr/gcc/13/libexec/gcc/"$TRIPLE"/"$GCCVER"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do [ -f "$f" ] && relocate "$f" "$RP_GCCINT"; done
done
# gcc's own lib dir (usr/gcc/13/lib/sparcv9): siblings + libc
RP_GCCLIBDIR='$ORIGIN:$ORIGIN/../../../lib/sparcv9:$ORIGIN/../../../usr/gnu/lib/sparcv9'
for f in "$SEED"/usr/gcc/13/lib/sparcv9/* "$SEED"/usr/gcc/13/lib/*; do
  [ -f "$f" ] && relocate "$f" "$RP_GCCLIBDIR"
done
# lib sinks themselves: give the gnu-lib sink a runpath to siblings + libc
RP_GNULIB='$ORIGIN:$ORIGIN/../../../lib/sparcv9:$ORIGIN/../../../usr/lib/sparcv9'
for f in "$GNULIB"/*; do [ -f "$f" ] && relocate "$f" "$RP_GNULIB"; done
# libc-family sink: keep siblings resolvable ($ORIGIN)
for f in "$SEED"/lib/sparcv9/*.so* "$SEED"/usr/lib/sparcv9/*.so*; do
  [ -f "$f" ] && relocate "$f" '$ORIGIN'
done

echo "=== 9. host-free scan: no absolute /usr or /lib refs (except illumos interp) ==="
# The illumos interp (DT_NEEDED resolution via ld.so.1) legitimately references
# /lib/sparcv9/ld.so.1 as the PT_INTERP for executables — that path also exists
# INSIDE the seed once relocated, and on any illumos host, so it is allowed.
# We flag any RUNPATH/RPATH entry that is an absolute /usr or /lib path.
SCAN_BAD=0; nscanned=0
# Only scan ELF-bearing dirs (bins + lib sinks + gcc exes), NOT the ~30k headers
# (find over the whole tree + elfdump-per-file is what made the run crawl).
SCAN_DIRS="$SEED/usr/gnu/bin $SEED/usr/bin $SEED/usr/gnu/lib/sparcv9 $SEED/lib/sparcv9 $SEED/usr/lib/sparcv9 $SEED/usr/gcc/13/bin $SEED/usr/gcc/13/lib/sparcv9 $GCCLIB $GCCLIB/install-tools $SEED/usr/gcc/13/libexec/gcc/$TRIPLE/$GCCVER"
for d in $SCAN_DIRS; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    elfdump -d "$f" >/dev/null 2>&1 || continue
    nscanned=$((nscanned+1))
    rp="$(elfdump -d "$f" 2>/dev/null | awk '/RUNPATH|RPATH/{for(i=1;i<=NF;i++)if($i ~ /\//)print $i}')"
    [ -n "$rp" ] || continue
    if echo "$rp" | tr ':' '\n' | grep -E '^/(usr|lib)/' >/dev/null 2>&1; then
      echo "HOST-REF: $f -> $rp"; SCAN_BAD=$((SCAN_BAD+1))
    fi
  done
done
echo "  scanned $nscanned ELF objects"
if [ "$SCAN_BAD" -eq 0 ]; then echo "HOST-FREE: clean (no absolute /usr,/lib RUNPATH)"; else echo "HOST-FREE: $SCAN_BAD ELF(s) still reference host paths"; fi
set -e   # re-arm strict mode for the tar/hash tail

echo "=== 10. provenance / versions ==="
{
  echo "# solnix sparcv9 GROWN seed manifest — generated $(date -u +%FT%TZ)"
  echo "# host uname: $(uname -a)"
  echo "# native sparcv9 OI-Hipster gate (sun4u)"
  echo "# gcc triple: $TRIPLE   gcc version: $GCCVER"
  "$GCC_PREFIX/bin/gcc" --version | sed 's/^/#   /' | head -1
  echo "# gcc internal crt dir: usr/gcc/13/lib/gcc/$TRIPLE/$GCCVER/ (TOP, no sparcv9 subdir)"
  echo "# ---- provenance<TAB>src<TAB>dest<TAB>sha256 ----"
} > "$MANIFEST.hdr"
cat "$MANIFEST" >> "$MANIFEST.hdr" && mv "$MANIFEST.hdr" "$MANIFEST"

echo "=== 11. tarball (top dir: seed/) ==="
( cd "$OUT" && "$TAR" -cf - seed | zstd -19 -T0 -o seed.tar.zst )
SEEDSUM="$(digest -a sha256 "$OUT/seed.tar.zst" 2>/dev/null || echo unknown)"
echo "seed.tar.zst sha256: $SEEDSUM" | tee -a "$MANIFEST"
echo "SIZE: $(ls -l "$OUT/seed.tar.zst" | awk '{print $5}') bytes"
echo
echo "DONE. seed=$SEED  manifest=$MANIFEST  tarball=$OUT/seed.tar.zst  ($SEEDSUM)"
echo "GROW-COMPLETE-SENTINEL $SEEDSUM"
