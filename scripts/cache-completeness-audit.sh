#!/bin/sh
# CACHE COMPLETENESS AUDIT: for every starter package the shipped configs name,
# report the narinfo HTTP code for the package AND for each of its References.
# A package whose own narinfo is 200 is still unbuildable if any reference is 404,
# which is the shape that made 5 of 13 names fail one at a time.
set -u
. /etc/profile.d/nix-illumos.sh 2>/dev/null || true
PATH=/nix-tools224/bin:/usr/bin:/usr/sbin:/sbin; export PATH
W=$(ls -dt /var/tmp/solnix-host.* 2>/dev/null | head -1)
TSV=$W/docs/registry/real-derivations.tsv
C=https://cache.solnix.io

code() { curl -s -o /dev/null -w "%{http_code}" "$C/$1.narinfo"; }

printf '%-12s %-34s %-4s %s\n' PKG HASH HTTP "BROKEN REFERENCES (404)"
printf '%-12s %-34s %-4s %s\n' --- ---- ---- -----------------------
for p in coreutils file gnugrep gnused bzip2 xz zlib pcre2 nvi which gdb git curl; do
  # The PUBLISHED row, not merely the first row: `which` has 3 staged rows and 1
  # published, so first-match picks a staged path that is not in the cache.
  path=$(awk -F'\t' -v n="$p" '$1==n && $7=="published" {print $4; exit}' "$TSV")
  if [ -z "$path" ]; then printf '%-12s %-34s %-4s %s\n' "$p" "-" "-" "NO PUBLISHED ROW"; continue; fi
  h=$(basename "$path" | cut -c1-32)
  c=$(code "$h")
  broken=""
  if [ "$c" = 200 ]; then
    refs=$(curl -s "$C/$h.narinfo" | sed -n 's/^References: //p')
    for r in $refs; do
      rh=$(echo "$r" | cut -c1-32)
      [ "$rh" = "$h" ] && continue
      rc=$(code "$rh")
      [ "$rc" = 200 ] || broken="$broken $(echo "$r" | cut -c34-)($rc)"
    done
  fi
  printf '%-12s %-34s %-4s %s\n' "$p" "$h" "$c" "${broken:-none}"
done
echo "AUDIT-DONE"
