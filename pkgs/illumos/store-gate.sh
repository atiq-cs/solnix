#!/usr/bin/bash
# store-gate.sh <scan-dir> <ts-errno-gate.sh> [forbidden-store-path...]: the mk-src-pkg closure
# gate for builders that are not mk-src-pkg (go-build.sh): no ELF names the global errno or a
# forbidden build-time path, every RUNPATH entry is in /nix/store, and "$IB/ldd" (no LD_LIBRARY_PATH)
# resolves every NEEDED inside /nix/store. Exit 1 with the first 40 failures.
IB=${ILLUMOS_BIN:-/usr/bin}   # illumos elfedit/elfdump/ldd: the world's usr/bin in a store-only build, /usr/bin when exempt
set -eu
d=$1; tsg=$2; shift 2
T=$(mktemp -d /var/tmp/sgate.XXXXXX); : > "$T/fail"
/usr/bin/bash "$tsg" "$d" 2>> "$T/fail" || echo "ts-errno gate failed" >> "$T/fail"
find "$d" -type f > "$T/files"
n=0
while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  for x in "$@"; do grep -q "$x" "$f" && echo "$f names $x" >> "$T/fail"; done
  "$IB/elfdump" -d "$f" 2>/dev/null | grep -q NEEDED || continue
  n=$((n+1))
  for e in $("$IB/elfdump" -d "$f" 2>/dev/null | awk '$2=="RUNPATH"||$2=="RPATH"{print $4}' | tr ':' ' '); do
    case "$e" in /nix/store/*) ;; *) echo "$f RUNPATH $e" >> "$T/fail";; esac
  done
  (unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64; "$IB/ldd" "$f") 2>&1 \
    | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> "$T/fail"
done < "$T/files"
if [ -s "$T/fail" ]; then echo "FATAL: closure gate failed:" >&2; head -40 "$T/fail" >&2; exit 1; fi
[ "$n" -gt 0 ] || { echo "FATAL: closure gate saw no dynamic ELF under $d" >&2; exit 1; }
echo "=== store-gate: $n dynamic ELFs under $d resolve inside /nix/store ===" >&2
