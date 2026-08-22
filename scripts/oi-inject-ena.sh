#!/usr/bin/env bash
# oi-inject-ena.sh — install the MTU-1500-default ena kernel module into a target
# root so the built image ships the fixed driver (min(max_mtu, ETHERMTU) instead
# of the jumbo device max). The stock gate ena defaults ena_mtu to the device
# maximum (jumbo 9216); on some EC2 Nitro backends a queue programmed with
# jumbo-sized Rx buffers does not reliably deliver small broadcast frames on cold
# boot, so the DHCP OFFER is never received and the interface comes up but never
# gets a lease. Defaulting to a standard 1500-byte MTU (patch
# pkgs/illumos/patches/ena-default-mtu-1500.patch) fixes cold-launch DHCP; larger
# MTUs remain reachable via the device max.
#
#   oi-inject-ena.sh -R <root>                   install fixed ena into <root> (no bootadm)
#   oi-inject-ena.sh -R <root> --archive         install + rebuild <root> boot_archive (needs bootadm/illumos)
#   oi-inject-ena.sh -R <root> --archive-offline install + repack <root> boot_archive WITHOUT bootadm
#
# Sources the fixed module from ENA_MODULE (default: the stripped module built
# from the patched gate). Verifies the installed driver defaults to 1500 (the
# ena_attach_device_init 0x5dc immediate) when a disassembler is available.
#
# OFFLINE INJECTION (no running illumos node) — proven method that built
# ami-0fd4acf5e378c3e25 from a Linux helper (AL2023, kernel 6.18):
#   1. Build OpenZFS from source vs the kernel headers (no distro pkg on AL2023):
#        ./autogen.sh && ./configure --with-linux=/lib/modules/$(uname -r)/build && make -j && make install
#        modprobe zfs   # OpenZFS 2.4.4 imports illumos pools read-write, no feature-flag mismatch
#   2. zpool import -f -R /mnt/illumos <pool>   # illumos root pool is "spool"; BE = spool/ROOT/<be>
#      zfs mount <pool>/ROOT/<be>
#   3. oi-inject-ena.sh -R /mnt/illumos --archive-offline
#   4. zfs unmount; zpool export <pool>; snapshot the vol; register a uefi/ena AMI.
# The illumos boot_archive is a gzip'd odc (POSIX ASCII) cpio; /boot/loader.conf
# on solnix sets boot_archive.hash_load="NO", so the .hash file is NOT verified
# (do not bother recomputing it). The loader reads boot_archive directly, so the
# fixed ena MUST be inside it — the on-disk replacement alone is not enough.
set -eu

ROOT=/
DO_ARCHIVE=0
DO_ARCHIVE_OFFLINE=0
# Fixed module: prefer an explicit ENA_MODULE, else the staged fixed module,
# else build it from the patched gate on demand.
ENA_MODULE="${ENA_MODULE:-/root/solnix-assets/ena-mtu-fix}"
GATE="${GATE:-/aarch64/arm64-gate/illumos-gate}"
GATE_ENA="$GATE/usr/src/uts/intel/ena/debug64/ena"

while [ $# -gt 0 ]; do
  case "$1" in
    -R) ROOT="$2"; shift 2 ;;
    --archive) DO_ARCHIVE=1; shift ;;
    --archive-offline) DO_ARCHIVE_OFFLINE=1; shift ;;
    *) echo "usage: $0 -R <root> [--archive|--archive-offline]" >&2; exit 2 ;;
  esac
done

die() { echo "FATAL: $*" >&2; exit 1; }
log() { printf '\n=== oi-inject-ena: %s ===\n' "$*" >&2; }

# Resolve a fixed module. If the staged one is absent but the patched gate has a
# built module, strip it (the stripped gate module IS the fixed release module).
if [ ! -f "$ENA_MODULE" ] && [ -f "$GATE_ENA" ]; then
  log "staged module absent; stripping fixed module from patched gate build"
  cp "$GATE_ENA" /tmp/ena-mtu-fix.staged
  strip /tmp/ena-mtu-fix.staged 2>/dev/null || /usr/ccs/bin/strip /tmp/ena-mtu-fix.staged 2>/dev/null || true
  ENA_MODULE=/tmp/ena-mtu-fix.staged
fi
[ -f "$ENA_MODULE" ] || die "no fixed ena module ($ENA_MODULE); build the patched gate uts/intel/ena first"

DEST="$ROOT/kernel/drv/amd64/ena"
[ -d "$ROOT/kernel/drv/amd64" ] || die "no $ROOT/kernel/drv/amd64 (not an illumos root?)"

log "installing fixed ena -> $DEST (MTU-1500 default)"
cp "$ENA_MODULE" "$DEST"
chmod 0755 "$DEST"; chown root:sys "$DEST" 2>/dev/null || true
md5sum "$DEST" 2>/dev/null || digest -a md5 "$DEST" 2>/dev/null || true

# Verify the fix compiled in: ena_attach_device_init loads/compares 0x5dc (1500).
if command -v dis >/dev/null 2>&1; then
  if dis -F ena_attach_device_init "$DEST" 2>/dev/null | grep -q '0x5dc'; then
    log "verified: ena_attach_device_init defaults MTU to 0x5dc (1500)"
  else
    echo "WARN: could not confirm 0x5dc in ena_attach_device_init (driver may be stock jumbo-default)" >&2
  fi
fi

if [ "$DO_ARCHIVE" = 1 ]; then
  log "rebuilding boot_archive for $ROOT so the fixed ena is in the ramdisk"
  mkdir -p "$ROOT/platform/i86pc/amd64"
  bootadm update-archive -f -R "$ROOT" 2>&1 | grep -vE '^gzip:|cannot find' | tail -6 || true
fi

# Offline boot_archive repack (no bootadm/illumos): the archive is a gzip'd odc
# cpio; extract it, swap ena in the tree (same original entry order), repack,
# and re-gzip. hash_load="NO" in loader.conf so the .hash is not verified.
if [ "$DO_ARCHIVE_OFFLINE" = 1 ]; then
  BA="$ROOT/platform/i86pc/amd64/boot_archive"
  [ -f "$BA" ] || die "no boot_archive at $BA"
  command -v cpio >/dev/null || die "cpio required for --archive-offline"
  log "offline-repacking boot_archive $BA with the fixed ena"
  WD=$(mktemp -d); trap 'rm -rf "$WD"' EXIT
  gunzip -c "$BA" > "$WD/ba.cpio"
  ( cd "$WD" && cpio -it < ba.cpio 2>/dev/null > order.txt )
  mkdir -p "$WD/root"
  ( cd "$WD/root" && cpio -idm --no-absolute-filenames < "$WD/ba.cpio" 2>/dev/null )
  [ -f "$WD/root/kernel/drv/amd64/ena" ] || die "boot_archive has no kernel/drv/amd64/ena"
  cp "$ENA_MODULE" "$WD/root/kernel/drv/amd64/ena"
  chmod 0755 "$WD/root/kernel/drv/amd64/ena"
  chown 0:3 "$WD/root/kernel/drv/amd64/ena" 2>/dev/null || true
  ( cd "$WD/root" && cpio -o -H odc < "$WD/order.txt" 2>/dev/null > "$WD/ba.new.cpio" )
  cp -p "$BA" "$BA.stock.bak"
  gzip -c -9 "$WD/ba.new.cpio" > "$BA"
  # keep the per-file bootadm cache consistent so a later rebuild won't regress
  C="$ROOT/platform/i86pc/amd64/archive_cache/kernel/drv/amd64/ena"
  if [ -f "$C" ]; then cp -p "$C" "$C.stock.bak"; gzip -1 -c "$ENA_MODULE" > "$C"; fi
  log "offline boot_archive repacked (fixed ena inside; hash not verified per loader.conf)"
fi
log "done"
