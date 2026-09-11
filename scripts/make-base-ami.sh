#!/usr/bin/env bash
# make-base-ami.sh — rebuild the x86_64 solnix/OpenIndiana base AMI from the
# PUBLIC OI cloud image, carrying BOTH documented cold-boot fixes so the result is
# cold-launch reliable (the prior base measured 10/10).
#
# ACCOUNT-PORTABLE, and that is the whole point. This file supersedes
# beef-make-base-ami.sh, ouch-make-base-ami.sh and bene-make-base-ami.sh —
# three forks of ONE procedure, one per dead burner account, each stranded with
# its account and each drifted from the others. A fourth fork was the obvious
# move and would have repeated the mistake. Every account specific now comes
# from the environment:
#
#   SOLNIX_PROFILE  aws cli profile AND the expected iam user name (default lava)
#   REGION SG_ID SUBNET AZ KEY_NAME KEY   substrate ids
#   HELPER_TYPE BOOT_TYPE                 instance types
#   BASE_IMG_URL                          raw-image source (public OI, or a banked one)
#
# For a fresh account, prefer restoring from the R2-banked raw image
# (scripts/ami-bank.sh restore) — that skips the seed stage entirely because the
# banked image already carries the fixes. This script is the from-scratch path
# and the ultimate fallback if R2 is ever lost too.
#
# Lineage: beef-make-base-ami.sh (proven 3-stage orchestrator) + the two fixes
# that took the base from ~70% to 10/10:
#   1. docs/ena-rx-coldboot-fix.md   — MTU-1500 ena + single-addrobj metadata shim
#   2. docs/kernel-hang-tsc-pit-fix.md — set pit_is_broken=1 (Nitro's emulated
#      i8254 PIT wedges tsc_calibrate_pit() pre-userland ~7-11% of cold boots)
#
#   stage dd    : AL2023 helper dd's the public OI cloud image onto a blank vol
#   stage seed  : Ubuntu 24.04 OpenZFS helper does a SINGLE import at an altroot,
#                 applies the shim + ena + the PIT tunable, rebuilds the
#                 boot_archive OFFLINE as raw gzip'd odc cpio, clean-exports
#   stage reg   : snapshot the vol + register a uefi/ena x86_64 AMI
#   stage boot  : single cold-launch smoke test (ssh + console)
#   stage batch : N fresh cold launches, ssh-probe each, terminate -> N/10 score
#   stage reap  : terminate every helper/test instance
#
# WHY the boot_archive is rebuilt offline as raw cpio rather than via bootadm:
# the kernel reads /etc/system (and /etc/system.d fragments) from the
# boot_archive RAMDISK inside kmem_init(), long before the ZFS root is mounted,
# so the PIT tunable is only in effect if it lives INSIDE the archive. bootadm
# cannot be run against a foreign root from Linux, and re-baking a derivative
# AMI from a running instance (create-image/snapshot of a booted node) LOSES the
# reliable-boot property (documented cold-boot DHCP regression). Raw
# extract -> add -> repack (same entry order, odc format, re-gzip) is surgical.
#
# WHY a Linux/OpenZFS single-import is safe here (the "ZFS-import corrupts DHCP"
# hazard): that corruption came from importing a GUID-COLLIDING pool on a native
# illumos node and breaking the collision with `zpool reguid`. This helper is
# Linux (root is ext4, no pool to collide with), does exactly ONE import at an
# altroot and ONE clean export -- the method that produced the 15/15 canonical
# AMI. Never reguid, never import the target pool on illumos.
#
# SECURITY: uses ONLY the pre-existing locked SG (:22 from the operator /24).
# Creates NO SG, opens NO 0.0.0.0/0. Verify with scripts/sg-guard.sh audit.
#
# Every remote call is short + non-interactive; long work runs detached on the
# helper and is polled from separate short reads (never block on a host op).
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${SOLNIX_PROFILE:-lava}"
export AWS_PROFILE="$PROFILE"
REGION="${REGION:-us-east-2}"
OI_URL="${BASE_IMG_URL:-https://dlc.openindiana.org/isos/hipster/20251026/OI-hipster-cloudimage.img.zst}"
OI_VERSION="${OI_VERSION:-hipster-20251026}"
AMI_NAME="solnix-base-x86_64-${OI_VERSION}-$(date +%Y%m%d)"
DATA_VOL_GB="${DATA_VOL_GB:-20}"      # raw image is 1.95GiB; headroom for a later offline grow
KEY_NAME="${KEY_NAME:-solnix-lava}"
SG_ID="${SG_ID:-sg-0d7ce9a7390bfadfe}"      # :22 from the operator /24 ONLY -- never world-open
SUBNET="${SUBNET:-subnet-0230d1c45d8a098a7}" # us-east-2a; helpers pinned here (EBS is AZ-bound)
AZ="${AZ:-us-east-2a}"
HELPER_TYPE="${HELPER_TYPE:-c5.4xlarge}"    # fast dd + fast apt/zfs, minutes of runtime
BOOT_TYPE="${BOOT_TYPE:-m5.4xlarge}"  # the type the prior 10/10 + 15/15 were measured on
KEY="${KEY:-$HOME/.ssh/${KEY_NAME}.pem}"
# Derive the public half from the private key: a fresh account's EC2 keypair
# arrives as a lone .pem with no .pub beside it.
PUBKEY="$( [ -f "$KEY.pub" ] && cat "$KEY.pub" || ssh-keygen -y -f "$KEY" )"
EXPIRY="$(date -d '+14 days' +%Y-%m-%d 2>/dev/null || date -v+14d +%Y-%m-%d)"
ST="/tmp/${PROFILE}-base-ami.state"
PROG="${PROG:-/tmp/base-ami-progress.txt}"

aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }
log() { printf '\n=== %s ===\n' "$*" >&2; }
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$PROG" >&2; }
kv()  { grep "^$1=" "$ST" 2>/dev/null | tail -1 | cut -d= -f2-; }
set_kv() { touch "$ST"; grep -v "^$1=" "$ST" 2>/dev/null > "$ST.tmp" || true; echo "$1=$2" >> "$ST.tmp"; mv "$ST.tmp" "$ST"; }
# Short, hard-bounded, non-interactive ssh. setsid detaches from the tty so a
# stuck remote can never hold this shell; KILL beats any ssh-internal blocking.
lssh() { timeout -s KILL 45 setsid ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
           -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -o ConnectTimeout=10 "$@"; }
lscp() { timeout -s KILL 120 setsid scp -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
           -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -o ConnectTimeout=10 "$@"; }
ip_of() { aws ec2 describe-instances --instance-ids "$1" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }

TAGS="ResourceType=instance,Tags=[{Key=Name,Value=NAMEHERE},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-base-ami},{Key=Expiry,Value=${EXPIRY}}]"
tags_for() { echo "${TAGS/NAMEHERE/$1}"; }

# --- stage dd: public OI cloud image -> blank EBS volume ----------------------
stage_dd() {
  log "identity"; aws sts get-caller-identity --query Arn --output text | grep -q ":user/$PROFILE" \
    || { echo "wrong account/profile (expected $PROFILE)"; exit 1; }
  AL2023="$(aws ec2 describe-images --owners amazon \
    --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' 'Name=state,Values=available' \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
  note "dd: launching AL2023 helper $AL2023 (+${DATA_VOL_GB}G blank vol) in $SUBNET"
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
    --tag-specifications "$(tags_for solnix-base-dd)" --output json)"
  DDIID="$(echo "$RUN" | jq -r '.Instances[0].InstanceId')"
  set_kv DDIID "$DDIID"; note "dd: helper $DDIID launched"
}

stage_dd_poll() {
  DDIID="$(kv DDIID)"; [ -n "$DDIID" ] || { echo "no DDIID"; exit 1; }
  IP="$(ip_of "$DDIID")"; echo "dd-helper $DDIID ip=$IP"
  [ "$IP" = None ] && { echo "no IP yet"; return 0; }
  set_kv DDIP "$IP"
  lssh ec2-user@"$IP" 'sudo tail -4 /root/oi-import.log 2>/dev/null; sudo ls /root/oi-import.done >/dev/null 2>&1 && echo DD_DONE || echo DD_RUNNING' 2>&1 || echo "ssh not ready"
}

# --- stage seed: apply the fixes offline on an Ubuntu/OpenZFS helper ----------
stage_seed() {
  DDIID="${1:-$(kv DDIID)}"; [ -n "$DDIID" ] || { echo "need dd iid"; exit 1; }
  log "locate the OI data volume on dd-helper $DDIID"
  VOL="$(aws ec2 describe-volumes --filters Name=attachment.instance-id,Values="$DDIID" \
    --query 'Volumes[?Attachments[0].Device==`/dev/xvdb`].VolumeId' --output text)"
  [ -n "$VOL" ] && [ "$VOL" != None ] || { echo "no data vol"; exit 1; }
  set_kv VOL "$VOL"; note "seed: OI vol $VOL — detaching from dd-helper"
  aws ec2 create-tags --resources "$VOL" --tags Key=Name,Value=solnix-base-oi-vol Key=Owner,Value=gregburd Key=Purpose,Value=solnix-base-ami Key=Expiry,Value="$EXPIRY" || true
  aws ec2 detach-volume --volume-id "$VOL" >/dev/null
  aws ec2 wait volume-available --volume-ids "$VOL"
  # 099720109477 is Canonical's PUBLIC AMI owner id (an upstream constant, not
  # one of our account numbers -- do not scrub it).
  UBU="$(aws ec2 describe-images --owners 099720109477 \
    --filters 'Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*' 'Name=state,Values=available' \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
  note "seed: launching Ubuntu 24.04 helper $UBU in $SUBNET ($AZ)"
  RUN="$(aws ec2 run-instances --image-id "$UBU" --instance-type "$HELPER_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --tag-specifications "$(tags_for solnix-base-seed)" --output json)"
  SEEDIID="$(echo "$RUN" | jq -r '.Instances[0].InstanceId')"
  set_kv SEEDIID "$SEEDIID"
  aws ec2 wait instance-running --instance-ids "$SEEDIID"
  aws ec2 attach-volume --volume-id "$VOL" --instance-id "$SEEDIID" --device /dev/sdf >/dev/null
  SIP="$(ip_of "$SEEDIID")"; set_kv SEEDIP "$SIP"
  note "seed: helper $SEEDIID ip=$SIP — waiting for ssh"
  for i in $(seq 1 30); do lssh ubuntu@"$SIP" true 2>/dev/null && break; sleep 10; done
  lscp artifacts/ena/ena artifacts/ena/ena.conf scripts/metadata-shim.sh \
       modules/config/solnix-nitro-pit.system.d ubuntu@"$SIP":/tmp/
  lssh ubuntu@"$SIP" "cat > /tmp/mypub" <<<"$PUBKEY"
  lssh ubuntu@"$SIP" "sudo tee /tmp/seed-run.sh >/dev/null" < scripts/base-ami-seed.sh
  lssh ubuntu@"$SIP" 'grep -c . /tmp/seed-run.sh; head -1 /tmp/seed-run.sh' || true
  lssh ubuntu@"$SIP" 'sudo bash -c "chmod +x /tmp/seed-run.sh; nohup /tmp/seed-run.sh </dev/null >/dev/null 2>&1 & echo started $!"'
  note "seed: running detached on $SEEDIID; poll with: $0 seed-poll"
}

stage_seed_poll() {
  SIP="$(kv SEEDIP)"; [ -n "$SIP" ] || { echo "no SEEDIP"; exit 1; }
  lssh ubuntu@"$SIP" 'sudo tail -40 /tmp/seed.log 2>/dev/null; echo "---STATUS---"; grep -q SEED_DONE /tmp/seed.log 2>/dev/null && echo SEED_DONE || (grep -qE "SEED_FAILED" /tmp/seed.log 2>/dev/null && echo SEED_FAILED || echo SEED_RUNNING)' 2>&1 || echo "ssh not ready"
}

stage_seed_log() {
  SIP="$(kv SEEDIP)"; lssh ubuntu@"$SIP" 'sudo cat /tmp/seed.log' 2>&1
}

# --- stage reg: snapshot + register ------------------------------------------
stage_reg() {
  VOL="$(kv VOL)"; [ -n "$VOL" ] || { echo "no VOL"; exit 1; }
  note "reg: detaching $VOL"
  aws ec2 detach-volume --volume-id "$VOL" >/dev/null 2>&1 || true
  aws ec2 wait volume-available --volume-ids "$VOL"
  SNAP="$(aws ec2 create-snapshot --volume-id "$VOL" --description "solnix base x86_64 $OI_VERSION (ena-mtu1500 + pit_is_broken)" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$AMI_NAME},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-base-ami},{Key=Expiry,Value=$EXPIRY}]" \
    --query SnapshotId --output text)"
  set_kv SNAP "$SNAP"; note "reg: snapshot $SNAP — waiting complete"
  aws ec2 wait snapshot-completed --snapshot-ids "$SNAP"
  AMI="$(aws ec2 register-image --name "$AMI_NAME" \
    --description "solnix x86_64 base (OI $OI_VERSION + ena MTU-1500 + single-addrobj shim + pit_is_broken=1)" \
    --architecture x86_64 --root-device-name /dev/xvda --ena-support \
    --virtualization-type hvm --boot-mode uefi \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$SNAP,VolumeType=gp3,DeleteOnTermination=true}" \
    --query ImageId --output text)"
  set_kv AMI "$AMI"
  aws ec2 create-tags --resources "$AMI" \
    --tags Key=Name,Value="$AMI_NAME" Key=Owner,Value=gregburd Key=Purpose,Value=solnix-base-ami Key=Expiry,Value="$EXPIRY"
  note "reg: BASE AMI = $AMI (snapshot $SNAP)"
  echo "AMI=$AMI"
}

# --- stage boot: single cold-launch smoke test -------------------------------
stage_boot() {
  AMI="${2:-$(kv AMI)}"; [ -n "$AMI" ] || { echo "no AMI"; exit 1; }
  RUN="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$BOOT_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --tag-specifications "$(tags_for solnix-base-boottest)" --output json)"
  BIID="$(echo "$RUN" | jq -r '.Instances[0].InstanceId')"
  set_kv BIID "$BIID"; note "boot: smoke test $BIID from $AMI ($BOOT_TYPE)"
}

stage_boot_poll() {
  BIID="${2:-$(kv BIID)}"; [ -n "$BIID" ] || { echo "no BIID"; exit 1; }
  IP="$(ip_of "$BIID")"; echo "boot-test $BIID ip=$IP"
  [ "$IP" = None ] && { echo "no IP yet"; return 0; }
  set_kv BIP "$IP"
  lssh root@"$IP" 'uname -a; hostname; ipadm show-addr; echo "--- pit ---"; echo "pit_is_broken/D" | mdb -k 2>/dev/null | tail -2; echo "pit_tsc_hz/E" | mdb -k 2>/dev/null | tail -2; echo "--- mtu ---"; dladm show-linkprop -p mtu ena0 2>/dev/null; echo "--- svcs ---"; svcs -x 2>&1 | head -8; echo PROBE_OK' 2>&1 || echo "SSH_NOT_READY"
}

# A plain API console read: cannot hang, no ssh involved.
stage_console() {
  IID="${2:-$(kv BIID)}"; [ -n "$IID" ] || { echo "no instance id"; exit 1; }
  aws ec2 get-console-output --instance-id "$IID" --latest --output text 2>&1 | tail -60
}

# --- stage batch: N fresh cold launches -> N/N ssh score ---------------------
# Run this DETACHED on the dev box (nohup) and poll its logfile; it sleeps a lot.
stage_batch() {
  AMI="${AMI_OVERRIDE:-$(kv AMI)}"; N="${2:-5}"; TAG="${BATCH_TAG:-b1}"
  [ -n "$AMI" ] || { echo "no AMI"; exit 1; }
  OUT="/tmp/base-ami-batch-$TAG.txt"
  : > "$OUT"
  echo "batch $TAG: N=$N ami=$AMI type=$BOOT_TYPE $(date -u +%FT%TZ)" | tee -a "$OUT"
  IIDS="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$BOOT_TYPE" --count "$N" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --tag-specifications "$(tags_for solnix-base-batch-$TAG)" \
    --query 'Instances[].InstanceId' --output text)"
  echo "instances: $IIDS" | tee -a "$OUT"
  declare -A PASS
  # Poll up to ~14 min; a cold OI boot + possible first-boot bootadm reboot is slow.
  for round in $(seq 1 42); do
    sleep 20
    alldone=1
    for iid in $IIDS; do
      [ "${PASS[$iid]:-}" = "1" ] && continue
      ip="$(ip_of "$iid" 2>/dev/null || echo None)"
      if [ "$ip" != None ] && [ -n "$ip" ]; then
        if timeout -s KILL 20 setsid ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
             -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o LogLevel=ERROR -o ConnectTimeout=8 root@"$ip" 'uname -s' 2>/dev/null | grep -q SunOS; then
          PASS[$iid]=1
          echo "  PASS $iid $ip round=$round (~$((round*20))s)" | tee -a "$OUT"
          continue
        fi
      fi
      alldone=0
    done
    [ "$alldone" = 1 ] && break
  done
  P=0; F=""
  for iid in $IIDS; do
    if [ "${PASS[$iid]:-}" = "1" ]; then P=$((P+1)); else F="$F $iid"; fi
  done
  echo "SCORE $TAG: $P/$N pass; failed:${F:- none}" | tee -a "$OUT"
  for iid in $F; do
    echo "=== console tail $iid ===" >> "$OUT"
    aws ec2 get-console-output --instance-id "$iid" --latest --output text 2>&1 | tail -40 >> "$OUT"
    aws ec2 describe-instance-status --instance-ids "$iid" --include-all-instances \
      --query 'InstanceStatuses[0].[InstanceState.Name,InstanceStatus.Status,SystemStatus.Status]' --output text >> "$OUT" 2>&1
  done
  aws ec2 terminate-instances --instance-ids $IIDS --query 'TerminatingInstances[].InstanceId' --output text >> "$OUT" 2>&1
  echo "BATCH_${TAG}_DONE $P/$N" | tee -a "$OUT"
  note "batch $TAG: $P/$N"
}

stage_reap() {
  for k in DDIID SEEDIID BIID; do
    id="$(kv $k)"; [ -n "$id" ] && [ "$id" != None ] && { note "reap: terminating $k $id"; aws ec2 terminate-instances --instance-ids "$id" >/dev/null 2>&1 || true; }
  done
  # any straggler tagged instance from this build
  S="$(aws ec2 describe-instances --filters Name=tag:Purpose,Values=solnix-base-ami \
        Name=instance-state-name,Values=pending,running,stopping,stopped \
        --query 'Reservations[].Instances[].InstanceId' --output text)"
  [ -n "$S" ] && { note "reap: straggler(s) $S"; aws ec2 terminate-instances --instance-ids $S >/dev/null 2>&1 || true; }
  true
}

case "${1:-}" in
  dd)        stage_dd ;;
  dd-poll)   stage_dd_poll ;;
  seed)      stage_seed "${2:-}" ;;
  seed-poll) stage_seed_poll ;;
  seed-log)  stage_seed_log ;;
  reg)       stage_reg ;;
  boot)      stage_boot "$@" ;;
  boot-poll) stage_boot_poll "$@" ;;
  console)   stage_console "$@" ;;
  batch)     stage_batch "$@" ;;
  reap)      stage_reap ;;
  state)     cat "$ST" 2>/dev/null || echo "(no state)" ;;
  *) echo "usage: $0 {dd|dd-poll|seed [ddiid]|seed-poll|seed-log|reg|boot [ami]|boot-poll [iid]|console [iid]|batch N|reap|state}"; exit 1 ;;
esac
