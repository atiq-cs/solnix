#!/usr/bin/env bash
# world-unloadable.sh -- the logic pkgs/illumos/mk-proto-world.nix uses to find
# ELF objects that cannot load because a DT_NEEDED library is absent, plus a
# self-test. The world build deletes exactly these (its dropUnloadable list) and
# fails if the found set changed. This script is the runnable control: it must
# find a planted broken object and must NOT flag one whose libraries all resolve.
#
#   world-unloadable.sh <dir>   list unloadable ELF objects under <dir>
#   world-unloadable.sh --selftest
#
# "unloadable" here means ldd reports a NEEDED library "not found" OR resolved to
# a path outside /nix/store (the same test the world build gates on). Needs the
# illumos ldd/elfdump; the self-test is skipped off illumos.
set -u

scan() {
  local root=$1
  ( cd "$root" || exit 1
    find . -type f ! -path './lib-*' | while read -r f; do
      /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
      /usr/bin/ldd "$f" 2>&1 \
        | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f}'
    done | sort -u | sed 's,^\./,,'
  )
}

selftest() {
  command -v /usr/bin/ldd >/dev/null && command -v /usr/bin/elfdump >/dev/null \
    || { echo "SKIP: no illumos ldd/elfdump"; exit 0; }
  command -v gcc >/dev/null || { echo "SKIP: no gcc"; exit 0; }
  local t; t=$(mktemp -d)
  mkdir -p "$t/root/bin"
  # good: links only libc (always resolvable)
  echo 'int main(void){return 0;}' | gcc -x c - -o "$t/root/bin/good"
  # bad: links a soname that does not exist anywhere
  gcc -shared -x c /dev/null -o "$t/phantom.so.9" -Wl,-h,libphantom.so.9 2>/dev/null
  echo 'int main(void){return 0;}' | gcc -x c - -L"$t" -lphantom -o "$t/root/bin/bad" 2>/dev/null
  rm -f "$t/phantom.so.9" "$t/libphantom.so.9"   # remove the lib so it is "not found"
  local out; out=$(scan "$t/root")
  echo "found: ${out:-<none>}"
  local rc=0
  echo "$out" | grep -qx 'bin/bad'  || { echo "FAIL: did not flag the broken object"; rc=1; }
  echo "$out" | grep -qx 'bin/good' && { echo "FAIL: flagged a good object"; rc=1; }
  rm -rf "$t"
  [ "$rc" = 0 ] && echo "SELFTEST OK" || echo "SELFTEST FAILED"
  return $rc
}

case "${1:-}" in
  --selftest) selftest ;;
  "") echo "usage: $0 <dir> | --selftest" >&2; exit 2 ;;
  *) scan "$1" ;;
esac
