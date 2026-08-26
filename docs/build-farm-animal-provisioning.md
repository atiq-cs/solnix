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

## aarch64 build-farm animal (NATIVE = campaign in progress)
Native aarch64-on-Graviton is A6 (multi-week: GICv3/ACPI/Nitro-drivers). QEMU-boot is DONE (A4+A5). Until A6
lands, the aarch64 role is a CROSS-build target ON an x86 animal (218 aarch64-solaris store paths built). A
native aarch64 PG animal follows A6+A7.

## RISC-V build-farm animal / daily driver
Hardware-gated: the SpacemiT K1 board (QEMU R-P63 done). Provision when the board arrives + the K1 bring-up
lands. The 10/10-class boot fixes + the aarch64 kernel-build learnings carry over.

## Fleet reliability (why these will be STABLE long-term)
- 10/10 cold boot (ena Rx-config + the tsc_pit_also/pit_is_broken kernel-hang fix, measured).
- Nix upgrade-over-time works (by-name channel + the solnix binary cache substituters).
- Never live-grow the mounted root; attach a separate large pool for build/store data.
