# PostgreSQL Buildfarm CLIENT on solnix x86 (Goal 3) -- VERIFIED

## Result: YES. run_build.pl --test drove a FULL PG build cycle on solnix, ALL STAGES SUCCEEDED.

Node: i-01a24525d684882e5 (m5.2xlarge, us-east-2, 18.191.233.227), solnix (illumos + Nix) x86_64,
on-box OpenIndiana toolchain (gcc 14.3.0 / gmake 4.4.1 / bison 3.8.2 / flex 2.6.4 / perl 5.42 / git 2.55).

The PGBuildFarm client (PGBuildFarm/client-code, run_build.pl) built **PostgreSQL 20devel** (git HEAD
`1051099a9045fe4d6c81eeea33dcd24cd2ba7fd4`) end-to-end in the buildfarm harness, `--test` mode (no upstream
reporting). Wall time ~65 min (single-core make: `make_jobs => undef`). Final marker: `All stages succeeded`.

## Perl / CPAN deps run_build.pl needed (+ what was MISSING on solnix)

The client's own `use`/`require` surface (run_build.pl + PGBuild/*.pm) is almost all satisfied by the
base perl 5.42 install:

- ALL PRESENT out of the box (core or already installed): Carp, Config, Cwd, Data::Dumper, Digest::SHA,
  Fcntl, File::{Path,Copy,Basename,Temp,Spec,Find}, FindBin, Getopt::Long, IO::Handle, JSON::PP,
  MIME::Base64, POSIX, Scalar::Util, Storable, Time::HiRes, Test::More, **LWP / LWP::UserAgent /
  HTTP::Request::Common** (libwww-perl -- already on the box).
- MISSING but NOT needed for `--test`: **DBD::Pg**. The client ships `PGBuild/dummylib/DBD` /
  `dummylib/DBI.pm` as a stub precisely so DBD::Pg is only required when actually reporting to a DB.
  `--test` (= `--nosend --nostatus --verbose --force`) never touches it. Leave DBD::Pg out for local runs.

So: the buildfarm CLIENT itself needs no CPAN installs on solnix. The real deps that had to be installed
were for the PG BUILD it drives (below), not for run_build.pl.

## Deps installed to make the harness complete a PG build (the real animal-readiness findings)

Three stage failures, each a missing tool/dep -- NONE illumos-specific. Fixed in order:

1. **`ccache: not found`** (configure exit 77). The buildfarm defaults `config_env.CC => 'ccache gcc'` +
   `use_accache => 1` + `use_default_ccache_dir => 1`. ccache wasn't on the box.
   Fix: `pkg install developer/ccache`  ->  ccache 4.13.6. (A real animal wants ccache; kept it enabled.)

2. **ICU not found** (`icu-uc >= 55 icu-i18n`, configure exit 1). Modern PG defaults `--with-icu` ON and
   errors without it. The IPS `developer/icu` is ancient (v4.6 / 2014, < the required 55), so installing it
   would NOT satisfy PG. Matched the verified PG-17 build: added **`--without-icu`** to config_opts.
   (For an ICU-enabled animal later: wire a modern ICU from nixpkgs and drop `--without-icu`.)

3. **`IPC::Run` missing** (configure exit 1, "Additional Perl modules are required to run TAP tests").
   Required by `--enable-tap-tests`. This is a PG-side dep, not a client dep.
   Fix: `pkg install library/perl-5/ipc-run`.

Base perl already had `prove`, Test::More, Time::HiRes -- the other TAP prereqs.

## Stages that PASSED (run_build.pl --test HEAD, all on solnix illumos x86_64)

configure -> build (make) -> basic regression (make check) -> make testmodules -> install ->
make contrib install -> testmodules install -> make check misc modules ->
ALL bin TAP tests (initdb, pg_amcheck, pg_archivecleanup, pg_basebackup, pg_checksums, pg_combinebackup,
pg_config, pg_controldata, pg_ctl, pg_dump, pg_resetwal, pg_rewind, pg_test_fsync, pg_test_timing,
pg_upgrade, pg_verifybackup, pg_waldump, pg_walsummary, pgbench, psql, scripts) ->
misc-recovery / misc-subscription / misc-authentication TAP ->
~30 module TAP tests (brin, commit_ts, test_aio, worker_spi, xid_wraparound, libpq, ...) ->
~18 contrib TAP tests (amcheck, auto_explain, bloom, dblink, pg_stat_statements, postgres_fdw,
test_decoding, ...) ->
installcheck (C) -> isolation check -> contrib installcheck (C) -> test-modules installcheck (C) ->
ecpg check -> **OK / All stages succeeded**.

No illumos-specific stage failure. configure correctly detected CRC-32C (SSE 4.2 + AVX-512 runtime),
unnamed POSIX semaphores, /dev/urandom -- illumos is a first-class PG platform (the tree carries
src/.../solaris port bits).

## build-farm.conf used (only the knobs changed from build-farm.conf.sample)

    animal            => "CHANGEME"      # unchanged -- only used to REPORT upstream; --test never reports
    secret            => "CHANGEME"      # unchanged -- ditto
    make              => 'gmake'         # was 'make'
    build_root        => '/tmp/pgbf-root/buildroot'   # was undef
    use_accache       => 1               # (default) needs ccache installed
    config_env.CC     => 'ccache gcc'    # (default) needs ccache installed
    config_opts       => [ --enable-cassert --enable-debug --enable-tap-tests --without-icu ]
                         # trimmed from the sample's full set (dropped --with-{perl,python,tcl,gssapi,
                         # openssl,ldap,libxml,libxslt} + --enable-nls -- none verified on this box);
                         # --without-icu added because IPS ICU is too old.

Branch built via CLI: `HEAD` (default). `perl -c build-farm.conf` = syntax OK.

## Persistent solnix PG build-farm ANIMAL recipe

1. Unprivileged user (PG initdb/run_build refuse root):
       useradd -m -d /export/home/pgbf -s /bin/bash pgbf
   (this run used pgbf; build_root on /tmp tmpfs -- see disk note.)

2. Toolchain (already on solnix base /usr/bin): gcc 14.3.0, gmake, bison, flex, perl 5.42, git.
   Plus install:  `pkg install developer/ccache library/perl-5/ipc-run`

3. Perl: client needs no CPAN installs (LWP etc. present; DBD::Pg only for real reporting via a DB,
   not for --test; dummylib covers local runs).

4. Get the client + config:
       git clone --depth 1 https://github.com/PGBuildFarm/client-code.git
       cp build-farm.conf.sample build-farm.conf
       # edit: make=>gmake, build_root=>..., config_opts as above (--without-icu unless modern ICU wired)

5. Run locally (NO reporting):
       perl run_build.pl --test --verbose --config=build-farm.conf HEAD
   `--test` == `--nosend --nostatus --verbose --force`.

6. To become a REAL registered animal later (HUMAN step, not done here):
   - Register at https://buildfarm.postgresql.org to get an animal NAME + SECRET.
   - Put them in build-farm.conf (`animal`, `secret`), install DBD::Pg if the server run needs it,
     drop `--test`/`--nosend` so run_build.pl reports to `target =>
     https://buildfarm.postgresql.org/cgi-bin/pgstatus.pl`.
   - Do NOT register/report until a human owns the animal. This run stayed strictly local.

## DISK NOTE (why build_root is on /tmp)

Root zpool `spool` is only ~7.5G (on fdisk partition capped at 16777215 sectors of an 80G EBS disk;
the VTOC/fdisk don't span the disk). Only ~770M free on /. So build_root points at `/tmp` -- a
28G swap-backed tmpfs on the 32G-RAM box. A full HEAD --test run peaked ~1.3G there and is VOLATILE
(lost on reboot). For a PERSISTENT animal: grow the fdisk partition + VTOC slice1 + `zpool online -e`
to reclaim the ~72G unused EBS, then put build_root on persistent ZFS.

## Artifacts on the box (node LEFT RUNNING)

- Client: /tmp/pgbf-root/client-code   (build-farm.conf lives here)
- Build root: /tmp/pgbf-root/buildroot  (HEAD tree, ccache-CHANGEME, pgmirror.git)
- Run logs: /tmp/pgbf-root/run4.log (the successful run), run.log/run2.log/run3.log (the 3 failures above)
- Stage logs: /tmp/pgbf-root/buildroot/HEAD/CHANGEME-test.lastrun-logs/
- Progress: /tmp/pgbf-client-progress.txt
