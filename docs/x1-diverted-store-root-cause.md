# X1 install: "building using a diverted store is not supported" at [5/9]

## Symptom
`solnix-install --flake github:gburd/nix-config#dixi` fails at step 5/9 (build the toplevel):

    error: building using a diverted store is not supported on this platform
    ... while realising the context of path
        '/nix/store/s6qn4fk8c3a2l7dj183knczpk91pi5l1-nixpkgs-solnix-patched/lib'
    ... while calling 'import' at flake.nix:18:  lib = import "${nixpkgs}/lib";

## Root cause (measured, after one refuted hypothesis)
solnix `flake.nix` sets `nixpkgs = solnix-pkgs.lib.nixpkgsSrc` and `lib = import "${nixpkgs}/lib"`.
`nixpkgsSrc = patchedNixpkgs` is an `applyPatches` DERIVATION (solnix-pkgs flake.nix:22), built for
`x86_64-linux`. Importing `"${nixpkgs}/lib"` forces REALISING that derivation at eval time (it reads the
actual /lib tree, so the output must exist on disk).

illumos single-user nix REFUSES to BUILD a derivation in a diverted store (any `--store`/`--eval-store`
pointing away from the daemon's /nix). And `patchedNixpkgs` is a Linux derivation the X1 could never build
anyway. So on the X1 the build tries to realise-by-build -> refused.

### Refuted hypothesis (recorded so it is not retried)
First fix removed `--eval-store $ALTROOT`, on the theory that a plain `--store` chroot store is not
"diverted." REFUTED on hardware: the re-run (confirmed fixed script -- the re-run hint showed no
--eval-store) failed IDENTICALLY. `--store /a` is ALSO diverted for BUILD purposes. Removing --eval-store
is harmless but was not the fix.

Why the step-2 name gate (`--store $SCRATCH_STORE`) succeeded while step 5 failed: evaluating the attr
name / drvPath does not force realising patchedNixpkgs (the .drv is computable from narinfo); the toplevel
build forces the realise.

## The fix
`patchedNixpkgs` was NEVER PUBLISHED to the cache (cache.solnix.io + s3.solnix.io both 404'd its narinfo),
so realising it could only be a build -> refused. Realising is satisfied by BUILD *or* SUBSTITUTE; only
BUILD is blocked in a diverted store. So: build `nixpkgs-solnix-patched` on a Linux box (the dev box IS
x86_64-linux), sign it (cache.solnix.io-1 / 5HAV), and `nix copy` it + closure to the cache. Then the X1
SUBSTITUTES the prebuilt path (narinfo+nar on s3.solnix.io, in the X1's substituters + trusted-keys) instead
of building it -- substitution into a diverted store is allowed (the base-closure copy already does exactly
that on this hardware).

Published 2026-09-22: hash s6qn4fk8c3a2l7dj183knczpk91pi5l1, narinfo+nar 200 on s3.solnix.io, signed by 5HAV.

## Durable follow-up
The solnix-pkgs cache-publish step must include `lib.nixpkgsSrc` (nixpkgs-solnix-patched) in what it signs +
uploads, so a fresh clone / any illumos install can substitute it. It is a build-time source dependency of
EVERY solnix system eval; it must always be in the cache. (Also: the B2/cache.solnix.io copy lagged -- verify
it lands there too, not only s3.solnix.io transit.)
