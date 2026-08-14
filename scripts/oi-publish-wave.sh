#!/usr/bin/env bash
# Publish a wave's paths file via oi-node-publish.sh, extracting BARE store paths first.
# Wave paths files are "<pname> <space/tab> /nix/store/..." (2 fields) but oi-node-publish.sh
# reads each line as a bare store path -> without extraction it publishes 0 (the recurring bug).
# Usage (ON the build node, with /tmp/.pubcreds + /root/oi-node-publish.sh present):
#   oi-publish-wave.sh <wave-paths-file>
set -eu
PF="${1:?usage: oi-publish-wave.sh <wave-paths-file>}"
BARE="$(mktemp)"
grep -oE '/nix/store/[a-z0-9]{32}-[^ 	]*' "$PF" | grep -vE '\.drv$' | sort -u > "$BARE"
echo "oi-publish-wave: $(wc -l < "$BARE") bare paths from $PF"
. /tmp/.pubcreds
ST="$(mktemp)"; printf '%s' "$SIGNKEY" > "$ST"
AWS_ACCESS_KEY_ID="$AKID" AWS_SECRET_ACCESS_KEY="$SECRET" SIGN_KEY="$ST" \
  bash /root/oi-node-publish.sh "$BARE"
shred -u "$ST" 2>/dev/null || rm -f "$ST"
rm -f "$BARE"
