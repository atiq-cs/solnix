# A minimal solnix system flake: the base system, a hostname, one admin user,
# and one extra package. Install it from the solnix installer media with
#
#   solnix-install --flake 'path:/path/to/this/dir#example' c1t0d0
#
# or from a git host: --flake 'github:<you>/<repo>#example'.
{
  inputs.solnix.url = "git+https://git.solnix.io/solnix.git?ref=main";

  outputs = { solnix, ... }: {
    solnixConfigurations.example = solnix.lib.solnixSystem {
      system = "x86_64-solaris";
      pkgs = solnix.lib.mkPkgs { };
      modules = [
        "${solnix}/configurations/base.nix"
        ({ pkgs, ... }: {
          networking.hostName = "example";
          # QEMU's e1000 and the X1's onboard Intel NIC are both e1000g0;
          # `dladm show-phys` on the media lists the names this machine has.
          networking.interfaces = { ena0.dhcp = false; e1000g0.dhcp = true; };
          networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
          users.users.alice = {
            uid = 1000;
            group = "staff";
            home = "/home/alice";
            extraGroups = [ "sysadmin" ];
            profiles = [ "Primary Administrator" ];
          };
          environment.systemPackages = [ pkgs.solnix.git ];
        })
      ];
    };
  };
}
