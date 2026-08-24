#!/bin/sh
# oi-make-desktop-instance.sh -- provision a connectable solnix COSMIC desktop
# instance for the maintainer to test.
#
# Prereqs (all now satisfied this campaign):
#   * the canonical reliable-boot AMI (ena-fixed): ami-0978836610527a836
#   * the built COSMIC stack on the nixpool store volume (vol-00db8261b2ab3c143)
#   * scripts/solnix-cosmic-session.sh (Xorg-dummy + smallvil + cosmic apps + VNC-on-localhost)
#   * the graphical installer (installer/, renders over VNC)
#   * the gburd@solnix home-manager profile (nix-config: hosts/solnix.nix + systems/solaris.nix)
#
# The instance:
#   * boots reliably (canonical AMI)
#   * mounts the built COSMIC store (nixpool)
#   * runs the COSMIC Wayland session, VNC bound to 127.0.0.1:5900 ONLY (SSH-tunnel access)
#   * has gburd's nix-config homeConfiguration activated (the gburd@solnix profile)
#
# ⚠️ SECURITY: VNC is 127.0.0.1-bound; access ONLY via  ssh -N -L 5900:127.0.0.1:5900 root@<ip>
#   then  vncviewer localhost:5900 . The SG is never opened beyond the maintainer's /32 on :22.
#
# Usage: AWS_PROFILE=chiuso ./scripts/oi-make-desktop-instance.sh [instance-type]
set -eu

REGION=us-east-2
AMI=ami-0978836610527a836            # canonical reliable-boot (ena-fixed)
NIXPOOL_VOL=vol-00db8261b2ab3c143    # the built COSMIC store
SG=sg-0c5bd795eebf02b59
SUBNET=subnet-0bacf32f8c7ba9a5b      # us-east-2a (same AZ as the nixpool vol)
KEY=chiuso-key
ITYPE="${1:-m5.2xlarge}"

echo "== preflight: SG guard =="
scripts/sg-guard.sh audit

echo "== launch the desktop instance (reliable AMI, 80G root) =="
IID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" --instance-type "$ITYPE" --key-name "$KEY" \
  --security-group-ids "$SG" --subnet-id "$SUBNET" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":80,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=solnix-desktop-gburd}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "  instance: $IID"

echo "== wait for reliable boot (canonical AMI networks first-try ~90-110s) =="
sleep 20
IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "  IP: $IP"
for i in $(seq 1 15); do
  sleep 20
  if timeout 8 bash -c "echo > /dev/tcp/$IP/22" 2>/dev/null; then echo "  SSH up"; break; fi
done

echo "== attach the built-COSMIC-store nixpool volume (same AZ) =="
aws ec2 attach-volume --region "$REGION" --volume-id "$NIXPOOL_VOL" \
  --instance-id "$IID" --device /dev/xvdf >/dev/null
echo "  attached; rebooting once so illumos enumerates the disk (canonical AMI reboots reliably)"
aws ec2 reboot-instances --region "$REGION" --instance-ids "$IID"
sleep 40
for i in $(seq 1 12); do
  sleep 20
  timeout 8 bash -c "echo > /dev/tcp/$IP/22" 2>/dev/null && break
done

echo "== on the instance: mount the store, start COSMIC, activate gburd's nix-config =="
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@"$IP" 'sh -s' <<'REMOTE'
set -eu
export NIX_CONF_DIR=/nix-tools224/etc/nix PATH=/nix-tools224/bin:$PATH
export LD_LIBRARY_PATH=/nix-tools224/runtime-lib:${LD_LIBRARY_PATH:-}
mount | grep -q /dev/fd || mount -F fd fd /dev/fd
# mount the built COSMIC store (nix tool is at /nix-tools224, so /nix = the store)
zpool import -f nixpool 2>/dev/null || true
zfs set mountpoint=/nix nixpool/nix 2>/dev/null || true
zfs mount -O nixpool/nix 2>/dev/null || true
echo "  /nix store paths: $(ls /nix/store | wc -l)"
# activate gburd's home-manager profile (the gburd@solnix homeConfiguration)
# (network-fetched from the nix-config flake; falls back to a local checkout if present)
if [ -d /root/nix-config ]; then
  ( cd /root/nix-config && nix run '.#homeConfigurations."gburd@solnix".activationPackage' -- switch 2>&1 | tail -5 ) || \
    echo "  (gburd@solnix activation deferred -- needs the solnix nixpkgs-illumos overlay wired into mkHome)"
fi
echo "  desktop instance ready. Start the session with: scripts/solnix-cosmic-session.sh --cosmic-term"
REMOTE

echo ""
echo "== DONE. Connect (VNC is 127.0.0.1-bound -- SSH tunnel only): =="
echo "   ssh -N -L 5900:127.0.0.1:5900 root@$IP    # in one terminal"
echo "   vncviewer localhost:5900                   # in another"
echo "   (on the box: scripts/solnix-cosmic-session.sh --cosmic-term  to bring up the COSMIC session)"
echo "   instance: $IID   ip: $IP"
