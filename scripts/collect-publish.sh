#!/usr/bin/env bash
# collect-publish.sh — grab every built store path from a finished oi-job log on a
# builder and publish it to the solnix.io cache IMMEDIATELY. Deadline-safe: never
# batch. Extracts top-level /nix/store/<hash>-<plain-name> paths (OK results AND
# "built at" paths from load/import FAILs — all are valid published-worthy paths;
# their deps resolve from the cache at real runtime).
#
#   BIP=<ip> ./collect-publish.sh <job-name> [name-regex]
# name-regex defaults to perl542|py39|py313 (module tags). Prints published paths.
set -u
cd "$(dirname "$0")/.."
BIP="${BIP:?set BIP}"; JOB="${1:?job name}"; RE="${2:-(perl542|py39|py313)}"
KEY="${SOLNIX_KEY:-$HOME/.ssh/id_ed25519}"
ssh_(){ timeout 40 ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$BIP" "$@"; }

tmp=$(mktemp); log=$(mktemp)
ssh_ "cat /var/tmp/solnix-jobs/$JOB.log" > "$log" 2>/dev/null
grep -oE "/nix/store/[a-z0-9]{32}-${RE}-[a-zA-Z0-9._+-]+" "$log" | sort -u \
  | grep -vE '/(lib|bin|share)/' > "$tmp"
n=$(wc -l < "$tmp")
echo "collected $n built paths from $JOB"
[ "$n" -gt 0 ] || { rm -f "$tmp" "$log"; exit 0; }
BUILDER_IP="$BIP" ./scripts/oi-fleet-publish.sh "$tmp" 2>&1 | grep -E "publish|published=" | tail -60
cp "$tmp" "artifacts/wave5/published-$JOB.txt"
rm -f "$log"
