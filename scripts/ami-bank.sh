#!/usr/bin/env bash
# ami-bank.sh — bank a solnix base AMI's disk image in the R2 object store, and
# restore it into a fresh AWS account.
#
# WHY THIS EXISTS: an AMI is account-scoped, so a burner-account expiry destroys
# it. That has now happened at least three times (beef, ouch, bene), and each
# time the response was a NEW PER-ACCOUNT SCRIPT rather than a durable artifact
# — scripts/ held beef-make-base-ami.sh, ouch-make-base-ami.sh and
# bene-make-base-ami.sh, three drifted forks of one procedure, each stranded with
# its account. R2 is not account-scoped, so the image banked here outlives any
# burner.
#
# THE SHAPE, and why it works without a second account: AMI *export* is not used
# and is not needed. `aws ec2 export-image` only works on AMIs that were
# VM-Imported, so it would fail here anyway. Instead this reads the image out of
# a live EBS volume with dd — the exact inverse of how make-base-ami.sh writes
# the public OI image IN. Restore is therefore the already-proven
# dd -> snapshot -> register-image path with the banked image substituted for the
# public one, and it SKIPS the seed stage entirely because the banked image
# already carries every cold-boot fix.
#
# ⚠️ VERIFICATION: uploads are verified by READING THE OBJECT BACK and comparing
# sha256 — never by exit status. Direct evidence this matters:
# images/release-224-ena-mtufix/solnix-raw.img.gz in this same bucket is 20 BYTES,
# a silently truncated upload that has sat there since August. A successful exit
# status produced that file.
#
#   ami-bank.sh bank <ami-id> [prefix]   snapshot -> helper -> dd -> gzip -> upload -> read-back verify -> manifest
#   ami-bank.sh verify <prefix>          re-verify a banked prefix from the object store alone
#   ami-bank.sh restore <prefix>         register a working AMI in the CURRENT account from a banked image
#   ami-bank.sh list                     what is banked
#
# Env: SOLNIX_PROFILE REGION SG_ID SUBNET AZ KEY_NAME KEY HELPER_TYPE
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${SOLNIX_PROFILE:-lava}"
REGION="${REGION:-us-east-2}"
SG_ID="${SG_ID:-sg-0d7ce9a7390bfadfe}"        # :22 from the operator /24 ONLY — never world-open
SUBNET="${SUBNET:-subnet-0230d1c45d8a098a7}"
AZ="${AZ:-us-east-2a}"
KEY_NAME="${KEY_NAME:-solnix-lava}"
KEY="${KEY:-$HOME/.ssh/${KEY_NAME}.pem}"
HELPER_TYPE="${HELPER_TYPE:-c5.4xlarge}"       # 16 vCPU; the gzip is the long pole
S3_BUCKET="${S3_BUCKET:-solnix-cache}"
S3_ENDPOINT="${S3_ENDPOINT:-https://s3.solnix.io}"
EXPIRY="$(date -d '+14 days' +%Y-%m-%d 2>/dev/null || date -v+14d +%Y-%m-%d)"
PROG="${PROG:-/tmp/ami-bank-progress.txt}"

aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }
log()  { printf '\n=== %s ===\n' "$*" >&2; }
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$PROG" >&2; }

# Short, hard-bounded, non-interactive ssh. setsid detaches from the tty so a
# stuck remote can never hold this shell; KILL beats any ssh-internal blocking.
lssh() { timeout -s KILL "${SSH_TIMEOUT:-60}" setsid ssh -i "$KEY" -o IdentitiesOnly=yes \
           -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 "$@"; }
ip_of() { aws ec2 describe-instances --instance-ids "$1" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }

# S3 creds come from sops and stay in this shell only — never written to a file.
# Same idiom as scripts/oi-cache-publish.sh.
s3_creds() {
  export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
  local sops_bin; sops_bin="$(command -v sops || true)"
  if [ -n "$sops_bin" ]; then
    eval "$("$sops_bin" --decrypt secrets/s3-cache.yaml \
      | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
  else
    eval "$(nix run nixpkgs#sops -- --decrypt secrets/s3-cache.yaml \
      | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
  fi
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "FATAL: no S3 creds from sops" >&2; exit 1; }
  export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
}
# The object-store aws call must NOT inherit --profile (those are EC2 creds).
s3() { command aws --endpoint-url "$S3_ENDPOINT" "$@"; }

# --- bank -------------------------------------------------------------------
cmd_bank() {
  local ami="${1:?usage: ami-bank.sh bank <ami-id> [prefix]}"
  # ⚠️ NOT under `images/`: the sops S3 credential is DENIED write on that exact
  # prefix (403 on PutObject, measured — it can write every other prefix in this
  # bucket, including the root). The pre-existing images/release-224-* blobs were
  # uploaded with a different, more privileged key that is not in secrets/.
  local prefix="${2:-ami/x86_64-$(date +%Y%m%d)}"
  note "bank: $ami -> s3://$S3_BUCKET/$prefix"

  local name arch snap bootmode ena
  read -r name arch bootmode ena snap <<<"$(aws ec2 describe-images --image-ids "$ami" \
    --query 'Images[0].[Name,Architecture,BootMode,EnaSupport,BlockDeviceMappings[0].Ebs.SnapshotId]' \
    --output text)"
  [ -n "$snap" ] && [ "$snap" != None ] || { echo "no snapshot on $ami"; exit 1; }
  note "bank: name=$name arch=$arch boot=$bootmode ena=$ena snap=$snap"

  # A volume FROM THE AMI'S SNAPSHOT, not from a running instance: capturing a
  # booted node is the documented way to LOSE the reliable-boot property
  # (docs/base-ami-rebuild-runbook.md — a create-image of a running instance
  # regressed cold-boot DHCP). The snapshot is the pristine registered state.
  local vol
  vol="$(aws ec2 create-volume --availability-zone "$AZ" --snapshot-id "$snap" \
    --volume-type gp3 --tag-specifications \
    "ResourceType=volume,Tags=[{Key=Name,Value=solnix-amibank-src},{Key=Project,Value=solnix},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-amibuild},{Key=Expiry,Value=$EXPIRY}]" \
    --query VolumeId --output text)"
  note "bank: volume $vol from $snap"
  aws ec2 wait volume-available --volume-ids "$vol"

  local al2023 iid
  al2023="$(aws ec2 describe-images --owners amazon \
    --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' 'Name=state,Values=available' \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
  # Root big enough to hold the raw image AND its gzip side by side.
  iid="$(aws ec2 run-instances --image-id "$al2023" --instance-type "$HELPER_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":80,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-amibank},{Key=Project,Value=solnix},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-amibuild},{Key=Expiry,Value=$EXPIRY}]" \
    --query 'Instances[0].InstanceId' --output text)"
  note "bank: helper $iid"
  aws ec2 wait instance-running --instance-ids "$iid"
  aws ec2 attach-volume --volume-id "$vol" --instance-id "$iid" --device /dev/sdf >/dev/null
  local ip; ip="$(ip_of "$iid")"; note "bank: helper ip=$ip"
  local i
  for i in $(seq 1 40); do lssh ec2-user@"$ip" true 2>/dev/null && break; sleep 10; done

  # Compress ON the helper: 2 GiB of mostly-empty ZFS gzips ~10x, so this moves
  # far less over the wire. gzip (not zstd) matches the existing images/ prefix.
  lssh ec2-user@"$ip" 'sudo dnf install -y pigz >/dev/null 2>&1 || true; command -v pigz || command -v gzip' || true
  # push the identity gate to the helper first (bank.sh runs it on the raw device)
  lssh ec2-user@"$ip" 'sudo bash -c "cat > /root/solnix-image-identity-gate.sh; chmod 755 /root/solnix-image-identity-gate.sh"' < "$(dirname "$0")/solnix-image-identity-gate.sh" || { note "bank: FAILED to push the identity gate"; exit 1; }
  SSH_TIMEOUT=60 lssh ec2-user@"$ip" 'sudo bash -c "cat > /root/bank.sh" <<'"'"'EOS'"'"'
set -euxo pipefail
ROOT=$(findmnt -no SOURCE / | sed "s/p\?[0-9]*$//")
SRC=""
for d in /dev/nvme*n1; do [ "$d" = "$ROOT" ] && continue; SRC=$d; done
[ -n "$SRC" ] || { echo BANK_FAILED_NODISK; exit 1; }
SZ=$(blockdev --getsize64 "$SRC")
echo "src=$SRC bytes=$SZ"
# sha256 of the RAW device as read, so the manifest pins what was actually banked.
dd if="$SRC" bs=16M status=none | tee >(sha256sum | cut -d" " -f1 > /root/raw.sha256) \
  | { command -v pigz >/dev/null && pigz -1 -c || gzip -1 -c; } > /root/solnix-base-raw.img.gz
sync
echo "raw_sha256=$(cat /root/raw.sha256)"
echo "raw_bytes=$SZ"
echo "gz_bytes=$(wc -c < /root/solnix-base-raw.img.gz)"
sha256sum /root/solnix-base-raw.img.gz | cut -d" " -f1 > /root/gz.sha256
echo "gz_sha256=$(cat /root/gz.sha256)"
# Prove the gzip stream is complete and decompresses to the same bytes. gzip -t
# alone would not catch a truncated-then-valid-prefix case as decisively.
{ command -v pigz >/dev/null && pigz -dc || gzip -dc; } < /root/solnix-base-raw.img.gz \
  | sha256sum | cut -d" " -f1 > /root/roundtrip.sha256
echo "roundtrip_sha256=$(cat /root/roundtrip.sha256)"
[ "$(cat /root/raw.sha256)" = "$(cat /root/roundtrip.sha256)" ] || { echo BANK_FAILED_ROUNDTRIP; exit 1; }
# MANDATORY identity gate (security 2026-11-06): refuse to bank an image carrying a private key, age secret,
# inline sops, a maintainer identity string, or a non-root password hash. Scans the RAW device bytes. A released
# raw once carried a maintainer private key; this makes that un-publishable by construction.
[ -x /root/solnix-image-identity-gate.sh ] || { echo BANK_FAILED_NO_GATE; exit 1; }
if ! /root/solnix-image-identity-gate.sh "$SRC" >/root/gate.log 2>&1; then
  echo BANK_FAILED_IDENTITY_GATE; sed "s/^/gate: /" /root/gate.log; exit 1
fi
echo "identity-gate: $(grep -E "^(CLEAN|REJECT)" /root/gate.log | tail -1)"
echo BANK_LOCAL_OK
EOS
sudo bash -c "chmod +x /root/bank.sh; nohup /root/bank.sh </dev/null >/root/bank.log 2>&1 & echo started"' || true
  note "bank: dd+gzip running detached on $iid; poll: $0 bank-poll $iid"
  printf 'BANK_IID=%s\nBANK_VOL=%s\nBANK_AMI=%s\nBANK_SNAP=%s\nBANK_PREFIX=%s\nBANK_NAME=%s\nBANK_ARCH=%s\nBANK_BOOT=%s\nBANK_ENA=%s\n' \
    "$iid" "$vol" "$ami" "$snap" "$prefix" "$name" "$arch" "$bootmode" "$ena" > /tmp/ami-bank.state
  note "bank: state -> /tmp/ami-bank.state"
}

cmd_bank_poll() {
  local iid="${1:-$(grep '^BANK_IID=' /tmp/ami-bank.state | cut -d= -f2)}"
  local ip; ip="$(ip_of "$iid")"
  lssh ec2-user@"$ip" 'sudo tail -6 /root/bank.log; echo ---; sudo grep -q BANK_LOCAL_OK /root/bank.log && echo BANK_LOCAL_OK || (sudo grep -q BANK_FAILED /root/bank.log && echo BANK_FAILED || echo BANK_RUNNING)' 2>&1
}

# Upload from the helper, then VERIFY BY READING BACK — the only check that
# catches the 20-byte-truncation failure mode.
cmd_bank_upload() {
  . /tmp/ami-bank.state
  local ip; ip="$(ip_of "$BANK_IID")"
  local raw_sha gz_sha raw_bytes gz_bytes
  raw_sha="$(lssh ec2-user@"$ip" 'sudo cat /root/raw.sha256')"
  gz_sha="$(lssh ec2-user@"$ip" 'sudo cat /root/gz.sha256')"
  raw_bytes="$(lssh ec2-user@"$ip" 'sudo grep ^raw_bytes= /root/bank.log | tail -1 | cut -d= -f2')"
  # sudo must own the redirect too: /root is not readable by ec2-user, so a bare
  # `sudo wc -c < /root/...` fails with "Permission denied" in the LOCAL shell.
  gz_bytes="$(lssh ec2-user@"$ip" 'sudo wc -c /root/solnix-base-raw.img.gz | cut -d" " -f1')"
  note "upload: raw=$raw_bytes ($raw_sha) gz=$gz_bytes ($gz_sha)"

  s3_creds
  # Push creds to the helper's env for one command; aws cli on the helper does
  # the multipart upload so the image never transits the dev box.
  lssh ec2-user@"$ip" 'command -v aws >/dev/null || sudo dnf install -y awscli-2 >/dev/null 2>&1 || sudo dnf install -y awscli >/dev/null 2>&1; aws --version' || true
  SSH_TIMEOUT=2400 lssh ec2-user@"$ip" \
    "sudo AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID' AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY' \
     AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true \
     aws --endpoint-url '$S3_ENDPOINT' s3 cp /root/solnix-base-raw.img.gz \
       's3://$S3_BUCKET/$BANK_PREFIX/solnix-base-raw.img.gz' --only-show-errors && echo UPLOAD_EXIT_OK"

  # ⚠️ Exit status is NOT evidence. Read the object back and compare sha256.
  note "verify: reading the object BACK from $S3_ENDPOINT (exit status is not evidence)"
  local remote_sha remote_len
  remote_len="$(s3 s3api head-object --bucket "$S3_BUCKET" --key "$BANK_PREFIX/solnix-base-raw.img.gz" --query ContentLength --output text)"
  remote_sha="$(curl -fsSL "$S3_ENDPOINT/$S3_BUCKET/$BANK_PREFIX/solnix-base-raw.img.gz" | sha256sum | cut -d' ' -f1)"
  note "verify: remote length=$remote_len local=$gz_bytes"
  note "verify: remote sha256=$remote_sha"
  note "verify: local  sha256=$gz_sha"
  [ "$remote_len" = "$gz_bytes" ] || { note "VERIFY_FAILED: length mismatch (TRUNCATED UPLOAD)"; exit 1; }
  [ "$remote_sha" = "$gz_sha" ]   || { note "VERIFY_FAILED: sha256 mismatch"; exit 1; }
  note "VERIFY_OK: read-back sha256 matches"

  cmd_manifest "$raw_sha" "$gz_sha" "$raw_bytes" "$gz_bytes" "$remote_sha" "$remote_len"
}

cmd_manifest() {
  . /tmp/ami-bank.state
  local raw_sha="$1" gz_sha="$2" raw_bytes="$3" gz_bytes="$4" remote_sha="$5" remote_len="$6"
  local M=/tmp/ami-bank-MANIFEST.txt
  cat > "$M" <<EOF
solnix x86_64 base AMI — banked disk image
==========================================
Banked (UTC):        $(date -u +%FT%TZ)
Source AMI:          $BANK_AMI  ($BANK_NAME)
Source snapshot:     $BANK_SNAP
Architecture:        $BANK_ARCH
Boot mode:           $BANK_BOOT      ENA support: $BANK_ENA
Root device:         /dev/xvda (gp3, 20 GiB)
Login:               root + the account keypair's private key; PermitRootLogin yes
Built from:          https://dlc.openindiana.org/isos/hipster/20251026/OI-hipster-cloudimage.img.zst
Recipe:              scripts/make-base-ami.sh (dd/seed/reg/boot/batch/reap)
Seed payload:        scripts/base-ami-seed.sh

ARTIFACTS
---------
solnix-base-raw.img            $raw_bytes bytes   raw whole-disk image (GPT: ESP + rpool + Solaris reserved)
  sha256 $raw_sha
solnix-base-raw.img.gz         $gz_bytes bytes   (gzip -1 of the raw image; THIS is the banked object)
  sha256 $gz_sha

READ-BACK VERIFICATION (not exit status)
----------------------------------------
Object:              s3://$S3_BUCKET/$BANK_PREFIX/solnix-base-raw.img.gz
HTTPS URL:           $S3_ENDPOINT/$S3_BUCKET/$BANK_PREFIX/solnix-base-raw.img.gz
head-object length:  $remote_len   (equals local $gz_bytes)
re-downloaded sha256: $remote_sha   (equals local $gz_sha)
gzip round-trip:     decompressed stream sha256 == raw image sha256 (verified on the helper)

FIXES CARRIED IN THIS IMAGE
---------------------------
1. Offline boot_archive rebuild (raw gzip'd odc cpio, original entry order) so the
   kernel sees /etc/system + the fixed ena from the RAMDISK, which it reads in
   kmem_init() long before the ZFS root is mounted.
2. metadata-shim.sh over /usr/lib/metadata — IMDSv2-proof (the stock OI
   metadata-agent is an IMDSv1 client and hangs 300 s, gating milestone/network).
3. Single DHCP addrobj: ena0/v4 stripped from ipadm.conf + stale .dhc/duid/iaid
   removed, so exactly one ena0/dhcp claims the lease.
4. set pit_is_broken=1 in /etc/system AND /etc/system.d/solnix-nitro-pit, both
   inside the boot_archive — the Nitro emulated i8254 PIT intermittently wedges
   tsc_calibrate_pit() pre-userland.
5. Root pool grown to the whole 20 GiB volume. NOTE: the grow guard used to
   SILENTLY no-op because it trusted sfdisk's stale last-lba (the GPT is dd'd
   from a 1.95 GiB image onto a 20 GiB volume); it now reads the real device size
   via blockdev --getsz, rewrites last-lba in the emitted table, and ASSERTS the
   result (GROW_VERIFIED). Measured 3555039 -> 41385694 sectors.
6. Native illumos Nix 2.3.16 bootstrap staged at /root/nix-illumos-2.3.16.tar.zst.

RESTORE INTO A FRESH ACCOUNT
----------------------------
No VM Import/Export and no vmimport IAM role. 'aws ec2 export-image' would not
work here anyway (it only exports VM-Imported AMIs) and is not needed:

  SOLNIX_PROFILE=<new> SG_ID=<sg> SUBNET=<subnet> AZ=<az> KEY_NAME=<kp> \\
    scripts/ami-bank.sh restore $BANK_PREFIX

which launches an AL2023 helper, curls this object over plain HTTPS, pipes it
through gunzip straight onto a blank 20 GiB volume, verifies the written bytes'
sha256 against $raw_sha, snapshots it and registers an AMI with
--architecture $BANK_ARCH --boot-mode $BANK_BOOT --ena-support --root-device-name /dev/xvda.
The seed stage is SKIPPED — this image already carries every fix above.

Only the ssh key differs per account: a restored AMI still trusts the OLD key.
Either keep the private key, or restore and then re-seed authorized_keys.
EOF
  cat "$M"
  s3_creds
  s3 s3 cp "$M" "s3://$S3_BUCKET/$BANK_PREFIX/MANIFEST.txt" --only-show-errors
  # Verify the manifest read-back too — it is the thing a future operator trusts.
  local rt; rt="$(curl -fsSL "$S3_ENDPOINT/$S3_BUCKET/$BANK_PREFIX/MANIFEST.txt" | sha256sum | cut -d' ' -f1)"
  local lt; lt="$(sha256sum "$M" | cut -d' ' -f1)"
  [ "$rt" = "$lt" ] || { note "VERIFY_FAILED: MANIFEST.txt read-back mismatch"; exit 1; }
  note "MANIFEST_OK: s3://$S3_BUCKET/$BANK_PREFIX/MANIFEST.txt (sha256 $lt)"
  # A SHA256SUMS sidecar so a future operator can verify without parsing prose.
  printf '%s  solnix-base-raw.img.gz\n%s  solnix-base-raw.img\n' "$gz_sha" "$raw_sha" > /tmp/ami-bank-SHA256SUMS
  s3 s3 cp /tmp/ami-bank-SHA256SUMS "s3://$S3_BUCKET/$BANK_PREFIX/SHA256SUMS" --only-show-errors
  note "banked: $S3_ENDPOINT/$S3_BUCKET/$BANK_PREFIX/"
}

# --- verify (from the object store alone, no EC2) ----------------------------
cmd_verify() {
  local prefix="${1:?usage: ami-bank.sh verify <prefix>}"
  s3_creds
  local url="$S3_ENDPOINT/$S3_BUCKET/$prefix/solnix-base-raw.img.gz"
  echo "verifying $url"
  local want len
  want="$(curl -fsSL "$S3_ENDPOINT/$S3_BUCKET/$prefix/SHA256SUMS" | awk '/solnix-base-raw.img.gz/{print $1}')"
  len="$(s3 s3api head-object --bucket "$S3_BUCKET" --key "$prefix/solnix-base-raw.img.gz" --query ContentLength --output text)"
  echo "  head-object ContentLength: $len"
  [ "${len:-0}" -gt 100000000 ] || { echo "  FAIL: implausibly small ($len bytes) — this is the 20-byte truncation mode"; exit 1; }
  local got; got="$(curl -fsSL "$url" | sha256sum | cut -d' ' -f1)"
  echo "  manifest sha256: $want"
  echo "  fetched  sha256: $got"
  [ "$want" = "$got" ] && echo "  VERIFY_OK" || { echo "  VERIFY_FAILED"; exit 1; }
}

cmd_list() {
  s3_creds
  s3 s3 ls "s3://$S3_BUCKET/images/" --recursive --human-readable
}

# --- restore into a fresh account -------------------------------------------
cmd_restore() {
  local prefix="${1:?usage: ami-bank.sh restore <prefix>}"
  local url="$S3_ENDPOINT/$S3_BUCKET/$prefix/solnix-base-raw.img.gz"
  local name="solnix-base-x86_64-restored-$(date +%Y%m%d)"
  note "restore: $url -> AMI in $PROFILE/$REGION"
  # The expected raw sha256 travels with the image, so the restore can assert the
  # bytes it wrote rather than assuming the download was intact.
  local want_raw
  want_raw="$(curl -fsSL "$S3_ENDPOINT/$S3_BUCKET/$prefix/SHA256SUMS" | awk '/solnix-base-raw.img$/{print $1}')"
  [ -n "$want_raw" ] || { echo "no raw sha256 in $prefix/SHA256SUMS"; exit 1; }
  note "restore: expecting raw sha256 $want_raw"

  local al2023 iid
  al2023="$(aws ec2 describe-images --owners amazon \
    --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' 'Name=state,Values=available' \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
  local ud
  ud="$(cat <<EOF
#!/bin/bash
set -euxo pipefail
ROOT=\$(findmnt -no SOURCE / | sed 's/p\?[0-9]*\$//')
for d in /dev/nvme*n1; do
  [ "\$d" = "\$ROOT" ] && continue
  if [ -z "\$(lsblk -no PARTUUID \$d)" ]; then DATA=\$d; break; fi
done
echo "DATA=\$DATA" > /root/restore.log
curl -fsSL "$url" | gzip -dc | dd of=\$DATA bs=16M status=none 2>>/root/restore.log
sync
# Verify the BYTES ON THE DISK, not the transfer's exit status. The image is
# smaller than the volume, so hash only the image's own length.
LEN=\$(curl -fsSL "$S3_ENDPOINT/$S3_BUCKET/$prefix/MANIFEST.txt" | awk '/^solnix-base-raw.img /{print \$2}')
echo "image length \$LEN" >> /root/restore.log
GOT=\$(dd if=\$DATA bs=16M count=\$(( (LEN + 16777215) / 16777216 )) status=none | head -c \$LEN | sha256sum | cut -d' ' -f1)
echo "want $want_raw" >> /root/restore.log
echo "got  \$GOT" >> /root/restore.log
[ "\$GOT" = "$want_raw" ] && echo RESTORE_SHA_OK >> /root/restore.log || echo RESTORE_SHA_MISMATCH >> /root/restore.log
touch /root/restore.done
EOF
)"
  iid="$(aws ec2 run-instances --image-id "$al2023" --instance-type "$HELPER_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --block-device-mappings '[{"DeviceName":"/dev/xvdb","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":false}}]' \
    --user-data "$ud" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-amirestore},{Key=Project,Value=solnix},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-amibuild},{Key=Expiry,Value=$EXPIRY}]" \
    --query 'Instances[0].InstanceId' --output text)"
  note "restore: helper $iid — poll with: $0 restore-poll $iid"
  printf 'RESTORE_IID=%s\nRESTORE_PREFIX=%s\nRESTORE_NAME=%s\n' "$iid" "$prefix" "$name" > /tmp/ami-restore.state
}

cmd_restore_poll() {
  local iid="${1:-$(grep '^RESTORE_IID=' /tmp/ami-restore.state | cut -d= -f2)}"
  local ip; ip="$(ip_of "$iid")"
  [ "$ip" = None ] && { echo "no IP yet"; return 0; }
  lssh ec2-user@"$ip" 'sudo cat /root/restore.log 2>/dev/null | tail -8; echo ---; sudo ls /root/restore.done >/dev/null 2>&1 && (sudo grep -q RESTORE_SHA_OK /root/restore.log && echo RESTORE_OK || echo RESTORE_SHA_MISMATCH) || echo RESTORE_RUNNING' 2>&1
}

cmd_restore_reg() {
  . /tmp/ami-restore.state
  local vol snap ami
  vol="$(aws ec2 describe-volumes --filters Name=attachment.instance-id,Values="$RESTORE_IID" \
    --query 'Volumes[?Attachments[0].Device==`/dev/xvdb`].VolumeId' --output text)"
  note "restore-reg: vol $vol — detaching"
  aws ec2 detach-volume --volume-id "$vol" >/dev/null
  aws ec2 wait volume-available --volume-ids "$vol"
  snap="$(aws ec2 create-snapshot --volume-id "$vol" --description "solnix base restored from $RESTORE_PREFIX" \
    --query SnapshotId --output text)"
  note "restore-reg: snapshot $snap"
  # The waiter gives up after 10 min; a 20 GiB snapshot of a freshly written
  # volume took ~25 min (2026-10-17), so retry it until the snapshot completes.
  until aws ec2 wait snapshot-completed --snapshot-ids "$snap" 2>/dev/null; do
    st="$(aws ec2 describe-snapshots --snapshot-ids "$snap" --query 'Snapshots[0].State' --output text)"
    [ "$st" = error ] && { note "restore-reg: snapshot $snap failed"; exit 1; }
    note "restore-reg: snapshot $snap still $st"
  done
  ami="$(aws ec2 register-image --name "$RESTORE_NAME" \
    --description "solnix x86_64 base restored from s3://$S3_BUCKET/$RESTORE_PREFIX" \
    --architecture x86_64 --root-device-name /dev/xvda --ena-support \
    --virtualization-type hvm --boot-mode uefi \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$snap,VolumeType=gp3,DeleteOnTermination=true}" \
    --query ImageId --output text)"
  note "restore-reg: RESTORED AMI = $ami"
  echo "AMI=$ami"
}

cmd_reap() {
  local s
  s="$(aws ec2 describe-instances --filters Name=tag:Purpose,Values=solnix-amibuild \
        Name=instance-state-name,Values=pending,running,stopping,stopped \
        --query 'Reservations[].Instances[].InstanceId' --output text)"
  [ -n "$s" ] && { note "reap: $s"; aws ec2 terminate-instances --instance-ids $s >/dev/null; } || note "reap: nothing"
}

case "${1:-}" in
  bank)         shift; cmd_bank "$@" ;;
  bank-poll)    shift; cmd_bank_poll "$@" ;;
  bank-upload)  shift; cmd_bank_upload "$@" ;;
  verify)       shift; cmd_verify "$@" ;;
  list)         cmd_list ;;
  restore)      shift; cmd_restore "$@" ;;
  restore-poll) shift; cmd_restore_poll "$@" ;;
  restore-reg)  shift; cmd_restore_reg "$@" ;;
  reap)         cmd_reap ;;
  *) echo "usage: $0 {bank <ami> [prefix]|bank-poll|bank-upload|verify <prefix>|list|restore <prefix>|restore-poll|restore-reg|reap}" >&2; exit 1 ;;
esac
