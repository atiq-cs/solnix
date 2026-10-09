# /var state outside the boot environment

## The problem (measured on the X1, 2026-10-09)

A solnix generation is a ZFS boot environment (`<pool>/ROOT/solnix-N`), and /var
used to live inside it. `switch-to-configuration boot` clones the running BE and
the reboot runs the clone, so:

* anything written to /var after the clone and before the reboot stayed behind in
  the old BE. On the X1, solnix-2 was cloned to solnix-3 at 05:05:41 and ran until
  the 06:40 reboot: `zfs get written rpool/ROOT/solnix-2` = 106M stranded there;
  solnix-3's /var/adm/messages has nothing between 04:17 and 06:40;
  /var/tmp/streamE4 (made under solnix-2 after the clone) was gone.
* a rollback (`solnix-rebuild rollback`, or picking an older BE in the loader)
  reverted /var: logs, /var/lib, /var/tmp, cores, spools, crontabs.

NixOS does not do this. A switch touches /etc, /run/current-system and the boot
loader. A rollback picks an older system profile and leaves /var alone. State is
not part of a generation.

## The layout

The subtrees the running system writes are datasets outside `<pool>/ROOT`, as
`<pool>/nix` and `<pool>/home` already are. This is libbe's "shared file systems"
(be_mount.c zpool_shared_fs_callback/iter_shared_fs_callback: datasets outside the
BE container that every BE mounts), and close to OpenIndiana's rpool/VARSHARE.

```
<pool>/var          canmount=off     mountpoint=/var   (container; never mounted)
<pool>/var/svc      canmount=off     (inherits /var/svc; container for svc/log)
<pool>/var/<x>      canmount=noauto  (inherits /var/<x>)
    x = adm cores crash cron fm lib log logadm mail saf spool tmp svc/log
```

How the list was chosen. On the X1, every file under /var newer than the install
(`find /var -xdev ! -type d -newer /var/empty`), outside /var/tmp:

| subtree | writer, measured | |
|---|---|---|
| adm | messages, sulog, utmpx, wtmpx, lastlog | shared |
| cores | coreadm's /var/cores/core.%f.%p.%t | shared |
| crash | savecore's dumps (/var/crash/dixi) | shared |
| cron | cron/log | shared |
| fm | fmd's errlog, fltlog, infolog_hival | shared |
| lib | /var/lib/solnix/{did-channel-init,mtu-done} | shared |
| log | syslog, authlog, solnix-mtu.log | shared |
| logadm | logadm/timestamps | shared |
| saf | saf/_log, saf/zsmon/log | shared |
| svc/log | 171 SMF logs, svc.startd.log | shared |
| svc/manifest/site/solnix | install-be lays this generation's manifests | **generation** |
| tmp | the /var/tmp work dirs (2.4 GB) | shared |
| mail, spool | no writes yet; mailboxes, crontabs, at jobs, print and mail queues are user state | shared |

Everything else stays in the BE: var/svc/manifest and var/svc/profile (what a
generation installs; install-be relies on reconciling the manifests per BE),
var/sadm, var/ld, var/empty, var/run (tmpfs), and the stock-only directories
nothing has written (audit, db, idmap, inet, krb5, ldap, lp, nfs, opt, preserve,
smb, tsol, uucp, yp). Add one to `VAR_SHARED` (solnix-install and
solnix-migrate-var; test-install-closure.sh checks that the two lists match) once
something writes there.

Choices that differ from NixOS, and why:

* **var/spool/cron/crontabs is shared**, root's stock crontab included. NixOS's
  `services.cron.systemCronJobs` goes in /etc/crontab, which is generation, and
  user crontabs are state. illumos cron reads only var/spool/cron/crontabs, and no
  solnix module writes a crontab, so the whole directory is user state. A module
  that ever generates crontabs would have to write them into this directory, the
  way NixOS writes /etc/crontab.
* **/var/lib/solnix/did-channel-init is shared**. NixOS's channel.nix keeps
  /var/lib/nixos/did-channel-init across switches too, so the channel is installed
  once per system, not once per BE.
* **var/adm/utmpx is shared** although it is runtime data. svc.startd clears the
  dead entries and writes the boot record at every boot (specials.c
  utmpx_clear_old/utmpx_write_boottime), so a copy left over from another BE is
  harmless. It sits in the same directory as wtmpx, which is history.

## Mount order

svc.startd writes /var/svc/log/*, utmpx and wtmpx as soon as filesystem/minimal
is online (startd specials.c special_fsminimal_post_online). That is before
filesystem/local's `zfs mount -va` (fs-local), so mounting there would split
every boot's early log lines between the BE and the dataset. These datasets are
mounted in the same place as `<pool>/nix`, by a stage-2 inittab line that
install-be writes right after the `nx` line:

```
vr::sysinit:/sbin/sh -c '/sbin/zfs list -H -o canmount,name -r -t filesystem <pool>/var 2>/dev/null | while read c n; do [ "$c" = noauto ] && /sbin/zfs mount -O "$n"; done; exit 0' ...
```

* `-O` (overlay): each BE keeps its own directory underneath. Without -O,
  `zfs mount` refuses a non-empty directory ("directory is not empty", measured
  on a scratch pool; libzfs_mount.c), and every BE's /var/adm is non-empty.
* `canmount=noauto`: `zfs mount -a` skips them (zfs_main.c "Ignore canmount=noauto
  mounts"), so filesystem/local never tries a plain mount and fails.
* The canmount=off containers (`<pool>/var`, `<pool>/var/svc`) fail the noauto
  test and are never mounted. svc/log mounts on the BE's own var/svc directory.
* A pool with no `<pool>/var` lists nothing and the line exits 0. The BE keeps its
  own /var, so the line is safe on every BE whether or not the datasets exist.
* The line is 212 bytes as `exec <cmd>` with pool rpool. init's limit is 512
  (init.c MAXCMDL).
* Never encrypted: nothing at that point in boot can ask for a passphrase.

## Who does what

* **scripts/solnix-install** (dataset block, after the `<pool>/nix` checks):
  creates the datasets, mounts them at `$ALTROOT/var/<x>`, and checks that each
  is noauto, at /var/<x>, and mounted. install-be's stock /var merge then lands in
  them, with the gate's owners and modes, because its ownership pass works by path.
  After install-be it checks the BE's inittab has the vr line. At finalize it
  unmounts them before the BE.
* **install-be** (step 4a): adds the vr line after nx when it is missing, and
  creates each dataset's mountpoint directory in the BE.
  `switch-to-configuration boot` needs no change: `beadm create` clones the BE
  root only; `beadm mount` without `-s` leaves the shared datasets alone
  (be_mount.c mounts them only for BE_MOUNT_FLAG_SHARED_FS), and `beadm unmount`
  unmounts only lofs mounts under the altroot (unmount_shared_fs). So install-be
  sees the clone's own directories and never the live state. It also does not lay
  the stock /var again on an existing BE (guard: `var/svc` and `etc/passwd` exist).
* **lib/make-be.nix** (images) does not create `<pool>/var`. Its BEs get the vr
  line, which finds nothing to mount, so images keep /var inside the BE. Adding
  the same dataset block there is a follow-up.
* **scripts/solnix-migrate-var**: converts an existing system. See below.

## Proof (REAL, dixi, scratch pools on file vdevs, 2026-10-09)

`/tmp/streamV1.WIP/prove.sh` (copy at dixi /var/tmp/streamV1/prove.sh). It uses
two scratch pools, `v1a` and `v1b`, each on a 2 GB file under /var/tmp/streamV1.
It runs the real install-be on the X1's generation-3 and generation-2 toplevels,
with a private store root (`sr/nix/store -> /nix/store`) so the live gcroots are
untouched. A switch is emulated as `zfs snapshot` + `zfs clone` + install-be into
the clone. A boot is emulated by unmounting everything, mounting the BE at the
altroot, and running that BE's own vr line the way init runs a sysinit entry
(`env -i ... sh -c "exec ..."`, stdin /dev/null). Six writes are made, one each
into var/adm, var/tmp, var/lib, var/svc/log, var/spool/cron/crontabs and
var/cores, and counted. Two runs, the same result each time: 16 PASS, 0 FAIL, and
1 DIFF, explained in the table (`/tmp/streamV1.WIP/prove.run1.log`,
`prove.run2.log`). This is a deterministic file-system check, not a timing one,
so two runs are enough.

| scenario | result |
|---|---|
| A: layout at HEAD (negative control), write after the clone, then boot the clone | 0/6 arrive (bug reproduced) |
| A: write in the new BE, roll back | 0/6 remain (bug reproduced) |
| B: new layout, the clone booted WITHOUT its vr line (sabotage) | 0/6 |
| B: write before the clone / after the clone, boot the clone | 6/6 / 6/6 |
| B: write in the new BE, roll back | 6/6 remain |
| B: generation subtrees follow the BE | gen-2 BE has no solnix-channel-init manifest, gen-3 BE has it; current-system per BE |
| B: /var as booted vs A (mode, uid, gid, path of every entry) | identical, except var/crash and var/lib exist (as they do on the running X1) |
| M: `solnix-migrate-var` dry run | creates nothing, edits nothing |
| M: `--apply` on pool A | 13 datasets copied (solnix:migrate=done), vr line in both BEs, old state visible, later writes shared across switch and rollback |
| M: `--revert` | vr line gone from both BEs; a1 boots on its own /var again |

Also measured: `zfs mount` without -O over a BE's non-empty var/adm fails with
"directory is not empty"; with -O it succeeds. Cleanup: `beadm list` showed the
scratch pools' BEs (a1 a2 b1 b2) next to rpool's, because libbe walks every
imported pool. The scratch pools were destroyed so that `solnix-rebuild rollback`,
which picks the previous BE from `beadm list`, could not pick one of them.

scripts/test-install-closure.sh has a `no-vr` negative control: an install-be
whose inittab lacks the vr line is refused.

PLANNED (not yet run): a real install and boot with this layout (KVM or the X1),
and `svcs -x` on that first boot.

## Migrating an existing system (the X1)

`scripts/solnix-migrate-var` is the maintainer's to run. A dry run is the default.

```
pfexec sh scripts/solnix-migrate-var            # dry run: lists every step
pfexec sh scripts/solnix-migrate-var --apply    # then reboot right away
pfexec sh scripts/solnix-migrate-var --revert   # undo: the vr line out of every BE
```

`--apply` creates `<pool>/var/<x>` under a staging mountpoint, copies the running
BE's /var/<x> in with tar (owners, modes, links, mtimes; sockets are not archived),
checks the entry count, sets `solnix:migrate=done`, and gives the dataset its real
mountpoint, unmounted. It then adds the vr line to every BE's inittab: the running
BE in place, each other BE through `beadm mount` (only BEs on the same pool). It
deletes nothing. Each BE keeps its own /var/<x> under the mount, which is why
`--revert` is enough to go back. That holds for a migrated system only. On a
fresh install the stock /var went straight into the datasets, and the BE's own
directories under them are empty mountpoints, so a fresh install has nothing to
revert to. A re-run skips datasets marked done and refuses
one that is not marked (an interrupted copy).

Read-only dry run on the X1 as gburd (`/tmp/streamV1.WIP/migrate-dryrun-dixi.txt`):
13 datasets, /var/tmp at 2.8 GB is the largest copy, and BEs solnix-1 and solnix-2
would get the vr line. Stop the builds in /var/tmp before --apply: anything
written to /var after the copy and before the reboot goes to the running BE's own
copy, which is the same window this change removes for later switches.
