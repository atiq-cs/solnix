# Nix-managed base: /nix layout, decided by measurement

Status: the layout decision is measured. The from-source chain, a non-DEBUG kernel derivation, the
toplevel, install-be and make-be are built, and the disk boots to login under KVM with two generations
selectable from the loader. Check (d) is partial because nix cannot substitute yet (see the end).

## The question

NixOS keeps one shared `/nix` and points the system at it. illumos raises two questions that decide whether
solnix can do the same:

1. Can the boot loader read the kernel and boot_archive through a symlink, and does that work when the
   symlink crosses into another ZFS dataset?
2. Which files must sit on the boot environment's root dataset because they run before any other dataset is
   mounted?

## Measurements (2026-10-04, build guest bhost, OpenIndiana loader, illumos-5dc8ec7c48)

Gate proto restored from R2 rather than rebuilt:
`/nix/store/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto` (219,678,907 B tarball; NAR hash matches
`gate.nix` protoHash; unix 2,616,328 B, libc 2,013,192 B, matching docs/gate-fod-findings.md).

### 1. Loader and symlinks

Run at the EFI loader prompt on a cloned test BE, driven through the qemu monitor (the EFI loader ignores
serial input).

| `load` target | result |
|---|---|
| `/ct/unix-dangling` (negative control) | can't find |
| `/ct/unix-rel` -> `../platform/...` (same dataset) | OK, multiboot2 kernel |
| `/ct/unix-abs` -> `/platform/...` (same dataset) | OK |
| `/ct/unix-instore` -> `/nix/store/<h>-kernel/...` stored INSIDE the BE dataset | OK |
| `/ct/plat` directory symlink into the in-BE store, then `.../kernel/amd64/unix` | OK |
| `load -t rootfs` boot_archive via relative / in-BE-store symlink | OK |
| `/ct/unix-nix` -> `/nix/ctest/unix` on the separate `rpool/nix` dataset | can't find |
| `load zfs:rpool/nix:/ctest/unix` (explicit device path, no symlink) | OK |

The loader follows symlinks within the BE dataset, including into a store laid out inside it. It does not
follow a symlink into another dataset; it can only read another dataset by explicit device path.

### 2. What must exist before the shared store is mounted

Each test BE booted via `set currdev=zfs:rpool/ROOT/<be>:` + `boot` (pool bootfs unchanged).

| BE | change | result |
|---|---|---|
| ctB1 | `/sbin/init` -> `/nix/ctest/init` on rpool/nix | `exec(/sbin/init) failed (file not found)`, "Could not start init" |
| ctB2 | `/sbin/init` -> `/sbin/init.real` (same dataset), positive control | boots to console login |
| ctB3 | `svc.startd` -> `/nix/ctest/svc.startd`, no early mount | `INITSH: exec: /lib/svc/bin/svc.startd: not found` x3, maintenance mode |
| ctB4 | as ctB3, plus inittab `nx::sysinit:/sbin/zfs mount rpool/nix` before `smf::` | multi-user-server online; pmap shows svc.startd text mapped from /nix/ctest |

So the files needed before that inittab line runs must be real files on the BE root: kernel and modules,
boot_archive, `/sbin/init`, `/etc/inittab`, `/sbin/sh`, `/sbin/zfs` plus its libraries, and `ld.so.1`.
Everything started after the sysinit mount can live in the shared store.

## Decision

Follow NixOS: one shared `<pool>/nix` dataset holds the store and profiles for every generation. illumos
forces one departure, and it is narrow. Per generation, the boot-time set above is copied as real files into
that generation's BE, and an inittab sysinit entry mounts `<pool>/nix` before `svc.startd` starts.
Each generation is its own BE, so each generation is its own loader menu entry and the boot-time rollback
NixOS gets from its bootloader entries comes from `beadm`.

What the installer and `switch-to-configuration` must therefore agree on:
- `/nix` is the shared dataset, not inside the BE (the installer already does this; the current activation
  code copies the closure into each BE's own `/nix/store` and must change).
- the early set is materialized from the toplevel into the BE when the BE is created.
- inittab carries the early `zfs mount <pool>/nix` line ahead of `smf::`.

Test BEs ctA and ctB1-ctB4 on the bhost rpool are measurement scaffolding and are to be destroyed once the
real base boots.

## The read-only store question (measured 2026-10-05)

NixOS mounts `/nix/store` read-only and gives nix-daemon a private mount namespace in which it is
writable. illumos has no mount namespaces, so the question was whether a read-only view plus a writable
real path could work instead.

| test (bhost) | result |
|---|---|
| dataset at a root-only `X/.rw` (0700), `mount -F lofs -o ro X/.rw/store X/store` | rc=0 |
| root `touch X/store/x` | "Read-only file system" |
| write via `X/.rw/store`, read via `X/store` | rc=0, visible |
| user nobody reads `X/store`, lists `X/.rw` | reads OK, `X/.rw` Permission denied |
| `nix-build --store 'local?real=/var/tmp/dv/store'` (store dir /nix/store, real path elsewhere) | "error: building using a diverted store is not supported on this platform" |

The view works, but Nix refuses to build when the store's logical and real paths differ, and that is
exactly what a read-only `/nix/store` with writes through another path is. So on illumos a read-only
`/nix/store` and "nix builds through the daemon" are mutually exclusive.

Decision: the installed system's store is writable by root and the daemon only, with NixOS's permissions
(`root:nixbld`, mode 1775), and normal users go through nix-daemon. The secondary reference agrees: NixBSD
(nix-community/nixbsd) also leaves `/nix/store` writable on an installed system; its `readOnlyNixStore`
module (modules/tasks/nix-store.nix, nullfs/unionfs) is enabled only for VM and netboot images
(modules/virtualisation/qemu-vm.nix, configurations/freebsd-netboot), and nix-daemon runs as a plain init
service with nixbld users (modules/services/system/nix-daemon.nix).

## Everything on the target is built from source

The maintainer's rule: every file on the target is a derivation built from source by a recipe in this
repo; the one exception is the gate proto (pkgs/illumos/gate.nix, from illumos-gate source) and its slices.
That rules out host copies of any kind (the old `externalLibs`, the host sshd/bash, `/nix-tools224`, the
host `/etc` driver files). How each was replaced:

| was | now |
|---|---|
| host IPS gcc-14 runtime (libstdc++, libgcc_s) | `pkgs/illumos/gcc-src.nix`: gcc 14.3.0 from source, stage0 = host gcc used only to compile it (the NixOS bootstrap shape); multilib; `gcc.lib` is the only output a shipped binary references |
| externalLibs (host libxml2, zlib, ICU, libstdc++) | `base-src.nix` zlib 1.3.2 (with OpenIndiana's symbol-version mapfile, which libzfs requires) and libxml2 2.14.6 |
| host sshd + libcrypto | `base-src.nix` openssl 3.4.0, openssh 10.2p1 (`--with-pam`, sshd_config `UsePAM yes`) |
| (none) bash | `base-src.nix` bash 5.2.37 |
| /nix-tools224 nix with LD_LIBRARY_PATH wrapper | `nix-src.nix`: boost, sqlite, xz, libsodium, curl, libarchive, brotli, editline, nlohmann_json, toml11, libgit2, nix 2.24.15 (patches 0001-0006) |
| host /etc/{name_to_major,driver_aliases,minor_perm,...} | `data/drivers/`, rendered by `data/drivers/gen.py` from the 362 `driver` actions of illumos-gate's own pkg manifests at the pinned rev |
| gate userland as hand-picked slices | `mk-proto-world.nix`: the whole gate userland in one store path, one libc per process |

Pass rule per package: `ldd` with `LD_LIBRARY_PATH` unset shows no "not found" and no path outside
/nix/store. mk-src-pkg.nix enforces it in the builder, and also fails the build if a shipped ELF still
names the gate proto or the compiler.

Problems hit on the way, each measured:
- gcc: the libstdc++ configure runs test programs that need the just-built libgcc_s (host has none on
  its default path), and upstream libstdc++ rejects OpenIndiana's `--enable-clocale=dragonfly` (an OI patch).
- DWARF in the runtime libs records the sysroot include paths, which Nix's reference scan turns into a
  runtime dependency on the 219 MB gate proto. Fixed by `strip --strip-debug` (stdenv's strip phase).
- GCC 14 makes `-Wincompatible-pointer-types` an error; illumos PAM and curses prototypes trip it in
  openssh and bash.
- nix: illumos has neither `SO_PEERCRED` nor `LOCAL_PEERCRED`, so without patch 0006 (getpeerucred) the
  daemon never learns the client uid and `trusted-users = root` cannot match.
- nix: header-only deps leave their store paths in assert strings and DWARF; the first nix build's
  closure carried 150 MB of boost headers.
- the world: 69 of 17,428 relocated objects NEED libraries the gate does not build (dbus/glib for hal,
  NSS/NSPR, OpenSSL 1.0 for sendmail/wpad/bhyve, net-snmp, python 3.9, libtspi, jvm, and the C++ runtime
  for make/audioconvert/libfru/yp). None is on the boot path; they are listed in the world's
  `.world/ldd-bad`. 149 more resolve only through subdirectories (usr/lib/krb5, smbsrv, scsi, ...) the
  flat lib dirs do not cover yet.

## Generations: install-be (one step for image, installer and switch)

`<toplevel>/bin/switch-to-configuration install-be <toplevel>` (modules/system/activation/install-be.sh)
fills a mounted BE from the toplevel alone, reading every store path through `SOLNIX_STORE_ROOT`:
the early set (`<toplevel>/early-paths`, the closure of pkgs.solnix.early: init, sh, zfs, mount, ld.so.1,
libc and their libs) copied as real files to the same store paths in the BE's own /nix; kernel trees as
real files (bootadm walks them); `/usr/bin` -> sw/bin; `/lib`, `/usr/lib`, `/sbin` as per-entry link
farms into the userland, with ld.so.1 and the four early tools pointing at the in-BE copies; `/etc` from
the gate's stock tree with the toplevel's files and users over it; the driver database; `/etc/system`
fragments applied once; inittab gains `zfs mount -O <pool>/nix` as its first sysinit entry; a fresh SMF
seed, the solnix manifests and the site profile (presets as a site profile, because `svccfg setprop` on a
fresh seed is a silent no-op for services not yet imported); /boot from the kernel slice; boot_archive.
lib/make-be.nix (image) and `switch-to-configuration boot` (new generation) both call it.

The shared `<pool>/nix` is filled with `nix copy --to local?root=...` (copying into a non-default root
works on illumos; building there does not), so the store DB is written directly and no first-boot
registration is needed.

## Build state (2026-10-05, REAL unless marked)

- Base toplevel `/nix/store/vkyzzm120qz9gwngnn22idiyh8az2qvs-solnix-system-solnix`, closure 493,743,744 B,
  no gate proto, compiler or boost in it (the toplevel fails to build if it would contain the gate proto or
  gcc; negative control: adding an old gate-carrying libxml2 made it fail with
  "runtime closure contains build-only ...-illumos-gate-proto").
- make-be produced a disk from a test variant of it: loader, kernel, root from the BE, the inittab
  `zfs mount -O <pool>/nix`, svc.startd and all 174 manifests import from the shared store.
- Kernel slice bug found by that boot: relocating RUNPATH into kernel modules (ET_REL objects whose
  .dynamic carries their depends_on list as NEEDED) overwrote specfs's `NEEDED fs/fifofs`, so krtld could
  not load specfs. Kernel objects are now left byte-identical to the gate (0 of 890 differ).
- The DEBUG-kernel panic named here earlier is fixed by the non-DEBUG kernel derivation, and checks a-g are
  measured; both are in the sections below.

## The kernel is its own derivation, non-DEBUG (measured 2026-10-06)

NixOS builds the kernel as a separate package from userland; solnix now does too. The gate proto's kernel
is DEBUG: gate.nix runs nightly with illumos.sh's `NIGHTLY_OPTIONS='-FnCDAmprt'`, and `-F` skips the
non-DEBUG pass. Every boot of that kernel panicked right after "Hostname:" in `so_integrity_check()`, an
assertion compiled only `#ifdef DEBUG` (sockcommon_subr.c), on the socket TPI-fallback path.

`pkgs/illumos/kernel-nd.nix` (`pkgs.solnix.kernelNd`) builds only what the kernel needs, from the pinned
source tarball (`fetchTarball`, sha256 measured with `nix-prefetch-url --unpack`) plus
`scripts/patches/0001-tscc_pit-default-pit_is_broken.patch`, inside `bldenv +d` (non-DEBUG):
usr/src/tools (bootstrap + install), then uts `rootdirs`, `all_h`, `install_h`, intel, i86pc. Each step was
found by the previous one failing: host onbld ships neither `bin/amd64/ld` (this gate rev links kernel
modules with its own sgs ld) nor `rpcgen`, so the workspace tools must be built; `install_h` also
generates sources (qlc `ql_fw_table.c`). About 22 minutes on bhost (4 vCPU). Build tools added to bhost:
`developer/gcc-10`, `developer/build/onbld`. No JDK needed.

The builder fails unless all three of these hold, and a negative control ran them against the DEBUG gate proto
(all three FAIL there, all PASS on kernelNd): genunix has no "DEBUG enabled" string (`strings -a`; a plain
`grep -c` reported 0 on the DEBUG genunix too, so it could not fail), sockfs has no `so_integrity_check`
symbol, and `pit_is_broken` sits in `.data` (initialised to 1), not `.bss`. The repo's tscc_pit patch was
malformed (hunk header `+48,12`, body 13 lines; `patch` rejected it); earlier builds applied the change with
sed instead. The patch is fixed.

The kernel slice (`slices.nix`, `kernelTree = kernelNd`) takes kernel/, platform/i86pc and usr/kernel from
it together (gotcha #5). 924 of 926 files are byte-identical to kernelNd; the two that differ are userland ELFs
under boot/ that the slice relocates. Known gap: kmdb is not built (57 files: kmdbmod and the dmods come from
usr/src/cmd/mdb), so the boot log shows `kmdb: undefined symbol kctl_*`. That only affects `boot -k`.

## First boot: what the BE has to provide before devfsadm runs

With the non-DEBUG kernel the panic is gone. These turned up next, each traced to a cause:

| symptom | cause | fix (install-be.sh) |
|---|---|---|
| "hostid missing or corrupt on line 3" | the kernel reads a rot47-encoded quoted string (startup.c `set_soft_hostid`); install-be wrote a bare `0x...` | write no /etc/hostid (NixOS writes one only for `networking.hostId`); the kernel uses the SMBIOS UUID and `system/hostid` saves it |
| datalink-management exit 95, maintenance mode | `open("/dev/dld")` ENOENT (truss). /dev held only the 23 seeded nodes. dlmgmt is a dependency of system/device/local, so devfsadm never ran | `dev/dld` link and the `dev/*` dirs from the gate manifests (system-kernel.p5m, SUNWcsd.p5m) |
| nix-daemon "cannot create Unix domain socket: Address family not supported"; "Failed to convert socket to TPI (err=2)"; cryptosvc and pmconfig fail on first boot | inittab's `soconfig` maps AF_UNIX to /dev/ticotsord, and sockfs's TPI fallback opens /dev/tcp etc. devfsadmd creates these links only after the consumers have run. A second boot of the same BE was clean | seed the tl, keysock, spdsock, crypto, cryptoadm, pm, tcp, udp, icmp, ip and arp links. A forced /reconfigure would do the same, but check (f) forbids it |
| `digest` killed: `libtspi.so.1: open failed`, so the boot_archive.hash was 0 bytes | /etc/crypto/pkcs11.conf lists pkcs11_tpm.so, and trousers is not built | drop pkcs11_tpm from pkcs11.conf |
| non-root login PATH `/usr/bin:` | the gate /etc/profile has no profile.d loop (OpenIndiana adds one), and the generated solnix-env.sh had an empty `then fi` (syntax error) | generated /etc/profile (shell-environment.nix) and a `:` in the alias block |
| a user cannot write /var/tmp | the proto's 0555 dirs (gotcha #7); the stock var/ tree was copied after the chmod | `chmod 1777 var/tmp` after the copy |

## Checks a-g (KVM, disk from make-be, first boot of a fresh disk)

| | result | negative control |
|---|---|---|
| a | 1138/1139 entries of /usr/bin, /usr/sbin, /sbin, /lib resolve into /nix/store. The remainder is /lib/amd64, a real dir of links. `nix-store -q --deriver` on the resolved /usr/bin/ls gives the illumos-userland .drv | /etc counted the same way: 17/195 |
| b | /run/current-system = /run/booted-system = the toplevel; an ssh password login as a normal user gets PATH starting /run/current-system/sw/bin | /etc is not a toplevel |
| c | a normal user cannot write /nix/store (root:nixbld 1775). Root can, because the store cannot be read-only and still build (see above) | the same user can write /var/tmp |
| d | PARTIAL. A non-root `nix-build` goes through the daemon (root-owned output), and `nix profile install` works, but only with `substituters` empty. With the shipped nix.conf every build fails: `failed to get libarchive filter by name: Using external zstd program` (cache.solnix.io), `couldn't initialize compression (Using external bzip2 program)` (cache.nixos.org). nix-src.nix builds libarchive `--without-zstd --without-bz2lib`, so nix cannot substitute | daemon disabled: "cannot connect to socket ... Connection refused" |
| e | a second config (kvm-test-gen2.nix, adds sqlite) imported, then `switch-to-configuration boot` created BE solnix-2. The loader's BE menu lists solnix-2 and solnix-1. Default boot = gen 2 (sqlite3 runs). Picking solnix-1 in the menu booted gen 1 (its toplevel, no sqlite3), and bootfs stayed solnix-2 | the same probe on the default boot reported gen 2 |
| f | no screen-#, no /reconfigure, autofs and smserver disabled with multi-user online, `UsePAM yes`, pit_is_broken once in /etc/system and 1 in `mdb -k`, /boot/fonts has 22 entries | a copy with the line doubled counts 2 |
| g | system/power online, pmconfig rc 0, `cpupm_policy` = 1 (`mdb -k`). Checking the clock speed needs real hardware | - |
| sshd | wrong password rejected 8/8 ("PAM: Authentication failed"), right one accepted. An earlier 12/12 "accepted" run was the dev box's ssh ControlMaster reusing a session, so auth tests must use `ssh -F /dev/null` | right password accepted |

Bug found by (e): switch-to-configuration defaulted POOL to "spool". On pool tpool, `bootfs` came back empty,
and `ensure_menu` overwrote `do_boot`'s `$be` with "." (sh has no locals), so it created and activated a BE
named `tpool/ROOT/.`. The fix (pool taken from the running root dataset, `_mbe`, FATAL on an empty bootfs) is
written, but no toplevel built with it has been tested yet. (e) passed with `SOLNIX_POOL=tpool` set explicitly.

## Next blocker

nix cannot substitute because libarchive is built without zstd and bzip2 (nixpkgs builds it with both). The
fix is zstd and bzip2 from source, then libarchive `--with-zstd --with-bz2lib`, then a nix rebuild.
