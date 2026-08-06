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
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKCqHOIyYwbp42C7MxnRFxOcy+ZE8cNOWdsdvCgVFm1L Greg Burd <greg@burd.me>"
  ];

  # gburd: personal admin login. RBAC Primary Administrator (pfexec -> root).
  # Password is SHA-512 crypt, delivered out-of-band; key login also enabled.
  users.users.gburd = {
    uid = 1000;
    group = "staff";
    description = "Greg Burd";
    shell = "/usr/bin/ksh93";
    extraGroups = [ "adm" "sys" ];
    hashedPassword = "$6$ArPWLrn2ySFy0yku$UT8DvBWBxdrSJ0LLGgznIBjfBwa.hBG6td1UjoOiue.FaNsp3sHs6yLwjDSWN7Aa6TT/aQJgMTEzGUtw//yJ40";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKCqHOIyYwbp42C7MxnRFxOcy+ZE8cNOWdsdvCgVFm1L Greg Burd <greg@burd.me>"
    ];
  };
}
