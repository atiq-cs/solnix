#!/usr/bin/env bash
# drv-gate.sh [--closure|--leaf] <drv | store path>... -- check A of the cache publish gate: the derivations of each
# argument (a store path is mapped to its deriver) build from the store only. Two modes, so the policy is explicit:
#   --closure (default, strict): every drv in the deriver's closure. pre-submit-check.sh uses this for a HOST's first
#             publishing, so hosts publish only outs whose whole build chain is store-only (wave6 era).
#   --leaf:   the deriver plus every input drv with an output that is NOT served (what a substituting build runs).
#             The orchestrator's cache-submit path uses this: served inputs were judged when they were submitted. The
#             closure's failing served drvs are counted on an INFO line (the debt stays visible).
# Verification rebuilds of SERVED rows (the builder's attestation votes) do not run this gate at all. NixOS gets this from the sandbox; illumos
# has none, so it is read off the derivations:
#   A1  the builder's PATH (env PATH, and every PATH= in its -c text and builder .sh) holds only /nix/store paths, its
#       own build dir ($W, $PWD, $out ...) and $PATH; MAKE/SHELL/CONFIG_SHELL/M4/INSTALL are store paths or unset;
#   A2  no LD_LIBRARY_PATH*/LD_PRELOAD*/LD_AUDIT*, NIX_REMOTE, NIX_PATH; TMPDIR/HOME not a host directory;
#   A3  the builder and every input are store paths; every inputSrc is content-addressed (not a builtins.storePath
#       import of a built path); every /nix/store path the drv names is one of its declared inputs or outputs;
#   A4  a fixed-output drv has a real pinned hash and no host /usr or /opt dir on its PATH.
# Exempt: only pkgs/illumos/bootstrap-exempt.tsv (the bootstrap set: name + structural marker), the exact store paths of
# scripts/gate2-exemptions.tsv (each printed with its path) and the served registry/ca-lane.tsv (fixed-output, by path).
# Prints PASS/FAIL per argument; exit 1 if any FAIL, 2 on setup.
# Env: GATE_PYTHON (a python3 >= 3.9; a solnix host has none on PATH: use a store python3's bin/python3).
# --selftest: every check against crafted bad and good derivations (no store needed).
set -u
here=$(cd "$(dirname "$0")" && pwd)
py=${GATE_PYTHON:-$(command -v python3)}
[ -n "$py" ] && "$py" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null || {
  echo "drv-gate: no python3 >= 3.9 (set GATE_PYTHON)" >&2; exit 2; }
[ "${1:-}" = --selftest ] && exec "$py" "$here/gate-checks.py" selftest
mode=--closure; case "${1:-}" in --closure|--leaf) mode=$1; shift ;; esac
[ $# -gt 0 ] || { echo "usage: drv-gate.sh [--closure|--leaf] <drv|out>... | --selftest" >&2; exit 2; }
drvs=()
for a in "$@"; do
  case "$a" in
    /nix/store/*.drv) drvs+=("$a") ;;
    /nix/store/*) d=$(nix-store -q --deriver "$a" 2>/dev/null)
      case "$d" in /nix/store/*.drv) [ -e "$d" ] && { drvs+=("$d"); continue; } ;; esac
      echo "FAIL $a: deriver '${d:-none}' is not a .drv in this store"; exit 1 ;;
    *) echo "FAIL $a: not a store path"; exit 1 ;;
  esac
done
exec "$py" "$here/gate-checks.py" drv "$mode" "${drvs[@]}"
