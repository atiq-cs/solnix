#!/usr/bin/env bash
# w14-sync.sh — push the repo files oi-tool.sh needs to /var/tmp/solnix-repo on a
# builder, plus /var/tmp/oi-pull.sh. Wave-14 helper (proven pkgsrc workflow).
#   BIP=<ip> scripts/w14-sync.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BIP="${BIP:?set BIP=<builder ip>}"
KEY="${SOLNIX_KEY:-$HOME/.ssh/id_ed25519}"
SSH() { ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ControlMaster=no \
          -o ControlPath=none "root@$BIP" "$@"; }
R=/var/tmp/solnix-repo
SSH "mkdir -p $R/pkgs/illumos $R/scripts"
for f in pkgs/illumos/mk-userland-pkg.nix pkgs/illumos/packages.nix scripts/oi-cc-wrapper.sh scripts/oi-tool.sh; do
  cat "$f" | SSH "cat > $R/$f"
done
# patches referenced by packages.nix (pkgsrc illumos fixes)
SSH "mkdir -p $R/pkgs/illumos/patches/pkgsrc"
for p in pkgs/illumos/patches/pkgsrc/*.patch; do
  [ -f "$p" ] && cat "$p" | SSH "cat > $R/pkgs/illumos/patches/pkgsrc/$(basename "$p")"
done
cat scripts/oi-pull.sh | SSH "cat > /var/tmp/oi-pull.sh"
SSH "ls $R/pkgs/illumos/packages.nix && echo SYNC_OK"
