#!/usr/bin/env bash
# solnix harness SG self-heal for Starlink/Italy flapping egress.
#
# We work over a Starlink (AS14593) link from Italy; the public egress IP flaps
# across many /24s, which keeps locking the harness out of the build-fleet SGs
# (scoped to /32). This ensures the CURRENT egress IP's /24 is authorized on the
# fred SGs, and prunes stale harness /24s we added before. It NEVER opens
# 0.0.0.0/0 -- all adds go through sg-guard (which refuses world-open / >= /8),
# and a /24 is a real Starlink block, not the whole internet.
#
# Run at the start of each work batch (or when SSH to nodes starts failing):
#   AWS_PROFILE=fred bash scripts/harness-sg-heal.sh
#
# Keeps the devbox /32 + at most the last few harness /24s (prunes older ones).
set -euo pipefail

DEVBOX="73.4.58.126/32"                 # never pruned
GUARD="$(dirname "$0")/sg-guard.sh"
REGIONS=(us-east-2 us-west-2)
SG_NAME="solnix-build-fred"
MAX_HARNESS_24=3                          # keep at most this many harness /24s

myip="$(curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
[ -n "$myip" ] || { echo "harness-sg-heal: could not determine egress IP" >&2; exit 1; }
# /24 of the current egress (Starlink PoP block)
my24="$(echo "$myip" | awk -F. '{print $1"."$2"."$3".0/24"}')"
echo "harness-sg-heal: egress $myip -> ensuring $my24 on $SG_NAME"

for region in "${REGIONS[@]}"; do
  sg="$(aws ec2 describe-security-groups --region "$region" \
      --filters "Name=group-name,Values=$SG_NAME" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  [ -n "$sg" ] && [ "$sg" != "None" ] || { echo "  $region: no $SG_NAME SG, skip"; continue; }

  # current :22 ingress cidrs
  existing="$(aws ec2 describe-security-groups --region "$region" --group-ids "$sg" \
      --query 'SecurityGroups[0].IpPermissions[?ToPort==`22`].IpRanges[].CidrIp' \
      --output text 2>/dev/null | tr '\t' '\n')"

  # add my /24 if missing (via the guard -- refuses world-open)
  if ! echo "$existing" | grep -qx "$my24"; then
    bash "$GUARD" authorize "$region" "$sg" tcp 22 "$my24" >/dev/null && echo "  $region: +$my24"
  else
    echo "  $region: $my24 already present"
  fi

  # prune stale harness /24s (keep devbox /32, keep the newest MAX_HARNESS_24 /24s incl mine)
  harness24s="$(echo "$existing" | grep -E '/24$' | grep -vx "$my24" || true)"
  n=0
  for c in $harness24s; do
    n=$((n+1))
    if [ "$n" -ge "$MAX_HARNESS_24" ]; then
      aws ec2 revoke-security-group-ingress --region "$region" --group-id "$sg" \
        --protocol tcp --port 22 --cidr "$c" >/dev/null 2>&1 && echo "  $region: pruned stale $c"
    fi
  done

  # safety: verify no world-open crept in
  bash "$GUARD" preflight "$region" >/dev/null || { echo "  $region: DIRTY after heal!" >&2; exit 2; }
done
echo "harness-sg-heal: done. SSH to fred nodes should work from $myip."
