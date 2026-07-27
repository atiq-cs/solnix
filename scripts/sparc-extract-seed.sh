#!/usr/bin/env bash
# sparc-extract-seed.sh — extract a sparcv9 target-sysroot seed from the Tribblix
# m34 sun4v_boot_archive (a big-endian SPARC UFS ramdisk), the S2 world source.
#
# ADAPTED FROM scripts/aa-extract-seed.sh (the aarch64 seed extractor). The two
# differ only in WHERE the proto lives and the ISA layout:
#   - aarch64 proto = an on-disk richlowe/arm64-gate proto/root_aarch64 (LP64,
#     no ISA subdir). sparc proto = the userland INSIDE the big-endian UFS
#     boot_archive (archive/sparc/extracted/sun4v_boot_archive). SPARC is
#     BIG-ENDIAN — Linux's native `ufs` driver reads it read-only via
#     `-o ufstype=sun` (the Sun/SPARC UFS variant). No custom reader needed.
#   - sparc keeps the classic ISA split like x86: 32-bit (SPARC32PLUS/V8+) libs
#     in lib/ + usr/lib/, and the 64-bit (SPARC V9, EM_SPARCV9) libs in
#     lib/sparcv9/ + usr/lib/sparcv9/. The sparcv9-solaris TARGET is 64-bit
#     (cpu=sparc64), so this seed carries the sparcv9/ (V9) objects — the
#     analog of x86's amd64/ subdir.
#   - The boot_archive is a RUNTIME ramdisk: it has libc/ld/rtld/link-editor +
#     headers but NO compile-time crt*.o/values-*.o and NO elfdump/elfedit
#     binaries (only the runtime linker path). So this seed is the TARGET-SYSROOT
#     half only (like aarch64's: the cross gcc / crt objects come later from a
#     native gate build on the maintainer's Ultra 45). The RUNPATH relocation
#     that the Nix world slices do uses the HOST illumos elfedit (arch-independent
#     mechanism), so shipping sparc elfedit in the seed is unnecessary.
#
# RUNS ON: the Linux dev-box (has the local archive + `ufs` kernel module) OR any
# host with the big-endian UFS mounted read-only. Root needed for the loop mount
# + symlink/perm preservation.
#
# Output (in $OUT, default /var/tmp/solnix-sparc-seed):
#   seed/               staging tree (mirrors on-disk layout, sparcv9/ ISA subdir)
#   seed-manifest.txt   provenance + sha256
#   sparc-seed.tar.zst
set -euo pipefail

ARCHIVE="${ARCHIVE:-$HOME/ws/solnix-archive/sparc}"
BOOT_ARCHIVE="${BOOT_ARCHIVE:-$ARCHIVE/extracted/sun4v_boot_archive}"
MNT="${MNT:-/mnt/sparc-ba}"
OUT="${OUT:-/var/tmp/solnix-sparc-seed}"
SEED="$OUT/seed"
MANIFEST="$OUT/seed-manifest.txt"

die()  { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

[ "$(id -u)" = 0 ]  || die "run as root (loop mount + symlink/perm preservation)"
command -v zstd >/dev/null || die "zstd not on PATH"

# --- mount the big-endian SPARC UFS read-only if not already mounted ---
ROOT="$MNT"
if ! mountpoint -q "$MNT" 2>/dev/null && [ ! -e "$MNT/lib/sparcv9/libc.so.1" ]; then
  [ -f "$BOOT_ARCHIVE" ] || die "boot_archive not found: $BOOT_ARCHIVE"
  file "$BOOT_ARCHIVE" | grep -qi 'big-endian' || die "not a big-endian UFS: $BOOT_ARCHIVE"
  mkdir -p "$MNT"
  modprobe ufs 2>/dev/null || true
  LOOP="$(losetup -f --show -r "$BOOT_ARCHIVE")"
  mount -t ufs -o ufstype=sun,ro "$LOOP" "$MNT" \
    || die "mount failed (need Linux ufs module, ufstype=sun for big-endian SPARC UFS)"
  echo "mounted $BOOT_ARCHIVE ($LOOP) at $MNT (ro, ufstype=sun)"
  MOUNTED_HERE=1
fi
[ -f "$ROOT/lib/sparcv9/libc.so.1" ] || die "no sparcv9 libc in proto: $ROOT/lib/sparcv9/libc.so.1"
[ -f "$ROOT/lib/sparcv9/ld.so.1" ]   || die "no sparcv9 rtld in proto: $ROOT/lib/sparcv9/ld.so.1"

cleanup() {
  if [ "${MOUNTED_HERE:-0}" = 1 ]; then
    umount "$MNT" 2>/dev/null || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

rm -rf "$OUT"; mkdir -p "$SEED"
: > "$MANIFEST"

_record() { local src="$1" dst="$2" prov="$3" sum
  sum="$(sha256sum "$SEED/$dst" 2>/dev/null | awk '{print $1}' || echo unknown)"
  printf '%s\t%s\t%s\t%s\n' "$prov" "$src" "$dst" "$sum" >> "$MANIFEST"; }
_cp() { local src="$1" dst="$2" prov="$3" req="$4"
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    if [ "$req" = req ]; then die "missing required: $src"; else warn "missing optional: $src"; return 0; fi
  fi
  mkdir -p "$SEED/$(dirname "$dst")"
  cp -a "$src" "$SEED/$dst" 2>/dev/null || cp -RP "$src" "$SEED/$dst"
  [ -L "$src" ] || _record "$src" "$dst" "$prov"; }
cp_req()  { _cp "$1" "$2" "$3" req; }
cp_opt()  { _cp "$1" "$2" "$3" opt; }
cp_glob() { local g="$1" dd="$2" prov="$3" req="$4" n=0 f
  for f in $g; do [ -e "$f" ] || continue
    cp_req "$f" "$dd/$(basename "$f")" "$prov"; n=$((n+1)); done
  [ "$n" -gt 0 ] || { [ "$req" = req ] && die "glob matched nothing: $g" || warn "glob empty: $g"; }; }

echo "=== 1. proto: sparcv9 (64-bit, EM_SPARCV9) libc + siblings (lib/sparcv9) ==="
cp_req  "$ROOT/lib/sparcv9/ld.so.1"          lib/sparcv9/ld.so.1          proto
cp_req  "$ROOT/lib/sparcv9/libc.so.1"        lib/sparcv9/libc.so.1        proto
cp_glob "$ROOT/lib/sparcv9/libm.so.*"        lib/sparcv9                  proto req
cp_glob "$ROOT/lib/sparcv9/libsocket.so.*"   lib/sparcv9                  proto req
cp_glob "$ROOT/lib/sparcv9/libnsl.so.*"      lib/sparcv9                  proto req
cp_glob "$ROOT/lib/sparcv9/libresolv.so.*"   lib/sparcv9                  proto req
cp_glob "$ROOT/lib/sparcv9/libelf.so.*"      lib/sparcv9                  proto req
cp_glob "$ROOT/lib/sparcv9/libmd.so.*"       lib/sparcv9                  proto req
cp_opt  "$ROOT/lib/sparcv9/libpthread.so.1"  lib/sparcv9/libpthread.so.1  proto
cp_opt  "$ROOT/lib/sparcv9/librt.so.1"       lib/sparcv9/librt.so.1       proto
cp_opt  "$ROOT/lib/sparcv9/libdl.so.1"       lib/sparcv9/libdl.so.1       proto
cp_opt  "$ROOT/lib/sparcv9/libmp.so.2"       lib/sparcv9/libmp.so.2       proto
cp_opt  "$ROOT/lib/sparcv9/libcustr.so.1"    lib/sparcv9/libcustr.so.1    proto
cp_opt  "$ROOT/lib/sparcv9/libofmt.so.1"     lib/sparcv9/libofmt.so.1     proto
cp_opt  "$ROOT/lib/sparcv9/libumem.so.1"     lib/sparcv9/libumem.so.1     proto

# link-editor .so -> .so.N symlinks (cp -a keeps them as symlinks)
for l in libc libm libsocket libnsl libresolv libelf libpthread librt libdl \
         libmp libcustr libofmt libumem; do
  cp_opt "$ROOT/usr/lib/sparcv9/$l.so" "usr/lib/sparcv9/$l.so" proto
  cp_opt "$ROOT/lib/sparcv9/$l.so"     "lib/sparcv9/$l.so"     proto
done

echo "=== 2. proto: system headers (whole tree; arch-independent) ==="
cp_req "$ROOT/usr/include" usr/include proto

echo "=== 3. proto: runtime linker + link-editor shared objects (sparcv9) ==="
cp_glob "$ROOT/lib/sparcv9/librtld.so.*"         lib/sparcv9     proto req
cp_glob "$ROOT/lib/sparcv9/libld.so.*"           lib/sparcv9     proto req
cp_glob "$ROOT/lib/sparcv9/liblddbg.so.*"        lib/sparcv9     proto req
cp_glob "$ROOT/usr/lib/sparcv9/libldstab.so.*"   usr/lib/sparcv9 proto req
if [ -d "$ROOT/usr/lib/ld" ]; then cp_req "$ROOT/usr/lib/ld" usr/lib/ld proto; else warn "no usr/lib/ld in proto"; fi

echo "=== 4. proto: Solaris ld (sparc-native) — elfdump/elfedit NOT in the ramdisk ==="
# the boot_archive ships the runtime `ld` but not elfdump/elfedit (build tools).
# The world-slice RUNPATH relocation uses the HOST illumos elfedit (arch-agnostic).
cp_opt  "$ROOT/usr/bin/ld"       usr/bin/ld       proto
cp_opt  "$ROOT/usr/bin/nm"       usr/bin/nm       proto
cp_opt  "$ROOT/usr/bin/ar"       usr/bin/ar       proto
cp_opt  "$ROOT/usr/bin/mcs"      usr/bin/mcs      proto
cp_opt  "$ROOT/usr/bin/as"       usr/bin/as       proto

echo "=== 5. capture versions / provenance ==="
{
  echo "# solnix sparcv9 seed manifest — generated $(date -u +%FT%TZ)"
  echo "# host uname: $(uname -a)"
  echo "# target triple: sparcv9-unknown-solaris2.11 (cpu=sparc64, BIG-ENDIAN, LP64 via sparcv9/ ISA)"
  echo "# source: Tribblix m34 sun4v_boot_archive (big-endian SPARC UFS ramdisk)"
  echo "#   ISO: tribblix-sparc-0m34.iso sha256 afc1b115633c5a3c63bb683c0608fd22c41568eb5909f09556e045caa04aa323"
  echo "#   recipe: illumos-gate base 6538c7b4c76e1d53fc801540cfe1dfe59d26bf29 (2021-11-05), gcc4.4.4, native sparc"
  echo "# NOTE: target-sysroot seed only; NO crt*.o/values-*.o (runtime ramdisk has"
  echo "#       no compile-time startup objects), NO elfdump/elfedit (build tools)."
  echo "#       The eventual authoritative source is the maintainer's Ultra 45 (OI"
  echo "#       Hipster on sparc) native gate build; this Tribblix m34 userland is"
  echo "#       the same illumos-gate lineage and is what we can slice now."
  echo "# sparcv9 libc readelf (Class/Data/Machine):"
  readelf -h "$ROOT/lib/sparcv9/libc.so.1" 2>/dev/null | grep -E 'Class|Data|Machine' | sed 's/^/#   /' || true
  echo "# ---- provenance<TAB>src<TAB>dest<TAB>sha256 ----"
} > "$MANIFEST.hdr"
cat "$MANIFEST" >> "$MANIFEST.hdr" && mv "$MANIFEST.hdr" "$MANIFEST"

echo "=== 6. tarball ==="
( cd "$OUT" && tar -cf - seed | zstd -19 -T0 -o sparc-seed.tar.zst )
SEEDSUM="$(sha256sum "$OUT/sparc-seed.tar.zst" | awk '{print $1}')"
echo "sparc-seed.tar.zst sha256: $SEEDSUM" | tee -a "$MANIFEST"
echo "SIZE: $(stat -c %s "$OUT/sparc-seed.tar.zst" 2>/dev/null || ls -l "$OUT/sparc-seed.tar.zst" | awk '{print $5}') bytes"

echo
echo "DONE."
echo "  seed tree: $SEED"
echo "  manifest:  $MANIFEST"
echo "  tarball:   $OUT/sparc-seed.tar.zst  ($SEEDSUM)"
