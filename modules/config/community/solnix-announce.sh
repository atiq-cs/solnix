#!/bin/sh
# solnix-announce -- nix's post-build-hook (seed.nix): queue each path this host just built for solnix-seed. Nix runs
# it as root after every build with $OUT_PATHS; it must be fast and must not fail the build, so it only records the
# names. solnix-seed decides later whether each one may be seeded (served by cache.solnix.io under 8UNr).
d=${SEED_STATE:-/var/lib/solnix/seed}/built
mkdir -p "$d" 2>/dev/null || exit 0
for p in $OUT_PATHS; do
	case $p in /nix/store/*) : > "$d/${p#/nix/store/}" ;; esac
done
exit 0
