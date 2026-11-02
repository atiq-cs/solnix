#!/usr/bin/bash
# path-gate.sh [--selftest]: a store-only builder must have no host directory on PATH (NixOS: the sandbox has no /usr; here
# there is no sandbox, so every hermetic builder checks it). FAILs (exit 1) if any PATH entry is not under /nix/store, or is
# the builder's own build dir ($W/... is allowed via PATH_GATE_ALLOW, a colon list of prefixes). /usr/bin/bash as the
# builder interpreter is the one documented exception (it is not on PATH). --selftest: the check must FAIL a PATH holding
# /usr/bin and PASS a store-only one (the negative control runs in every build, so the gate can never silently pass).
check() {
  local IFS=: e bad=""
  for e in $1; do
    [ -n "$e" ] || { bad="$bad <empty>"; continue; }   # an empty entry means the cwd
    case "$e" in /nix/store/*) continue;; esac
    local a ok=""; for a in ${PATH_GATE_ALLOW:-}; do case "$e" in "$a"|"$a"/*) ok=1;; esac; done
    [ -n "$ok" ] || bad="$bad $e"
  done
  [ -z "$bad" ] || { echo "FATAL: path-gate: PATH has host entries:$bad" >&2; return 1; }
}
check "/nix/store/00000000000000000000000000000000-x/bin:/usr/bin" 2>/dev/null && { echo "FATAL: path-gate selftest: /usr/bin passed" >&2; exit 1; }
check "/nix/store/00000000000000000000000000000000-x/bin" || { echo "FATAL: path-gate selftest: a store PATH failed" >&2; exit 1; }
[ "${1:-}" = --selftest ] && { echo "path-gate selftest PASS"; exit 0; }
check "$PATH" || exit 1
echo "=== path-gate: PATH is store-only ===" >&2
