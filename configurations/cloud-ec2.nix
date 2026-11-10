# configurations/cloud-ec2.nix — the public-cloud (EC2 AMI) solnix system.
#
# base.nix + the public-AMI deltas: the IMDS first-boot keypair fetch stays ON
# (so a launcher's EC2 keypair logs in), and the evidence-based MTU raise is OFF.
#
# WHY MTU OFF: solnix-mtu reboots to apply a jumbo-MTU ena.conf change
# (scripts/solnix-mtu.sh), and on a fresh public AMI whose /var/lib/solnix stamp
# does not persist across that reboot it reboot-LOOPS (measured on m5.large: 12
# cycles, "reboot: initiated by root" every ~30s). The MTU raise is an opt-in
# optimization, not needed for a working cloud image, so a public AMI ships with
# the boot-safe 1500 MTU and no self-reboot. (This is the only delta vs base.)

{ lib, ... }:

{
  imports = [ ./base.nix ];

  # IMDS first-boot keypair fetch: ON (the whole point of a loginnable public AMI).
  solnix.cloud.ec2.firstBootAuthKeys = true;

  # The published-AMI edition label. Without this, solnix.release defaults to
  # "unstable" and /etc/solnix-release reports RELEASE=unstable even though the
  # AMI is named "Solnix 2026.11 (DP)" -- the mismatch that shipped on the first
  # (stale) build. Pin the DP edition so a clean-HEAD build is self-consistent.
  solnix.release = "26.11";

  # Grow the root pool onto whatever EBS size the launcher picked (NixOS amazon-image.nix sets the same).
  services.zfs.expandOnBoot = "all";

  # MTU self-raise + reboot: OFF for cloud images (reboot-loop hazard above).
  solnix.mtu.enable = false;

  # DHCP on whatever wired NIC the instance has, as NixOS's useDHCP default does: ena0 on EC2, e1000g0 or vioif0 on
  # KVM/OpenStack/Proxmox. base.nix's named ena0 alone left a KVM guest with no address (solnix-net waited 300 s for
  # ena0, ipfilter's start timed out behind it). solnix-net, not solnix-netd: its bringup keeps the ena ifconfig
  # fallback (gotcha #15).
  networking.interfaces = lib.mkForce { };
  networking.useDHCP = true;
  networking.solnix-netd.enable = false;
}
