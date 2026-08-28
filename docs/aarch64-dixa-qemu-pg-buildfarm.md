# dixa: aarch64 solnix PG build-farm animal via QEMU -- result

Node i-0f422ef27fdaa5881 (mala x86 illumos host, us-east-2a, m5.4xlarge, 16 vCPU / 64 GB),
now at 18.117.105.120. LEFT RUNNING (it is dixa). AWS_PROFILE=mala.

## Verdict (one line)
The aarch64 solnix QEMU guest BOOTS to multi-user + root shell, and a NATIVE aarch64
gcc IN the guest BUILDS + INSTALLS PostgreSQL 16.4 (native aarch64 ELF binaries that run);
runtime `initdb` wedges on an early-port kernel syscall gap (the forked `postgres --check`
config probe blocks uninterruptibly). So dixa is a working aarch64 PG *build* animal today;
the *run* (initdb -> live SELECT) is one kernel-syscall gap away.

---
## 1. QEMU boot to multi-user -- YES (console evidence)

The build-tree EBS snapshot (snap-0c9fb0d1309732f2c, 150 G) is a clone of this build
node's own root; its ZFS pool is named `spool` with the SAME pool_guid as the live root
(2383845163825270245), so `zpool import` refuses it (guid collision). Fix: stopped the
node, made the build-tree volume (vol-0f6ab5ccf7eaf1771) the ROOT disk (xvda), re-attached
the original root as a secondary (sdf). Node booted from the richer 150 G disk with the
full `/aarch64/arm64-gate` tree present (incl. a prebuilt `qemu-setup/illumos-disk.img`).

Booted the A5 recipe: `qemu-setup/run-usernet.sh` (QEMU -M virt, GICv2, user-mode net),
8 GB RAM / 4 vCPU, serial console -> /tmp/qcon.log on the host, stdin from a FIFO.
NOTE: the shipped image already had the build_qemu.sh `pv`-drop fix applied (bootable).
NOTE: the image's loader is A6-instrumented (A6BLK/A6RS block-read debug) so the serial
console is noisy; boot still reaches multi-user. Let it AUTOBOOT (do not send loader keys).

Console proof (de-ANSI, /tmp/dixa-console-evidence.txt):
```
illumos Version arm64-gate-0-gd37d5ec328 64-bit
root on armpool/ROOT/braich fstype zfs
cpu0..cpu3: ARM Cortex-A53 @ 1000 MHz   (4 CPUs online)
Hostname: braich
console login:  -> root ->
SunOS braich 5.11 arm64-gate-0-gd37d5ec328 armv8 aarch64 QEMU,virt
64-bit aarch64 kernel modules
uid=0(root) gid=0(root)
```
Interactive root shell confirmed (uname/isainfo/id ran live).

---
## 2. PG build capability IN the guest

### Native aarch64 gcc: PRESENT (mission brief's "native gcc ABSENT" is FALSE for this image)
The A5 image ships the arm64-gate build-essential userland WITH a native compiler:
```
/usr/bin/gcc  = gcc (OmniOS 151059/14.3.0-il-1) 14.3.0
/usr/bin/g++  /usr/bin/gmake  /usr/bin/make  present
```
Verified native codegen: a trivial C file compiled+linked+ran ->
`file t: ELF 64-bit LSB executable aarch64` (GCCRC=7, its own exit). So NO cross-toolchain
is needed for the guest to build native aarch64 code -- it self-hosts.

### PostgreSQL 16.4 built NATIVELY in the guest: YES
- Guest egress: `vioif0` is the virtio NIC (not "net0"). `ipadm create-if vioif0` +
  `create-addr -T dhcp` -> 10.0.2.15/24. DNS worked only after fixing nsswitch
  (`hosts: files` had no `dns` -> added `dns`). Then curl fetched postgresql-16.4.tar.bz2.
- configure needed the build triple: `./configure --build=aarch64-unknown-solaris2.11
  --prefix=/opt/pg16 --without-icu --without-readline --without-zlib --without-gssapi`
  (config.guess can't name aarch64-illumos; `gcc -dumpmachine` = aarch64-unknown-solaris2.11).
- `gmake -j4 world-bin` compiled the WHOLE tree (backend + bin + libpq + ecpg + contrib)
  with zero errors. `src/backend/postgres: ELF 64-bit LSB executable aarch64`.
- `gmake install` -> /opt/pg16/bin: postgres, initdb, psql, pg_ctl, pg_dump, pg_controldata,
  pg_restore, pg_rewind, reindexdb, ...  All report `(PostgreSQL) 16.4`.
- Binaries execute: `postgres --version` = "postgres (PostgreSQL) 16.4";
  `postgres --describe-config` RC=0; `psql --version` / `pg_controldata --version` = 16.4.

### initdb + live SELECT: BLOCKED by an early-port runtime syscall gap (real finding)
`initdb -D /pgdata -U pguser -E UTF8 --locale=C` reliably wedges at
`selecting default max_connections ...`. That step is initdb's `test_config_settings()`,
which forks trial `postgres --check -F -c log_checkpoints=false -c max_connections=...`
backends. The trial backend blocks in an uninterruptible syscall:
- 4 stuck `postgres --check` procs SURVIVE `kill -9` (AFTERKILL=4); pending SIG9 is queued
  in lwpstatus but never delivered -> the LWP is in a signal-uninterruptible kernel path.
- pstack on the stuck proc itself hangs (had to Ctrl-C).
- SysV semaphores are NOT the gap: a standalone C `semget/semop/semctl` test returns
  SEMA_OK (STRC=0). The wedge is in another backend-startup syscall
  (shared-memory sizing / poll / fsync-class) not yet complete/interruptible in this
  early aarch64-illumos QEMU-virt kernel.

So: the guest self-hosts a full native PG BUILD; the RUN trips on one kernel syscall
gap during initdb's fork-heavy config probe. This is an A6-class kernel-maturity item,
not a toolchain problem.

### Cross-build interim (per mandate)
The x86 host cross-build path (A7-prep, committed: docs/aa-pgdeps-report.md, 218 store
paths of aarch64 deps openssl/zlib/bison/readline, a PG-representative C file that
cross-compiles+links) remains the interim to produce aarch64 PG artifacts until the
guest's initdb syscall gap is closed. NOTE: the A7-prep cross toolchain lived on the
node's ORIGINAL root (now the secondary sdf volume, not imported) -- not re-exercised
this leg; it is already proven in the committed report.

---
## 3. dixa nix-config status

`~/ws/nix-config` already has the `gburd@dixa` home fully wired:
- flake.nix: `"gburd@dixa" = libx.mkHome { hostname="dixa"; platform="aarch64-solaris"; };`
- hosts/dixa.nix imports _solnix-common.nix (headless, no COSMIC; litellm/skillSpector off).
- lib/helpers.nix mkHome routes `*-solaris` through `inputs.solnix-pkgs.lib.nixpkgsSrc`
  + `solnix-pkgs.overlays.default` (allowUnsupportedSystem) -> a real aarch64-solaris pkg set.

Gaps (documented, not forced):
1. `flake.lock` does NOT contain `solnix-pkgs` at all -- the input was declared but never
   locked, so dixa cannot instantiate yet.
2. A pre-existing BROKEN input blocks ALL lock updates: `NOTE = github:DietrichGebert/NOTE`
   (flake.nix ~line 101) returns HTTP 404 -> `nix eval`/lock update fails before reaching
   dixa. Fix that input (correct the repo, or drop/relax it) FIRST, then
   `nix flake lock --update-input solnix-pkgs` to wire aarch64-solaris in.
3. Once locked, the aarch64 nixpkgs-illumos overlay must actually expose aarch64-solaris
   builds (solnix-pkgs coverage) for the profile to build; until then dixa evaluates by
   shape but won't build a closure.

---
## Reproduce (guest PG build)
```
# on the node (illumos x86 host):
cd /aarch64/arm64-gate/qemu-setup
mkfifo /tmp/qin; sleep 100000 > /tmp/qin &         # keep stdin open
QEMU_SCRIPT_MEMORY=8g QEMU_SCRIPT_NCPU=4 nohup ./run-usernet.sh < /tmp/qin > /tmp/qcon.log 2>&1 &
# wait ~5 min for autoboot to "console login:", then via /tmp/qin:
#   root  (enter)
#   ipadm create-if vioif0; ipadm create-addr -T dhcp vioif0/v4
#   sed -i 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf
#   cd /root; curl -fsSLO https://ftp.postgresql.org/pub/source/v16.4/postgresql-16.4.tar.bz2
#   bzip2 -dc postgresql-16.4.tar.bz2 | tar xf -; cd postgresql-16.4
#   ./configure --build=aarch64-unknown-solaris2.11 --prefix=/opt/pg16 \
#       --without-icu --without-readline --without-zlib --without-gssapi
#   gmake -j4 world-bin && gmake -C src install && gmake -C src/bin install
#   /opt/pg16/bin/postgres --version    # -> postgres (PostgreSQL) 16.4  (native aarch64)
# initdb currently wedges at "selecting default max_connections" (kernel syscall gap).
```

## Artifacts
- Node 18.117.105.120 (i-0f422ef27fdaa5881), LEFT RUNNING. Build vol = ROOT.
  - /aarch64/arm64-gate (full tree), qemu-setup/illumos-disk.img (bootable)
  - guest: /opt/pg16 (installed native aarch64 PG 16.4), /root/postgresql-16.4 (built tree)
  - host: /tmp/qcon.log (guest console), /tmp/qin (console FIFO)
- Dev box: /tmp/dixa-report.md, /tmp/dixa-progress.txt, /tmp/dixa-console-evidence.txt
