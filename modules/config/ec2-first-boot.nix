{ config, lib, pkgs, ... }:
# modules/config/ec2-first-boot.nix -- cloud-init-lite for public cloud images.
#
# base.nix is identity-free (PermitRootLogin prohibit-password, NO baked user or
# key -- docs/.../base.nix "IDENTITY-FREE DEFAULT"). A PUBLIC AMI built from it
# boots and networks but accepts no key, because nothing installs the keypair
# the launcher chose at RunInstances. Every cloud launcher expects "my chosen
# EC2 keypair just works" (cloud-init semantics). This module closes that gap.
#
# It is the illumos analog of NixOS's amazon-init / cloud-init ssh-key seeding
# (nixos/modules/virtualisation/amazon-init.nix fetches the key from EC2 IMDS and
# writes authorized_keys). A first-boot SMF transient oneshot does an IMDSv2
# token PUT then GETs meta-data/public-keys/0/openssh-key and installs it into
# root's (and the operator user's) ~/.ssh/authorized_keys.
#
# FAIL-SAFE: no instance metadata (bare metal, the X1, a non-EC2 VM) -> no-op.
# So the SAME image is unharmed off-EC2 -- the installer media and the X1 still
# boot and behave exactly as before. Default-ON for that reason: on anything
# that is not EC2 it costs one short failed curl at first boot and does nothing.
#
# Idempotent: a run-once stamp keyed to the metadata instance-id. A re-launch of
# the same AMI under a NEW keypair gets a new instance-id and re-fetches, which
# is exactly what a public AMI needs.
let
  cfg = config.solnix.cloud.ec2;

  firstBootScript = pkgs.writeTextFile {
    name = "solnix-ec2-first-boot.sh";
    executable = true;
    text = builtins.readFile ../../scripts/solnix-ec2-first-boot.sh;
  };

  # illumos ships NO curl/wget in the base world (measured: the public image has
  # ftp/nc but no HTTP client), so the script must be handed one by store path or
  # its IMDS calls silently no-op and the launch key is never installed. Pass the
  # from-source curl's absolute path via SOLNIX_CURL.
  curlBin = "${pkgs.solnix.curl}/bin/curl";
in
{
  options.solnix.cloud.ec2.firstBootAuthKeys = lib.mkOption {
    type = lib.types.bool;
    # Default ON: fail-safe no-op off-EC2 (see header), and it is the thing that
    # makes a public AMI loginnable. A private/bare-metal build can set it false.
    default = true;
    description = ''
      On first boot of an EC2 instance, fetch the launcher's public SSH key from
      instance metadata (IMDSv2) and install it into root's (and the operator
      user's) authorized_keys -- the cloud-init key-seeding NixOS's amazon-image
      does. No-op when no instance metadata is reachable (bare metal / non-EC2),
      so the same image is safe on the installer media and the X1.
    '';
  };

  config = lib.mkIf cfg.firstBootAuthKeys {
    smf.services.solnix-ec2-first-boot = {
      enable = true;
      category = "site";
      description = "solnix EC2 first-boot authorized_keys from instance metadata (cloud-init-lite)";
      # run-once per boot: fetch the launch key, install it, exit.
      model = "transient";
      start = {
        exec = "/bin/sh -c 'SOLNIX_CURL=${curlBin} ${firstBootScript}'";
        timeoutSeconds = 120;
      };
      stop.exec = ":true";
      # The network must be up (DHCP done) before 169.254.169.254 answers; the
      # solnix networking bringup (solnix-net) runs the DHCP, so order after the
      # network milestone + physical, exactly as the MTU service does.
      requires = [
        "svc:/milestone/network:default"
        "svc:/network/physical:default"
      ];
    };
  };
}
