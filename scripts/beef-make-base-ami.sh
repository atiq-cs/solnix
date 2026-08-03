#!/usr/bin/env bash
# beef-make-base-ami.sh — cold-start a FULL OpenIndiana AMI in the beef account.
#
# Adapted from ouch-make-base-ami.sh (which was the proven 3-stage orchestrator).
# Produces a full OI Hipster host (gcc + pkg/IPS installable) — the build
# SUBSTRATE that unblocks the bootstrap chicken-and-egg (docs/roadmap-fully-
# nixified.md). This is NOT the solnix Nix-world image; it is stock OpenIndiana
# from OI's own public raw cloud image.
#
#   stage dd    : AL2023 helper dd's the PUBLIC OI cloud image onto a blank vol
#   stage seed  : Ubuntu 24.04 ZFS helper imports the pool and applies
#                 metadata-shim.sh (IMDSv2 workaround — beef org-enforces IMDSv2)
#                 + oi-inject-ena.sh (Nitro NIC) + root ssh key + PermitRootLogin
#   stage reg   : snapshot the vol + register AMI with --ena-support (Nitro-capable)
#
# Never blocks on a long host op: the dd and the zfs seed run detached on the
# helpers; this script polls with short ssh calls. Resumable via subcommands.
#
#   beef-make-base-ami.sh dd            # launch AL2023 dd-helper (writes OI image)
#   beef-make-base-ami.sh dd-poll       # short poll of the dd-helper
#   beef-make-base-ami.sh seed <ddiid>  # move vol to Ubuntu helper, apply seed
#   beef-make-base-ami.sh seed-poll     # short poll of the seed-helper
#   beef-make-base-ami.sh reg           # snapshot + register the base AMI
#   beef-make-base-ami.sh reap          # terminate both helpers
#
# SECURITY: uses ONLY the pre-existing locked SG (sg-056af80635c09aa5b, :22 from
# 73.4.58.126/32 ONLY). Creates NO new SG, opens NO 0.0.0.0/0. All helpers land
# in the fixed beef subnet (us-east-2a) so the EBS vol can move between them.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE=beef
REGION=us-east-2
OI_URL="https://dlc.openindiana.org/isos/hipster/20251026/OI-hipster-cloudimage.img.zst"  # newest cloudimage (20260430 ships no cloudimage)
OI_VERSION="hipster-20251026"
AMI_NAME="openindiana-${OI_VERSION}-beef-$(date +%Y%m%d)"
DATA_VOL_GB=20
KEY_NAME="beef-key"
SG_ID="sg-056af80635c09aa5b"          # solnix-build-locked (:22 from 73.4.58.126/32 ONLY)
SUBNET="subnet-0dbc3dc75358df5d2"     # beef, us-east-2a; both helpers pinned here (EBS is AZ-bound)
HELPER_TYPE="c5.4xlarge"              # fast dd + fast apt/zfs; still cheap for the ~minutes it runs
KEY="$HOME/.ssh/id_ed25519"          # beef-key = this key
PUBKEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
EXPIRY="$(date -d '+14 days' +%Y-%m-%d 2>/dev/null || date -v+14d +%Y-%m-%d)"
ST=/tmp/beef-base-ami.state          # tiny kv state so subcommands find each other

aws() { command aws --profile beef --region "$REGION" "$@"; }
log() { printf '\n=== %s ===\n' "$*" >&2; }
kv()  { grep "^$1=" "$ST" 2>/dev/null | tail -1 | cut -d= -f2-; }
set_kv() { touch "$ST"; grep -v "^$1=" "$ST" 2>/dev/null > "$ST.tmp" || true; echo "$1=$2" >> "$ST.tmp"; mv "$ST.tmp" "$ST"; }
# short, non-blocking ssh to a linux helper (ec2-user for AL2023, ubuntu for 24.04)
lssh() { timeout 40 ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
           -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$@"; }
ip_of() { aws ec2 describe-instances --instance-ids "$1" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }

stage_dd() {
  log "identity"; aws sts get-caller-identity --query Arn --output text | grep -Eq ':user/(beef|numa|ouch)' \
    || { echo "wrong account/profile (expected beef)"; exit 1; }
  AL2023="$(aws ec2 describe-images --owners amazon \
    --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' 'Name=state,Values=available' \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
  log "launching AL2023 dd-helper from $AL2023 (+${DATA_VOL_GB}G blank vol) in $SUBNET"
  USERDATA="$(cat <<EOF
#!/bin/bash
set -euxo pipefail
dnf install -y zstd gdisk || yum install -y zstd gdisk
ROOT=\$(findmnt -no SOURCE / | sed 's/p\?[0-9]*\$//')
for d in /dev/nvme*n1; do
  [ "\$d" = "\$ROOT" ] && continue
  if [ -z "\$(lsblk -no PARTUUID \$d)" ]; then DATA=\$d; break; fi
done
echo "DATA disk: \$DATA" > /root/oi-import.log
curl -fsSL "$OI_URL" | zstd -d | dd of=\$DATA bs=16M status=progress 2>>/root/oi-import.log
sync
echo "--- partition layout ---" >> /root/oi-import.log
sgdisk -p \$DATA >> /root/oi-import.log 2>&1 || fdisk -l \$DATA >> /root/oi-import.log 2>&1 || true
echo "DONE writing OI image to \$DATA" >> /root/oi-import.log
touch /root/oi-import.done
EOF
)"
  RUN="$(aws ec2 run-instances --image-id "$AL2023" --instance-type "$HELPER_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvdb\",\"Ebs\":{\"VolumeSize\":${DATA_VOL_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":false}}]" \
    --user-data "$USERDATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-oi-import-beef},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=${EXPIRY}}]" \
    --output json)"
  DDIID="$(echo "$RUN" | jq -r '.Instances[0].InstanceId')"
  set_kv DDIID "$DDIID"
  log "dd-helper $DDIID launched; poll with: $0 dd-poll"
}

stage_dd_poll() {
  DDIID="$(kv DDIID)"; [ -n "$DDIID" ] || { echo "no DDIID"; exit 1; }
  IP="$(ip_of "$DDIID")"; echo "dd-helper $DDIID ip=$IP"
  [ "$IP" = None ] && { echo "no IP yet"; return; }
  set_kv DDIP "$IP"
  lssh ec2-user@"$IP" 'cat /root/oi-import.log 2>/dev/null | tail -6; echo "---done?---"; ls /root/oi-import.done 2>/dev/null && echo DD_DONE || echo DD_RUNNING' 2>&1 || echo "ssh not ready"
}

stage_seed() {
  DDIID="${1:-$(kv DDIID)}"; [ -n "$DDIID" ] || { echo "need dd iid"; exit 1; }
  log "find the OI data volume on dd-helper $DDIID"
  VOL="$(aws ec2 describe-volumes --filters Name=attachment.instance-id,Values="$DDIID" \
    --query 'Volumes[?Attachments[0].Device==`/dev/xvdb`].VolumeId' --output text)"
  [ -n "$VOL" ] && [ "$VOL" != None ] || { echo "no data vol"; exit 1; }
  set_kv VOL "$VOL"; log "OI vol: $VOL — detaching from dd-helper"
  aws ec2 detach-volume --volume-id "$VOL" >/dev/null
  aws ec2 wait volume-available --volume-ids "$VOL"
  UBU="$(aws ec2 describe-images --owners 099720109477 \
    --filters 'Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*' 'Name=state,Values=available' \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
  log "launching Ubuntu 24.04 seed-helper from $UBU in $SUBNET (us-east-2a, same AZ as the vol)"
  RUN="$(aws ec2 run-instances --image-id "$UBU" --instance-type "$HELPER_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-oi-seed-beef},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=${EXPIRY}}]" \
    --output json)"
  SEEDIID="$(echo "$RUN" | jq -r '.Instances[0].InstanceId')"
  set_kv SEEDIID "$SEEDIID"
  log "seed-helper $SEEDIID launched; waiting running"
  aws ec2 wait instance-running --instance-ids "$SEEDIID"
  log "attaching OI vol $VOL to seed-helper as /dev/sdf"
  aws ec2 attach-volume --volume-id "$VOL" --instance-id "$SEEDIID" --device /dev/sdf >/dev/null
  SIP="$(ip_of "$SEEDIID")"; set_kv SEEDIP "$SIP"
  log "seed-helper ip=$SIP — waiting for ssh, then push seed payload + run detached"
  for i in $(seq 1 30); do lssh ubuntu@"$SIP" true 2>/dev/null && break; sleep 10; done
  scp -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new \
    artifacts/ena/ena artifacts/ena/ena.conf scripts/oi-inject-ena.sh scripts/metadata-shim.sh \
    ubuntu@"$SIP":/tmp/
  lssh ubuntu@"$SIP" "cat > /tmp/mypub" <<<"$PUBKEY"
  lssh ubuntu@"$SIP" "sudo tee /tmp/seed-run.sh >/dev/null" <<'SEED'
#!/bin/bash
set -euxo pipefail
exec >/tmp/seed.log 2>&1
export DEBIAN_FRONTEND=noninteractive
until apt-get update -y; do sleep 5; done
apt-get install -y zfsutils-linux
modprobe zfs
ROOT=$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')
for d in /dev/nvme*n1; do [ "$d" = "$ROOT" ] && continue; DATA=$d; done
echo "DATA=$DATA"
zpool import -f -N -R /mnt rpool
BE=$(zfs list -H -o name -r rpool/ROOT | grep -E '/ROOT/.' | head -1)
echo "BE=$BE"
zfs set mountpoint=legacy "$BE"
mkdir -p /mnt/be; mount -t zfs "$BE" /mnt/be
# 1. metadata-shim: replace the IMDSv1 metadata agent (beef org-enforces IMDSv2)
install -m 0755 /tmp/metadata-shim.sh /mnt/be/usr/lib/metadata
# 2. ena driver -> Nitro NIC.  inject module+conf+aliases+major into the BE.
install -m 0755 -o 0 -g 3 /tmp/ena     /mnt/be/kernel/drv/amd64/ena
install -m 0644 -o 0 -g 3 /tmp/ena.conf /mnt/be/kernel/drv/ena.conf
for a in 'pciex1d0f,ec2' 'pciex1d0f,1ec2' 'pciex1d0f,ec20' 'pciex1d0f,ec21'; do
  grep -q "^ena \"$a\"" /mnt/be/etc/driver_aliases || echo "ena \"$a\"" >> /mnt/be/etc/driver_aliases
done
if ! grep -qw '^ena' /mnt/be/etc/name_to_major; then
  MAJ=$(awk '{print $2}' /mnt/be/etc/name_to_major | sort -n | tail -1); MAJ=$((MAJ+1))
  echo "ena $MAJ" >> /mnt/be/etc/name_to_major; echo "ena major $MAJ"
fi
# 3. root ssh key + PermitRootLogin (the metadata-shim enables sshd)
mkdir -p /mnt/be/root/.ssh; chmod 700 /mnt/be/root/.ssh
cp /tmp/mypub /mnt/be/root/.ssh/authorized_keys; chmod 600 /mnt/be/root/.ssh/authorized_keys
sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' /mnt/be/etc/ssh/sshd_config
grep -q '^PermitRootLogin yes' /mnt/be/etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /mnt/be/etc/ssh/sshd_config
sync
umount /mnt/be
zpool export rpool
echo SEED_DONE
SEED
  lssh ubuntu@"$SIP" 'sudo bash -c "chmod +x /tmp/seed-run.sh; nohup /tmp/seed-run.sh </dev/null >/dev/null 2>&1 & echo started $!"'
  log "seed running detached on $SEEDIID; poll with: $0 seed-poll"
}

stage_seed_poll() {
  SIP="$(kv SEEDIP)"; [ -n "$SIP" ] || { echo "no SEEDIP"; exit 1; }
  lssh ubuntu@"$SIP" 'sudo tail -8 /tmp/seed.log 2>/dev/null; echo "---"; grep -q SEED_DONE /tmp/seed.log 2>/dev/null && echo SEED_DONE || echo SEED_RUNNING' 2>&1 || echo "ssh not ready"
}

stage_reg() {
  SEEDIID="$(kv SEEDIID)"; VOL="$(kv VOL)"
  [ -n "$VOL" ] || { echo "no VOL"; exit 1; }
  log "detaching OI vol $VOL from seed-helper"
  aws ec2 detach-volume --volume-id "$VOL" >/dev/null 2>&1 || true
  aws ec2 wait volume-available --volume-ids "$VOL"
  log "snapshotting $VOL"
  SNAP="$(aws ec2 create-snapshot --volume-id "$VOL" --description "full OI $OI_VERSION beef" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$AMI_NAME},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=$EXPIRY}]" \
    --query SnapshotId --output text)"
  set_kv SNAP "$SNAP"; log "snapshot $SNAP — waiting complete"
  aws ec2 wait snapshot-completed --snapshot-ids "$SNAP"
  log "registering AMI $AMI_NAME (ena, uefi)"
  AMI="$(aws ec2 register-image --name "$AMI_NAME" \
    --architecture x86_64 --root-device-name /dev/xvda --ena-support \
    --virtualization-type hvm --boot-mode uefi \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$SNAP,VolumeType=gp3,DeleteOnTermination=true}" \
    --query ImageId --output text)"
  set_kv BASE_AMI "$AMI"
  aws ec2 create-tags --resources "$AMI" \
    --tags Key=Name,Value="$AMI_NAME" Key=Owner,Value=gregburd Key=Purpose,Value=solnix-dev Key=Expiry,Value="$EXPIRY"
  log "FULL OI AMI = $AMI  (snapshot $SNAP)"
  echo "BASE_AMI=$AMI"
}

stage_reap() {
  for k in DDIID SEEDIID; do
    id="$(kv $k)"; [ -n "$id" ] && [ "$id" != None ] && { log "terminating $k $id"; aws ec2 terminate-instances --instance-ids "$id" >/dev/null || true; }
  done
}

case "${1:-}" in
  dd)        stage_dd ;;
  dd-poll)   stage_dd_poll ;;
  seed)      stage_seed "${2:-}" ;;
  seed-poll) stage_seed_poll ;;
  reg)       stage_reg ;;
  reap)      stage_reap ;;
  state)     cat "$ST" 2>/dev/null || echo "(no state)" ;;
  *) echo "usage: $0 {dd|dd-poll|seed [ddiid]|seed-poll|reg|reap|state}"; exit 1 ;;
esac
