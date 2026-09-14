#!/bin/sh
# proto-probe.sh -- which of a list of proto-relative paths actually EXIST, and
# what class each is. Run on the node. Prints MISSING lines first so a slice's
# `bins` can be corrected from measurement rather than from memory of what a
# Linux/OI userland has.
P=/var/tmp/proto-unpack/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto
for b in "$@"; do
  if [ -e "$P/$b" ] || [ -L "$P/$b" ]; then
    lnk=""
    [ -L "$P/$b" ] && lnk=" (symlink)"
    printf 'OK      %s%s\n' "$b" "$lnk"
  else
    printf 'MISSING %s\n' "$b"
  fi
done
