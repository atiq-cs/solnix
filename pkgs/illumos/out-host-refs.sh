#!/usr/bin/bash
# out-host-refs.sh <out>... | --selftest: a store-only output must not point at the host at RUN time. FAILs on
#  - a symlink whose target is absolute and outside /nix/store (quilt shipped share/quilt/compat/awk -> /usr/bin/nawk; recipes1),
#  - a #! line naming an interpreter outside /nix/store, except /bin/sh and /usr/bin/env (POSIX, present on every illumos host).
# A relative symlink is fine. --selftest (the negative control; run in every call): a planted /usr/bin/nawk link and a
# #!/usr/bin/perl script must both fail, a store link and #!/bin/sh must pass.
chk() {
  for o in "$@"; do
    [ -e "$o" ] || continue
    find "$o" -type l | while read -r l; do
      t=$(readlink "$l" 2>/dev/null || ls -l "$l" | sed 's/.* -> //')
      case "$t" in /nix/store/*) ;; /*) echo "$l -> $t: symlink to the host";; esac
    done
    find "$o" -type f | while read -r f; do
      [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ] || continue
      i=$(head -1 "$f" | tr -d '\000' | sed 's/^#![[:space:]]*//; s/[[:space:]].*//')
      # only an absolute interpreter is a host path (cmake's GHS templates start "#!gbuild": a data format, not a script)
      case "$i" in /nix/store/*|/bin/sh|/usr/bin/env) ;; /*) echo "$f: #!$i outside /nix/store";; esac
    done
  done
}
T=$(mktemp -d "${TMPDIR:-/tmp}/ohr.XXXXXX") || exit 1
mkdir -p "$T/bad" "$T/good"
ln -s /usr/bin/nawk "$T/bad/awk"; printf '#!/usr/bin/perl\n' > "$T/bad/s"
ln -s /nix/store/00000000000000000000000000000000-x/bin/awk "$T/good/awk"; ln -s ../x "$T/good/rel"; printf '#!/bin/sh\n' > "$T/good/s"; printf '#!gbuild\n' > "$T/good/g"
[ "$(chk "$T/bad" | wc -l | tr -d ' ')" = 2 ] && [ -z "$(chk "$T/good")" ] || { echo "FATAL: out-host-refs selftest failed" >&2; find "$T" -depth -delete; exit 1; }
find "$T" -depth -delete
[ "${1:-}" = --selftest ] && { echo "out-host-refs selftest PASS"; exit 0; }
bad=$(chk "$@")
[ -z "$bad" ] || { echo "FATAL: the output points at the host at run time:" >&2; echo "$bad" | head -20 >&2; exit 1; }
echo "=== out-host-refs: no host symlink or #! in the outputs ===" >&2
