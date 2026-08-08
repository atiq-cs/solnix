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
#   oi-inject-ena.sh -R <root>            install fixed ena into <root> (no bootadm)
#   oi-inject-ena.sh -R <root> --archive  install + rebuild <root> boot_archive
#
# Sources the fixed module from ENA_MODULE (default: the stripped module built
# from the patched gate). Verifies the installed driver defaults to 1500 (the
# ena_attach_device_init 0x5dc immediate) when a disassembler is available.
set -eu

ROOT=/
DO_ARCHIVE=0
# Fixed module: prefer an explicit ENA_MODULE, else the staged fixed module,
# else build it from the patched gate on demand.
ENA_MODULE="${ENA_MODULE:-/root/solnix-assets/ena-mtu-fix}"
GATE="${GATE:-/aarch64/arm64-gate/illumos-gate}"
GATE_ENA="$GATE/usr/src/uts/intel/ena/debug64/ena"

while [ $# -gt 0 ]; do
  case "$1" in
    -R) ROOT="$2"; shift 2 ;;
    --archive) DO_ARCHIVE=1; shift ;;
    *) echo "usage: $0 -R <root> [--archive]" >&2; exit 2 ;;
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
log "done"
