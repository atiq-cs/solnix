#!/usr/bin/env bash
# oi-boot-batch.sh — launch N solnix instances from an AMI, poll each serial
# console for the multi-user-server milestone (SUCCESS) vs. the early-kernel TSC
# hang (HANG), report N/M reached multi-user, then TERMINATE them all.
#
# This is the honest metric for the T2.1 boot-hang: the batch success rate.
#
# Usage:
#   AMI=ami-... N=10 ITYPE=m6i.large ./scripts/oi-boot-batch.sh
# Env:
#   AMI     (required) AMI id to boot
#   N       (default 10) how many instances
#   ITYPE   (default m6i.large) instance type
#   CPUOPTS (optional) e.g. "CoreCount=1,ThreadsPerCore=1" to force 1 vCPU
#   WAIT    (default 300) seconds to poll each console before declaring HANG
#   KEEP    (default 0) if 1, do NOT terminate (for post-mortem); default terminates
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-numa}"
REGION="${REGION:-us-east-2}"
AMI="${AMI:?set AMI=ami-...}"
N="${N:-10}"
ITYPE="${ITYPE:-m6i.large}"
WAIT="${WAIT:-300}"
KEEP="${KEEP:-0}"
SUBNET="${SUBNET:-subnet-08627f3be3da35553}"
SG="${SG:-sg-06d7b829bb2ac37f1}"
EXPIRY="$(date -d '+2 days' +%Y-%m-%d 2>/dev/null || date -v+2d +%Y-%m-%d)"

# The gate milestone string in the serial console when boot succeeds:
SUCCESS_RE='multi-user-server:default'
# Last line before the hang (per gotcha #10): TSC calibration.
TSC_RE='TSC calibrated'

log() { printf '%s\n' "$*" >&2; }

CPUARG=()
[ -n "${CPUOPTS:-}" ] && CPUARG=(--cpu-options "$CPUOPTS")

log "=== launching batch: N=$N type=$ITYPE ami=$AMI cpuopts=${CPUOPTS:-none} ==="
IIDS="$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" \
  --instance-type "$ITYPE" --count "$N" \
  --subnet-id "$SUBNET" --security-group-ids "$SG" \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  "${CPUARG[@]}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-boottest},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=$EXPIRY}]" \
  --query 'Instances[].InstanceId' --output text)"
log "instances: $IIDS"

cleanup() {
  if [ "$KEEP" = 1 ]; then
    log "KEEP=1: NOT terminating: $IIDS"
  else
    log "=== terminating batch ==="
    aws ec2 terminate-instances --region "$REGION" --instance-ids $IIDS \
      --query 'TerminatingInstances[].InstanceId' --output text >&2 || true
  fi
}
trap cleanup EXIT

# poll: for each instance, keep grabbing --latest console until it shows SUCCESS
# or (after WAIT) is still stuck at/after TSC with no milestone -> HANG.
declare -A RESULT
declare -A LAST
for i in $IIDS; do RESULT[$i]=""; done

START=$(date +%s)
while :; do
  NOW=$(date +%s); ELAPSED=$((NOW-START))
  PENDING=0
  for i in $IIDS; do
    [ -n "${RESULT[$i]}" ] && continue
    PENDING=$((PENDING+1))
    OUT="$(aws ec2 get-console-output --region "$REGION" --instance-id "$i" --latest --output text 2>/dev/null | tr -d '\000' || true)"
    if printf '%s' "$OUT" | grep -q "$SUCCESS_RE"; then
      RESULT[$i]="SUCCESS"
      log "[$i] SUCCESS (reached multi-user-server) at ${ELAPSED}s"
    else
      # record last meaningful kernel line (drop blanks + AWS's trailing
      # ISO-timestamp line) for the post-mortem
      LL="$(printf '%s' "$OUT" | tr -d '\000' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -vE '^[[:space:]]*$|^[[:space:]]*2[0-9]{3}-[0-9]{2}-[0-9]{2}T' | tail -1)"
      [ -n "$LL" ] && LAST[$i]="$LL"
    fi
  done
  [ "$PENDING" = 0 ] && break
  if [ "$ELAPSED" -ge "$WAIT" ]; then
    for i in $IIDS; do
      [ -z "${RESULT[$i]}" ] && RESULT[$i]="HANG"
    done
    break
  fi
  sleep 20
done

# report
OK=0; TOT=0
echo
echo "========== BATCH RESULT (ami=$AMI type=$ITYPE cpuopts=${CPUOPTS:-none}) =========="
for i in $IIDS; do
  TOT=$((TOT+1))
  r="${RESULT[$i]}"
  [ "$r" = "SUCCESS" ] && OK=$((OK+1))
  printf '  %-22s %-8s last=[%s]\n' "$i" "$r" "${LAST[$i]:-}"
done
echo "----------"
echo "SUCCESS: $OK / $TOT reached multi-user-server"
echo "==========================================================="
