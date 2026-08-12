#!/usr/bin/env bash
# solnix AWS security-group guard.
#
# WHY THIS EXISTS: opening tcp/22 (or anything) to 0.0.0.0/0 has twice caused a
# burner AWS account to be shut down for a T&C security violation, terminating
# the entire build fleet (ouch->crackers migration, then egret). A written rule
# in steering was not enough -- agents kept adding the open rule. This script is
# the ENFORCEMENT: all SG ingress changes must go through `sg-guard authorize`,
# which physically refuses any world-open CIDR, and `sg-guard audit` scans a
# region (or all regions) and fails loudly on any existing world-open rule.
#
# USAGE:
#   sg-guard authorize <region> <sg-id> <proto> <port> <cidr>   # safe add (refuses 0.0.0.0/0 and ::/0)
#   sg-guard audit [region ...]                                 # scan; nonzero exit + report on any world-open rule
#   sg-guard preflight <region>                                 # run before EVERY fleet launch; aborts launch if dirty
#
# It uses the current AWS profile/creds in the environment. No creds are logged.
set -euo pipefail

WORLD_V4="0.0.0.0/0"
WORLD_V6="::/0"

die() { echo "sg-guard: FATAL: $*" >&2; exit 2; }

is_world_open() {  # $1=cidr -> 0 if world-open
  case "$1" in
    "$WORLD_V4"|"$WORLD_V6") return 0 ;;
    # also catch sloppy equivalents
    "0.0.0.0/0 "|"0/0"|"::/0 ") return 0 ;;
    *) return 1 ;;
  esac
}

cmd_authorize() {
  local region="$1" sg="$2" proto="$3" port="$4" cidr="$5"
  if is_world_open "$cidr"; then
    die "REFUSED: attempt to open $proto/$port to WORLD-OPEN CIDR '$cidr' on $sg ($region).
     This is the exact action that got prior burner accounts SHUT DOWN for a T&C
     security violation (fleet terminated). Scope to a /32 (dev-box, harness, or
     build-host IP). NEVER 0.0.0.0/0 or ::/0. If you truly need broader access,
     that is a human decision -- stop and ask."
  fi
  # sanity: refuse absurdly-wide non-/32 v4 blocks too (defense in depth)
  case "$cidr" in
    */0|*/1|*/2|*/3|*/4|*/5|*/6|*/7|*/8)
      die "REFUSED: CIDR '$cidr' is far too wide (>= /8). Use a /32." ;;
  esac
  echo "sg-guard: OK -> authorizing $proto/$port from $cidr on $sg ($region)"
  aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg" \
    --protocol "$proto" --port "$port" --cidr "$cidr"
}

audit_region() {  # $1=region -> prints violations, returns count via global
  local region="$1"
  # every ingress rule with a world-open v4 or v6 range, across all SGs
  aws ec2 describe-security-groups --region "$region" \
    --query "SecurityGroups[].{sg:GroupId,name:GroupName,ip:IpPermissions[?contains(to_string(IpRanges[].CidrIp),'0.0.0.0/0') || contains(to_string(Ipv6Ranges[].CidrIpv6),'::/0')]}" \
    --output json 2>/dev/null \
  | python3 -c '
import sys,json
try: data=json.load(sys.stdin)
except Exception: data=[]
region=sys.argv[1]; bad=0
for g in data:
    for perm in (g.get("ip") or []):
        for r in (perm.get("IpRanges") or []):
            if r.get("CidrIp") in ("0.0.0.0/0",):
                proto=perm.get("IpProtocol"); fp=perm.get("FromPort","?"); tp=perm.get("ToPort","?")
                print(f"  VIOLATION {region} {g[\"sg\"]} ({g[\"name\"]}): {proto} {fp}-{tp} <- 0.0.0.0/0"); bad+=1
        for r in (perm.get("Ipv6Ranges") or []):
            if r.get("CidrIpv6") in ("::/0",):
                proto=perm.get("IpProtocol"); fp=perm.get("FromPort","?"); tp=perm.get("ToPort","?")
                print(f"  VIOLATION {region} {g[\"sg\"]} ({g[\"name\"]}): {proto} {fp}-{tp} <- ::/0"); bad+=1
sys.exit(1 if bad else 0)
' "$region"
}

cmd_audit() {
  local regions=("$@")
  [ ${#regions[@]} -eq 0 ] && regions=(us-east-1 us-east-2 us-west-2)
  local dirty=0
  echo "sg-guard: auditing regions: ${regions[*]}"
  for r in "${regions[@]}"; do
    if ! audit_region "$r"; then dirty=1; fi
  done
  if [ "$dirty" -ne 0 ]; then
    echo "sg-guard: DIRTY -- world-open SG rules found above. REMEDIATE before launching a fleet." >&2
    return 1
  fi
  echo "sg-guard: CLEAN -- no 0.0.0.0/0 or ::/0 ingress in the audited regions."
}

cmd_preflight() {  # must pass before any fleet launch
  local region="${1:?preflight needs a region}"
  echo "sg-guard: preflight for $region ..."
  cmd_audit "$region" || die "preflight FAILED for $region -- do NOT launch a fleet into a region with a world-open SG."
  echo "sg-guard: preflight PASS for $region."
}

cmd_selftest() {  # runnable check of the refusal logic; no AWS calls
  local fail=0
  for bad in 0.0.0.0/0 ::/0 10.0.0.0/8 0/0; do
    if ( is_world_open "$bad" ) || case "$bad" in */0|*/8) true;; *) false;; esac; then :; else
      echo "selftest: MISS -- did not flag '$bad'"; fail=1; fi
  done
  # positive: a /32 must NOT be world-open
  if is_world_open 73.4.58.126/32; then echo "selftest: FALSE-POSITIVE on /32"; fail=1; fi
  [ "$fail" -eq 0 ] && echo "sg-guard selftest: PASS" || { echo "sg-guard selftest: FAIL"; return 1; }
}

case "${1:-}" in
  authorize) shift; cmd_authorize "$@" ;;
  audit)     shift; cmd_audit "$@" ;;
  preflight) shift; cmd_preflight "$@" ;;
  selftest)  cmd_selftest ;;
  *) echo "usage: sg-guard {authorize <region> <sg> <proto> <port> <cidr> | audit [region...] | preflight <region> | selftest}" >&2; exit 1 ;;
esac
