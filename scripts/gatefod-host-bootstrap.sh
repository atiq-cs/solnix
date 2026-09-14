#!/usr/bin/env bash
# gatefod-host-bootstrap.sh -- prepare the m5.8xlarge illumos node for a
# gate-in-a-Nix-derivation experiment. Run ON the node as root, detached.
#
# Three stages, each logged separately so a poll can tell which one is running:
#   1. IPS prereqs (onbld + the five prereqs found the expensive way)
#   2. Nix 2.24.15 from the banked relocatable tarball (NO compile)
#   3. illumos-gate source at the pinned rev, as a store path
#
# developer/gnu-binutils is deliberately NOT installed: userland-incorporation
# rejects it on a running BE (docs/design-gate-derivation.md host-prereq note).
set -u
LOG=/var/log/gatefod
mkdir -p "$LOG"
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin

step() { echo "=== $(date -u +%FT%TZ) $* ==="; }

step "stage 1: IPS prereqs"
ifconfig ena0 mtu 1400 2>/dev/null || true
pkg set-publisher -G '*' -g https://pkg.openindiana.org/hipster/ openindiana.org 2>&1 | tail -2
env PKG_CLIENT_CONNECT_TIMEOUT=60 PKG_CLIENT_LOWSPEED_TIMEOUT=180 \
    PKG_CLIENT_MAX_CONSECUTIVE_ERROR=10 PKG_CLIENT_MAX_TIMEOUT=20 \
  pkg install -v \
    developer/build/onbld \
    developer/build/gnu-make \
    developer/lexer/flex \
    developer/parser/bison-38 \
    developer/versioning/git \
    developer/versioning/patch \
    text/texinfo \
    developer/object-file \
    developer/java/openjdk8 \
    library/idnkit library/idnkit/header-idnkit \
    system/library/mozilla-nss/header-nss library/nspr/header-nspr \
    print/cups \
    text/gnu-diffutils \
    compress/zstd \
  > "$LOG/1-pkg.log" 2>&1
echo "pkg install exit=$? (see $LOG/1-pkg.log)"
ls -d /opt/onbld/bin/nightly /usr/java/bin/javac 2>&1
command -v gpatch patch makeinfo git 2>&1

step "stage 2: Nix 2.24.15 from the banked tarball"
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

step "stage 3: illumos-gate source at the pinned rev"
GATE_REV=ac45d71fc2b04a5422e72a14b54dd1e746e7be07
mkdir -p /code && cd /code
if [ ! -d illumos-gate/.git ]; then
  git clone --quiet https://github.com/illumos/illumos-gate.git illumos-gate > "$LOG/3-clone.log" 2>&1
fi
cd illumos-gate && git fetch --quiet origin "$GATE_REV" 2>/dev/null
git checkout --quiet "$GATE_REV" 2>&1 | tail -2
echo "gate HEAD: $(git rev-parse HEAD)"
du -sh /code/illumos-gate 2>/dev/null | tail -1

step "BOOTSTRAP DONE"
