# configurations/kvm-test-gen2.nix -- TEST-ONLY second generation of kvm-test:
# the same machine plus one more from-source package (sqlite's CLI), to prove a
# switch produces a new generation/BE and gen 1 stays bootable from the menu.
{ pkgs, ... }:
{
  imports = [ ./kvm-test.nix ];
  environment.systemPackages = [ pkgs.solnix.nixChain.sqlite ];
}
