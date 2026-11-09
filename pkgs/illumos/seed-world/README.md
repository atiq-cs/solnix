# seed-world: the seed instance's world builder, frozen (wave7)

The seed instance (`buildTools = [ ]`, lib/host-pkgs.nix `seedPkgs`) is solnix's x86 bootstrap: its rows (`*-seed`,
`illumos-userland-seed`, `seed-tar-alias`, `solnix-seed-build-tools`, `gcc-wrapper-seed`) build only on an OpenIndiana host
(stage0 `/usr/gcc/14`, `/usr/bin/gstrip`, `/usr/gnu`), are served, and are substituted everywhere else. As in nixpkgs'
bootstrap-tools and the aarch64 seed (`../aarch64/seed-main`), a change to the stdenv must not rebuild them.

The world builder is shared: the seed GNU tools link the seed world, so editing `../mk-proto-world.nix`,
`../world-fixups.sh` or `../world-links.sh` moved 13 seed rows (wave7, measured), and those can only be rebuilt on an OI host.
These three files are verbatim copies of wave6 c02fe74's, and `../default.nix` imports them for the seed instance only. The
seed world drv is then the served one (illumos-userland-seed aa8rsvzp), and so is every seed row.

Do not edit these files. When the bootstrap-tools wave replaces the seed, delete this directory.

Check: every seed row's drvPath equals wave6 c02fe74's (`/scratch/solnix/wave7/ev.sh`, then cmpmv.sh against the base).
