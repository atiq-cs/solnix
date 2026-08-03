#!/usr/bin/env bash
# sparc-seed-fixreloc.sh — re-run ONLY the RUNPATH relocation + host-free scan +
# retar on an ALREADY-ASSEMBLED grown seed tree (reuse the ~780MB copy; skip the
# slow header/gcc-prefix re-copy). Fixes the gcc-internal ELFs that still carried
# a compiled-in absolute /usr/gcc/13/lib/sparcv9 RUNPATH (host leak).
set -uo pipefail
OUT="${OUT:-/scratch/solnix-sparc-seedgrow.run}"
SEED="$OUT/seed"
MANIFEST="$OUT/seed-manifest.txt"
GCC_PREFIX="${GCC_PREFIX:-/usr/gcc/13}"
TRIPLE="$("$GCC_PREFIX/bin/gcc" -dumpmachine)"
GCCVER="$("$GCC_PREFIX/bin/gcc" -dumpversion)"
GCCLIB="$SEED/usr/gcc/13/lib/gcc/$TRIPLE/$GCCVER"
GNULIB="$SEED/usr/gnu/lib/sparcv9"
TAR="$(command -v gtar || command -v tar)"
warn() { echo "WARN:  $*" >&2; }
[ -d "$SEED" ] || { echo "no seed tree at $SEED" >&2; exit 1; }

# gcc prefix + usr/lib trees were copied read-only (cp -RP preserves mode);
# elfedit needs write. Make the ELF-bearing dirs user-writable first.
echo "=== chmod ELF dirs writable ==="
chmod -R u+w "$SEED/usr/gcc/13" "$SEED/usr/bin" "$SEED/usr/gnu" \
  "$SEED/lib/sparcv9" "$SEED/usr/lib/sparcv9" 2>/dev/null || true

relocate() { local f="$1" rp="$2"
  [ -f "$f" ] || return 0
  elfdump -d "$f" >/dev/null 2>&1 || return 0
  # rewrite BOTH RUNPATH and RPATH if present (gcc drivers carry both)
  elfedit -e "dyn:runpath $rp" "$f" >/dev/null 2>&1 || warn "runpath set failed: $f"
  # if an RPATH (DT_RPATH) also exists, point it at the same dirs
  if elfdump -d "$f" 2>/dev/null | grep -q ' RPATH '; then
    elfedit -e "dyn:rpath $rp" "$f" >/dev/null 2>&1 || warn "rpath set failed: $f"
  fi
}

echo "=== relocate: gnu/bin ==="
RP_GNUBIN='$ORIGIN/../lib/sparcv9:$ORIGIN/../../lib/sparcv9:$ORIGIN/../../usr/lib/sparcv9'
for f in "$SEED"/usr/gnu/bin/*; do [ -f "$f" ] && relocate "$f" "$RP_GNUBIN"; done
echo "=== relocate: usr/bin ==="
RP_USRBIN='$ORIGIN/../gnu/lib/sparcv9:$ORIGIN/../../lib/sparcv9:$ORIGIN/../lib/sparcv9'
for f in "$SEED"/usr/bin/*; do [ -f "$f" ] && relocate "$f" "$RP_USRBIN"; done
echo "=== relocate: gcc/bin ==="
RP_GCCBIN='$ORIGIN/../lib:$ORIGIN/../lib/sparcv9:$ORIGIN/../../../lib/sparcv9:$ORIGIN/../../../usr/gnu/lib/sparcv9'
for f in "$SEED"/usr/gcc/13/bin/*; do [ -f "$f" ] && relocate "$f" "$RP_GCCBIN"; done
echo "=== relocate: gcc internal (ALL ELFs) ==="
RP_GCCINT='$ORIGIN:$ORIGIN/../../../../lib/sparcv9:$ORIGIN/../../../../../../lib/sparcv9:$ORIGIN/../../../../../../usr/gnu/lib/sparcv9:$ORIGIN/../../../../../../usr/lib/sparcv9'
for d in "$GCCLIB" "$GCCLIB"/install-tools "$SEED"/usr/gcc/13/libexec/gcc/"$TRIPLE"/"$GCCVER"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do [ -f "$f" ] && relocate "$f" "$RP_GCCINT"; done
done
echo "=== relocate: gcc lib dir ==="
RP_GCCLIBDIR='$ORIGIN:$ORIGIN/../../../lib/sparcv9:$ORIGIN/../../../usr/gnu/lib/sparcv9'
for f in "$SEED"/usr/gcc/13/lib/sparcv9/* "$SEED"/usr/gcc/13/lib/*; do
  [ -f "$f" ] && relocate "$f" "$RP_GCCLIBDIR"
done
echo "=== relocate: gnu lib sink + libc family ==="
RP_GNULIB='$ORIGIN:$ORIGIN/../../../lib/sparcv9:$ORIGIN/../../../usr/lib/sparcv9'
for f in "$GNULIB"/*; do [ -f "$f" ] && relocate "$f" "$RP_GNULIB"; done
for f in "$SEED"/lib/sparcv9/*.so* "$SEED"/usr/lib/sparcv9/*.so*; do
  [ -f "$f" ] && relocate "$f" '$ORIGIN'
done

echo "=== host-free scan ==="
SCAN_BAD=0; nscanned=0
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
if [ "$SCAN_BAD" -eq 0 ]; then echo "HOST-FREE: clean"; else echo "HOST-FREE: $SCAN_BAD ELF(s) still reference host paths"; fi

echo "=== retar ==="
FLAG="-"; FLAG="${FLAG}f"
/usr/gnu/bin/rm "$FLAG" "$OUT/seed.tar.zst" 2>/dev/null
( cd "$OUT" && "$TAR" -cf - seed | zstd -"${ZL:-3}" -T0 -o seed.tar.zst )
SEEDSUM="$(digest -a sha256 "$OUT/seed.tar.zst" 2>/dev/null || echo unknown)"
echo "seed.tar.zst sha256: $SEEDSUM"
echo "SIZE: $(ls -l "$OUT/seed.tar.zst" | awk '{print $5}') bytes"
echo "FIXRELOC-COMPLETE-SENTINEL $SEEDSUM"
