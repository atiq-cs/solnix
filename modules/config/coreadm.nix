{ config, lib, ... }:
# modules/config/coreadm.nix — core-file policy for solnix systems.
#
# Directive (maintainer, 2026-08-04): ISOs, AMIs, install images, and first-run
# systems must NOT contain core files, and must not litter CWD/home with `core`
# on a crash. illumos `coreadm` governs this; the persistent config is
# /etc/coreadm.conf, read by svc:/system/coreadm:default at boot.
#
# Policy: route ALL cores to a managed /var/cores/ dir with descriptive names,
# enable global dumps + logging, DISABLE the per-process CWD `core` litter.
# (Debugging is preserved — cores land in /var/cores, discoverable + not in the
# way — while images/first-boot stay clean.)
{
  options.solnix.coreadm.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Manage the illumos core-file policy (route to /var/cores, no CWD litter).";
  };

  config = lib.mkIf config.solnix.coreadm.enable {
    # Persisted coreadm policy (svc:/system/coreadm reads /etc/coreadm.conf at boot).
    environment.generatedEtc."coreadm.conf" = ''
      COREADM_GLOB_PATTERN=/var/cores/core.%f.%p.%t
      COREADM_GLOB_CONTENT=default
      COREADM_INIT_PATTERN=/var/cores/core.%f.%p.%t
      COREADM_INIT_CONTENT=default
      COREADM_GLOB_ENABLED=yes
      COREADM_PROC_ENABLED=no
      COREADM_GLOB_SETID_ENABLED=no
      COREADM_PROC_SETID_ENABLED=no
      COREADM_GLOB_LOG_ENABLED=yes
    '';
    # NOTE: /var/cores is created by the image builder's core-scrub step (scripts)
    # and re-created at first boot if absent; coreadm tolerates a missing dir (the
    # first crash creates the path components under an existing parent). We keep
    # the dir-creation in the builder rather than an activation hook because solnix
    # has no free-form system.activation.<name> option (activation is fixed).
  };
}
