#!/usr/bin/env bash
# oi-fleet-build.sh — fan package builds across the illumos builder fleet.
#
# Usage:
#   oi-fleet-build.sh sync                 # push pkgs/scripts to every builder
#   oi-fleet-build.sh build <IP> <cc> <pkg...>   # build pkgs (compiler cc) on IP
#   oi-fleet-build.sh path  <IP> <cc> <pkg>      # print the store path (build if needed)
#
# The build wave is orchestrated by the caller (round-robin assignment); this
# script is the per-host worker. Builds run with GNU-nproc parallelism inside
# each package; multiple packages per host run sequentially here (the caller
# parallelizes across hosts + can launch multiple `build` calls per host).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
SSH() { ./scripts/oi-ssh.sh "$@"; }
HOST_ENV='export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin; export NIX_CONF_DIR=/nix-tools/etc/nix;'
REMOTE=/var/tmp/solnix-pkgs

FLEET_IPS=(18.188.11.117 18.226.58.142 18.227.80.34 3.22.168.45 3.134.97.192)

sync_one() {
  local IP="$1"
  SSH "$IP" "mkdir -p $REMOTE/pkgs/illumos $REMOTE/scripts" >/dev/null 2>&1
  for f in pkgs/illumos/mk-userland-pkg.nix pkgs/illumos/packages.nix \
           pkgs/illumos/mk-illumos-component.nix scripts/oi-cc-wrapper.sh; do
    [ -f "$f" ] && cat "$f" | SSH "$IP" "cat > $REMOTE/$f"
  done
  echo "synced $IP"
}

case "${1:-}" in
  sync)
    shift
    ips=("${@:-${FLEET_IPS[@]}}")
    for IP in "${ips[@]}"; do sync_one "$IP" & done
    wait
    ;;
  build)
    IP="$2"; CC="$3"; shift 3
    for pkg in "$@"; do
      echo "### $IP $CC $pkg ###"
      SSH "$IP" "$HOST_ENV cd $REMOTE/pkgs/illumos && nix-build packages.nix -A $pkg.$CC --no-out-link 2>&1 | tail -3"
    done
    ;;
  path)
    IP="$2"; CC="$3"; PKG="$4"
    SSH "$IP" "$HOST_ENV cd $REMOTE/pkgs/illumos && nix-build packages.nix -A $PKG.$CC --no-out-link 2>/dev/null"
    ;;
  *)
    echo "usage: $0 {sync|build <IP> <cc> <pkg...>|path <IP> <cc> <pkg>}" >&2; exit 1;;
esac
