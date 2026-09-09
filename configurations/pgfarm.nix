# configurations/pgfarm.nix — the solnix PostgreSQL build-farm animal + dev host.
#
# This is what an installer writes for a machine whose job is: multi-user solnix,
# PostgreSQL development, and acting as a PostgreSQL community build-farm animal.
# It is base.nix (the minimal bootable system) PLUS the pgfarm role module.
#
# It replaces the hand-provisioning in scripts/bene-provision-dixi.sh steps 4+5
# (build user, buildfarm client, build-farm.conf, the GNU-diff PATH fix, the
# run_build.pl service). Steps 1/2/3/6 of that script — the ZFS build pool, the
# IPS `pkg update`, the IPS toolchain (INCLUDING the load-bearing
# text/gnu-diffutils), and the Nix bootstrap — are still imperative and are
# documented as such in modules/config/pgfarm.nix and
# docs/build-farm-animal-provisioning.md. A known gap beats a false claim.
#
# Select it as:
#   nix build .#pgfarmToplevel                      (flake, evaluates anywhere)
#   nix-build lib/eval-host.nix -A toplevel \
#     --arg configModule ../configurations/pgfarm.nix   (on the illumos host)

{ config, lib, pkgs, ... }:

{
  imports = [ ./base.nix ];

  networking.hostName = lib.mkDefault "solnix-pgfarm";

  # The role. Everything else about the animal follows from this module's
  # defaults (see modules/config/pgfarm.nix for the full option surface).
  solnix.pgfarm.enable = true;

  # A 16-vCPU animal: parallel make, but leave headroom for the test cluster.
  # The buildfarm reports make_jobs, so this is part of the animal's identity.
  solnix.pgfarm.jobs = 8;

  # NOT scheduled by default. A fresh install must not start hammering
  # PostgreSQL HEAD before the operator has registered the animal with
  # buildfarm.postgresql.org and sized the build pool. The SMF manifest is still
  # generated + DTD-validated at build time, so turning it on is a config flip:
  #   solnix.pgfarm.scheduled = true;
  solnix.pgfarm.scheduled = false;

  # animal/secret come from buildfarm.postgresql.org — a HUMAN registration step.
  # While they are unset the run wrapper forces --test, so an unregistered animal
  # builds and tests locally and reports nothing upstream. Do NOT put a real
  # secret here: the store is world-readable (see gap 5 in the role module).
  #   solnix.pgfarm.animal = "myanimal";
  #   solnix.pgfarm.secret = "...";

  # PG development host, not only an animal: the dev tools an operator expects on
  # a machine they SSH into to work on PostgreSQL. Kept to the published
  # real-derivation starter set (base.nix explains why that set and not more) —
  # the PG build toolchain itself (gcc-14, gmake, bison, flex, ccache,
  # IPS perl + IPC::Run, gnu-diffutils) is IPS-installed, not from here.
  environment.systemPackages = with pkgs.solnix.starter; [ git diffutils ];

  # Time matters for a build farm: the buildfarm server rejects reports with
  # badly-skewed timestamps, and PG's own tests are timestamp-sensitive.
  solnix.defaults.timeZone = "UTC";
}
