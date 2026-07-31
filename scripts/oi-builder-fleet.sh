#!/usr/bin/env bash
# oi-builder-fleet.sh — launch/scale a fleet of solnix illumos build hosts on the
# cloud build substrate so package-build agents can build the registry in parallel.
#
# The build account has a large vCPU quota and is a cost-free burner, so we
# parallelize aggressively. Each fleet host is a full illumos+Nix build env
# (from the solnix-builder image) that pulls the base world + toolchains from the
# solnix.io cache (so hosts don't each rebuild the foundation) and builds its
# assigned batch of packages, signing + pushing results back to the cache.
#
# Usage:
#   oi-builder-fleet.sh up   N [instance-type]   # launch N builders (default c6i.8xlarge? no -- illumos needs Xen or ena; use m6i, NON-c6id)
#   oi-builder-fleet.sh list                      # show the fleet
#   oi-builder-fleet.sh down                      # terminate all fleet hosts (NOT the keepers)
#
# NOTE: illumos on this substrate needs the paravirt net driver (our image has it)
# and does NOT boot on certain newer instance-store hypervisor types (see docs).
# Use an EBS-backed type with the paravirt net driver. Big cores per host + several
# hosts. Avoid the ~50% TSC hang: the builder image carries the pit_is_broken fix.
set -euo pipefail
# Live infra (profile, region, AMI, keypair, SG) comes from the gitignored
# .infra/fleet.env so it stays out of the published tree. Source it if present.
_INFRA="$(git rev-parse --show-toplevel 2>/dev/null)/.infra/fleet.env"
[ -f "$_INFRA" ] && . "$_INFRA"
export AWS_PROFILE="${AWS_PROFILE:-}"
REGION="${REGION:-us-east-2}"
# The solnix-builder image: a snapshot of solnix-build WITH Nix + world + gcc-14 +
# clang, taken AFTER the toolchains land. Set BUILDER_AMI in .infra/fleet.env.
BUILDER_AMI="${BUILDER_AMI:-}"
ITYPE="${2:-m6i.4xlarge}"           # 32 vCPU/host; bump count for more parallelism
KEY="${KEY:-}"

sg() { aws ec2 describe-security-groups --region "$REGION" --filters Name=group-name,Values=solnix-ssh --query 'SecurityGroups[0].GroupId' --output text; }

case "${1:-}" in
  up)
    N="${2:-4}"; ITYPE="${3:-m6i.4xlarge}"
    [ -n "$BUILDER_AMI" ] || { echo "set BUILDER_AMI first (snapshot solnix-build after toolchains land)"; exit 1; }
    SG=$(sg)
    echo "launching $N x $ITYPE builders from $BUILDER_AMI"
    for i in $(seq 1 "$N"); do
      aws ec2 run-instances --region "$REGION" --image-id "$BUILDER_AMI" --instance-type "$ITYPE" \
        --key-name "$KEY" --security-group-ids "$SG" \
        --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
        --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=200,VolumeType=gp3,Iops=8000,Throughput=500,DeleteOnTermination=true}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-builder-$i},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Role,Value=builder-fleet},{Key=Expiry,Value=$(date -d '+7 days' +%F 2>/dev/null || date -v+7d +%F)}]" \
        --query 'Instances[0].InstanceId' --output text
    done ;;
  list)
    aws ec2 describe-instances --region "$REGION" \
      --filters Name=tag:Role,Values=builder-fleet Name=instance-state-name,Values=running,pending \
      --query 'Reservations[].Instances[].[InstanceId,InstanceType,PublicIpAddress,Tags[?Key==`Name`]|[0].Value]' --output table ;;
  down)
    ids=$(aws ec2 describe-instances --region "$REGION" \
      --filters Name=tag:Role,Values=builder-fleet Name=instance-state-name,Values=running,pending,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text)
    [ -n "$ids" ] && aws ec2 terminate-instances --region "$REGION" --instance-ids $ids \
      --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text || echo "no fleet hosts" ;;
  *) echo "usage: $0 {up N [type] | list | down}"; exit 1 ;;
esac
