#!/usr/bin/env bash
# test_build_env.sh — self-check for the match_prefix logic in lib/build-env.nix.
# The pathsToLink prefix filter is the one non-trivial branch in the buildEnv
# builder; this asserts it links the right subtrees and skips the rest. Run:
#   bash lib/test_build_env.sh
set -eu

# mirror of match_prefix from lib/build-env.nix (kept in sync by eye — it is 6
# lines). REL is a relative path like "bin/ls"; prefixes are like "/bin".
match_prefix() {
  _rel="/$1"
  for _p in $pathsToLinkArg; do
    case "$_rel" in "$_p" | "$_p"/*) return 0 ;; esac
  done
  return 1
}

fail=0
check() { # check <expect 0|1> <rel> <msg>
  if match_prefix "$2"; then got=0; else got=1; fi
  if [ "$got" != "$1" ]; then echo "FAIL: $3 (rel=$2 expected=$1 got=$got)"; fail=1; fi
}

# null (link everything) is handled by the caller before match_prefix, so here
# we only test the non-empty filter path.
pathsToLinkArg="/bin /sbin /lib /lib/amd64 /share/man /share/info"

check 0 "bin/ls"            "bin file under /bin"
check 0 "sbin/svcadm"       "sbin file under /sbin"
check 0 "lib/libc.so.1"     "lib file under /lib"
check 0 "lib/amd64/libc.so.1" "amd64 lib under /lib/amd64 (also matches /lib)"
check 0 "share/man/man1/x.1" "man page under /share/man"
check 1 "share/doc/README"  "share/doc NOT linked (no /share/doc prefix)"
check 1 "etc/passwd"        "etc NOT linked"
check 1 "libexec/foo"       "libexec NOT linked (not /lib exactly)"
check 0 "lib"               "bare 'lib' dir matches /lib exactly"

# empty prefix arg would mean 'link everything' — caller returns early, so an
# empty list here should match NOTHING (defensive: no prefix -> no match).
pathsToLinkArg=""
check 1 "bin/ls" "empty filter matches nothing in match_prefix itself"

[ "$fail" = 0 ] && echo "build-env match_prefix: ALL CHECKS PASS" || { echo "build-env self-check FAILED"; exit 1; }
