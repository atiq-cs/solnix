{ ... }:
# configurations/gburd.nix — the maintainer's PERSONAL test overlay.
#
# NOT part of the public solnix default. base.nix is identity-free; this overlay
# adds a personal admin user (gburd) with an SSH key + hashed password for the
# maintainer's own EC2/QEMU test hosts. It MUST NEVER be included in any public
# AMI/ISO/IMG — the image builders build the default (base.nix) config; this
# overlay is composed in ONLY for personal test builds (e.g.
#   solnixConfigurations.gburd = base + this).
#
# Rationale: a downloadable solnix image should ship no specific person's
# identity/credentials (matching NixOS's installer). The operator's user is
# created at install / first boot.
{
  # root's authorized key (so root ssh works on the personal test host).
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM2PZQ+eKLAdQWYSFT6oqZd5/HW3dmahfzE9hVO5qdN9 Greg Burd <greg@burd.me>"
  ];

  # gburd: personal admin login. RBAC Primary Administrator (pfexec -> root).
  users.users.gburd = {
    uid = 1000;
    group = "staff";
    description = "Greg Burd";
    shell = "/usr/bin/ksh93";
    extraGroups = [ "adm" "sys" ];
    # No password here: key login only. Set one by hand on the test host if needed.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM2PZQ+eKLAdQWYSFT6oqZd5/HW3dmahfzE9hVO5qdN9 Greg Burd <greg@burd.me>"
    ];
  };
}
