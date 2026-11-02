#!/usr/bin/bash
# vendor-fix.sh <srcroot> <patch>: apply a patch to vendored rust crates and re-stamp each touched file's sha256 in its crate's
# .cargo-checksum.json (cargo refuses a vendored crate whose files differ). Same job as cosmic-comp-vendor-fixup.sh's edit().
set -eu; R=$1; P=$2; cd "$R"
patch -p1 < "$P"
for f in $(grep '^+++ ' "$P" | awk '{print $2}' | sed 's@^b/@@'); do
  c=${f#third_party/rust/}; crate=${c%%/*}; rel=${c#*/}; J=third_party/rust/$crate/.cargo-checksum.json
  [ -f "$J" ] || { echo "FATAL: no $J" >&2; exit 1; }
  new=$(sha256sum "$f" 2>/dev/null | cut -c1-64 || /usr/bin/digest -a sha256 "$f")
  grep -q "\"$rel\":\"[0-9a-f]\{64\}\"" "$J" || { echo "FATAL: $rel not in $J" >&2; exit 1; }
  sed -i "s|\"$rel\":\"[0-9a-f]\{64\}\"|\"$rel\":\"$new\"|" "$J"; echo "restamped $crate/$rel"
done
