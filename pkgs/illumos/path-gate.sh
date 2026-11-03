#!/usr/bin/bash
# path-gate.sh [--selftest]: a store-only builder must have no host directory on PATH (NixOS: the sandbox has no /usr; here
# there is no sandbox, so every hermetic builder checks it). FAILs (exit 1) if any PATH entry is not under /nix/store, or is
# the builder's own build dir ($W/... is allowed via PATH_GATE_ALLOW, a colon list of prefixes). --selftest: the check must
# FAIL a PATH holding /usr/bin and PASS a store-only one (the negative control runs in every build, so the gate can never
# silently pass).
#
# FIXED-PATH EXEMPTIONS (not PATH entries, so this gate cannot see them; each is a host file a store-only build still reads):
#  1. /usr/bin/bash: the builder interpreter (derivation builder = "/usr/bin/bash") and #! of generated wrappers. Until the
#     bootstrap-tools wave ships a bash.
#  2. /usr/lib/lddstub, /usr/lib/64/lddstub: ldd (the world's, a store path) execs a stub to load the object it inspects.
#     Mechanism (illumos-gate cmd/sgs/libconv/common/lddstub.c conv_lddstub): as non-root it tries $ORIGIN/../../lib/64/lddstub
#     (64-bit ldd; ../../lib/lddstub for 32-bit objects) and falls back to the compiled-in /usr/lib/64/lddstub. The world ships
#     usr/lib/{,64/}lddstub but not lib/{,64/}lddstub, so the fallback is taken (truss on chef as nixbld). ldd runs only in the
#     closure gates; its output goes to the gates' fail lists, never into $out. Proper fix (bootstrap-tools wave; it moves the
#     world): mk-proto-world links lib/lddstub -> ../usr/lib/lddstub and lib/64/lddstub -> ../../usr/lib/64/lddstub (tested:
#     a copy tree with that link made ldd exec the world's stub). Root (euid 0) builds always take /usr/lib: builds run as nixbld.
#  3. Exempt instances, whole: the seed instance (buildTools = [ ]: an OI build host's /usr/gnu, /usr/bin, /usr/gcc/14) and the
#     world/gate/slice builders (mk-proto-world, mk-illumos-component, gate.nix), until the bootstrap-tools wave.
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
