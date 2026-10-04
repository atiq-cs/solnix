#!/usr/bin/env bash
# cache-audit-run.sh -- READ-ONLY Nix-correctness audit of the served solnix binary cache.
#
# Enumerates objects from the served arch-manifest.tsv + every /nix/store path named in
# docs/registry/*, BFSes their References over https://cache.solnix.io, streams every
# fetchable NAR (never materialised), and classifies each object keep / resign /
# regenerate / drop / absent. Writes nothing to any cache: anonymous HTTPS GET/HEAD only,
# plus an OPTIONAL rustfs read-only listing for the base-soname sets (sops S3 creds).
#
# Usage: scripts/cache-audit-run.sh [WORK] [DATE]
#   WORK  defaults to /var/tmp/cacheaudit (resumable: the NAR scan skips finished objects)
#   DATE  defaults to today (YYYYMMDD); names the docs/registry/AUDIT-* outputs
# Stages can be rerun independently; a full run is ~10 min metadata + ~50 min NAR scan
# (12.7 GB xz streamed at 8 jobs on the dev box, peak RSS well under 1 GB).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-/var/tmp/cacheaudit}
DATE=${2:-$(date +%Y%m%d)}
CACHE=${CACHE:-https://cache.solnix.io}
JOBS=${JOBS:-8}
REG=$REPO/docs/registry
mkdir -p "$WORK"

PY=$(nix build --no-link --print-out-paths --impure --expr \
  'with import (builtins.getFlake "nixpkgs") {}; python3.withPackages (ps: [ps.pynacl ps.pyelftools])')/bin/python3

echo "== 1. seeds (served manifest + registry paths)"
curl -fsS -m 120 -o "$WORK/served-arch-manifest.tsv" "$CACHE/arch-manifest.tsv"
cut -f1 "$WORK/served-arch-manifest.tsv" | sort -u > "$WORK/manifest-hashes.txt"
grep -ohE '/nix/store/[0-9a-z]{32}-[^[:space:]"|`)]+' "$REG"/*.tsv "$REG"/*.txt "$REG"/*.md 2>/dev/null \
  | grep -v "AUDIT-cache-nix-correctness" | sed 's/[,;:.]*$//' | sort -u > "$WORK/registry-paths.txt" || true
cut -c12-43 "$WORK/registry-paths.txt" | sort -u > "$WORK/registry-hashes.txt"
sort -u "$WORK/manifest-hashes.txt" "$WORK/registry-hashes.txt" > "$WORK/seeds.txt"
wc -l "$WORK/manifest-hashes.txt" "$WORK/registry-hashes.txt" "$WORK/seeds.txt"

echo "== 2. arch + tranche hints from the registry"
"$PY" - "$REG" "$WORK" <<'EOF'
import glob, re, sys
reg, work = sys.argv[1], sys.argv[2]
seen = set()
with open(f"{work}/registry-arch.tsv", "w") as out:
    for f in glob.glob(f"{reg}/*.tsv") + glob.glob(f"{reg}/*.txt"):
        if "AUDIT-cache-nix-correctness" in f:
            continue
        for l in open(f, errors="replace"):
            a = re.search(r"(x86_64|aarch64|sparcv9)-solaris", l)
            for m in re.finditer(r"/nix/store/([0-9a-z]{32})-", l):
                if a and m.group(1) not in seen:
                    seen.add(m.group(1)); out.write(f"{m.group(1)}\t{a.group(0)}\n")
cur = "(top)"
with open(f"{work}/tranche-map.tsv", "w") as out:
    for i, l in enumerate(open(f"{reg}/cached-paths.tsv"), 1):
        if l.startswith("#"):
            t = l.strip("# -=\n")
            if re.search(r"wave|tranche|fleet|backfill|xw\d|P-D1|xbuild", t, re.I):
                cur = f"L{i}:{t[:70]}"
            continue
        m = re.search(r"/nix/store/([0-9a-z]{32})-", l)
        if m:
            out.write(f"{m.group(1)}\t{cur}\n")
EOF

echo "== 3. base illumos sonames per arch (gate proto / seed listings; public reads)"
if [ ! -s "$WORK/illumos-base-sonames.txt" ]; then
  # x86_64: the gate proto tarball lives in the rustfs keep-list (proto/), read with the sops S3 creds.
  # shellcheck disable=SC1091
  ( cd "$REPO"
    export SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
    AWS_ACCESS_KEY_ID=$(sops --decrypt --extract '["aws_access_key_id"]' secrets/s3-cache.yaml)
    AWS_SECRET_ACCESS_KEY=$(sops --decrypt --extract '["aws_secret_access_key"]' secrets/s3-cache.yaml)
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_EC2_METADATA_DISABLED=true AWS_DEFAULT_REGION=us-east-1
    key=$(aws --endpoint-url https://s3.solnix.io s3 ls --recursive s3://solnix-cache/proto/ | awk '/proto-root_i386.*\.tar\.gz$/{print $4}' | tail -1)
    aws --endpoint-url https://s3.solnix.io s3 cp "s3://solnix-cache/$key" - | tar tzvf - > "$WORK/proto-listing.txt" )
  awk '{print $NF}' "$WORK/proto-listing.txt" | grep -E '/(lib|usr/lib)/(amd64/)?[^/]+\.so\.[0-9]+$' \
    | sed -E 's#^.*/##' | sort -u > "$WORK/illumos-base-sonames.txt"
fi
cp "$WORK/illumos-base-sonames.txt" "$WORK/illumos-base-sonames.x86_64-solaris.txt"
curl -fsS -m 1800 "$CACHE/seed/aarch64-solaris/aarch64-seed-cross-14.3.0.tar.gz" | tar tzf - \
  | grep -E '^seed/(usr/)?lib/[^/]+\.so\.[0-9]+$' | sed 's#.*/##' | sort -u > "$WORK/illumos-base-sonames.aarch64-solaris.txt"
curl -fsS -m 120 "$CACHE/seed/sparcv9-solaris/seed-manifest.txt" | awk -F'\t' '$1=="proto"{print $2}' \
  | grep -E '\.so\.[0-9]+$' | sed 's#.*/##' | sort -u > "$WORK/illumos-base-sonames.sparcv9-solaris.txt"
wc -l "$WORK"/illumos-base-sonames.*.txt

echo "== 4. narinfo metadata + References BFS"
[ -s "$WORK/meta/meta.tsv" ] || CACHE=$CACHE "$PY" "$REPO/scripts/cache-audit-narinfo.py" "$WORK/seeds.txt" "$WORK/meta"

echo "== 5. streaming NAR/ELF scan (resumable)"
awk -F'\t' 'NR>1 && $3==200 && $11==200 {print $1}' "$WORK/meta/meta.tsv" | sort > "$WORK/scan-todo.txt"
CACHE=$CACHE "$PY" "$REPO/scripts/cache-audit-nar-scan.py" "$WORK" "$WORK/scan-todo.txt" "$JOBS"

echo "== 6. classify + manifest"
"$PY" "$REPO/scripts/cache-audit-classify.py" "$WORK" "$WORK/final-$DATE.tsv" | tee "$WORK/final-$DATE.out"
awk -F'\t' 'BEGIN{OFS="\t"} {t=$6; if(NR>1 && t!="-"){sub(/:.*/,"",t); t="cached-paths.tsv:"substr(t,2)} $6=t; NF=27; print}' \
  "$WORK/final-$DATE.tsv" > "$REG/AUDIT-cache-nix-correctness-$DATE.tsv"
NARINFO_DIR=$WORK/meta/narinfo "$PY" "$REPO/scripts/cache-audit-manifest.py" "$WORK/final-$DATE.tsv" \
  "$REG/AUDIT-cache-nix-correctness-$DATE-manifest.tsv"
echo "wrote $REG/AUDIT-cache-nix-correctness-$DATE.tsv and -manifest.tsv"
