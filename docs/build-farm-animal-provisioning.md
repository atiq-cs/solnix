# solnix build-farm animal provisioning (durable-account recipe)

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
