# solnix build-farm animal provisioning (durable-account recipe)

> **⚠️ STALE CLOUD IDENTIFIERS.** Every AWS instance/AMI/snapshot id below belongs to a
> CLOSED account (chiuso / mala / lala) and no longer resolves. The findings, root causes
> and recipes here remain valid — only the ids are dead. Current substrate ids live in the
> gitignored `.infra/`; the rebuild paths are `docs/base-ami-rebuild-runbook.md` (x86_64,
> from the public OI cloudimage) and `docs/aarch64-buildhost-runbook.md` (the aarch64 gate
> host). See `docs/durability-account-loss.md` for why this keeps happening and the rules
> that limit the damage.

## THE DECLARATIVE PATH (preferred; use this for new animals)

The animal is now a solnix **role module + configuration**, so an installed system gets it
from config instead of from a provisioning script:

| what | where |
|---|---|
| the role module | `modules/config/pgfarm.nix` (option surface `solnix.pgfarm.*`) |
| the configuration an installer selects | `configurations/pgfarm.nix` (= `base.nix` + the role) |
| flake outputs | `solnixConfigurations.pgfarm`, `packages.*.pgfarmToplevel`, and `pgfarmConf` / `pgfarmRun` / `pgfarmSetup` |

What the module makes declarative (this is `scripts/bene-provision-dixi.sh` steps 4+5):

* the unprivileged **`pgbf` build user** via `users.users` (PostgreSQL's `initdb` and
  `run_build.pl` both REFUSE to run as root),
* **`build-farm.conf` generated from options** as a store path — only the keys
  `run_build.pl` actually reads, instead of regex-patching the 500-line upstream sample,
* the **GNU-diffutils PATH fix** (see the warning below) in all three places that matter,
* **`run_build.pl` wired as an SMF service** through the existing `smf.services.*`
  generator, so its manifest is DTD-validated at build time,
* a scoped **`safe.directory` gitconfig** as a store path, instead of mutating
  `git config --global`.

Usage:

```sh
# evaluate/build the role's artifacts (works on the illumos target itself)
nix-build lib/eval-host.nix -A toplevel --arg configModule ../configurations/pgfarm.nix

# register the animal (a HUMAN step at buildfarm.postgresql.org), then set:
#   solnix.pgfarm.animal = "..."; solnix.pgfarm.secret = "...";  (secret via sops, not inline)
# and turn on the schedule:
#   solnix.pgfarm.scheduled = true;
```

Until `animal`/`secret` are set, the generated run driver forces `--test`, so an
unregistered animal builds and tests locally and reports nothing upstream.

### ⚠️ The load-bearing detail: illumos `diff` breaks `test_json_parser`

illumos `/usr/bin/diff` prints **"No differences encountered"** for identical files (rc=0).
PostgreSQL's `src/test/modules/test_json_parser` TAP test asserts diff prints **NOTHING**,
so with the illumos diff ahead on PATH it fails 4 subtests and the whole
`module-test_json_parserCheck` stage — while the build itself looks fine. The fix has two
halves:

1. `text/gnu-diffutils` installed (**imperative**, IPS — see the gaps below), and
2. **`/usr/gnu/bin` FIRST in PATH** (declarative: `solnix.pgfarm.gnuBinFirst`, default true).

The module applies (2) in **three** places from that one option, because each covers a
different execution path and missing any one reintroduces the bug:

* `build-farm.conf`'s `build_env.PATH` — every configure/make/test child process;
* the SMF `method_environment` — the scheduled animal run;
* `environment.shellInit` — an **operator's interactive** `run_build.pl`.

It also adds a loud runtime gate in the setup oneshot that fails immediately if the illumos
diff is winning, rather than letting one stage go red 30 minutes later.

> **Do not assume the base modules already cover this.**
> `modules/config/shell-environment.nix` does list `/usr/gnu/bin` in its `basePathTail`, but
> that only *appends* directories not already present, *after* the inherited PATH — so on a
> stock login `/usr/bin` lands AHEAD of `/usr/gnu/bin`. Measured by sourcing the generated
> profile under `env -i`: with `gnuBinFirst = true` `/usr/gnu/bin` is at position 1; with it
> false, `/usr/bin` is at 7 and `/usr/gnu/bin` at 11 (bug live). The role module's own
> `shellInit` is load-bearing, not redundant.
>
> Verified on the live host (2026-09-09): `/opt/pgbf/client-code/build-farm.conf` line 209 is the
> only functional occurrence — the sole other `grep` hit is its explanatory comment. And dixi's
> **login PATH does not contain `/usr/gnu/bin` at all** (`/usr/bin` at position 3), so outside that
> one conf there is no GNU-diff precedence whatsoever. dixi stays green because `run_build.pl` reads
> the conf; nothing else on the box is protected.
>
> Note also that `dixi` itself carries the fix in only ONE place (its `build_env.PATH`), so a
> hand-run `run_build.pl` on dixi would still hit this. The declarative path is stricter than
> the reference animal.

### VERIFIED (x86_64, c5.4xlarge from `ami-014c4aaccd37b2356`)

A real `run_build.pl` launched as the module-declared user, from the module-generated driver
and config, reached the literal acceptance string:

```
CHANGEME:HEAD          [14:51:14] running make ecpg check ...
CHANGEME:HEAD          [14:51:42] OK
Branch: HEAD
All stages succeeded
```

87 stages, zero failures, including `module-test_json_parser`. The whole configuration was
evaluated and built **natively on the illumos target** with the node's own Nix 2.24.15, and
the generated SMF manifests passed `xmllint --dtdvalid` against that node's real
`/usr/share/lib/xml/dtd/service_bundle.dtd.1`.

**Negative control** (a test that cannot fail proves nothing): rebuilding with
`--arg gnuBinFirst false` flips `build_env.PATH` to `/usr/bin:/usr/sbin`, removes the setup
script's diff gate, and drops `/usr/gnu/bin` from the interactive PATH — and the
`module-test_json_parserCheck` stage then FAILS, which is exactly the failure recorded on
dixi's first run (`Stage module-test_json_parserCheck failed with status 2`).

### KNOWN GAPS — still imperative (a known gap beats a false claim)

These are the remaining `scripts/bene-provision-dixi.sh` steps, and they are **not** yet
declarative. The full list with upgrade paths is in the footer of `modules/config/pgfarm.nix`.

1. **The IPS toolchain** (step 3). `pkg install developer/gcc-14 developer/build/gnu-make
   developer/parser/bison developer/lexer/flex developer/versioning/git developer/ccache
   library/perl-5/ipc-run-542 text/gnu-diffutils`. solnix has no declarative IPS mechanism
   (there is no `ips.packages` option). The module declares the PATH ordering that makes
   `gnu-diffutils` win; it cannot yet declare its installation. Note the animal needs the IPS
   perl 5.42 that `ipc-run-542` was built against, so substituting the published
   real-derivation perl/gcc rows is not a drop-in.
   *Upgrade path:* an `ips.packages` option rendering a first-boot `pkg install` oneshot.
2. **`pkg update` + the BE reboot** (step 2). The pristine base carries 2025 incorporations
   while the catalog offers 2026 packages, so every toolchain install is rejected until a full
   update — which creates a new BE needing the DHCP shim + `pit_is_broken` carried into its
   boot_archive. A precondition of step 3.
3. **The ZFS build pool** (step 1). `zpool create bfpool` + `/pgbf` + `/nix` datasets. No
   filesystems/zpool module exists yet; pool creation is destructive and needs a
   disk-selection policy. *Upgrade path:* a `solnix.storage.pools.*` module.
4. **The Nix bootstrap** (step 6) — chicken-and-egg: it is what evaluates the config.
5. **The buildfarm client checkout** is `git clone`d at runtime by the setup oneshot, not
   pinned as a store path (it is a moving upstream HEAD the animal is expected to track).
6. **No calendar schedule.** SMF has no periodic model, so the service is a fixed-interval
   sleep/run loop (`solnix.pgfarm.intervalSeconds`), not a cron expression.
7. **`animal`/`secret` in the store are world-readable.** Use a sops-managed secret for a
   registered animal.

A practical consequence: provisioning a new animal today is **imperative substrate, then
declarative role** — pool + `pkg update` + toolchain + Nix by hand (or with
`scripts/bene-provision-dixi.sh`), then build `configurations/pgfarm.nix` for everything else.

---

## Historical: the fully hand-provisioned recipe

When the durable (non-burner) account is designated, provision the long-term solnix build-farm animals with
this recipe. The technical capabilities are all PROVEN (Goals 2+3 done on x86; aarch64 QEMU-boot done).

## x86_64 PostgreSQL build-farm animal (READY -- proven)
Base: the 10/10 canonical AMI ami-08028a88f6e53ff49 (ena + PIT-hang fixed; boots first-try, verified 15/15).
Copy it to the durable account (aws ec2 register-image from a copied snapshot, or CreateStore/CopyImage).

1. Launch from the AMI (m5.4xlarge or larger). It boots reliably (10/10).
2. STORAGE (the one real gotcha -- docs/postgresql-buildfarm-client-on-solnix-verified.md): the AMI's root
   zpool is only ~7.5G (the fdisk/VTOC don't span the disk). Do NOT try to grow the mounted root slice
   (the project rule: never live-grow a mounted root slice). Instead ATTACH A SEPARATE LARGE VOLUME + make a
   whole-disk pool for the build root:
     aws ec2 attach-volume ... --device /dev/xvdf   (reboot -- illumos enumerates new disks at boot; the
       10/10 AMI reboots reliably)
     zpool create bfpool c<N>t<M>d0   (whole disk)
     zfs create -o mountpoint=/pgbf bfpool/pgbf
   Point the buildfarm build_root at /pgbf (persistent), NOT /tmp (tmpfs, volatile).
3. The PG buildfarm CLIENT (proven -- run_build.pl --test HEAD = All stages succeeded, PG 20devel):
   - unprivileged user `pgbf` (PG initdb/run_build refuse root).
   - pkg install developer/ccache library/perl-5/ipc-run (the only deps beyond the base toolchain +
     core-perl+LWP that the box already has; DBD::Pg only needed for upstream DB reporting).
   - git clone https://github.com/PGBuildFarm/client-code.git
   - build-farm.conf: make=>gmake, build_root=>/pgbf/buildroot,
     config_opts=>[--enable-cassert --enable-debug --enable-tap-tests --without-icu]  (IPS ICU is v4.6<55;
     add modern ICU later if wanted), ccache enabled.
   - REGISTER a real animal: get an animal name + secret from buildfarm.postgresql.org (a human step), put
     them in build-farm.conf, drop --test to report. Until then `run_build.pl --test HEAD` builds+tests
     locally (proven).
4. Nix-upgradable (Goal 2, proven): the by-name flake + registry are baked; `nix profile install
   nixpkgs#<pkg>` + `nix profile upgrade` work (the AMI-bake re-lock step is in oi-make-declarative-be.sh).

### x86 animal AMI bake (session findings — the baked AMI + the first-boot pool hook)
The animal capability was baked onto a running node and snapshotted. The **pre-install, the first-boot
build-pool hook, nix-by-name, and run_build driving a PG build are all PROVEN on the live node**; a baked AMI
(`ami-05b9358e0aacc7bc3`, name `solnix-pgbf-animal-20260827`) boots to a login prompt with the full stack,
but **a cold-launched instance of the derived AMI does not acquire a DHCP lease** (SSH unreachable) — an
unresolved `create-image`-capture regression, NOT the base/software/pool-hook/subnet (the 10/10 base
cold-launches fine and the build node reboots+DHCPs fine with the full stack). Ruled out: root-pool space,
wrong base, a stale `/etc/dhcp/ena0.dhc` lease cache, and the added SMF service. Strongest remaining
hypothesis: `svc:/system/illumos/metadata` is transient and the live snapshot captures it complete, so the
fresh boot skips the metadata shim's DHCP bring-up — consistent with ena-rx-coldboot-fix.md's central finding
that only the specific IN-PLACE boot_archive build method yields a cold-boot-reliable AMI. **Recommended
operator path: provision the animal directly on a cold-launched 10/10 base** (`ami-0f5ab5fac82d7cd1f`
solnix-ena-1010-v15, verified reliable) via the scripted pre-install above, rather than depending on a
re-baked AMI; if you do re-bake with `create-image --no-reboot`, cold-launch-verify SSH before trusting it.

- **The extra deps are exactly two IPS packages** beyond the base toolchain+core-perl:
  `pkg install developer/ccache library/perl-5/ipc-run-542` (ipc-run-542 matches perl 5.42 on the box;
  the unversioned `library/perl-5/ipc-run` may resolve to a wrong perl ABI).
- **First-boot build-pool hook (idempotent):** if a second whole disk is attached and `bfpool` doesn't
  exist, find the first disk that is NOT the root-pool disk and NOT already in a pool, then
  `zpool create -f bfpool <cNtMd0>; zfs create -o mountpoint=/pgbf bfpool/pgbf; chown pgbf /pgbf`. The disk
  is enumerated by `diskinfo`; the root disk comes from `zpool status spool`. illumos enumerates new disks
  at boot, so the operator attaches the volume at launch (or attaches later + reboots). Implemented as an
  append to the proven metadata shim (`/usr/lib/metadata`); PROVEN to create `bfpool/pgbf` at `/pgbf` on the
  first boot after a 100 GiB volume attach.
- **Keep ~630 MB+ free on the root pool.** A near-full root (94–98%) separately wedged a node's LOADER with
  an out-of-memory boot_archive (`No rootfs module provided, aborting`) — the boot_archive rewrite couldn't
  get its COW space on the full pool. Do NOT install large by-name closures (e.g. coreutils) onto the root
  before baking; the by-name capability needs only the flake+registry+inputs present, not a `nix profile
  install`.
- **Remove the cached DHCP lease before baking:** `rm -f /etc/dhcp/ena0.dhc` (it otherwise bakes the
  build-node's dead lease/IP). Also clear `/var/lib/solnix-dhcp-reboots`.
- Full report + operator runbook: /tmp/pgbf-ami-report.md (session), and the runbook is the scripted
  pre-install in this section.

## aarch64 build-farm animal (NATIVE = campaign in progress)
Native aarch64-on-Graviton is A6 (multi-week: GICv3/ACPI/Nitro-drivers). QEMU-boot is DONE (A4+A5). Until A6
lands, the aarch64 role is a CROSS-build target ON an x86 animal (aarch64-solaris store paths built). A
native aarch64 PG animal follows A6+A7.

### aarch64 PostgreSQL build-dependency set (A7 groundwork -- CROSS-built + verified)
The PG link/build deps cross-build x86 -> aarch64-solaris and are ready for the moment A6 lands a bootable
Graviton. Verified this session (EM_AARCH64 via elfdump, on the x86 cross-build node). See
docs/aa-pgdeps-report.md for the full run + store paths.

- **Cross-eval entry (the driver):** `pkgs/illumos/phase3/aarch64-overlays/entry-aa-fin-x.nix`. It reuses
  the proven native x86_64-solaris stdenv as buildPackages and swaps the cross target cc for the seed
  aarch64 cross cc-wrapper wrapped in `cxxNomapCc` (the shared-link mapfile fix, docs/aarch64-cxx-wall-fix.md).
  Invoke: `nix-build entry-aa-fin-x.nix -A <pkg>` (openssl needs `extraCrossOverlays = [ (import
  aa-openssl-target-overlay.nix) ]`). The older `entry-aa-fin.nix` LACKS cxxNomapCc -> shared links fail; use
  the -x entry.
- **PG link deps, cross-built + EM_AARCH64-verified:**
  - zlib 1.3.2 -- static `.a` and shared `libz.so.1.3.2` (ET_DYN), from source.
  - openssl 3.6.3 -- full: `openssl` bin (ET_EXEC, NEEDED libssl/libcrypto/libsocket/libnsl/libdl/libgcc_s/libc),
    `libssl.so.3` + `libcrypto.so.3` (ET_DYN), aarch64 armv8 crypto asm objects. Needs the
    `aa-openssl-target-overlay.nix` (adds a `solaris64-aarch64-gcc` Configure target openssl upstream lacks,
    plus `--allow-shlib-undefined` for the libnsl filter chain).
  - readline 8.3p3 + ncurses 6.6 -- shared `.so` (ET_DYN), from the solnix binary cache (s3.solnix.io).
- **PG build tools cross-built (run ON aarch64, not usable to bootstrap on x86):** bison 3.8.2 (ET_EXEC).
  flex/perl/gmake are on the same cross path; libxml2/icu are OPTIONAL (`--without-libxml`/`--without-icu`)
  and libxml2 drags a large native buildPackages rebuild -- skip unless XML support is wanted.
- **KEY capability check PASSED (step 3):** a PG-representative C file (GCC atomics/CAS, pthreads, memory
  barriers, 64-bit ints -- the surface `src/port` + `src/backend/port/atomics` use) cross-compiles to an
  aarch64-solaris `.o` AND links to a full `ET_EXEC` (interp `/lib/ld.so.1`, NEEDED libpthread/libgcc_s/libc,
  no phantom undefs). The aarch64 build environment can build C the way PG needs.

### The native-toolchain gap (what a NATIVE aarch64 animal still needs)
The seed cross gcc driver + cc1 are **EM_AMD64** -- x86 binaries that RUN on x86 and EMIT aarch64. There is
**NO native aarch64 gcc** (a gcc that runs ON aarch64). So:
- **Today (A7 role): CROSS only.** The x86 animal cross-produces aarch64-solaris artifacts. This is the
  provisionable capability right now; a PG buildfarm animal that reports aarch64 results by cross-building on
  x86 is a config choice, but the PG buildfarm normally wants a NATIVE compile on the target.
- **A NATIVE aarch64 PG buildfarm animal (post-A6) needs a native aarch64 gcc/binutils built ON the animal**
  (or cross-built as aarch64-runnable binaries). That is the arm64-gate `make illumos` + a native gcc
  bootstrap on the booted aarch64 system -- NOT done yet. The cross-built aarch64 `bison`/`gmake` binaries DO
  run on the animal once it boots; the missing piece is the compiler itself.

### ELFOSABI status (SOLARIS vs NONE)
- Cross builds through the stdenv/GNU-ld path (zlib, openssl, bison, the step-3 exe) come out
  **ELFOSABI_NONE + EM_AARCH64**. The seed has ONLY a GNU ld for aarch64 (the "Solaris ld" is an x86-host
  binary that rejects EM_AARCH64), and GNU ld stamps OSABI_NONE.
- The cache-built readline/ncurses `.so` are **ELFOSABI_SOLARIS + EM_AARCH64** (an artifact of how the
  218-baseline was linked). Both are valid aarch64 illumos ELF (interp `/lib/ld.so.1`, correct EM_AARCH64,
  resolve the illumos system libs). The OSABI-byte difference is a toolchain-consistency item (IPD 24 is
  predraft), not a build blocker -- track it before claiming ABI parity with native illumos.

### The two cross-link nuances (both fixed / bounded)
1. **libgcc-unwind.map shared-link wall** (docs/aarch64-cxx-wall-fix.md): the seed gcc's built-in `*link:`
   spec emits `-M %slibgcc-unwind.map` (a Solaris mapfile) for shared links, but GNU ld reads it as a linker
   script and dies. FIXED by `cxxNomapCc` in entry-aa-fin-x.nix (a `-specs=` override dropping the `-M` map
   clauses). All shared `.so` links then work.
2. **libnsl filter phantom undefs**: `apps/openssl` links `-lnsl`, and the seed's `libnsl.so` re-exports
   `mp_*@SUNW_1.1`/`MD5*@SUNW_1.1` from `libmp`/`libmd`; `libmd.so` is ABSENT from the seed sysroot, so GNU
   ld (which resolves a shared lib's own undefs eagerly) errors. FIXED with `--allow-shlib-undefined` (baked
   into aa-openssl-target-overlay.nix); the symbols resolve at runtime via the illumos filter chain. Upgrade
   path: add `libmd.so` to the aarch64 seed sysroot, then the flag is unnecessary.

### Build-space gotcha (this node had it)
The cross-build node's root zpool was undersized (the same fdisk/VTOC-doesn't-span-disk gotcha as the x86 AMI
-- ~7.5G of a 100G disk). Cross-realising the seed + a few leaves needs more. Fix: attach a separate EBS
volume, reboot (illumos enumerates disks at boot), `zpool create bfpool c<N>t<M>d0` (whole disk), move `/nix`
onto it (`zfs create` a dataset, tar-copy `/nix`, `zfs set mountpoint=/nix`). Do NOT live-grow the mounted
root slice.

## RISC-V build-farm animal / daily driver
Hardware-gated: the SpacemiT K1 board (QEMU R-P63 done). Provision when the board arrives + the K1 bring-up
lands. The 10/10-class boot fixes + the aarch64 kernel-build learnings carry over.

## Fleet reliability (why these will be STABLE long-term)
- 10/10 cold boot (ena Rx-config + the tsc_pit_also/pit_is_broken kernel-hang fix, measured).
- Nix upgrade-over-time works (by-name channel + the solnix binary cache substituters).
- Never live-grow the mounted root; attach a separate large pool for build/store data.

## Post-migration note (mala account 724081032357)
The migration copied `solnix-pgbf-animal-mala` (ami-0fc72ded5e56955e5) into mala, BUT re-baked pgbf-animal
AMIs carry the cold-boot DHCP regression above (the create-image capture loses the in-place-boot_archive
reliable-boot property, per ena-rx-coldboot-fix.md). So in mala, provision the PG build-farm animal the
RELIABLE way: cold-launch the migrated 10/10 base `solnix-10of10-pitfix-mala` (ami-074834047d4775cc7) --
which boots reliably -- then run the scripted pre-install (pgbf user + PGBuildFarm/client-code +
developer/ccache + library/perl-5/ipc-run + the build-farm.conf; attach a volume for the first-boot bfpool).
Do NOT rely on the re-baked solnix-pgbf-animal-mala for a reliable cold boot until the DHCP regression is
fixed. (mala quota is 5 vCPU/0 GPU until the open increase requests approve -- 1 small animal for now.)
