#!/bin/sh
# ami-registry-check.sh -- run ON a booted solnix system (an AMI launch, an installed disk).
#
# Proves that the system flake registry actually works, not just that it is listed:
# `nix flake metadata nixpkgs` must fetch git.solnix.io/solnix.git at the edition ref.
# The dde2cbe AMI passed `nix registry list` on 25/25 launches, but every registry
# fetch failed, because nix 2.24 runs the git CLI for git+https inputs and git was
# not on PATH. A check that only lists the registry cannot see that.
#
# Usage: ssh root@<host> sh -s < scripts/ami-registry-check.sh
# Exit 0 and "REGISTRY_FETCH_OK <rev>" on success; non-zero and REGISTRY_FETCH_FAIL otherwise.
set -u
PATH=/run/current-system/sw/bin:$PATH
export PATH
H=$(mktemp -d /tmp/regchk.XXXXXX)
# A fresh cache, so an earlier successful fetch cannot mask a broken one.
out=$(HOME=$H XDG_CACHE_HOME=$H/c nix flake metadata --json nixpkgs 2>&1)
rc=$?
rev=$(printf '%s' "$out" | sed -n 's/.*"revision":"\([0-9a-f]\{40\}\)".*/\1/p')
if [ $rc -eq 0 ] && [ -n "$rev" ]; then
  echo "REGISTRY_FETCH_OK $rev"
  exit 0
fi
echo "REGISTRY_FETCH_FAIL rc=$rc"
printf '%s\n' "$out" | tail -3
command -v git >/dev/null || echo "  (git is not on PATH; nix 2.24 needs it for git+https inputs)"
exit 1
