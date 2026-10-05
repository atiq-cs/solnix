# Nix-managed base: /nix layout, decided by measurement

Status: the layout decision below is measured. Building and booting a disk from a toplevel is the next step
and is not done yet.

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
