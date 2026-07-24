#!/usr/bin/env bash
# oi-extract-seed.sh — extract a relocatable seed toolchain from an illumos-gate
# build (T0.3). Run ON the illumos build host, as root.
#
#   Sources:
#     proto  = $ROOT (gate-built libc/crt/headers/ld-libs/ld.so.1)   -> preferred
#     host   = live / (OI developer/gcc-10, /usr/bin/ld, ELF tools)  -> only what
#              the gate does not itself produce
#
#   Output (in $OUT, default /var/tmp/solnix-seed):
#     seed/                 staging tree (mirrors the seed's on-disk layout)
#     seed-manifest.txt     src-path -> seed-path, sha256, provenance, versions
#     seed.tar.zst          the seed
#
# Defensive: any REQUIRED file missing -> abort. OPTIONAL files warn only.
set -euo pipefail

GATE="${GATE:-/code/illumos-gate}"
ROOT="${ROOT:-$GATE/proto/root_i386}"          # amd64 nightly proto area
GCC_PREFIX="${GCC_PREFIX:-/usr/gcc/10}"
OUT="${OUT:-/var/tmp/solnix-seed}"
SEED="$OUT/seed"
MANIFEST="$OUT/seed-manifest.txt"

die()  { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

# ---- sanity ---------------------------------------------------------------
[ "$(id -u)" = 0 ]        || die "run as root (need perms/symlink preservation)"
[ -d "$ROOT" ]           || die "proto area not found: $ROOT (build the gate first)"
[ -x "$GCC_PREFIX/bin/gcc" ] || die "gcc not found: $GCC_PREFIX/bin/gcc"
command -v elfdump >/dev/null || die "elfdump not on PATH"
command -v elfedit >/dev/null || die "elfedit not on PATH"
command -v zstd    >/dev/null || die "zstd not on PATH (pkg install compress/zstd)"
[ -f "$ROOT/lib/amd64/libc.so.1" ] || die "no libc in proto: $ROOT/lib/amd64/libc.so.1"

rm -rf "$OUT"; mkdir -p "$SEED"
: > "$MANIFEST"
TRIPLE="$("$GCC_PREFIX/bin/gcc" -dumpmachine)"   # e.g. i386-pc-solaris2.11
echo "gcc target triple: $TRIPLE"

# ---- copy helpers ---------------------------------------------------------
# cp_req  SRC  DESTREL  PROVENANCE   : required, abort if missing
# cp_opt  SRC  DESTREL  PROVENANCE   : optional, warn if missing
# cp_glob SRCGLOB DESTDIRREL PROVENANCE REQUIRED?  : glob copy
_record() { # abs-src  dest-rel  provenance
  local src="$1" dst="$2" prov="$3" sum
  sum="$(digest -a sha256 "$SEED/$dst" 2>/dev/null || sha256sum "$SEED/$dst" | awk '{print $1}')"
  printf '%s\t%s\t%s\t%s\n' "$prov" "$src" "$dst" "$sum" >> "$MANIFEST"
}
_cp() { # src dst-rel provenance required?
  local src="$1" dst="$2" prov="$3" req="$4"
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    if [ "$req" = req ]; then die "missing required: $src"; else warn "missing optional: $src"; return 0; fi
  fi
  mkdir -p "$SEED/$(dirname "$dst")"
  # -R preserve symlinks; -P no-dereference; @/= ext-attr/acl if present
  cp -RP@ "$src" "$SEED/$dst" 2>/dev/null || cp -RP "$src" "$SEED/$dst"
  [ -L "$src" ] || _record "$src" "$dst" "$prov"
}
cp_req()  { _cp "$1" "$2" "$3" req; }
cp_opt()  { _cp "$1" "$2" "$3" opt; }
cp_glob() { # glob dst-dir-rel provenance required?
  local g="$1" dd="$2" prov="$3" req="$4" n=0 f
  for f in $g; do
    [ -e "$f" ] || continue
    cp_req "$f" "$dd/$(basename "$f")" "$prov"; n=$((n+1))
  done
  [ "$n" -gt 0 ] || { [ "$req" = req ] && die "glob matched nothing: $g" || warn "glob empty: $g"; }
}

echo "=== 1. proto: startup objects + libc + siblings (amd64) ==="
cp_req  "$ROOT/lib/amd64/ld.so.1"        lib/amd64/ld.so.1        proto
cp_req  "$ROOT/usr/lib/amd64/crt1.o"     usr/lib/amd64/crt1.o     proto
cp_req  "$ROOT/usr/lib/amd64/crti.o"     usr/lib/amd64/crti.o     proto
cp_req  "$ROOT/usr/lib/amd64/crtn.o"     usr/lib/amd64/crtn.o     proto
cp_glob "$ROOT/usr/lib/amd64/values-*.o" usr/lib/amd64            proto req

# libc + the historically-split siblings + link-time deps
cp_req  "$ROOT/lib/amd64/libc.so.1"      lib/amd64/libc.so.1      proto
cp_glob "$ROOT/lib/amd64/libm.so.*"      lib/amd64                proto req
cp_glob "$ROOT/lib/amd64/libsocket.so.*" lib/amd64                proto req
cp_glob "$ROOT/lib/amd64/libnsl.so.*"    lib/amd64                proto req
cp_glob "$ROOT/lib/amd64/libresolv.so.*" lib/amd64                proto req
cp_glob "$ROOT/lib/amd64/libelf.so.*"    lib/amd64                proto req
# these are filters/stubs on illumos but referenced by -lpthread/-lrt/-ldl:
cp_opt  "$ROOT/lib/amd64/libpthread.so.1" lib/amd64/libpthread.so.1 proto
cp_opt  "$ROOT/lib/amd64/librt.so.1"      lib/amd64/librt.so.1      proto
cp_opt  "$ROOT/lib/amd64/libdl.so.1"      lib/amd64/libdl.so.1      proto

# link-editor symlinks (.so -> .so.N) live under usr/lib; copy the whole set of
# unversioned link names we care about (cp -RP keeps them as symlinks)
for l in libc libm libsocket libnsl libresolv libelf libpthread librt libdl; do
  cp_opt "$ROOT/usr/lib/amd64/$l.so" "usr/lib/amd64/$l.so" proto
done

echo "=== 2. proto: system headers (whole tree) ==="
cp_req "$ROOT/usr/include" usr/include proto

echo "=== 3. proto: link-editor shared objects + mapfiles ==="
# libld lives in /lib/amd64; libldstab/liblddbg in /usr/lib/amd64. Copy from both.
cp_glob "$ROOT/lib/amd64/libld.so.*"         lib/amd64     proto req
cp_glob "$ROOT/usr/lib/amd64/libldstab.so.*" usr/lib/amd64 proto req
cp_glob "$ROOT/usr/lib/amd64/liblddbg.so.*"  usr/lib/amd64 proto opt
cp_glob "$ROOT/lib/amd64/liblddbg.so.*"      lib/amd64     proto opt
if [ -d "$ROOT/usr/lib/ld" ]; then
  cp_req "$ROOT/usr/lib/ld" usr/lib/ld proto
else
  warn "no $ROOT/usr/lib/ld in proto; pulling from live host /usr/lib/ld"
  cp_opt /usr/lib/ld usr/lib/ld host
fi

echo "=== 4. host: Solaris ld + ELF tools ==="
cp_req /usr/bin/ld       usr/bin/ld       host
cp_req /usr/bin/elfdump  usr/bin/elfdump  host
cp_req /usr/bin/elfedit  usr/bin/elfedit  host
cp_opt /usr/bin/elffile  usr/bin/elffile  host
cp_opt /usr/bin/nm       usr/bin/nm       host
cp_opt /usr/bin/ar       usr/bin/ar       host
cp_opt /usr/bin/mcs      usr/bin/mcs      host
# whatever gcc actually calls for as/ld (may differ from the above):
AS="$("$GCC_PREFIX/bin/gcc" -print-prog-name=as)"; [ -x "$AS" ] && cp_req "$AS" "usr/bin/$(basename "$AS")" host
GLD="$("$GCC_PREFIX/bin/gcc" -print-prog-name=ld)"; [ -x "$GLD" ] && cp_opt "$GLD" "usr/bin/gld-$(basename "$GLD")" host

echo "=== 5. host: OI gcc-10 prefix (whole) ==="
cp_req "$GCC_PREFIX" "usr/gcc/10" host   # bin, lib, lib/amd64, libexec, lib/gcc/<triple>/10 incl include-fixed + crt*

# ---- versions / provenance ------------------------------------------------
echo "=== 6. capture versions ==="
{
  echo "# solnix seed manifest — generated $(date -u +%FT%TZ)"
  echo "# host uname: $(uname -a)"
  echo "# gcc triple: $TRIPLE"
  echo "# gcc version:"; "$GCC_PREFIX/bin/gcc" --version | sed 's/^/#   /'
  echo "# ld version:";  /usr/bin/ld -V 2>&1 | sed 's/^/#   /' || true
  echo "# ld.so.1 (proto) elfdump -d NEEDED/soname:"
  elfdump -d "$ROOT/lib/amd64/libc.so.1" 2>/dev/null | sed 's/^/#   /' | head -40
  if [ -d "$GATE/.git" ]; then
    echo "# gate git commit: $(cd "$GATE" && git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "# gate git describe: $(cd "$GATE" && git describe --always --dirty 2>/dev/null || echo unknown)"
  fi
  echo "# ---- provenance<TAB>src<TAB>dest<TAB>sha256 ----"
} > "$MANIFEST.hdr"
cat "$MANIFEST" >> "$MANIFEST.hdr" && mv "$MANIFEST.hdr" "$MANIFEST"

echo "=== 7. tarball ==="
( cd "$OUT" && tar -cf - seed | zstd -19 -T0 -o seed.tar.zst )
SEEDSUM="$(digest -a sha256 "$OUT/seed.tar.zst" 2>/dev/null || sha256sum "$OUT/seed.tar.zst" | awk '{print $1}')"
echo "seed.tar.zst sha256: $SEEDSUM" | tee -a "$MANIFEST"

echo
echo "DONE."
echo "  seed tree: $SEED"
echo "  manifest:  $MANIFEST"
echo "  tarball:   $OUT/seed.tar.zst  ($SEEDSUM)"
