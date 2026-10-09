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
#   sg-guard preflight <region>                                 # run before EVERY fleet launch; aborts if dirty
#   sg-guard selftest                                           # runnable check of the refusal logic (no AWS)
#
# Uses the current AWS profile/creds in the environment. No creds are logged.
set -euo pipefail

# The audit is meaningless without credentials. The profile is named explicitly
# (no default): burner accounts expire (bene 2026-09-11, lava 2026-09-17, hotdog
# 2026-10-10, docs/account-expiry-hotdog.md), and a default naming a dead account
# reads nothing. Every region is also probed below, so an unreadable account is
# refused, never reported CLEAN.
case "${1:-}" in
  selftest) : ;;
  *) [ -n "${AWS_PROFILE:-}" ] || { echo "sg-guard: FATAL: set AWS_PROFILE to the account to audit (no default: burner accounts expire)" >&2; exit 2; }
     export AWS_PROFILE ;;
esac


WORLD_V4="0.0.0.0/0"
WORLD_V6="::/0"

die() { echo "sg-guard: FATAL: $*" >&2; exit 2; }

is_world_open() {  # $1=cidr -> 0 if world-open
  case "$1" in
    "$WORLD_V4"|"$WORLD_V6"|"0/0") return 0 ;;
    *) return 1 ;;
  esac
}

too_wide() {  # $1=cidr -> 0 if >= /8 (defense in depth)
  case "$1" in
    */0|*/1|*/2|*/3|*/4|*/5|*/6|*/7|*/8) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_authorize() {
  local region="$1" sg="$2" proto="$3" port="$4" cidr="$5"
  if is_world_open "$cidr"; then
    die "REFUSED: attempt to open $proto/$port to WORLD-OPEN CIDR '$cidr' on $sg ($region).
     This is the exact action that got prior burner accounts SHUT DOWN for a T&C
     security violation (fleet terminated). Scope to a /32 (dev-box, harness, or
     build-host IP). NEVER 0.0.0.0/0 or ::/0. Broader access is a human decision -- ask."
  fi
  if too_wide "$cidr"; then
    die "REFUSED: CIDR '$cidr' is far too wide (>= /8). Use a /32."
  fi
  echo "sg-guard: OK -> authorizing $proto/$port from $cidr on $sg ($region)"
  aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg" \
    --protocol "$proto" --port "$port" --cidr "$cidr"
}

# Detect world-open ingress using an AWS-side JMESPath filter (no embedded
# Python -- robust against quoting). Emits one line per offending SG; empty = clean.
audit_region() {  # $1=region -> returns 1 if any world-open rule found
  local region="$1" hits

  # REACHABILITY PROBE FIRST. The describe calls below end in
  # `2>/dev/null || true`, so an auth failure produced empty output and the
  # guard reported CLEAN -- "I cannot see anything" was indistinguishable from
  # "there is nothing to see". Confirmed by adding a real 0.0.0.0/0 rule and
  # watching it still say CLEAN. A security check that cannot fail is worse than
  # no check: it manufactures confidence.
  local probe
  if ! probe="$(aws ec2 describe-security-groups --region "$region" \
      --query 'length(SecurityGroups)' --output text 2>&1)"; then
    echo "  ERROR $region: cannot enumerate SGs -- $(echo "$probe" | tail -1)" >&2
    echo "  sg-guard: REFUSING to report CLEAN on an unreadable account." >&2
    return 2
  fi
  case "$probe" in
    ''|*[!0-9]*)
      echo "  ERROR $region: unexpected SG count '$probe' -- unreadable." >&2
      return 2 ;;
  esac
  echo "  sg-guard: $region -- $probe security group(s) visible" >&2

  hits="$(aws ec2 describe-security-groups --region "$region" \
      --filters "Name=ip-permission.cidr,Values=0.0.0.0/0" \
      --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null || true)"

  # SELF-TEST HOOK. Testing the detector previously meant creating a REAL
  # 0.0.0.0/0 rule, which is the single action that gets a burner account shut
  # down for a T&C violation -- minutes of exposure is enough. This injects a
  # synthetic hit so detection can be proven without ever opening anything.
  # Purely additive: it can only ever make the guard report DIRTY, never CLEAN.
  if [ -n "${SG_GUARD_SELFTEST:-}" ]; then
    hits="${hits}${hits:+$'\n'}sg-SELFTEST selftest-synthetic-not-a-real-sg"
  fi
  local hits6
  hits6="$(aws ec2 describe-security-groups --region "$region" \
      --filters "Name=ip-permission.ipv6-cidr,Values=::/0" \
      --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null || true)"
  local bad=0
  if [ -n "$hits" ]; then
    echo "$hits" | while read -r sg name; do
      [ -n "$sg" ] && echo "  VIOLATION $region $sg ($name): ingress <- 0.0.0.0/0"
    done
    bad=1
  fi
  if [ -n "$hits6" ]; then
    echo "$hits6" | while read -r sg name; do
      [ -n "$sg" ] && echo "  VIOLATION $region $sg ($name): ingress <- ::/0"
    done
    bad=1
  fi
  return $bad
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
  local fail=0 bad
  for bad in 0.0.0.0/0 ::/0 0/0; do
    is_world_open "$bad" || { echo "selftest: MISS world-open '$bad'"; fail=1; }
  done
  for bad in 0.0.0.0/0 10.0.0.0/8 172.16.0.0/4; do
    too_wide "$bad" || { echo "selftest: MISS too-wide '$bad'"; fail=1; }
  done
  is_world_open 73.4.58.126/32 && { echo "selftest: FALSE-POSITIVE on /32"; fail=1; }
  too_wide 73.4.58.126/32 && { echo "selftest: FALSE-POSITIVE too-wide on /32"; fail=1; }
  [ "$fail" -eq 0 ] && echo "sg-guard selftest: PASS" || { echo "sg-guard selftest: FAIL"; return 1; }
}

case "${1:-}" in
  authorize) shift; cmd_authorize "$@" ;;
  audit)     shift; cmd_audit "$@" ;;
  preflight) shift; cmd_preflight "$@" ;;
  selftest)  cmd_selftest ;;
  *) echo "usage: sg-guard {authorize <region> <sg> <proto> <port> <cidr> | audit [region...] | preflight <region> | selftest}" >&2; exit 1 ;;
esac
