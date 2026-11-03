#!/usr/bin/bash
# patch-shebangs.sh <out> <skip-prefixes> -- NixOS stdenv's patchShebangs (fixupPhase) for a store-only mk-src-pkg build: the #! of
# every executable file in <out> that names an absolute interpreter outside the store (#!/bin/bash, #!/usr/bin/perl, #!/usr/bin/python3)
# becomes that interpreter's store path from the build PATH (the store-only PATH: no host dir). /bin/sh and /usr/bin/env stay (POSIX,
# on every illumos host; gate B9 accepts them). An interpreter the PATH lacks, or one the PATH resolves only under a skip prefix
# (the seed farm, btPath: build-only, de-baked later) or the build dir, is left: out-host-refs.sh then FAILs the build on it.
# --selftest: #!/bin/bash -> PATH's bash, #!/bin/sh kept, #!/usr/bin/nosuch kept (the negative control; runs in every call).
patch() {  # <dir> <skip>
  find "$1" -type f -perm -u+x | while read -r f; do
    [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ] || continue
    l=$(head -1 "$f" | tr -d '\000'); set -- $(echo "$l" | sed 's/^#![[:space:]]*//'); i=${1:-}; shift || :
    case "$i" in /bin/sh|/usr/bin/env|/nix/store/*) continue;; /*) ;; *) continue;; esac
    p=$(command -v "$(basename "$i")" 2>/dev/null) || continue
    case "$p" in /nix/store/*) ;; *) continue;; esac
    s=0; for x in $SKIP; do case "$p" in "$x"/*) s=1;; esac; done; [ "$s" = 0 ] || continue   # before resolving: btPath is the seed farm
    # through a buildEnv farm's links to the package's own file (NixOS: HOST_PATH holds package bins, not a farm)
    while [ -h "$p" ]; do t=$(readlink "$p" 2>/dev/null || ls -ld "$p" | sed 's/.* -> //'); case "$t" in /*) p=$t;; *) p=$(dirname "$p")/$t;; esac; done
    chmod u+w "$f"; { printf '#!%s%s\n' "$p" "${1:+ $*}"; tail -n +2 "$f"; } > "$f.psb" && cat "$f.psb" > "$f"; rm -f "$f.psb"
    echo "patch-shebangs: $f: #!$i -> $p" >&2
  done
}
T=$(mktemp -d "${TMPDIR:-/tmp}/psb.XXXXXX") || exit 1
printf '#!/bin/bash -e\necho a\n' > "$T/a"; printf '#!/bin/sh\n' > "$T/b"; printf '#!/usr/bin/nosuch\n' > "$T/c"; chmod +x "$T/a" "$T/b" "$T/c"
SKIP="" patch "$T" 2>/dev/null; bp=$(command -v bash)
while [ -h "$bp" ]; do t=$(readlink "$bp" 2>/dev/null || ls -ld "$bp" | sed 's/.* -> //'); case "$t" in /*) bp=$t;; *) bp=$(dirname "$bp")/$t;; esac; done   # as patch() (gtk's farm bash link)
case "$bp" in /nix/store/*) [ "$(head -1 "$T/a")" = "#!$bp -e" ] || { echo "FATAL: patch-shebangs selftest: bash not patched" >&2; exit 1; };; esac
[ "$(head -1 "$T/b")" = '#!/bin/sh' ] && [ "$(head -1 "$T/c")" = '#!/usr/bin/nosuch' ] || { echo "FATAL: patch-shebangs selftest" >&2; exit 1; }
find "$T" -depth -delete
[ "${1:-}" = --selftest ] && { echo "patch-shebangs selftest PASS"; exit 0; }
SKIP=$(echo "${2:-}" | tr ':' ' '); export SKIP
for o in $1; do [ -d "$o" ] && patch "$o"; done
exit 0
