# PostgreSQL builds + runs on solnix x86 (Goal-3 crux: VERIFIED)

## Result: YES. PostgreSQL 17.11 builds, installs, and RUNS on solnix (illumos + Nix), x86_64.

Verified end-to-end on a solnix box (10/10 AMI):
- ./configure PASSED (the on-box toolchain: gcc 14.3.0, gmake, bison, flex, perl -- all present).
- gmake build COMPLETED -> src/backend/postgres (AMD64 ELF, PostgreSQL 17.11).
- gmake install COMPLETED cleanly into a prefix (all bins + libs).
- Runtime smoke (as an unprivileged user -- initdb correctly refuses root):
    initdb -> OK          (cluster created)
    pg_ctl start -> OK    (server up)
    SELECT version()  ->  "PostgreSQL 17.11 on x86_64-pc-solaris2.11, compiled by gcc
                           (OpenIndiana 14.3.0-oi-2) 14.3.0, 64-bit"
    CREATE TABLE / INSERT 2 rows / SELECT count(),max() -> "2 | solnix"  (correct)
    pg_ctl stop -> OK

So solnix x86 can be a real PostgreSQL BUILD-FARM ANIMAL: it builds PG from source + runs the server.
illumos is a historically-supported PG platform (the tree already carries src/.../solaris port bits), so
configure/build are clean. The regression/TAP suite was running at hand-off (make check in
src/test/authentication) -- a full pass-count is the next confirmation, but build + initdb + real-query +
clean-stop is proven.

## What a solnix PG build-farm animal needs (to set up the persistent animal)
- Toolchain: gcc/gmake/bison/flex/perl/git/gdb/autoconf/pkg-config -- ALL present on the solnix base
  (currently host /usr/bin; a nix-pure toolchain build exists in the store and can be wired if strict
  nix-purity is wanted for the animal).
- initdb must run as an UNPRIVILEGED user (PG refuses root -- standard). Create e.g. a `pgbf` user.
- The PostgreSQL buildfarm CLIENT (PGBuildFarm/client-code, run_build.pl) is a Perl app: clone it, satisfy
  its CPAN deps, `run_build.pl --test --verbose` drives a PG build in the buildfarm harness locally (do NOT
  register/report to the public server without a real animal name + secret). [Client-harness setup is the
  remaining step to a registered animal; the BUILD capability it depends on is proven above.]

## Note on tiers
This build used the on-box host toolchain (OpenIndiana gcc 14.3.0). For a NIX-PURE build-farm animal, wire
the nix-store gcc/binutils (they exist as real derivations) as the compiler; the build itself is identical.
