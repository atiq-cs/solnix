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
# --exempt-check <drv>... (a host tool, not a builder call: surveys and gate2's drv-gate.sh apply the same list). Each drv
# whose env PATH is store-only PASSes; one with a host entry PASSes only as EXEMPT, iff its env name matches a row of the CLOSED
# list (PATH_GATE_EXEMPT, default bootstrap-exempt.tsv beside this file) AND the row's marker holds in the drv (the tsv says
# what each marker means). Otherwise FAIL. Exit 1 on any FAIL. Its negative control (crafted drvs: a seed zlib is EXEMPT, the
# same name with btPath set FAILs, a "libc" without filesArg FAILs, a seed farm naming a non-seed out FAILs) runs on every call.
if [ "${1:-}" = --exempt-check ]; then
  shift; L=${PATH_GATE_EXEMPT:-$(cd "$(dirname "$0")" && pwd)/bootstrap-exempt.tsv}
  [ -r "$L" ] || { echo "FATAL: path-gate: no exempt list $L" >&2; exit 2; }
  ev() { sed -n "s/.*(\"$2\",\"\([^\"]*\)\").*/\1/p" "$1" | head -1; }   # env value (the keys used here hold no quotes)
  has() { grep -q "(\"$2\"," "$1"; }
  outs() { sed 's/^Derive(\[//; s/\],\[.*//' "$1" | tr ',' '\n' | sed -n 's/^"\(\/nix\/store\/[^"]*\)"$/\1/p'; }
  marker() {  # <drv> <marker>: does the marker hold?
    case "$2" in
      seed) grep -q '("btPath","")' "$1" ;;
      gccseed) [ "$(ev "$1" stage0)" = /usr/gcc/14 ] && has "$1" gccSrc && ! has "$1" btPath ;;
      slice) has "$1" gate && has "$1" filesArg ;;
      world) has "$1" gate && has "$1" dirsArg && has "$1" sharedLibsArg ;;
      fod) [ "$(ev "$1" outputHashMode)" = recursive ] && [ "$(ev "$1" outputHash | wc -c)" -gt 40 ] && ! has "$1" btPath ;;
      seedenv) local p d ok seen=""
        for p in $(ev "$1" paths) $(ev "$1" gnutar); do
          ok=""; for d in $(sed 's/^Derive(\[[^]]*\],\[//' "$1" | tr '(' '\n' | sed -n 's/^"\(\/[^"]*\.drv\)".*/\1/p'); do
            outs "$d" | grep -qx "$p" && { marker "$d" seed || marker "$d" gccseed || marker "$d" seedenv; } && ok=1 && break
          done; [ -n "$ok" ] || return 1; seen=1
        done; [ -n "$seen" ] ;;
      *) return 1 ;;
    esac
  }
  classify() {  # <drv>: PASS | EXEMPT <marker> | FAIL <why>
    local n re m; n=$(ev "$1" name)
    check "$(ev "$1" PATH)" 2>/dev/null && { echo PASS; return; }
    while IFS='	' read -r re m _; do
      case "$re" in ''|'#'*) continue;; esac
      printf '%s\n' "$n" | grep -Eq -- "$re" && marker "$1" "$m" && { echo "EXEMPT $m"; return; }
    done < "$L"
    echo "FAIL host PATH and not on the exempt list ($L)"
  }
  T=$(mktemp -d "${TMPDIR:-/tmp}/pge.XXXXXX") || exit 2
  z=0000000000000000000000000000000; H='("PATH","/usr/gnu/bin:/usr/bin")'
  printf 'Derive([("out","/nix/store/%s1-zlib-1.3.2","","")],[],[],"x","b",[],[("btPath",""),("name","zlib-1.3.2"),%s])' $z "$H" > "$T/s.drv"
  printf 'Derive([("out","/nix/store/%s2-zlib-1.3.2","","")],[],[],"x","b",[],[("btPath","/nix/store/x"),("name","zlib-1.3.2"),%s])' $z "$H" > "$T/z.drv"
  printf 'Derive([("out","/nix/store/%s3-libc","","")],[],[],"x","b",[],[("gate","/nix/store/g"),("name","libc"),%s])' $z "$H" > "$T/l.drv"
  printf 'Derive([("out","/nix/store/%s4-solnix-seed-build-tools","","")],[("%s/s.drv",["out"]),("%s/z.drv",["out"])],[],"x","b",[],[("name","solnix-seed-build-tools"),("paths","/nix/store/%s2-zlib-1.3.2"),%s])' $z "$T" "$T" $z "$H" > "$T/f.drv"
  printf 'Derive([("out","/nix/store/%s5-solnix-seed-build-tools","","")],[("%s/s.drv",["out"])],[],"x","b",[],[("name","solnix-seed-build-tools"),("paths","/nix/store/%s1-zlib-1.3.2"),%s])' $z "$T" $z "$H" > "$T/g.drv"
  r="$(classify "$T/s.drv")|$(classify "$T/z.drv" | cut -c1-4)|$(classify "$T/l.drv" | cut -c1-4)|$(classify "$T/f.drv" | cut -c1-4)|$(classify "$T/g.drv")"
  find "$T" -depth -delete
  [ "$r" = "EXEMPT seed|FAIL|FAIL|FAIL|EXEMPT seedenv" ] || { echo "FATAL: path-gate --exempt-check selftest: $r" >&2; exit 2; }
  rc=0; for d in "$@"; do c=$(classify "$d"); printf '%s\t%s\t%s\n' "${c%% *}" "$d" "${c#* }"; case "$c" in FAIL*) rc=1;; esac; done
  exit $rc
fi
check "$PATH" || exit 1
echo "=== path-gate: PATH is store-only ===" >&2
