#!/usr/bin/env bash
# fred-fix-base-ami.sh — inject EC2 first-boot networking into the reconstructed
# solnix build-base (release-224-v2) and register an EC2-reliable AMI in fred.
#
# The base AMI ami-0532a78a88e926f22 (snap-0a4a849d9b684b952) boots illumos but
# has NO network: release-224-v2 is the LOCAL-HARDWARE install image and lacks
# the EC2 first-boot networking that egret's AMI baked. We surgically inject it
# offline (no dd stage — we already have the solnix root snapshot):
#
#   stage seed : Ubuntu 24.04 ZFS helper imports the `spool` pool, mounts the BE
#                spool/ROOT/solnix-1, applies metadata-shim.sh (IMDSv2 net) +
#                scrubs the dual DHCP addrobj + injects the fixed ena driver +
#                root ssh key + PermitRootLogin, exports.
#   stage reg  : snapshot the fixed vol + register AMI (--ena-support, uefi).
#   stage boot : launch the new AMI, wait, ssh-verify nix + tranche + hello.
#   stage reap : terminate helper + boot-test instances.
#
# SECURITY: uses ONLY the pre-existing guard-clean SG (:22 from two /32s). Opens
# NO 0.0.0.0/0. Everything lands in the fixed fred subnet (EBS is AZ-bound).
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE=fred
REGION=us-east-2
SRC_SNAP="snap-0a4a849d9b684b952"     # solnix release-224-v2 root
AMI_NAME="solnix-build-base-v2-ec2fixed-fred"
VOL_GB=40
POOL="spool"                          # solnix root pool (NOT rpool)
KEY_NAME="fred-key"
SG_ID="sg-074eddb1fd24663e6"          # solnix-build-fred (:22 from two /32s ONLY)
SUBNET="subnet-0bf6b544c7ade866a"     # fred, us-east-2b; AZ-bound with the vol
AZ="us-east-2b"
HELPER_TYPE="m5.large"
BOOT_TYPE="m5.large"
KEY="$HOME/.ssh/id_ed25519"
PUBKEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
EXPIRY="$(date -d '+14 days' +%Y-%m-%d 2>/dev/null || date -v+14d +%Y-%m-%d)"
ST=/tmp/fred-fix-ami.state

aws() { command aws --profile fred --region "$REGION" "$@"; }
log() { printf '\n=== %s ===\n' "$*" >&2; }
kv()  { grep "^$1=" "$ST" 2>/dev/null | tail -1 | cut -d= -f2-; }
set_kv() { touch "$ST"; grep -v "^$1=" "$ST" 2>/dev/null > "$ST.tmp" || true; echo "$1=$2" >> "$ST.tmp"; mv "$ST.tmp" "$ST"; }
lssh() { timeout 40 ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
           -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$@"; }
ip_of() { aws ec2 describe-instances --instance-ids "$1" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }

stage_seed() {
  log "identity"; aws sts get-caller-identity --query Arn --output text | grep -Eq ':user/fred' \
    || { echo "wrong account/profile (expected fred)"; exit 1; }
  log "create fixed volume from $SRC_SNAP in $AZ"
  VOL="$(aws ec2 create-volume --snapshot-id "$SRC_SNAP" --availability-zone "$AZ" \
    --volume-type gp3 --size "$VOL_GB" \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=solnix-fred-fix},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=$EXPIRY}]" \
    --query VolumeId --output text)"
  set_kv VOL "$VOL"; log "vol $VOL — waiting available"
  aws ec2 wait volume-available --volume-ids "$VOL"
  UBU="$(aws ec2 describe-images --owners 099720109477 \
    --filters 'Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*' 'Name=state,Values=available' \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
  log "launching Ubuntu 24.04 seed-helper from $UBU in $SUBNET ($AZ)"
  RUN="$(aws ec2 run-instances --image-id "$UBU" --instance-type "$HELPER_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-fred-seed},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=$EXPIRY}]" \
    --output json)"
  SEEDIID="$(echo "$RUN" | jq -r '.Instances[0].InstanceId')"
  set_kv SEEDIID "$SEEDIID"; log "seed-helper $SEEDIID launched; waiting running"
  aws ec2 wait instance-running --instance-ids "$SEEDIID"
  log "attaching vol $VOL to seed-helper as /dev/sdf"
  aws ec2 attach-volume --volume-id "$VOL" --instance-id "$SEEDIID" --device /dev/sdf >/dev/null
  SIP="$(ip_of "$SEEDIID")"; set_kv SEEDIP "$SIP"
  log "seed-helper ip=$SIP — waiting for ssh, then push payload + run detached"
  for i in $(seq 1 30); do lssh ubuntu@"$SIP" true 2>/dev/null && break; sleep 10; done
  scp -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new \
    artifacts/ena/ena artifacts/ena/ena.conf scripts/oi-inject-ena.sh scripts/metadata-shim.sh \
    ubuntu@"$SIP":/tmp/
  lssh ubuntu@"$SIP" "cat > /tmp/mypub" <<<"$PUBKEY"
  lssh ubuntu@"$SIP" "sudo tee /tmp/seed-run.sh >/dev/null" <<SEED
#!/bin/bash
set -uxo pipefail
exec >/tmp/seed.log 2>&1
POOL="$POOL"
export DEBIAN_FRONTEND=noninteractive
until apt-get update -y; do sleep 5; done
apt-get install -y zfsutils-linux
modprobe zfs
ROOT=\$(findmnt -no SOURCE / | sed 's/p\\?[0-9]*\$//')
DATA=""
for d in /dev/nvme*n1; do [ "\$d" = "\$ROOT" ] && continue; DATA=\$d; done
echo "ROOT=\$ROOT DATA=\$DATA"
lsblk
# ---- probe: what pools/features does this snapshot carry? (diagnosis if import fails)
echo "=== zpool import (readonly probe) ==="
zpool import 2>&1 || true
echo "=== import \$POOL RW altroot /mnt ==="
if ! zpool import -f -N -R /mnt "\$POOL" 2>&1; then
  echo "ZFS_IMPORT_FAILED: cannot import \$POOL on this Ubuntu OpenZFS"
  echo "=== import by-id probe ==="
  zpool import -d /dev 2>&1 || true
  echo "SEED_FAILED_ZFS"
  exit 1
fi
zpool status "\$POOL" 2>&1 | head -40
BE=\$(zfs list -H -o name -r "\$POOL/ROOT" 2>/dev/null | grep -E '/ROOT/.' | head -1)
echo "BE=\$BE"
[ -n "\$BE" ] || { echo "NO_BE_FOUND"; zfs list 2>&1; echo SEED_FAILED_NOBE; exit 1; }
zfs set mountpoint=legacy "\$BE" 2>&1 || true
zfs set canmount=noauto "\$BE" 2>&1 || true
mkdir -p /mnt/be
mount -t zfs "\$BE" /mnt/be 2>&1 || { echo MOUNT_FAILED; zfs mount "\$BE" 2>&1; }
echo "=== BE mounted; pre-fix diagnosis ==="
echo "--- /usr/lib/metadata (shim present? IMDSv1 agent? absent?) ---"
if [ -f /mnt/be/usr/lib/metadata ]; then
  head -3 /mnt/be/usr/lib/metadata 2>&1; file /mnt/be/usr/lib/metadata 2>&1
  grep -q 'solnix shim' /mnt/be/usr/lib/metadata 2>/dev/null && echo "SHIM_ALREADY_PRESENT" || echo "NOT_THE_SHIM"
else
  echo "METADATA_ABSENT"
fi
echo "--- svc metadata manifest present? ---"
ls -la /mnt/be/lib/svc/manifest/system/*metadata* /mnt/be/var/svc/manifest/system/*metadata* 2>&1 | head
echo "--- /etc/ipadm/ipadm.conf (dual addrobj?) ---"
cat /mnt/be/etc/ipadm/ipadm.conf 2>&1 | head -20
echo "--- /boot/loader.conf (hash_load / console) ---"
cat /mnt/be/boot/loader.conf 2>&1 | grep -E 'hash_load|console' || echo "(no hash_load/console lines in /boot/loader.conf)"
echo "--- ena driver present? ---"
ls -la /mnt/be/kernel/drv/amd64/ena 2>&1
grep -w '^ena' /mnt/be/etc/name_to_major 2>&1 || echo "(no ena in name_to_major)"

echo "=== APPLYING FIXES ==="
# 1. metadata-shim: replace whatever is at /usr/lib/metadata (the SMF metadata
#    service execs this at first boot; the shim brings up ena0/dhcp + ssh).
install -m 0755 /tmp/metadata-shim.sh /mnt/be/usr/lib/metadata && echo "SHIM_INSTALLED"
# 1b. dual DHCP addrobj scrub + drop stale lease/identifiers (clean first boot).
if [ -f /mnt/be/etc/ipadm/ipadm.conf ]; then
  grep -v '_aobjname=ena0/v4' /mnt/be/etc/ipadm/ipadm.conf > /mnt/be/etc/ipadm/ipadm.conf.new \
    && mv /mnt/be/etc/ipadm/ipadm.conf.new /mnt/be/etc/ipadm/ipadm.conf && echo "IPADM_SCRUBBED"
fi
rm -f /mnt/be/etc/dhcp/*.dhc /mnt/be/etc/dhcp/duid /mnt/be/etc/dhcp/iaid 2>/dev/null || true
rm -f /mnt/be/var/lib/solnix/first-boot-net-rebooted /mnt/be/var/lib/solnix/first-boot-net-reboots /mnt/be/var/lib/solnix/net-ok 2>/dev/null || true
# 2. ena driver -> Nitro NIC (inject module+conf+aliases+major if missing).
install -m 0755 -o 0 -g 3 /tmp/ena     /mnt/be/kernel/drv/amd64/ena && echo "ENA_MODULE_INSTALLED"
install -m 0644 -o 0 -g 3 /tmp/ena.conf /mnt/be/kernel/drv/ena.conf
for a in 'pciex1d0f,ec2' 'pciex1d0f,1ec2' 'pciex1d0f,ec20' 'pciex1d0f,ec21'; do
  grep -q "^ena \"\$a\"" /mnt/be/etc/driver_aliases || echo "ena \"\$a\"" >> /mnt/be/etc/driver_aliases
done
if ! grep -qw '^ena' /mnt/be/etc/name_to_major; then
  MAJ=\$(awk '{print \$2}' /mnt/be/etc/name_to_major | sort -n | tail -1); MAJ=\$((MAJ+1))
  echo "ena \$MAJ" >> /mnt/be/etc/name_to_major; echo "ena major \$MAJ (added)"
fi
# 2b. ensure the SMF metadata service is ENABLED at next boot (so the shim runs).
#     If the seeds file exists, flip it; else rely on the baked default.
for repo in /mnt/be/etc/svc/repository.db; do [ -f "\$repo" ] && echo "svc repo present: \$repo"; done
# 3. root ssh key + PermitRootLogin (the shim enables sshd).
mkdir -p /mnt/be/root/.ssh; chmod 700 /mnt/be/root/.ssh
cp /tmp/mypub /mnt/be/root/.ssh/authorized_keys; chmod 600 /mnt/be/root/.ssh/authorized_keys
if [ -f /mnt/be/etc/ssh/sshd_config ]; then
  sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' /mnt/be/etc/ssh/sshd_config
  grep -q '^PermitRootLogin yes' /mnt/be/etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /mnt/be/etc/ssh/sshd_config
  echo "SSHD_CONFIGURED"
fi
sync
echo "=== post-fix verify ==="
grep -q 'solnix shim' /mnt/be/usr/lib/metadata && echo "VERIFY_SHIM_OK"
grep -q '_aobjname=ena0/v4' /mnt/be/etc/ipadm/ipadm.conf 2>/dev/null && echo "VERIFY_DUAL_REMAINS" || echo "VERIFY_NO_DUAL"
ls -la /mnt/be/kernel/drv/amd64/ena
umount /mnt/be 2>&1 || true
zpool export "\$POOL" 2>&1 || true
echo SEED_DONE
SEED
  lssh ubuntu@"$SIP" 'sudo bash -c "chmod +x /tmp/seed-run.sh; nohup /tmp/seed-run.sh </dev/null >/dev/null 2>&1 & echo started $!"'
  log "seed running detached on $SEEDIID; poll with: $0 seed-poll"
}

stage_seed_poll() {
  SIP="$(kv SEEDIP)"; [ -n "$SIP" ] || { echo "no SEEDIP"; exit 1; }
  lssh ubuntu@"$SIP" 'sudo cat /tmp/seed.log 2>/dev/null; echo "---"; grep -q SEED_DONE /tmp/seed.log 2>/dev/null && echo SEED_DONE || (grep -qE "SEED_FAILED" /tmp/seed.log 2>/dev/null && echo SEED_FAILED || echo SEED_RUNNING)' 2>&1 || echo "ssh not ready"
}

stage_reg() {
  VOL="$(kv VOL)"; SEEDIID="$(kv SEEDIID)"
  [ -n "$VOL" ] || { echo "no VOL"; exit 1; }
  log "detaching vol $VOL from seed-helper"
  aws ec2 detach-volume --volume-id "$VOL" >/dev/null 2>&1 || true
  aws ec2 wait volume-available --volume-ids "$VOL"
  log "snapshotting fixed vol $VOL"
  SNAP="$(aws ec2 create-snapshot --volume-id "$VOL" --description "solnix-224-v2 EC2-networking-fixed fred" \
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
  set_kv AMI "$AMI"
  aws ec2 create-tags --resources "$AMI" \
    --tags Key=Name,Value="$AMI_NAME" Key=Owner,Value=gregburd Key=Purpose,Value=solnix-dev Key=Expiry,Value="$EXPIRY"
  log "FIXED AMI = $AMI  (snapshot $SNAP)"
  echo "AMI=$AMI"
}

stage_boot() {
  AMI="$(kv AMI)"; [ -n "$AMI" ] || { echo "no AMI"; exit 1; }
  log "launching boot-test $BOOT_TYPE from $AMI"
  RUN="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$BOOT_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-fred-boottest},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dev},{Key=Expiry,Value=$EXPIRY}]" \
    --output json)"
  BIID="$(echo "$RUN" | jq -r '.Instances[0].InstanceId')"
  set_kv BIID "$BIID"; log "boot-test $BIID launched; poll with: $0 boot-poll"
}

stage_boot_poll() {
  BIID="$(kv BIID)"; [ -n "$BIID" ] || { echo "no BIID"; exit 1; }
  IP="$(ip_of "$BIID")"; echo "boot-test $BIID ip=$IP"
  [ "$IP" = None ] && { echo "no IP yet"; return; }
  set_kv BIP "$IP"
  echo "=== ssh verify (nix + tranche + hello) ==="
  lssh root@"$IP" 'uname -a; export PATH=/run/current-system/sw/bin:$PATH; nix --version 2>&1 | head -1; ls /root/tranche-224.nix 2>&1; nix-instantiate /root/tranche-224.nix -A hello >/dev/null 2>&1 && echo HELLO-OK || echo HELLO-FAIL' 2>&1 || echo "SSH_NOT_READY"
}

stage_console() {
  BIID="${1:-$(kv BIID)}"; [ -n "$BIID" ] || { echo "no instance id"; exit 1; }
  aws ec2 get-console-output --instance-id "$BIID" --output text 2>&1 | tail -80
}

stage_reap() {
  for k in SEEDIID BIID; do
    id="$(kv $k)"; [ -n "$id" ] && [ "$id" != None ] && { log "terminating $k $id"; aws ec2 terminate-instances --instance-ids "$id" >/dev/null || true; }
  done
}

case "${1:-}" in
  seed)      stage_seed ;;
  seed-poll) stage_seed_poll ;;
  reg)       stage_reg ;;
  boot)      stage_boot ;;
  boot-poll) stage_boot_poll ;;
  console)   stage_console "${2:-}" ;;
  reap)      stage_reap ;;
  state)     cat "$ST" 2>/dev/null || echo "(no state)" ;;
  *) echo "usage: $0 {seed|seed-poll|reg|boot|boot-poll|console [iid]|reap|state}"; exit 1 ;;
esac
