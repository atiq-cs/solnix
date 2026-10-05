# configurations/kvm-test.nix -- TEST-ONLY machine config for booting the base
# under local KVM (the hardware-configuration.nix analog). Never part of a
# public image: it carries a test key and a test password.
{ lib, ... }:
{
  imports = [ ./base.nix ];
  networking.interfaces.ena0.dhcp = false;
  networking.interfaces.vioif0.dhcp = true;
  networking.nameservers = lib.mkForce [ "10.0.2.3" ];
  users.users.root.openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDPOwiESY1mZStZqP3XUf7Al2BQQrN6eGe38uY70CN1gauoW3a0tnwfatiU71CCXenYo7FvPGpY+FwIjbU8KU4+prcPnGdL/OFnQi9AR8/2FXOUEpjMofaBATPHmyvGj6Gh1YO5ucP3VQfab6WRtgwle0l7eqVgWn+UwLJza6NJZMmVYz5fpKZejiUjuANSFbVOWC5MpNgf9jNsrejec4DQnp16oWUeiVWxWiWox4AwyfA7GftYhOvKHcxQBXGXytG8YysdT6MLYuKYLWcKbg/O/ZpjYRzazuoy3TPApIrTleoKCmFKwZbx9PH6GZaNreAzaQ7yKGUBpzf3l4LBOVox" ];
  # PAM test account: password 'kvm-test-pw-1' (sha256-crypt).
  users.users.tester = {
    uid = 1001; group = "staff"; home = "/var/tmp"; shell = "/usr/bin/bash";
    hashedPassword = "$5$solnixkvm$aWewKibVgzonY3lGBGvf4ONMQzTh6F/WHqAYVxly/e3";
  };
}
