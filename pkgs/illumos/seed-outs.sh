#!/usr/bin/bash
# seed-outs.sh <out> <W> -- the seed instance's OUTPUT fixups (orchestrator 2026-11-03: the seed may BUILD on the OI host's PATH, but
# its outs must pass the publish content gate, which has no waivers). mk-src-pkg runs this when seedOuts is set (base-src.nix: the
# buildTools = [ ] instance). Each fix ends in a check; the gate (scripts/gate-checks.py nar) is the independent one.
# 1. #! of executables: /bin/bash and /usr/xpg4/bin/sh -> /bin/sh. The seed has no store bash (it is what builds the first one), and
#    gzip's and xz's scripts are POSIX sh: gzip's configure picks bash only because it was first on the OI PATH; xz's configure forces
#    /usr/xpg4/bin/sh on solaris* (POSIX_SHELL). On illumos /bin/sh is ksh93, which is what both are.
# 2. No absolute OI tool path in a text file: GREP='${GREP-'/usr/gnu/bin/grep'}' (gzip's zgrep) etc. become the bare name, found on the
#    user's PATH at run time (NixOS's de-bake of build tools in generated scripts).
# 3. Check: no host #! (B9), no /usr/gnu/ (B13), no $W (B8) in any non-ELF file; ELFs are left to the gate.
set -eu
o=$1; W=$2
istext() { [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" != 7f454c46 ]; }
# documentation names paths as prose (bash.info, FAQ: "/usr/gnu/bin/bash"), which the gate reports as WARN (its DOC_RE): left as is
isdoc() { case "$1" in "$o"/share/man/*|"$o"/share/info/*|"$o"/share/doc/*|*.1|*.info|*.txt|*.html) return 0;; esac; return 1; }
find "$o" -type f | while read -r f; do istext "$f" || continue; isdoc "$f" && continue
  c=0
  if [ -x "$f" ] && [ "$(head -c 2 "$f")" = '#!' ]; then
    case "$(head -1 "$f" | sed 's/^#![[:space:]]*//; s/[[:space:]].*//')" in /bin/bash|/usr/bin/bash|/usr/xpg4/bin/sh|/usr/gnu/bin/sh) c=1;; esac
  fi
  grep -q '/usr/gnu/bin/' "$f" && c=1
  [ "$c" = 1 ] || continue
  chmod u+w "$f"
  sed -e '1s@^#![[:space:]]*\(/usr\)\{0,1\}/bin/bash\([[:space:]]\|$\)@#!/bin/sh\2@' -e '1s@^#![[:space:]]*/usr/\(xpg4\|gnu\)/bin/sh\([[:space:]]\|$\)@#!/bin/sh\2@' \
      -e "s@'/usr/gnu/bin/\([a-z0-9]*\)'@'\1'@g" -e 's@/usr/gnu/bin/\([a-z0-9]*\)@\1@g' "$f" > "$W/seedfix" && cat "$W/seedfix" > "$f"
done
bad=$(find "$o" -type f | while read -r f; do istext "$f" || continue; isdoc "$f" && continue
  if [ -x "$f" ] && [ "$(head -c 2 "$f")" = '#!' ]; then i=$(head -1 "$f" | sed 's/^#![[:space:]]*//; s/[[:space:]].*//')
    case "$i" in /bin/sh|/usr/bin/env|/nix/store/*) ;; /*) echo "$f: #!$i";; esac; fi
  grep -l -e '/usr/gnu/' -e "$W" "$f" 2>/dev/null | sed 's/$/: names \/usr\/gnu or the build dir/'
done)
[ -z "$bad" ] || { echo "FATAL: seed out names the build host:" >&2; echo "$bad" | head -10 >&2; exit 1; }
echo "=== seed-outs: no host #!, /usr/gnu or build dir in a text file ===" >&2
