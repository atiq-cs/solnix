#!/usr/bin/env bash
# aa-extract-seed.sh — extract an aarch64 target-sysroot seed from the restored
# richlowe/arm64-gate proto (A3). Runs ON an illumos build host, as root.
#
# ADAPTED FROM scripts/oi-extract-seed.sh (the x86_64 seed extractor). Differences
# for aarch64 (docs/design-aarch64-bootstrap.md §3, "aarch64 differs"):
#   - proto = proto/root_aarch64 (not root_i386).
#   - NO amd64/ ISA subdir: libs/crt live directly in lib/ and usr/lib/
#     (LP64-only; `lib/64 -> .` and `usr/lib/64 -> .` compat symlinks).
#   - The Solaris ld + elfdump + elfedit are PROTO-NATIVE (aarch64 binaries under
#     usr/bin/) — unlike x86 which pulled them from the host. We ship them so the
#     seed is self-describing (they only RUN on aarch64, but a Nix FOD only
#     UNPACKS the seed, so that is fine).
#   - The COMPILER half (cross gcc / $CROSS) is NOT in the archived proto — it
#     died with numa. This seed is the target-sysroot half only: libc/crt/headers/
#     ld.so.1/link-editor. A cross-gcc rebuild (gate `make setup`) is the A4 dep;
#     libcCross for pkgsCross.aarch64-solaris points at THIS sysroot.
#
# Output (in $OUT, default /var/tmp/solnix-aarch64-seed):
#   seed/               staging tree (mirrors on-disk layout)
#   seed-manifest.txt   provenance + sha256
#   aarch64-seed.tar.zst
set -euo pipefail

GATE="${GATE:-/aarch64/arm64-gate/illumos-gate}"
ROOT="${ROOT:-$GATE/proto/root_aarch64}"
OUT="${OUT:-/var/tmp/solnix-aarch64-seed}"
SEED="$OUT/seed"
MANIFEST="$OUT/seed-manifest.txt"

die()  { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

[ "$(id -u)" = 0 ]  || die "run as root (symlink/perm preservation)"
[ -d "$ROOT" ]      || die "aarch64 proto not found: $ROOT (restore it first)"
command -v zstd >/dev/null || die "zstd not on PATH"
[ -f "$ROOT/lib/libc.so.1" ] || die "no aarch64 libc in proto: $ROOT/lib/libc.so.1"
[ -f "$ROOT/lib/ld.so.1" ]   || die "no aarch64 rtld in proto: $ROOT/lib/ld.so.1"

rm -rf "$OUT"; mkdir -p "$SEED"
: > "$MANIFEST"

_record() { local src="$1" dst="$2" prov="$3" sum
  sum="$(digest -a sha256 "$SEED/$dst" 2>/dev/null || echo unknown)"
  printf '%s\t%s\t%s\t%s\n' "$prov" "$src" "$dst" "$sum" >> "$MANIFEST"; }
_cp() { local src="$1" dst="$2" prov="$3" req="$4"
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    if [ "$req" = req ]; then die "missing required: $src"; else warn "missing optional: $src"; return 0; fi
  fi
  mkdir -p "$SEED/$(dirname "$dst")"
  cp -RP@ "$src" "$SEED/$dst" 2>/dev/null || cp -RP "$src" "$SEED/$dst"
  [ -L "$src" ] || _record "$src" "$dst" "$prov"; }
cp_req()  { _cp "$1" "$2" "$3" req; }
cp_opt()  { _cp "$1" "$2" "$3" opt; }
cp_glob() { local g="$1" dd="$2" prov="$3" req="$4" n=0 f
  for f in $g; do [ -e "$f" ] || continue
    cp_req "$f" "$dd/$(basename "$f")" "$prov"; n=$((n+1)); done
  [ "$n" -gt 0 ] || { [ "$req" = req ] && die "glob matched nothing: $g" || warn "glob empty: $g"; }; }

echo "=== 1. proto: startup objects + libc + siblings (LP64, no amd64 subdir) ==="
cp_req  "$ROOT/lib/ld.so.1"          lib/ld.so.1          proto
cp_req  "$ROOT/usr/lib/crt1.o"       usr/lib/crt1.o       proto
cp_req  "$ROOT/usr/lib/crti.o"       usr/lib/crti.o       proto
cp_req  "$ROOT/usr/lib/crtn.o"       usr/lib/crtn.o       proto
cp_glob "$ROOT/usr/lib/values-*.o"   usr/lib              proto req

cp_req  "$ROOT/lib/libc.so.1"        lib/libc.so.1        proto
cp_glob "$ROOT/lib/libm.so.*"        lib                  proto req
cp_glob "$ROOT/lib/libsocket.so.*"   lib                  proto req
cp_glob "$ROOT/lib/libnsl.so.*"      lib                  proto req
cp_glob "$ROOT/lib/libresolv.so.*"   lib                  proto req
cp_glob "$ROOT/lib/libelf.so.*"      lib                  proto req
cp_glob "$ROOT/lib/libmd.so.*"       lib                  proto req
cp_opt  "$ROOT/lib/libpthread.so.1"  lib/libpthread.so.1  proto
cp_opt  "$ROOT/lib/librt.so.1"       lib/librt.so.1       proto
cp_opt  "$ROOT/lib/libdl.so.1"       lib/libdl.so.1       proto
cp_opt  "$ROOT/lib/libmp.so.2"       lib/libmp.so.2       proto
cp_opt  "$ROOT/lib/libcustr.so.1"    lib/libcustr.so.1    proto
cp_opt  "$ROOT/lib/libofmt.so.1"     lib/libofmt.so.1     proto
cp_opt  "$ROOT/lib/libumem.so.1"     lib/libumem.so.1     proto

# link-editor .so -> .so.N symlinks (cp -RP keeps them as symlinks)
for l in libc libm libsocket libnsl libresolv libelf libpthread librt libdl \
         libmp libcustr libofmt libumem; do
  cp_opt "$ROOT/usr/lib/$l.so" "usr/lib/$l.so" proto
  cp_opt "$ROOT/lib/$l.so"     "lib/$l.so"     proto
done
# the lib/64 + usr/lib/64 -> . compat symlinks (LP64 self-reference)
cp_opt "$ROOT/lib/64"     lib/64     proto
cp_opt "$ROOT/usr/lib/64" usr/lib/64 proto

echo "=== 2. proto: system headers (whole tree) ==="
cp_req "$ROOT/usr/include" usr/include proto

echo "=== 3. proto: runtime linker + link-editor shared objects ==="
cp_glob "$ROOT/lib/librtld.so.*"         lib     proto req
cp_glob "$ROOT/lib/libld.so.*"           lib     proto req
cp_glob "$ROOT/lib/liblddbg.so.*"        lib     proto req
cp_glob "$ROOT/usr/lib/libldstab.so.*"   usr/lib proto req
cp_glob "$ROOT/usr/lib/liblddbg.so.*"    usr/lib proto opt
if [ -d "$ROOT/usr/lib/ld" ]; then cp_req "$ROOT/usr/lib/ld" usr/lib/ld proto; else warn "no usr/lib/ld in proto"; fi

echo "=== 4. proto: Solaris ld + ELF tools (aarch64-native, from the proto) ==="
cp_req  "$ROOT/usr/bin/ld"       usr/bin/ld       proto
cp_req  "$ROOT/usr/bin/elfdump"  usr/bin/elfdump  proto
cp_req  "$ROOT/usr/bin/elfedit"  usr/bin/elfedit  proto
cp_opt  "$ROOT/usr/bin/elffile"  usr/bin/elffile  proto
cp_opt  "$ROOT/usr/bin/nm"       usr/bin/nm       proto
cp_opt  "$ROOT/usr/bin/ar"       usr/bin/ar       proto
cp_opt  "$ROOT/usr/bin/mcs"      usr/bin/mcs      proto
cp_opt  "$ROOT/usr/bin/as"       usr/bin/as       proto
# elfedit's loadable modules (the x86 seed omitted these -> "no such module: dyn")
if [ -d "$ROOT/usr/lib/elfedit" ]; then cp_req "$ROOT/usr/lib/elfedit" usr/lib/elfedit proto; else warn "no usr/lib/elfedit modules in proto"; fi

echo "=== 5. capture versions / provenance ==="
{
  echo "# solnix aarch64 seed manifest — generated $(date -u +%FT%TZ)"
  echo "# host uname: $(uname -a)"
  echo "# target triple: aarch64-unknown-solaris2.11 (LP64, no-multilib)"
  echo "# NOTE: target-sysroot seed only; cross gcc/\$CROSS not in the archived"
  echo "#       proto (died with numa). libcCross points at this sysroot."
  echo "# libc elfdump -d (SONAME/NEEDED):"
  "$ROOT/usr/bin/elfdump" -d "$ROOT/lib/libc.so.1" 2>/dev/null | sed 's/^/#   /' | head -20 || \
    elfdump -d "$ROOT/lib/libc.so.1" 2>/dev/null | sed 's/^/#   /' | head -20 || true
  if [ -d "$GATE/.git" ]; then
    echo "# gate git commit: $(cd "$GATE" && git rev-parse HEAD 2>/dev/null || echo 73466454-archived)"
  else
    echo "# gate rev (from archive): 73466454e9892e23a7860b3bd591d90accb85bd4"
  fi
  echo "# ---- provenance<TAB>src<TAB>dest<TAB>sha256 ----"
} > "$MANIFEST.hdr"
cat "$MANIFEST" >> "$MANIFEST.hdr" && mv "$MANIFEST.hdr" "$MANIFEST"

echo "=== 6. tarball ==="
( cd "$OUT" && tar -cf - seed | zstd -19 -T0 -o aarch64-seed.tar.zst )
SEEDSUM="$(digest -a sha256 "$OUT/aarch64-seed.tar.zst" 2>/dev/null || echo unknown)"
echo "aarch64-seed.tar.zst sha256: $SEEDSUM" | tee -a "$MANIFEST"
echo "SIZE: $(ls -l "$OUT/aarch64-seed.tar.zst" | awk '{print $5}') bytes"

echo
echo "DONE."
echo "  seed tree: $SEED"
echo "  manifest:  $MANIFEST"
echo "  tarball:   $OUT/aarch64-seed.tar.zst  ($SEEDSUM)"
