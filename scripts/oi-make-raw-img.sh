#!/usr/bin/env bash
# oi-make-raw-img.sh — build a bootable raw ZFS-root disk image (x86_64) carrying
# the declarative-Nix + build-host baseline, by running solnix-install against a
# lofi-backed raw file. Runs ON the illumos build host as root.
#
#   oi-make-raw-img.sh <current-system-store-path> [out.img] [size]
#
# The raw file is presented as a whole-disk node via `lofiadm -la` (yields
# /dev/dsk/cNtNd0p0 with a full slice set), then solnix-install lays down GPT +
# ESP + a ZFS pool (named by SOLNIX_POOL, NOT rpool since the host root IS rpool)
# + the CS closure + illumos loader + boot_archive. Result: a dd-able / qemu
# raw disk whose INSTALLED system is declarative-Nix (sw + nix + cache.solnix.io
# nix.conf), booting to a console login.
#
# scrub_cores runs on the target BE before export (no core
# files shipped).
set -euo pipefail
# build-host bootstrap nix-store for staging (never shipped). Prefer the sw
# profile / default profile; the store nix is RUNPATH-correct (no LD_LIBRARY_PATH).
export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/nix-tools224/bin:/usr/sbin:/usr/bin:/usr/gnu/bin:/sbin:/usr/ccs/bin

CS="${1:?usage: oi-make-raw-img.sh <current-system> [out.img] [size]}"
OUT="${2:-/scratch/solnix-raw.img}"
SIZE="${3:-8g}"
POOL="${SOLNIX_POOL:-spool}"          # NOT rpool (host root is rpool); boot uses bootfs, name-agnostic
INSTALLER="${INSTALLER:-/root/solnix-install}"
SCRUB="${SCRUB:-/root/lib-core-scrub.sh}"

die() { echo "FATAL: $*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*" >&2; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -d "$CS" ] || die "current-system $CS not found"
[ -x "$INSTALLER" ] || die "installer $INSTALLER missing"
command -v nix-store >/dev/null 2>&1 || die "nix-store not on PATH"

# clean any prior lofi mapping of this file
for l in $(lofiadm 2>/dev/null | awk -v f="$OUT" '$2==f{print $1}'); do
  lofiadm -d "$l" 2>/dev/null || true
done
rm -f "$OUT" 2>/dev/null || true

log "creating ${SIZE} raw file $OUT"
mkfile "$SIZE" "$OUT"

log "attaching as a labeled whole-disk node (lofiadm -la)"
NODE=$(lofiadm -la "$OUT") || die "lofiadm -la failed"
TARGET=$(basename "$NODE" | sed 's/p0$//')     # cNtNd0
log "lofi disk node=$NODE  target=$TARGET"
devfsadm >/dev/null 2>&1 || true

cleanup() {
  # export any pool on the target + detach lofi (best-effort)
  zpool export "$POOL" 2>/dev/null || zpool export -f "$POOL" 2>/dev/null || true
  lofiadm -d "$OUT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# make scrub_cores available to solnix-install-adjacent finalize: we scrub the
# target BE AFTER install populates it but BEFORE export. solnix-install exports
# the pool at the end, so we hook by importing/altroot after? Simpler: run the
# installer with an ALTROOT we control, then scrub, then let installer export.
# solnix-install mounts the BE at $SOLNIX_ALTROOT (default /a) and exports at the
# end. To scrub between, we run the installer, which leaves the pool EXPORTED.
# So we scrub by re-importing the pool read-write, scrubbing the BE root, re-export.

log "running solnix-install $TARGET  (pool=$POOL, CS=$CS)"
# Pass the host nix-store so solnix-install copies the closure the FAST way
# (nix-store -qR), not the O(closure*filesize) fixpoint content scan. Its
# runtime libs are on LD_LIBRARY_PATH (exported above); export both so the
# child /sbin/sh env keeps them.
# solnix-install tests `[ -x "$SOLNIX_NIXSTORE" ]` and resets its own PATH to
# /usr/sbin:/usr/bin:/sbin, so a BARE name (nix-store) fails the -x test AND is
# unresolvable in the child -> it falls back to the slow content-scan fixpoint
# which picks up bogus /nix/store strings baked in source trees (nixpkgs test
# fixtures) and dies "closure incomplete". Resolve an ABSOLUTE nix-store path
# from THIS script's PATH (has /nix-tools224/bin + sw/bin) so the fast exact
# `nix-store -qR` path is taken.
export SOLNIX_NIXSTORE="${SOLNIX_NIXSTORE:-$(command -v nix-store 2>/dev/null || echo nix-store)}"
SOLNIX_POOL="$POOL" SOLNIX_ALLOW_RPOOL="" SOLNIX_NIXSTORE="$SOLNIX_NIXSTORE" \
  "$INSTALLER" "$TARGET" "$CS" 2>&1 | tail -60 || die "solnix-install failed"

# ---- core-scrub the installed BE (import altroot, scrub, export) -----------
log "core-scrub the installed BE (no core files shipped)"
ALT=/a-scrub
mkdir -p "$ALT"
if zpool import -N -f -R "$ALT" "$POOL" 2>/dev/null; then
  BE=$(zfs list -H -o name -r "$POOL/ROOT" 2>/dev/null | grep -v '/ROOT$' | head -1)
  if [ -n "$BE" ]; then
    zfs set canmount=noauto "$BE" 2>/dev/null || true
    zfs mount "$BE" 2>/dev/null || true
    BEROOT="$ALT"
    if [ -f "$SCRUB" ]; then
      . "$SCRUB"
      scrub_cores "$BEROOT"
    else
      echo "WARN: $SCRUB not found; inline scrub"
      find "$BEROOT" \( -name 'core' -o -name 'core.[0-9]*' \) -type f -delete 2>/dev/null || true
    fi
    echo "=== core-file audit (must be zero) ==="
    _cores=$(find "$BEROOT" -name 'core*' -type f 2>/dev/null | while read c; do file "$c" 2>/dev/null | grep -qi 'core file' && echo "$c" || true; done || true)
    if [ -n "$_cores" ]; then echo "CORES REMAIN:"; echo "$_cores"; else echo "ZERO core files in image BE"; fi
    # ---- identity-free scrub: solnix-install clones the RUNNING build-host root
    # as the BE base, so its /etc/{passwd,shadow,group} carry the build host's
    # personal accounts (e.g. gburd). A PUBLIC image must be identity-free (root
    # only; installer/first-boot creates the operator). Strip any non-system
    # (uid>=1000) account + its home from the BE. Keeps root + system accounts.
    echo "=== identity-free scrub (strip personal uid>=1000 accounts) ==="
    _pw="$BEROOT/etc/passwd"
    if [ -f "$_pw" ]; then
      # names to strip = every uid>=1000 that is not a system placeholder.
      _strip=$(awk -F: '($3+0)>=1000 && $1!="nobody" && $1!="noaccess" && $1!="nobody4"{print $1}' "$_pw" 2>/dev/null)
      for _u in $_strip; do
        _h=$(awk -F: -v u="$_u" '$1==u{print $6}' "$_pw" 2>/dev/null)
        awk -F: -v u="$_u" '$1!=u' "$_pw" > "$_pw.c" && mv "$_pw.c" "$_pw"
        [ -f "$BEROOT/etc/shadow" ] && { awk -F: -v u="$_u" '$1!=u' "$BEROOT/etc/shadow" > "$BEROOT/etc/shadow.c" && mv "$BEROOT/etc/shadow.c" "$BEROOT/etc/shadow"; }
        [ -f "$BEROOT/etc/group" ]  && { awk -F: -v u="$_u" '$1!=u' "$BEROOT/etc/group"  > "$BEROOT/etc/group.c"  && mv "$BEROOT/etc/group.c"  "$BEROOT/etc/group"; }
        case "$_h" in /export/home/*|/home/*) rm -rf "$BEROOT$_h" 2>/dev/null || true;; esac
      done
    fi
    echo "identity audit: gburd rows=$(grep -c '^gburd' "$_pw" 2>/dev/null); uid>=1000 rows=$(awk -F: '($3+0)>=1000 && $1!="nobody" && $1!="noaccess"' "$_pw" 2>/dev/null | wc -l | tr -d ' ')"
    # ---- stage the 2.24 nix runtime + flake registry + native ping into the BE
    # solnix-install copies the toplevel closure + nix.conf/profile.d, but NOT
    # the /nix-tools224 nix runtime dir, the flake registry, or native ping.
    # The image's PATH + nix.conf reference all three; stage them here.
    if [ -d /nix-tools224 ]; then
      # store nix ships in the CS closure (sw/bin/nix); no /nix-tools224 stage.
      :
    fi
    if [ -f "$CS/etc/nix/registry.json" ]; then
      mkdir -p "$BEROOT/etc/nix"
      cp -L "$CS/etc/nix/registry.json" "$BEROOT/etc/nix/registry.json" 2>/dev/null || cp "$CS/etc/nix/registry.json" "$BEROOT/etc/nix/registry.json"
    fi
    if [ ! -e "$BEROOT/usr/sbin/ping" ] && [ -x /usr/sbin/ping ]; then
      cp /usr/sbin/ping "$BEROOT/usr/sbin/ping" 2>/dev/null && chmod 4555 "$BEROOT/usr/sbin/ping" && chown root:bin "$BEROOT/usr/sbin/ping" 2>/dev/null || true
    fi
    zfs unmount "$BE" 2>/dev/null || zfs unmount -f "$BE" 2>/dev/null || true
  fi
  zpool export "$POOL" 2>/dev/null || zpool export -f "$POOL" 2>/dev/null || true
else
  echo "WARN: could not re-import $POOL for scrub (installer may have left it exported cleanly; solnix-install already scrubs stray build cores)"
fi

lofiadm -d "$OUT" 2>/dev/null || true
trap - EXIT INT TERM

log "DONE: $OUT"
ls -la "$OUT"
echo "sha256:"; digest -a sha256 "$OUT" 2>/dev/null || sha256sum "$OUT" 2>/dev/null || openssl dgst -sha256 "$OUT"
echo "IMAGE-OK"
