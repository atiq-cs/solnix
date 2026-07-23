#!/usr/bin/env bash
# oi-make-ami.sh — build an OpenIndiana Hipster AMI on EC2 (numa account, us-east-2)
#
# No first-party OI AMI exists, so we take the lazy import path: a throwaway
# Amazon Linux helper instance dd's the official OI raw CloudImage onto a blank
# EBS volume, we snapshot it, and register it as an AMI. This avoids the
# vmimport IAM role + S3 dance that VM Import/Export would require.
#
# Reference: OI publishes OI-hipster-cloudimage.img.zst (raw ZFS-root disk,
# boots via the illumos loader). illumos has ENA + NVMe drivers, so it runs on
# Nitro — but AVOID Nitro v5/v6 until gate fix 17939 lands (ENA won't attach).
# Use m5/c5/m6i-class instances to boot the resulting AMI.
#
# Idempotent-ish: re-running relaunches the helper. Clean up with the printed
# terminate command when the AMI is registered.
#
# dd+snapshot instead of VM Import/Export — fewer moving parts, no new
# IAM role. Switch to VM Import only if we need OVA/multi-disk or checks fail.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-numa}"
REGION="${REGION:-us-east-2}"
OI_URL="${OI_URL:-https://dlc.openindiana.org/isos/hipster/20251026/OI-hipster-cloudimage.img.zst}"
OI_VERSION="${OI_VERSION:-hipster-20251026}"   # for tagging/naming
AMI_NAME="openindiana-${OI_VERSION}-$(date +%Y%m%d)"
HELPER_TYPE="${HELPER_TYPE:-c5.large}"          # Nitro, ENA+NVMe, cheap
DATA_VOL_GB="${DATA_VOL_GB:-20}"                # blank vol the OI image lands on
BOOT_MODE="${BOOT_MODE:-uefi}"                 # OmniOS precedent (same illumos loader); helper verifies ESP
EXPIRY="$(date -d '+7 days' +%Y-%m-%d 2>/dev/null || date -v+7d +%Y-%m-%d)"

log() { printf '\n=== %s ===\n' "$*" >&2; }

log "identity"
aws sts get-caller-identity --region "$REGION" --output text \
  --query 'Arn' | grep -q ':user/numa' || { echo "wrong account/profile"; exit 1; }

# --- key pair -----------------------------------------------------------------
KEY_NAME="solnix-oi"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  log "creating key pair $KEY_NAME"
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
else
  log "key pair $KEY_NAME exists (expecting $KEY_FILE locally)"
fi

# --- security group (SSH from my IP) -----------------------------------------
SG_NAME="solnix-ssh"
MYIP="$(curl -s https://checkip.amazonaws.com)/32"
VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  log "creating security group $SG_NAME"
  SG_ID="$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$SG_NAME" --description "solnix SSH" --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)"
fi
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "$MYIP" >/dev/null 2>&1 || true
log "security group $SG_ID allows SSH from $MYIP"

# --- helper instance ----------------------------------------------------------
AL2023="$(aws ec2 describe-images --region "$REGION" --owners amazon \
  --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' 'Name=state,Values=available' \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
log "launching helper $HELPER_TYPE from $AL2023 (+${DATA_VOL_GB}G blank data vol)"

USERDATA="$(cat <<EOF
#!/bin/bash
set -euxo pipefail
dnf install -y zstd gdisk || yum install -y zstd gdisk
# find the blank data disk (the non-root NVMe with no partitions)
ROOT=\$(findmnt -no SOURCE / | sed 's/p\?[0-9]*\$//')
for d in /dev/nvme*n1; do
  [ "\$d" = "\$ROOT" ] && continue
  if [ -z "\$(lsblk -no PARTUUID \$d)" ]; then DATA=\$d; break; fi
done
echo "DATA disk: \$DATA" > /root/oi-import.log
curl -fsSL "$OI_URL" | zstd -d | dd of=\$DATA bs=16M status=progress 2>>/root/oi-import.log
sync
# verify the image really has a GPT + EFI System Partition (confirms boot-mode=uefi)
echo "--- partition layout ---" >> /root/oi-import.log
sgdisk -p \$DATA >> /root/oi-import.log 2>&1 || fdisk -l \$DATA >> /root/oi-import.log 2>&1 || true
echo "DONE writing OI image to \$DATA" >> /root/oi-import.log
touch /root/oi-import.done
EOF
)"

RUN_JSON="$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AL2023" --instance-type "$HELPER_TYPE" \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvdb\",\"Ebs\":{\"VolumeSize\":${DATA_VOL_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":false}}]" \
  --user-data "$USERDATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-oi-import},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=${EXPIRY}}]" \
  --output json)"
IID="$(echo "$RUN_JSON" | jq -r '.Instances[0].InstanceId')"
log "helper instance: $IID — waiting for OI image write to finish (several min)"

echo
echo "Next steps (helper writes the OI image via user-data):"
echo "  1. Wait, then SSH in and confirm:  ssh -i $KEY_FILE ec2-user@<ip>  'cat /root/oi-import.log; ls /root/oi-import.done'"
echo "  2. Find the data volume id:"
echo "     aws ec2 describe-volumes --region $REGION --filters Name=attachment.instance-id,Values=$IID --query 'Volumes[?Attachments[0].Device==\`/dev/xvdb\`].VolumeId' --output text"
echo "  3. Snapshot it:  aws ec2 create-snapshot --region $REGION --volume-id <vol> --description 'OI $OI_VERSION'"
echo "  4. Register AMI from the snapshot (ENA + NVMe):"
echo "     aws ec2 register-image --region $REGION --name '$AMI_NAME' \\"
echo "       --architecture x86_64 --root-device-name /dev/xvda --ena-support \\"
echo "       --virtualization-type hvm --boot-mode $BOOT_MODE \\"
echo "       --block-device-mappings 'DeviceName=/dev/xvda,Ebs={SnapshotId=<snap>,VolumeType=gp3}'"
echo "  5. Launch the AMI on an m5/c5/m6i (NOT Nitro v5/v6) and SSH as the OI user."
echo "  6. Terminate the helper:  aws ec2 terminate-instances --region $REGION --instance-ids $IID"
echo
echo "INSTANCE_ID=$IID"

# =============================================================================
# LEARNINGS (2026-07-23, first successful run)
# -----------------------------------------------------------------------------
# The AMI boots, but two things bite:
#
# 1. IMDSv2 is ENFORCED at the org level on the numa account (can't disable).
#    The OI cloud image's metadata-agent is an IMDSv1 client -> it hangs to its
#    300s timeout gating svc:/milestone/network -> no network, no ssh login.
#    FIX: pre-seed the ZFS root (see oi-preseed-be.sh) replacing /usr/lib/metadata
#    with scripts/metadata-shim.sh (DHCP + ssh, no IMDS).
#
# 2. The OI cloud image has NO `ena` driver -> gets no NIC on Nitro (c5/m5/...).
#    It DOES have `xnf` (Xen). FIX: run the seeded host on a Xen-HVM instance
#    type (m4/c4/t2). Register that AMI with --boot-mode uefi-preferred and
#    WITHOUT --ena-support.
#
# Pre-seeding requires reading an illumos ZFS root, which a Linux box can do with
# packaged OpenZFS: use an UBUNTU 24.04 helper (`apt install zfsutils-linux`),
# NOT Amazon Linux 2023 (its 6.18 kernel is newer than any OpenZFS release
# supports, so the module won't build).
#
# SSH in with scripts/oi-ssh.sh (IdentitiesOnly + IdentityAgent=none + BatchMode
# so the agent doesn't offer the wrong key first / no password popup).
#
# Working build host as of first run:
#   base AMI (boots, no login):     ami-042e009635e7af4b7
#   seeded Xen AMI (loginnable):    ami-0d36d9529e928f931
#   instance type:                  m4.large (Xen HVM, xnf0 NIC)
# =============================================================================
