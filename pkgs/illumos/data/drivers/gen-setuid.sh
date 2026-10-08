#!/bin/sh
# gen-setuid.sh <gate-checkout> -- the setuid/setgid programs the illumos-gate pkg(5)
# manifests ship (mode, owner, group, path; i386 + common, global zone) into
# setuid.tsv. The store keeps no setuid bits, so install-be installs privileged
# copies of these outside the store (NixOS security.wrappers: /run/wrappers/bin).
set -eu
G=${1:?usage: gen-setuid.sh <illumos-gate checkout at the pinned rev>}
cd "$(dirname "$0")"
cat "$G"/usr/src/pkg/manifests/*.p5m \
  | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' \
  | grep -E '^file ' | grep -vE 'variant\.arch=sparc|variant\.opensolaris\.zone=nonglobal' \
  | awk '{p=""; o="root"; g="bin"; m=""
          for (i = 2; i <= NF; i++) {
            if ($i ~ /^path=/) p = substr($i, 6)
            else if ($i ~ /^owner=/) o = substr($i, 7)
            else if ($i ~ /^group=/) g = substr($i, 7)
            else if ($i ~ /^mode=/) m = substr($i, 6)
          }
          if (length(m) == 4 && substr(m, 1, 1) ~ /[2-7]/) printf "%s\t%s\t%s\t%s\n", m, o, g, p}' \
  | LC_ALL=C sort -t "$(printf '\t')" -k4,4 -u > setuid.tsv
# hardlink aliases of a setuid file in the same directory (usr/bin/uptime -> w):
# the program dispatches on argv[0], so the alias needs its own privileged copy.
cat "$G"/usr/src/pkg/manifests/*.p5m \
  | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' \
  | grep -E '^hardlink ' | grep -vE 'variant\.arch=sparc' \
  | awk '{p=""; t=""; for (i = 2; i <= NF; i++) { if ($i ~ /^path=/) p = substr($i, 6); else if ($i ~ /^target=/) t = substr($i, 8) }
          if (t !~ /\//) { d = p; sub(/\/[^\/]*$/, "", d); print p "\t" d "/" t } }' \
  | while IFS="$(printf '\t')" read -r alias target; do
      awk -F'\t' -v t="$target" -v a="$alias" '$4==t {printf "%s\t%s\t%s\t%s\n", $1, $2, $3, a}' setuid.tsv
    done >> setuid.tsv
LC_ALL=C sort -t "$(printf '\t')" -k4,4 -u setuid.tsv -o setuid.tsv
wc -l < setuid.tsv
