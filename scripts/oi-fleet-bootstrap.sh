#!/usr/bin/env bash
# oi-fleet-bootstrap.sh — bring a fresh OI-build-AMI fleet host to a nix-ready state.
# Usage: HOST=root@<ip> bash scripts/oi-fleet-bootstrap.sh
# Steps: MTU fix -> expand rpool onto the (larger) EBS -> create rpool/nix ->
#        install Nix 2.3.16 from the account-proof bootstrap tarball (NO compile) ->
#        wire profile.d env (LD_LIBRARY_PATH=runtime-lib) + /etc/nix/nix.conf
#        (substituters=cache.solnix.io + the current trusted pubkey).
# NOTE: the fresh OI build AMI ships gcc/pkg but NO nix; the bootstrap tarball at
#       cache.solnix.io/bootstrap makes this a minutes-not-hours, compiler-free step.
set -euo pipefail
: "${HOST:?set HOST=root@<ip>}"
KEY="${KEY:-$HOME/.ssh/id_ed25519}"
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$HOST" 'bash -s' <<'REMOTE'
set -e
ifconfig ena0 mtu 1400 2>/dev/null || true
DISK=$(zpool status rpool 2>/dev/null | awk '/c[0-9]t[0-9]/{print $1; exit}')
zpool set autoexpand=on rpool 2>/dev/null || true
zpool online -e rpool "$DISK" 2>/dev/null || true
zfs list rpool/nix >/dev/null 2>&1 || zfs create -o mountpoint=/nix rpool/nix 2>/dev/null || mkdir -p /nix
[ -d /root/nixboot ] && find /root/nixboot -mindepth 1 -delete 2>/dev/null || mkdir -p /root/nixboot
cd /root/nixboot
curl -fsSL https://cache.solnix.io/bootstrap/nix-illumos-2.3.16.tar.zst -o n.tar.zst 2>/dev/null \
  || curl -fsSL https://s3.solnix.io/solnix-cache/bootstrap/nix-illumos-2.3.16.tar.zst -o n.tar.zst
zstd -d n.tar.zst -o n.tar && tar xf n.tar
[ -f bootstrap-register.sh ] && sh ./bootstrap-register.sh >/dev/null 2>&1 || true
RTL=$(ls -d /nix-tools/runtime-lib /root/nixboot/runtime-lib 2>/dev/null | head -1)
mkdir -p /etc/profile.d /etc/nix
cat > /etc/profile.d/nix-illumos.sh <<EOF
export PATH=/nix-tools/bin:\$PATH
export LD_LIBRARY_PATH=${RTL}:/nix-tools/lib:\${LD_LIBRARY_PATH:-}
EOF
cat > /etc/nix/nix.conf <<EOF
substituters = https://cache.solnix.io https://cache.nixos.org
trusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
sandbox = false
build-users-group =
EOF
. /etc/profile.d/nix-illumos.sh
echo "nix: $(nix-store --version 2>&1 | head -1); cache: $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://cache.solnix.io/nix-cache-info)"
REMOTE
