#!/usr/bin/env bash
# slice-host-bootstrap.sh -- prepare the illumos node for PROTO SLICING (step 2).
# Run ON the node as root, detached. Unlike gatefod-host-bootstrap.sh this does NOT
# build the gate (~1h55m): the proto is already banked in R2 by step 1, so we fetch
# and ingest it. onbld/gcc are therefore not needed either.
set -u
LOG=/var/log/slice
mkdir -p "$LOG"
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin

step() { echo "=== $(date -u +%FT%TZ) $* ==="; }

step "stage 0: MTU (pkg/curl over ena0 needs 1400 on this AMI)"
ifconfig ena0 mtu 1400 2>/dev/null || true

step "stage 1: minimal IPS prereqs (zstd for the tarballs, gnu-diffutils for real diff)"
pkg set-publisher -G '*' -g https://pkg.openindiana.org/hipster/ openindiana.org 2>&1 | tail -2
for p in compress/zstd text/gnu-diffutils; do
  env PKG_CLIENT_CONNECT_TIMEOUT=60 PKG_CLIENT_LOWSPEED_TIMEOUT=180 \
      PKG_CLIENT_MAX_CONSECUTIVE_ERROR=10 PKG_CLIENT_MAX_TIMEOUT=20 \
    pkg install -v "$p" >> "$LOG/1-pkg.log" 2>&1
  echo "pkg install $p exit=$?"
done
command -v zstd gzip 2>&1

step "stage 2: Nix 2.24.15 from the banked relocatable tarball"
zfs list rpool/nix >/dev/null 2>&1 || zfs create -o mountpoint=/nix rpool/nix
mkdir -p /root/nixboot && cd /root/nixboot
curl -fsSL https://cache.solnix.io/bootstrap/nix-illumos-2.24.15.tar.zst -o n.tar.zst \
  || curl -fsSL https://s3.solnix.io/solnix-cache/bootstrap/nix-illumos-2.24.15.tar.zst -o n.tar.zst
ls -l n.tar.zst
zstd -d n.tar.zst -o n.tar && tar xf n.tar
[ -f bootstrap-register.sh ] && sh ./bootstrap-register.sh > "$LOG/2-nixreg.log" 2>&1
# bootstrap-register.sh's `cp -Pf runtime-lib/*` copies nothing under illumos cp,
# leaving the 39-lib runtime closure absent. Do it with plain cp -f.
if [ -d /nix-tools224 ] && [ -d runtime-lib ]; then
  mkdir -p /nix-tools224/runtime-lib
  cp -f runtime-lib/* /nix-tools224/runtime-lib/ 2>/dev/null || true
  [ -f ca-bundle.crt ] && cp -f ca-bundle.crt /nix-tools224/ca-bundle.crt
fi
NIXROOT=/nix-tools224
mkdir -p /etc/profile.d /etc/nix "$NIXROOT/etc/nix"
cat > /etc/profile.d/nix-illumos.sh <<EOF
export PATH=$NIXROOT/bin:\$PATH
export NIX_CONF_DIR=$NIXROOT/etc/nix
export LD_LIBRARY_PATH=$NIXROOT/runtime-lib:$NIXROOT/lib:$NIXROOT/lib/amd64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
EOF
SSLCERT=$NIXROOT/ca-bundle.crt
[ -f "$SSLCERT" ] || SSLCERT=$NIXROOT/etc/ssl/certs/ca-bundle.crt
cat > /etc/nix/nix.conf <<EOF
substituters = https://cache.solnix.io https://cache.nixos.org
trusted-public-keys = cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
ssl-cert-file = $SSLCERT
sandbox = false
build-users-group =
builders-use-substitutes = true
experimental-features = nix-command flakes
EOF
cp /etc/nix/nix.conf "$NIXROOT/etc/nix/nix.conf"
. /etc/profile.d/nix-illumos.sh
nix-store --init 2>/dev/null || true
nix --version 2>&1 | head -1

step "stage 3: the BANKED GATE PROTO from R2 (step 1's output; NOT rebuilt)"
# 219,678,907 B gzip, read-back verified by step 1. /var/tmp, NOT /tmp: illumos
# /tmp is tmpfs (RAM) and the unpacked proto is ~500 MB.
PROTO_URL=https://s3.solnix.io/solnix-cache/proto/x86_64-gate-ac45d71fc2-20260914/proto-root_i386-gate-ac45d71fc2.tar.gz
mkdir -p /var/tmp/protofetch && cd /var/tmp/protofetch
curl -fsSL "$PROTO_URL" -o proto.tar.gz \
  || curl -fsSL "https://cache.solnix.io/proto/x86_64-gate-ac45d71fc2-20260914/proto-root_i386-gate-ac45d71fc2.tar.gz" -o proto.tar.gz
echo "proto tarball bytes: $(wc -c < proto.tar.gz | tr -d ' ')"
# gzip magic check -- a 403/404 XML body would otherwise unpack to nothing and the
# failure would surface much later as "path not in proto".
magic=$(od -An -tx1 -N2 proto.tar.gz | tr -d ' \n')
[ "$magic" = "1f8b" ] || { echo "FATAL: not gzip (magic $magic); first bytes:"; head -c 200 proto.tar.gz; exit 1; }
mkdir -p /var/tmp/proto-unpack && cd /var/tmp/proto-unpack
gzip -dc /var/tmp/protofetch/proto.tar.gz | /usr/gnu/bin/tar xf - 2>&1 | tail -3
ls -d /var/tmp/proto-unpack/* | head
step "BOOTSTRAP DONE"
