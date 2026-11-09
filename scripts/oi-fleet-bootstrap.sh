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
# bootstrap-register.sh's `cp -Pf runtime-lib/*` copies nothing under illumos cp
# (the -P flag semantics differ), leaving /nix-tools224/runtime-lib empty. Do the
# copy directly with plain cp -f so the 39-lib runtime closure is in place.
if [ -d /nix-tools224 ] && [ -d runtime-lib ]; then
  mkdir -p /nix-tools224/runtime-lib
  cp -f runtime-lib/* /nix-tools224/runtime-lib/ 2>/dev/null || true
  [ -f ca-bundle.crt ] && cp -f ca-bundle.crt /nix-tools224/ca-bundle.crt 2>/dev/null || true
fi
NIXBIN=$(ls -d /nix-tools224/bin /nix-tools/bin 2>/dev/null | head -1)
NIXROOT=${NIXBIN%/bin}
mkdir -p /etc/profile.d /etc/nix
# The transitive nix libs (libnixstore.so etc.) carry build-host RUNPATHs
# (/usr/gcc/13, /usr/openssl/3, /var/tmp/libgit2-inst) not present on a bare
# host, so LD_LIBRARY_PATH=runtime-lib is required despite the top binary's own
# runtime-lib RUNPATH. (Bootstrap-tool concern only; final closures are host-free.)
cat > /etc/profile.d/nix-illumos.sh <<EOF
export PATH=${NIXBIN}:\$PATH
export NIX_CONF_DIR=${NIXROOT}/etc/nix
export LD_LIBRARY_PATH=${NIXROOT}/runtime-lib:${NIXROOT}/lib:${NIXROOT}/lib/amd64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
EOF
# ca-bundle lives at /nix-tools224/ca-bundle.crt (register script), fall back to
# the etc/ssl path if present.
SSLCERT=${NIXROOT}/ca-bundle.crt
[ -f "$SSLCERT" ] || SSLCERT=${NIXROOT}/etc/ssl/certs/ca-bundle.crt
cat > /etc/nix/nix.conf <<EOF
substituters = https://cache.solnix.io https://cache.nixos.org
trusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
ssl-cert-file = ${SSLCERT}
sandbox = false
build-users-group =
builders-use-substitutes = true
experimental-features = nix-command flakes
EOF
mkdir -p ${NIXROOT}/etc/nix && cp /etc/nix/nix.conf ${NIXROOT}/etc/nix/nix.conf
/nix-tools224/bin/nix-store --init 2>/dev/null || true
. /etc/profile.d/nix-illumos.sh
echo "nix: $(nix --version 2>&1 | head -1); cache: $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://cache.solnix.io/nix-cache-info)"
REMOTE
