#!/usr/bin/env bash
# oi-be-to-ami.sh — snapshot the scratch EBS volume holding the bootable solnix
# image (assembled by oi-make-be.sh) and register it as an EC2 AMI (Phase 2).
#
# Run on the WORKSTATION (has aws cli + numa profile). The scratch volume must be
# detached-or-quiesced (the pool exported on the build host) before snapshotting.
#
# Boot mode: uefi (the disk has a GPT ESP with EFI/Boot/bootx64.efi = the illumos
# loader). ena-support: our gate proto kernel has the ena driver + we added the
# PCI aliases + name_to_major, so it attaches on Nitro (m5/m6i/c5). Launch on a
# Nitro type. Capture the serial console with `aws ec2 get-console-output`.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-numa}"
REGION="${REGION:-us-east-2}"
VOL_ID="${VOL_ID:?set VOL_ID=vol-... (the scratch EBS vol with the image)}"
AMI_NAME="${AMI_NAME:-solnix-phase1-$(date +%Y%m%d-%H%M%S)}"
EXPIRY="$(date -d '+7 days' +%Y-%m-%d 2>/dev/null || date -v+7d +%Y-%m-%d)"
BOOT_MODE="${BOOT_MODE:-uefi}"

log() { printf '\n=== %s ===\n' "$*" >&2; }

log "snapshotting $VOL_ID"
SNAP_ID="$(aws ec2 create-snapshot --region "$REGION" --volume-id "$VOL_ID" \
  --description "solnix Phase-1 image" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$AMI_NAME},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=$EXPIRY}]" \
  --query SnapshotId --output text)"
echo "SNAP_ID=$SNAP_ID"
aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$SNAP_ID"
log "snapshot complete: $SNAP_ID"

log "registering AMI $AMI_NAME (boot-mode $BOOT_MODE, ena)"
AMI_ID="$(aws ec2 register-image --region "$REGION" --name "$AMI_NAME" \
  --architecture x86_64 --root-device-name /dev/xvda --ena-support \
  --virtualization-type hvm --boot-mode "$BOOT_MODE" \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$SNAP_ID,VolumeType=gp3,DeleteOnTermination=true}" \
  --query ImageId --output text)"
echo "AMI_ID=$AMI_ID"
aws ec2 create-tags --region "$REGION" --resources "$AMI_ID" \
  --tags Key=Name,Value="$AMI_NAME" Key=Owner,Value=gregburd Key=Purpose,Value=solnix-dev Key=Expiry,Value="$EXPIRY"

echo
echo "AMI registered: $AMI_ID (snapshot $SNAP_ID)"
echo "Launch (Nitro, uefi) + capture serial console:"
echo "  aws ec2 run-instances --region $REGION --image-id $AMI_ID --instance-type m6i.large \\"
echo "    --key-name solnix-builder --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=solnix-test},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=$EXPIRY}]'"
echo "  # then, repeatedly:"
echo "  aws ec2 get-console-output --region $REGION --instance-id <iid> --output text"
