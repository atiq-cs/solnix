# The first REAL solnix install, and the independent boot that proves it

x86_64, on EC2 (`bene`, us-east-2). Everything below was run on real EC2 instances, not QEMU.

## Verdict

| # | Brief step | Result |
|---|---|---|
| 1 | Build the ISO | **DONE** — but it emits a *staging tree + tarball*, not an `.iso`. rc=0 in **4m50s**. |
| 2 | Boot that ISO on a fresh instance, reach the installer | **NOT ATTEMPTED** — deliberately. Option (b) was taken instead; see "Why option (b)". |
| 3 | One REAL, destructive install onto a second blank volume | **DONE** — rc=0 in **74 s**, `SOLNIX_INSTALLER_DRYRUN` not involved (`solnix-install` run directly). |
| 4 | Reboot into the installed system and prove it works | **DONE — boots, root login, and `nix` runs.** |

The headline: **a second, fresh EC2 instance booted off the volume the installer wrote, root
logs in, and `nix` runs on it.** All four acceptance criteria are met. It took two rounds: the
first install booted but had no `nix`; the second closed that gap and needed **no code change**
(see "Round 2").

## Two rounds, and why

| | round 1 | round 2 |
|---|---|---|
| build host had nix? | no | yes (bootstrapped) |
| install path taken | `SELF_INSTALL=1` | `SELF_INSTALL=1` (still) |
| install rc | 0 | 0 |
| fresh instance booted? | yes | yes |
| root login? | yes | yes |
| **`nix` runs?** | **no — `/nix` empty** | **yes — Nix 2.24.15** |
| proof instance | `i-07962a79c5d5c8e36` | `i-00ab42b97fb9ce336` |

## The premise needed correcting first

The brief said a real install "has never been exercised." The repo claims the *opposite*, and
its evidence does not exist:

- `artifacts/install-media/README.md` line 3: "minimal ISO — VERIFIED (full install + disk
  boot to console login, 2026-07-30)", and `docs/progress.md` says the same.
- The log both cite as proof,
  `artifacts/install-media/boot-logs/x86_64-minimal-diskboot-VERIFIED-console-login.log`,
  **is not on disk and not in git.** `find / -name '*diskboot-VERIFIED*'` returns nothing.
- The newest disk-boot log that *does* exist,
  `artifacts/install-media/boot-logs/x86_64-minimal-diskboot-multiuser.log`, ends in an
  endless spin of the exact symptom the claimed fix was supposed to cure:
  ```
  svc.startd[304]: makeutx failed, retrying: No such file or directory
  SAC: could not open logfile /var/saf/_log: No such file or directory
  instance svc:/system/sac:default exited with status 1
  ```
  i.e. **no console login.**
- Every one of those runs was QEMU on the dev box, never EC2, and none of the
  `boot-logs/*minimal*` files are git-tracked (only the 6 graphical ones are).

So "install verified" was unproven, and the README was actively wrong. It is now proven on
EC2 — by this run, not by that claim. **Fix `README.md` line 3 or delete the citation.**

## Why option (b), not booting the ISO

The brief offered (a) dd the ISO to a volume and boot it, or (b) install from a running system
to a blank second volume, then boot that volume on a new instance. Took **(b)**, for the
reason the brief itself gives: it is the decisive test of "the installed system boots," and it
skips the awkward part (EC2 will not boot an El Torito ISO without an assembler step that
`oi-make-livecd.sh` does not even perform — see below). (b) also exercises the *same*
`solnix-install` code path the live media would run, so nothing about the installer is
untested by this choice. What (b) does **not** cover: the live media's own boot, and the
installer's interactive/TUI front-end.

## Step 1 — what `oi-make-livecd.sh` actually emits

Run as root on the build host, from a clean `ami-014c4aaccd37b2356`:

```sh
/usr/bin/bash /var/tmp/oi-make-livecd.sh      # rc=0
```

**4m50.57s real** (0m38s user, 0m18s sys) on a c5.4xlarge (16 vCPU, 31.8 GB RAM).
Started 13:24:28Z, finished 13:29:19Z. Output in `/var/tmp/solnix-media/`:

| file | size | what |
|------|------|------|
| `boot_archive` | 859,832,320 B | the raw 820 MB UFS live-root image (staging) |
| `boot_archive.gz` | 91,905,142 B | gzipped; the loader auto-inflates |
| `solnix-iso-tree.tar.gz` | 90,934,152 B | 86.8 MB — the tree, to ship to the assembler |
| `iso/` | 90.5 MB | the ISO **staging tree** |
| `loader64.efi` | 636,928 B | copied out for the ESP |
| `cdboot` | 1,249 B | BIOS El Torito boot image |

It pre-imported **156 SMF manifests** into the live `repository.db`.

**Correction to the brief's wording:** this script does *not* produce an ISO. It produces a
staging tree plus a tarball; a separate assembler (`scripts/make-iso-usb.sh`, which needs
`xorriso` and runs off-node) wraps that into the hybrid BIOS+UEFI ISO. Anyone expecting
`*.iso` from this script will not find one.

## Step 3 — the real, destructive install

```sh
SOLNIX_POOL=spool SOLNIX_BE=solnix-1 /var/tmp/solnix-install c2t1d0
# INSTALL-RC=0, 13:33:49Z -> 13:35:03Z (~74 s)
```

**The brief's literal command line cannot work.** It says to run
`SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 solnix-install c1t1d0 <toplevel>`. From a *running*
ZFS-root host that dies immediately on `solnix-install`'s own guard:

```sh
[ "$POOL" = "$ROOTPOOL" ] && die "target pool '$POOL' == the RUNNING root pool; ..."
```

On the base AMI `ROOTPOOL` **is** `rpool`. That command line is only valid from the live UFS
ramdisk, where the script deliberately leaves `ROOTPOOL` empty (there is no ZFS `/` to
protect). From a running host the target pool must be named something else — hence
`SOLNIX_POOL=spool`. The name is not load-bearing for boot: the loader follows the pool's
`bootfs` property, which is why the installed system boots from `spool` just fine.

Every step completed (full log: `/var/tmp/install-real.log` on the build host, copy at
`/tmp/install-real-artifacts/install-real.log`):

```
GPT label -> fmthard s0 ESP @256+524288 / s1 pool @524544+62373599 / s8 resv @62898143+16384
mkfs pcfs ESP -> "ESP fstyp: pcfs"
zpool create spool on c2t1d0s1 -> BE spool/ROOT/solnix-1
tar|tar root copy -> keep pre-imported repository.db (not the minimal global.db)
boot_archive built (CPIO + gzip)
loader64.efi -> ESP EFI/Boot/bootx64.efi
installboot pmbr+gptzfsboot on c2t1d0s1:
  "bootblock written for /dev/rdsk/c2t1d0s1, 280 sectors starting at 1024 (abs 525568)"
  "stage1 written to slice 1 sector 0 (abs 524544)"
zpool set bootfs -> export
```

Host left clean afterwards: `zpool list` shows **only** `rpool` (the target pool was
exported, not left imported — the state that wedged an earlier run), and zero mounts under
`/a`.

## Step 4 — the independent boot (the finish line)

Chain, with the hazards respected at each step:

```
build host i-0d82d4ba6b12617e0
  -> blank vol-0b6cde62e30e116f0 attached as /dev/sdf, enumerated as c2t1d0
  -> solnix-install writes it (rc=0)
  -> ec2 stop-instances  (see hazard note)
  -> snap-04d431a724a315efb   (snapshot of the DETACHED volume)
  -> ami-069ad5a9c0fb88947    (x86_64, /dev/xvda, hvm, boot-mode uefi, ena-support)
  -> FRESH instance i-07962a79c5d5c8e36 (c5.large)
```

That instance shares nothing with the build host except the volume the installer wrote.

**Captured console log: `/tmp/install-real-artifacts/bootproof-console-FULL.log`** (228 lines,
via `aws ec2 get-console-output --latest`, the only safe console read). Proving lines:

```
L12   Setting currdev to zfs:spool/ROOT/solnix-1:      <- loader found the installed BE
L31   Loading /platform/i86pc/kernel/amd64/unix...
L32   Loading /platform/i86pc/amd64/boot_archive...    <- the archive the installer built
L191  root on spool/ROOT/solnix-1 fstype zfs           <- ZFS root mounted from the pool
L226  unknown console login:                           <- console login prompt reached
```

Counters for the symptoms that killed the earlier QEMU attempt — all now zero:

| check | count |
|-------|-------|
| `makeutx failed` | **0** (the old log spun on this forever) |
| `could not open logfile` | **0** |
| `console login:` | **1** |

Root login verified over ssh:

```
id        -> uid=0(root) gid=0(root)
uname -a  -> SunOS 5.11 illumos-68259130da i86pc
zpool list-> spool 29.5G ONLINE        (only spool; it imported its own pool)
df -h /   -> spool/ROOT/solnix-1 on /
zpool get bootfs spool -> spool/ROOT/solnix-1 (local)
zfs list  -> spool/ROOT/solnix-1 mountpoint=/ canmount=noauto   (correct BE layout)
```

`/etc/solnix-release` on the booted system:

```
NAME="The Solnix Operating System"
solnix system (installed by solnix-install)
installed: 2026-09-08T13:34:45Z
toplevel:  <self-install: live root>
target:    c2t1d0 pool spool BE spool/ROOT/solnix-1
```

## The Gap in round 1 — `nix` did not run, and exactly why

On round 1, `/nix` on the booted system was an **empty directory** and
`command -v nix nix-store nix-env` found nothing. Not a regression, not an installer bug. The
mechanism was observed, not inferred:

1. The base AMI `ami-014c4aaccd37b2356` has **no `/nix/store` and no `/run-current-system`**.
2. So `solnix-install` took its **SELF_INSTALL** path and faithfully copied a nix-less root.
3. The entire nix half — closure copy, Stage-A userland, generation-1 registration,
   `.solnix-registration` DB dump — lives in the `SELF_INSTALL=0` branch and was skipped
   **by design**. The script says so three times in its own log:
   ```
   SELF-INSTALL: skipping nix-closure copy (the copied live root IS the system)
   SELF-INSTALL: skipping toplevel manifest/etc staging
   SELF-INSTALL: skipping generation/switch-tool registration (no nix toplevel)
   ```
4. It is structural, not incidental: `solnix-install:309` *always* excludes `./nix` from the
   root copy, on the stated assumption that the closure step will put it back. Under
   SELF_INSTALL that step never runs, so a SELF_INSTALL'd system **cannot** have nix
   — as long as nix lives under `/nix`.

## Round 2 — closing it, with no code change

That last clause is the whole fix. The repo's own bootstrap
(`scripts/oi-fleet-bootstrap.sh`) installs Nix 2.24.15 to **`/nix-tools224`** — a relocatable
tree *outside* `/nix`. And `/nix` is the only nix-related path the root copy excludes.
So: bootstrap nix onto the build host, then re-run **the same install command, unchanged**, and
nix rides along in the ordinary `tar | tar` root copy.

```sh
bash /var/tmp/nixboot-only.sh                    # Nix 2.24.15 -> /nix-tools224
SOLNIX_POOL=spool SOLNIX_BE=solnix-1 /var/tmp/solnix-install c2t1d0    # rc=0, unchanged
```

On the resulting **third fresh instance** (`i-00ab42b97fb9ce336`, from `ami-0ccb0e0bae4033e27`,
whose only content is the round-2 volume), console log
`/tmp/install-real-artifacts/bootproof2-console-FULL.log`:

```
L12   Setting currdev to zfs:spool/ROOT/solnix-1:
L191  root on spool/ROOT/solnix-1 fstype zfs
L226  unknown console login:
```

and on that booted system:

```
nix --version        -> nix (Nix) 2.24.15
nix-store --version  -> nix-store (Nix) 2.24.15
nix-store --add /tmp/proof.txt
                     -> /nix/store/ivvy0lhnirqph57qlcnffmjyiqzcm87n-proof.txt
df -h /              -> spool/ROOT/solnix-1
/etc/solnix-release  -> installed: 2026-09-08T14:27:34Z
```

That store write is a **real** operation on the installed system, not a version banner:
`/nix/store` went from empty to containing the added path.

**Tagging, per the brief:** the ZFS-BE install, the independent boot, root login, and `nix`
running are all **REAL**. What is still **untested** is the *declarative* path proper
(`SELF_INSTALL=0`: a nix-built toplevel, closure copy, generation-1 registration,
`switch-to-configuration`). Round 2 proves nix *runs on the installed system*; it does not
prove the system was *built declaratively from a config*. Those are different claims and only
the first is now evidenced.

### One nuance about `nix` on `PATH`

`ssh host 'nix --version'` (a non-login shell) reports `command not found`. This is not a
failure of the install; the mechanism was observed:

- `/etc/profile` gates its `profile.d` loop on `case "$0" in -sh | -ksh | -bash | ...)` — i.e.
  **only a real login shell**, whose `argv[0]` starts with `-`.
- Proven both directions on the booted system:
  ```
  bash -lc 'command -v nix'                        -> NOT-ON-PATH   (bash -l keeps argv0=bash)
  exec -a -bash /usr/bin/bash -c 'command -v nix'  -> /nix-tools224/bin/nix    <- works
  ```
  A real console or interactive-ssh login does `exec` with `argv[0]=-bash`, so it *does* get nix.
- Invoking `/nix-tools224/bin/nix` directly without the profile fails on
  `libboost_context.so.1.78.0`, because the bootstrap nix needs
  `LD_LIBRARY_PATH=/nix-tools224/runtime-lib`. `oi-fleet-bootstrap.sh` documents exactly this:
  the transitive libs carry build-host RUNPATHs. A bootstrap-tool limitation, not an install
  defect (final nix-built closures are host-free).

## Negative controls

`COMMON.md` requires that every check be shown capable of failing. Both were.

**1. The boot pass-criteria, against a known-FAIL log.** Run the same greps over the old QEMU
failure log `artifacts/install-media/boot-logs/x86_64-minimal-diskboot-multiuser.log`:

| log | `console login:` | `makeutx failed` | verdict |
|-----|---|---|---|
| old QEMU log (known FAIL) | 0 | **129** | correctly FAIL |
| round-1 boot proof | 1 | 0 | PASS |
| round-2 boot proof | 1 | 0 | PASS |

**2. The `nix` check, by sabotaging the mechanism** on the booted system:

```
mv /nix-tools224/runtime-lib aside; nix --version
  -> ld.so.1: nix: fatal: libstdc++.so.6: open failed    <- check FLIPS TO FAIL
restore;                            nix --version
  -> nix (Nix) 2.24.15                                   <- back to PASS
```

## Bugs found, fixed on disk, NOT committed

### 1. `oi-make-livecd.sh` created ZERO of the live ramdisk's `/dev` symlinks (REAL, fixed)

`scripts/oi-make-livecd.sh:393` was:

```sh
[ -L "/dev/$n" ] && ln -sf "$(/usr/bin/readlink /dev/$n)" "$RDROOT/dev/$n" 2>/dev/null || true
```

**illumos has no `readlink(1)`.** Confirmed absent from `/usr/bin`, `/usr/gnu/bin`, and
`/bin`. So the command substitution expanded to the empty string, `ln -sf "" ...` did nothing,
and the error was swallowed by `2>/dev/null || true`. It appeared **12 times** in the build
log:

```
/var/tmp/oi-make-livecd.sh: line 389: /usr/bin/readlink: No such file or directory
```

Effect: the live ramdisk got **none** of
`/dev/{console,msglog,null,zero,tty,syscon,systty,sysmsg,random,urandom,poll,dld,dlpi}` — the
exact nodes the code's own comment calls load-bearing for `svc.startd` stdio and `dlmgmtd`
(without `dld`, the comment notes, ~52 dependent services go to maintenance). A pure
silent-failure bug.

Fixed using the `ls -ld | sed -n 's/.* -> //p'` idiom `solnix-install` already uses
(`_readlink`), plus `rm`+`ln` because illumos `ln -sfn` follows an existing symlink-to-dir.
**This is exactly the class of gotcha `COMMON.md` warns about.** Note the ISO measured above
was built from the *pre-fix* copy, so the timing stands but a rebuild should be done to
confirm the ramdisk now carries those nodes.

### 2. `solnix-install`'s boot_archive size check is dead code on this image (REAL, not fixed)

`ba_ok()` and the success log line use GNU `stat -c %s`. This illumos image has **no `stat(1)`
at all** (`stat: command not found`), which is why step 9 printed:

```
=== boot_archive OK:  bytes, ... gzip compressed data ... ===
```

with an empty byte count. Harmless for the log line, but it means the size half of the
validity check silently evaluates as 0 — only the `gzip -t` half actually validated the
archive. Left unfixed deliberately: `gzip -t` is the stronger check and did its job; "capture
the next blocker rather than chain a second fix." Fix by using `ls -l` or `wc -c`.

### 3. `oi-fleet-bootstrap.sh` installs nix into a BE that the next reboot discards (REAL, worked around)

`scripts/oi-fleet-bootstrap.sh` runs `pkg update --accept` **first**, then installs nix. On this
AMI that `pkg update` **creates a new boot environment**:

```
beadm list
  7f4803ff                -   -   1.82G   2025-10-28 16:25
  openindiana-2026:09:08  NR  /   3.24G   2026-09-08 14:05     <- new, now active
```

Nix is installed into the *still-running old* BE, so the **next reboot activates the new BE and
nix vanishes.** Observed exactly that: `/nix-tools224` present, reboot, `/nix-tools224: No such
file or directory`. Since illumos requires a reboot to enumerate a hot-attached EBS volume,
this is guaranteed to bite the install workflow specifically.

Worked around with a nix-only slice (no `pkg update`), left at
`/tmp/install-real-artifacts/nixboot-only.sh`. **Not** fixed in the repo script — the proper fix
is to drop the `pkg update`, or install nix *after* activating the new BE.

## Hazards, and how each was handled

- **Never live-fdisk a mounted zpool slice** — never done. The install target was a
  *separate* 30 GiB volume (`vol-0b6cde62e30e116f0` -> `c2t1d0`); the mounted `rpool` on
  `c1t1d0` was never touched. `solnix-install`'s own guards (`TARGET` = `ROOTDISK`,
  `POOL` = `ROOTPOOL`) were both left armed.
- **Never `create-image` a running instance** — never done. Snapshotted the **detached
  volume** instead, then `register-image` from that snapshot.
- **Never `zpool import` / `format` / chained disk probes over ssh** — never done. Every
  disk probe and both long jobs were `nohup`'d on-node writing to a logfile, polled with
  separate short `timeout -s KILL … setsid ssh` reads.
- **`get-console-output --latest` was the only console read.**
- **A hazard the brief did not list, worth adding:** illumos does **not** hot-plug an
  EBS NVMe volume. After `attach-volume`, `diskinfo` still showed only `c1t1d0`; `cfgadm`
  reports "Configuration administration not supported". An `ec2 reboot-instances` was
  required before `c2t1d0` appeared. Related: `detach-volume` on the live instance returned
  `Attachments[0].State="busy"` and never released — the clean path was
  `ec2 stop-instances`, after which the volume went to `available` on its own.
- **No security-group rule was added or needed** (`sg-07689ce3114d45ec9` already allowed 22
  from the operator /24). Nothing to revoke.

## What the brief got right

The hypothesis that an installed system needs the three fixes from
`docs/base-ami-rebuild-runbook.md` is **correct, and already satisfied on this path** — for a
reason worth recording. The base AMI already carries all three:

- `/etc/system:116` — `set pit_is_broken = 1`
- `/etc/system.d/solnix-nitro-pit` and `/etc/system.d/.self-assembly`
- 9 `pit_is_broken` hits **inside** the gzip'd `boot_archive` (read offline via
  `gzcat | strings`, never by RW-mounting an illumos ZFS root)

Because SELF_INSTALL copies the running root wholesale, the installed system inherits all
three for free. That is very likely *why* this boot worked on the first attempt. A
`SELF_INSTALL=0` (declarative) install would need them verified separately — its root does
**not** come from a copy of a known-good booting system.

## To finish this, do X

1. **Fix the false claim.** `artifacts/install-media/README.md` line 3 cites a proof file
   that does not exist. Either point it at
   `/tmp/install-real-artifacts/bootproof2-console-FULL.log` (committed somewhere durable) or
   delete the claim. Same for the `docs/progress.md` 2026-07-30 entry.
2. **Prove the *declarative* path** — the one thing still untested. Round 2 proves nix runs on
   the installed system, but via the bootstrap tree, not a nix-built toplevel. For
   `SELF_INSTALL=0`: build a toplevel with
   `nix-build -A solnixConfigurations.base.config.system.build.toplevel`, then
   `solnix-install c2t1d0 <toplevel>` and re-do the boot proof. That is what exercises the
   closure copy, Stage-A userland, generation-1 registration and `switch-to-configuration`.
3. **Rebuild the ISO tree with the `readlink` fix** and confirm the live ramdisk now has the
   13 `/dev` nodes (`ls -l $RDROOT/dev/` should show all of them, not zero).
4. **Then, and only then, attempt brief step 2** (boot the media itself). It needs the
   `xorriso` assembler step, which is a separate script and does not run on the illumos build
   host.
5. **Replace `stat -c %s`** in `solnix-install` with `ls -l`/`wc -c` so the size half of
   `ba_ok()` is live rather than silently zero.
6. **Fix `oi-fleet-bootstrap.sh`'s BE ordering** (finding 3) so a bootstrapped nix survives the
   first reboot.
7. **Consider putting nix on the default `PATH`** independent of `$0`, if `nix` is meant to work
   in non-login shells (e.g. `ssh host 'nix ...'`, scripts, SMF methods) — today it only
   resolves in a true login shell.

## Reproduce

```sh
# build host: ami-014c4aaccd37b2356, c5.4xlarge, 200 GiB root, keypair solnix-key,
#             SG sg-07689ce3114d45ec9, subnet-0bfe4b750cdc33c45 (us-east-2a)
# target:     a SEPARATE blank 30 GiB gp3 volume attached as /dev/sdf
#             -> REBOOT the instance so illumos enumerates it as c2t1d0
scp scripts/oi-make-livecd.sh scripts/solnix-install root@<host>:/var/tmp/
ssh root@<host> 'nohup bash /var/tmp/oi-make-livecd.sh > /var/tmp/livecd-build.log 2>&1 &'
ssh root@<host> 'nohup sh -c "SOLNIX_POOL=spool SOLNIX_BE=solnix-1 \
    /var/tmp/solnix-install c2t1d0" > /var/tmp/install-real.log 2>&1 &'
# then: stop-instances -> create-snapshot (detached vol) -> register-image
#       (--boot-mode uefi --ena-support --root-device-name /dev/xvda)
#       -> run-instances -> get-console-output --latest
```

## Resources (all terminated / deleted at end of run)

| kind | id | note |
|------|----|------|
| build host | `i-0d82d4ba6b12617e0` | c5.4xlarge, 200 GiB root |
| install target volume | `vol-0b6cde62e30e116f0` | 30 GiB gp3, became `c2t1d0`; used for both rounds |
| snapshot (round 1) | `snap-04d431a724a315efb` | of the **detached** volume |
| AMI (round 1) | `ami-069ad5a9c0fb88947` | uefi + ena; boots, root login, no nix |
| boot proof (round 1) | `i-07962a79c5d5c8e36` | c5.large — booted to console login |
| snapshot (round 2) | `snap-00fcdd4770e1f0a00` | of the **detached** volume, with nix |
| AMI (round 2) | `ami-0ccb0e0bae4033e27` | uefi + ena |
| **boot proof (round 2)** | `i-00ab42b97fb9ce336` | **c5.large — booted, root login, `nix` runs** |

## Artifacts

| path | what |
|------|------|
| `/tmp/install-real-artifacts/bootproof2-console-FULL.log` | **the finish-line console capture** (round 2) |
| `/tmp/install-real-artifacts/bootproof-console-FULL.log` | round-1 boot console |
| `/tmp/install-real-artifacts/install-real.log` | round-1 install log (rc=0) |
| `/tmp/install-real-artifacts/install-real2.log` | round-2 install log (rc=0) |
| `/tmp/install-real-artifacts/livecd-build.log` | ISO build log (rc=0, 4m50s) |
| `/tmp/install-real-artifacts/nixboot-only.sh` | the nix-only bootstrap (finding 3 workaround) |
| `/home/gburd/ws/solnix/scripts/oi-make-livecd.sh` | the `readlink` fix (uncommitted) |
