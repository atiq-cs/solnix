#!/bin/sh
# gen.sh <gate-checkout> -- render the owner/group/mode the illumos-gate pkg(5)
# manifests give every dir and file under etc/ and var/ into etc-var-attrs.tsv.
#
# A pkg(5) install applies these; the Nix store does not keep ownership (every
# store path is root-owned), so the stock /etc and /var tree that install-be lays
# into a BE arrive root:root. Daemons that drop privilege then cannot write their
# own state: dlmgmtd runs as dladm:netadm and silently fails to persist a new
# link to a root-owned /etc/dladm/datalink.conf, so the NIC never shows up in
# `dladm show-phys` (measured on the installer media). install-be applies this
# table, as pkg(5) would.
#
# Defaults are those of usr/src/pkg/transforms/defaults: owner root, group bin,
# mode 0644 for files and 0755 for dirs. Only rows that differ from root:root
# with the mode the store already gives (dirs 0555, files 0444) matter, but the
# table carries every entry so it can be checked against the manifests.
# Global-zone, non-SPARC entries only (variant.arch=sparc and
# variant.opensolaris.zone=nonglobal are skipped).
set -eu
G=${1:?usage: gen.sh <illumos-gate checkout at the pinned rev>}
cd "$(dirname "$0")"
cat "$G"/usr/src/pkg/manifests/*.p5m \
  | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' \
  | grep -E '^(dir|file) ' | grep -E ' path=(etc|var)/' \
  | grep -vE 'variant\.arch=sparc|variant\.opensolaris\.zone=nonglobal' \
  | awk '{t=$1; o="root"; g="bin"; m=(t=="dir") ? "0755" : "0644"; p=""
          for (i = 2; i <= NF; i++) {
            if ($i ~ /^path=/) p = substr($i, 6)
            else if ($i ~ /^owner=/) o = substr($i, 7)
            else if ($i ~ /^group=/) g = substr($i, 7)
            else if ($i ~ /^mode=/) m = substr($i, 6)
          }
          if (length(m) == 3) m = "0" m
          printf "%s\t%s\t%s\t%s\t%s\n", t, p, o, g, m}' \
  | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -u > etc-var-attrs.tsv
wc -l < etc-var-attrs.tsv
