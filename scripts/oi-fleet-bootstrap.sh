#!/usr/bin/env bash
# oi-fleet-bootstrap.sh — bring a fresh OI-build-AMI fleet host to a nix-ready state.
# Usage: HOST=root@<ip> bash scripts/oi-fleet-bootstrap.sh
# Steps: MTU fix -> pkg update to the 2026 userland (gcc-13 + library/mpfr for the
#        seed gawk) -> expand rpool onto the (larger) EBS -> create rpool/nix ->
#        install Nix 2.24.15 from the relocatable bootstrap tarball (NO compile) ->
#        wire /etc/profile.d PATH + /etc/nix/nix.conf (cache.solnix.io + trusted key).
# The 2.24 tarball is RELOCATABLE (RUNPATH-correct, no LD_LIBRARY_PATH needed) and
# ships a baked CA bundle referenced via ssl-cert-file in nix.conf.
set -euo pipefail
: "${HOST:?set HOST=root@<ip>}"
KEY="${KEY:-$HOME/.ssh/id_ed25519}"
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$HOST" 'bash -s' <<'REMOTE'
set -e
ifconfig ena0 mtu 1400 2>/dev/null || true
# 2026 userland (the fresh AMI pins 2025 which blocks gcc-N); library/mpfr is a
# stage0 seed-gawk host dep (the seed gawk NEEDs libmpfr.so.6 to run substituteAll).
pkg update --accept >/dev/null 2>&1 || true
pkg install -q library/mpfr >/dev/null 2>&1 || true
DISK=$(zpool status rpool 2>/dev/null | awk '/c[0-9]t[0-9]/{print $1; exit}')
zpool set autoexpand=on rpool 2>/dev/null || true
zpool online -e rpool "$DISK" 2>/dev/null || true
zfs list rpool/nix >/dev/null 2>&1 || zfs create -o mountpoint=/nix rpool/nix 2>/dev/null || mkdir -p /nix
[ -d /root/nixboot ] && find /root/nixboot -mindepth 1 -delete 2>/dev/null || mkdir -p /root/nixboot
cd /root/nixboot
curl -fsSL https://cache.solnix.io/bootstrap/nix-illumos-2.24.15.tar.zst -o n.tar.zst 2>/dev/null \
  || curl -fsSL https://s3.solnix.io/solnix-cache/bootstrap/nix-illumos-2.24.15.tar.zst -o n.tar.zst
zstd -d n.tar.zst -o n.tar && tar xf n.tar
# the 2.24 tarball installs to /nix-tools224 (relocatable); its register script wires
# the store DB. No LD_LIBRARY_PATH — the binaries are RUNPATH-correct.
[ -f bootstrap-register.sh ] && sh ./bootstrap-register.sh >/dev/null 2>&1 || true
NIXBIN=$(ls -d /nix-tools224/bin /nix-tools/bin 2>/dev/null | head -1)
mkdir -p /etc/profile.d /etc/nix
cat > /etc/profile.d/nix-illumos.sh <<EOF
export PATH=${NIXBIN}:\$PATH
EOF
cat > /etc/nix/nix.conf <<EOF
substituters = https://cache.solnix.io https://cache.nixos.org
trusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
ssl-cert-file = ${NIXBIN%/bin}/etc/ssl/certs/ca-bundle.crt
sandbox = false
build-users-group =
builders-use-substitutes = true
experimental-features = nix-command flakes
EOF
. /etc/profile.d/nix-illumos.sh
echo "nix: $(nix --version 2>&1 | head -1); cache: $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://cache.solnix.io/nix-cache-info)"
REMOTE
