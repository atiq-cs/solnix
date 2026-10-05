# Nix-managed base: /nix layout, decided by measurement

Status: the layout decision is measured; the from-source package chain (gcc, world, openssh, bash, nix) is
built; the toplevel, `install-be` and the new make-be are written and the toplevel evaluates. Building the
toplevel, making a disk and booting it are in progress (see "Build state" at the end, tagged REAL/PLANNED).

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
- Next blocker (PLANNED to fix): the gate proto's kernel is a DEBUG build, and every boot panics right after
  "Hostname:" in the DEBUG-only `so_integrity_check()` (sockcommon_subr.c:2235, via `so_tpi_fallback`).
  docs/design-make-be.md already requires a non-DEBUG kernel; it has to become a derivation built from
  source, since the old host copy (`NDPROTO`) is gone.
- Not yet measured: checks a-g (store paths on PATH, read-only/daemon behaviour, generation switch, boot
  fixes, power management) need a boot that reaches login.
