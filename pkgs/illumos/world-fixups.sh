#!/usr/bin/bash
# world-fixups.sh <out> -- the system world's NixOS-style fixups, run by mk-proto-world.nix when fixups = true (the system
# instance; the seed world keeps its text, so the bootstrap set does not move). Each part ends in an in-build check, and the
# gate (scripts/gate-checks.py nar: S1 S3 B6 B9 B10) is the independent one. Measured on the wave6 world ay6d4263 (wave6t step4).
set -eu
o=$1; cd "$o"
isexe() { [ -f "$1" ] && [ -x "$1" ]; }
# 1. S1: usr/lib/inet/ppp/minconn.so records RUNPATH and RPATH /usr/gcc/10/lib (the gate built it with gcc 10) and NEEDs nothing,
# so the relocation loop (NEEDED|SONAME only) never touched it. Delete RUNPATH/RPATH only where it holds a host entry and the ELF
# has no NEEDED and no filter: a filter (libtermcap.so.1, SUNW_FILTER libcurses.so.1, no NEEDED) resolves its filtee through RUNPATH
# (W1 run 1: deleting it made bash's libcurses come from /lib/64).
find . -type f ! -path './lib-*' | while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] || continue
  d=$(/usr/bin/elfdump -d "$f" 2>/dev/null) || continue
  echo "$d" | awk '$2=="RUNPATH"||$2=="RPATH"{print $4}' | tr ':' '\n' | grep -v '^/nix/store/' | grep -q . || continue
  echo "$d" | grep -Eq 'NEEDED|FILTER|AUXILIARY' && continue
  chmod u+w "$f"; /usr/bin/elfedit -e 'dyn:delete RUNPATH' -e 'dyn:delete RPATH' "$f"
done
for l in lib/libtermcap.so.1 lib/amd64/libtermcap.so.1; do   # a filter keeps its store RUNPATH (the negative control of the above)
  [ ! -f "$l" ] || /usr/bin/elfdump -d "$l" | grep -q 'RUNPATH.*/nix/store/' || { echo "FATAL: world: $l lost its RUNPATH" >&2; exit 1; }
done
bad=$(find . -type f ! -path './lib-*' | while read -r f; do
  /usr/bin/elfdump -d "$f" 2>/dev/null | awk -v f="$f" '$2=="RUNPATH"||$2=="RPATH"{n=split($4,a,":"); for(i=1;i<=n;i++) if (a[i] !~ /^\/nix\/store\// && a[i] !~ /^\$ORIGIN/) print f": "$2" "a[i]}'
done)
[ -z "$bad" ] || { echo "FATAL: world: host RUNPATH/RPATH entries:" >&2; echo "$bad" | head >&2; exit 1; }
# 2. B10: no bytecode. The gate's python3.9 vendor-packages carry import-time (timestamp) .pyc; the base has no python3.9 at all
# (its .so bindings are in dropUnloadable), and NixOS ships only hash-based pyc.
find . -depth -type d -name __pycache__ -exec rm -rf {} +
find . -type f \( -name '*.pyc' -o -name '*.pyo' \) -exec rm -f {} +
[ -z "$(find . -name '*.py[co]' | head -1)" ] || { echo "FATAL: world: .pyc left" >&2; exit 1; }
# 3. S3: no build-host name (infra's gate is case-insensitive over every byte; E1's proto has none, so this only keeps it so).
# illumos grep has no -a and stops matching a line at a NUL, so each file goes through tr first (grep -rlaiE exited 2 here: inert).
find . -type f | while read -r f; do
  if LC_ALL=C tr '\000' '\n' < "$f" | grep -qiE 'solnix-builder-build|compute\.internal|ec2\.internal'; then echo "$f"; fi
done > .world/hostname-hits
[ ! -s .world/hostname-hits ] || { echo "FATAL: world names a build host:" >&2; head .world/hostname-hits >&2; exit 1; }
rm -f .world/hostname-hits
echo "=== world-fixups: runpath, pyc, hostname done ===" >&2
