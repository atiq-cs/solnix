# The live installer's Nix store: writable, in RAM

**Status: implemented in the livestore track (6bf1cc4 + final.diff), proven under KVM. Not committed.**

## Problem

On the live stick, `nix flake metadata nixpkgs` (scripts/ami-registry-check.sh), `nix shell nixpkgs#…` and
`nix-env -iA nixos.htop` all fail with "No space left on device". The live root is a UFS ramdisk sized to the
closure + 12% + 32 MiB (`make-installer-image.sh`). On 1c9b149-gpu that left 45,829 KB free, and `/nix/store`,
`/nix/var/nix/db` and `~/.cache/nix` all sit on it.

What one command needs, measured on floki with a fresh store and a fresh `~/.cache` (`nix eval` of
`git+https://git.solnix.io/solnix.git?ref=26.11#packages.x86_64-solaris.htop`):

| | store | ~/.cache/nix |
|---|---|---|
| today (the eval fetches the gate proto with `builtins.fetchTarball`, pkgs/illumos/gate.nix) | 1,247,296 KB | 275,232 KB |
| of which the gate proto (s7zkx8nx, NAR 679,840,760 B) | 632,496 KB | ~194 MB tarball cache |
| without the proto fetch (proto already present: what a FOD proto gives) | 606,476 KB (nixpkgs source 336 MB, solnix 47 MB, eval-time source tarballs 220 MB) | 81,664 KB |
| + substituting 26.11 htop (d0jqxnbi, 10 paths) | + 308,591,904 B NAR | |

So even without the proto, one command needs about 1 GB writable: 20 times the slack, and 35 times the 26 MB of
headroom left under the X1 cap.

## What NixOS does

`nixos/modules/installer/cd-dvd/iso-image.nix`: the media's store is a squashfs at `/nix/.ro-store`. A tmpfs at
`/nix/.rw-store` (`mode=0755`, no `size=`, which on Linux means half of RAM) is the upper layer, and an
**overlayfs** of the two is mounted on `/nix/store`. The store DB is loaded at boot from `nix-path-registration`,
and `/nix/var` lives on the root tmpfs. New store paths go to RAM; the media's paths are never copied.

## Options (measured)

* **(a) NixOS's layout, adapted.** A tmpfs upper, with the ramdisk's store underneath it read-only.
  *As the brief worded it*, a chroot store (`--store local?root=/tmp/...` or a substituter pointing at it),
  this does not work on illumos. A chroot store keeps its paths under `/tmp/.../nix/store`, so nothing in it can
  run as `/nix/store/...`, because illumos has no mount namespace to remap them. Flake eval also fails outright:
  `error: path '/tmp/regstore3/nix/store/…-source/flake.nix' is not in the Nix store` (measured on 1c9b149-gpu,
  bank evidence/kvm-registry-tmpstore.txt). What does work is the union itself, built from lofs (below).
* **(b) /nix/var and new paths on the stick's scratch partition (p3).** On the X1, the stick is not a block
  device after the kernel starts: scsa2usb never binds (make-installer-image.sh header, setup_scratch). It would
  also need `zpool create` on the stick at boot. It cannot be the default. solnix-install keeps using it for
  installs, as before.
* **(c) More ramdisk.** 26 MB of headroom under the 734,003,200 B cap is left, and the measured need is
  about 1 GB. Ruled out.

## Decision: (a), with lofs in place of overlayfs

`scripts/live/solnix-live-store`, run from inittab as `ls::sysinit`, right after `vol::` (so autopush is still
first) and before svc.startd:

1. `mount -F tmpfs -o size=50%,mode=0755 swap /nix/.rw-store`. That is NixOS's size: tmpfs `size=50%` is half of
   the available swap, which on a swapless live system is RAM (tmp_subr.c tmp_convnum).
2. For each entry of the ramdisk's `/nix/store`: a stub of the same name in `/nix/.rw-store/store` (a directory, or
   an empty file for a regular-file store path), with `mount -F lofs -m -o ro <entry> <stub>` on it. A symlink
   entry is copied as a symlink. `-m` keeps the ~100 mounts out of mnttab.
3. `mount -F lofs -O /nix/.rw-store/store /nix/store`. That one mount switches every lookup to the union. `-O`
   is there because the shell running the script is itself in /nix/store (lofs_vfsops.c refuses a busy
   mountpoint without MS_OVERLAY).
   `/nix/store/.links` is the exception: it gets an empty tmpfs directory and no lower. `auto-optimise-store
   = true` hard-links every new file into `.links`, and a hard link from the tmpfs into a lofs of the ramdisk
   fails EXDEV. Measured on the first KVM image: every write failed `cannot create hard link: Cross-device link
   [/nix/store/…-flake-registry.json] [/nix/store/.links/…]`, including solnix-channel-init at boot.
4. `/nix/var` and `/root` are copied into the tmpfs (`tar cEf` | `tar xpf`: illumos tar needs `E` for link
   targets longer than 100 bytes, which was measured to truncate them otherwise) and lofs-mounted back.

Each step falls back: if any mount fails, the store stays the ramdisk's, exactly as on earlier media.

Measured on the OI build host (lt.sh, lt3.sh, lt4.sh, lt6.sh in /scratch/solnix/livestore): reads and exec work
through the union, including `..` and getcwd. A new file lands in the tmpfs. A write into a media path gets
EROFS. The plain lofs over a store holding an open file succeeds. solnix-install's `overlay_nix`
(`mount -F zfs $POOL/nix /nix`) mounts over the union and unmounts back to it.

### Why lofs-per-path is enough here, and where it departs from overlayfs

* Nix never modifies a valid store path; it only adds new ones (temp name + rename in the store directory) and
  deletes during GC. Adds and renames go to the tmpfs. The union does not need copy-up, which is the overlayfs
  feature lofs lacks.
* Deleting a media path (GC) fails with EROFS or EBUSY. That is harmless: `min-free = max-free = 0` on the
  media (installer.nix), so no automatic GC runs, and NixOS's overlay cannot free media bytes either.
* The store DB is the ramdisk's, copied to RAM, and it already lists every media path (`nix copy` wrote it at
  image build time), so there is no `--load-db` step, unlike NixOS.

### What it keeps

* The X1 ceiling: no bytes are added to the ramdisk (one empty directory, one inittab line; the tmpfs is not in
  the archive).
* The read-only media store (solnix-store.iso, file:// substituter) is untouched.
* Install-from-flake: solnix-install builds into the target pool (`--store $ALTROOT` / overlay_nix), as before.
* Acceptance: check 15 in image-acceptance-test.sh (ls:: after ap, vol; the script in the media's store;
  /nix/.rw-store present), with a `--selftest` control and three per-defect controls in
  test-image-acceptance-contract.sh.

## Proof (KVM, m5zn.metal, 8 GB guest, the 6bf1cc4-livestore image, clean boot)

| | ramdisk `/` avail | `/nix/.rw-store` avail |
|---|---|---|
| after boot | 45,811 KB | 3,728,212 KB (tmpfs 3,736,544 KB) |
| `ami-registry-check.sh` → REGISTRY_FETCH_OK 9ba64349 (then 8/8 more) | 45,811 KB | 3,680,748 KB |
| `nix shell …?ref=unstable&rev=6bf1cc4#tree -c tree /etc` RC=0 | 45,811 KB | 1,825,896 KB |
| `nix shell nixpkgs#htop -c htop --version` RC=0 (substituted from cache.solnix.io) | 45,811 KB | 1,616,604 KB |
| `nix-env -iA nixos.htop` RC=0 | 45,811 KB | 1,619,068 KB |

About 2.06 GB lands in RAM: the gate proto 666 MB, nixpkgs source 489 MB, `~/.cache/nix` 684 MB, the solnix
sources, and htop's closure. The same commands on the 1c9b149-gpu image all fail "No space left on device", and
`/` drops from 45,841 to 3,709 KB.

Sizing: without the eval-time proto fetch, the floki measurement above drops to about 606 MB of store plus 82 MB
of cache for the eval, plus 309 MB of NAR for 26.11 htop, so about 1 GB. 50% of RAM covers either case on 4 GB or
more.

## Known limits

* 26.11's `packages.x86_64-solaris` has 29 attributes and no `tree`, so `nix shell nixpkgs#tree` fails on a 26.11
  edition with "does not provide attribute" however much space there is. Use `nixpkgs/unstable#tree`. This is an
  edition gap, not part of this change.
* A path the cache does not have is BUILT, and builds unpack under `/var/tmp` (gcc-src.nix: `mktemp -d
  /var/tmp/gccsrc.XXXXXX`), which is still the ramdisk. Measured: `nixpkgs/unstable#tree` after unstable moved to
  4706d6c (tree ndsfn9 not on cache.solnix.io) started a gcc build that filled `/` to 1,413 KB. The live media
  substitutes; it is not a build host. Moving TMPDIR/`/var/tmp` into the tmpfs is a possible follow-up, not done.
* Everything fetched is gone at reboot (as on NixOS). An 8 GB machine has a ~4 GB store, enough for the measured
  ~1.5 GB eval + cache.
