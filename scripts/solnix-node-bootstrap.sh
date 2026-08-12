#!/usr/bin/env bash
# solnix fred-fleet node bootstrap.
#
# The fred build-base AMI (ami-0bbf52c39d67d9aa3, reconstructed from the durable
# release-224-v2 IMG) boots + networks but ships an EMPTY /nix/store and only the
# old /nix-tools224 bootstrap nix. This script turns a freshly-booted fred node
# into a working solnix build node by bootstrapping the build world from the
# durable cache (cache.solnix.io). Run as root on the node after first boot.
#
# WHY each step (all discovered the hard way reconstructing the AMI):
#  1. /dev/fd is NOT mounted on the reconstructed image -> bash process
#     substitution (<(...) -> /dev/fd/63) fails -> EVERY stdenv build dies with
#     "/dev/fd/63: No such file or directory". illumos needs the fd filesystem
#     mounted. THIS IS THE KEY FIX.
#  2. /nix-tools224/bin/nix has a broken RUNPATH (libgit2.so.1.7 not found) but
#     the lib IS bundled in /nix-tools224/runtime-lib -> LD_LIBRARY_PATH makes it
#     run, enough to substitute the good nix.
#  3. The old /nix-tools224 nix lacks patch #6; use the from-source nix
#     q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15 (in the cache, RUNPATH-correct,
#     runs standalone) for actual builds.
#  4. /root/tranche-224.nix references two fork source paths by store path
#     (qmvlnvf0...-nixpkgs-patched-... and p3lfwcvh0...-nixpkgs-patched); realise
#     them from the cache before eval. Everything else substitutes on demand.
set -eu

GOODNIX=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15
FORK1=/nix/store/qmvlnvf0kk1zkfjpjpxwimg5ym8sfwnk-nixpkgs-patched-1785781297346528064
FORK2=/nix/store/p3lfwcvh0vz6xc8wc1yhj2f8rg1flnb9-nixpkgs-patched

echo "solnix-node-bootstrap: 1) mount /dev/fd (fd filesystem)"
mkdir -p /dev/fd
# mount only if process substitution is not already working (idempotent)
if ! bash -c 'cat <(echo ok)' >/dev/null 2>&1; then
  mount -F fd fd /dev/fd 2>/dev/null || true
fi
# persist across reboots
grep -q "/dev/fd" /etc/vfstab 2>/dev/null || \
  printf 'fd\t-\t/dev/fd\tfd\t-\tno\t-\n' >> /etc/vfstab
bash -c 'cat <(echo ok)' >/dev/null 2>&1 && echo "  /dev/fd OK" || { echo "  /dev/fd FAILED"; exit 1; }

echo "solnix-node-bootstrap: 2) bring up the bootstrap nix (LD_LIBRARY_PATH) + substitute the good nix"
export LD_LIBRARY_PATH=/nix-tools224/runtime-lib
export PATH=/nix-tools224/bin:$PATH
[ -x "$GOODNIX/bin/nix" ] || nix-store --realise "$GOODNIX" >/dev/null

echo "solnix-node-bootstrap: 3) realise the fork source paths from cache"
"$GOODNIX/bin/nix-store" --realise "$FORK1" >/dev/null 2>&1 || nix-store --realise "$FORK1" >/dev/null
"$GOODNIX/bin/nix-store" --realise "$FORK2" >/dev/null 2>&1 || nix-store --realise "$FORK2" >/dev/null

echo "solnix-node-bootstrap: 4) switch to the good nix + verify a build"
# from here on, use the good nix with a clean environment (no LD_LIBRARY_PATH)
unset LD_LIBRARY_PATH
export PATH="$GOODNIX/bin:$PATH"
if nix-build /root/tranche-224.nix -A hello --no-link >/tmp/bootstrap-hello.log 2>&1; then
  echo "  BUILD OK: $(grep -oE '/nix/store/[a-z0-9]{32}-hello-[0-9.]+$' /tmp/bootstrap-hello.log | tail -1)"
  echo "solnix-node-bootstrap: NODE IS BUILD-READY. Use: PATH=$GOODNIX/bin:\$PATH nix-build /root/tranche-224.nix -A <pkg>"
else
  echo "  BUILD FAILED -- see /tmp/bootstrap-hello.log"; tail -5 /tmp/bootstrap-hello.log; exit 1
fi
