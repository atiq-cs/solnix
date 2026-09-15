# Slicing the gate proto into real derivations — what was measured

Step 2 of `docs/design-nixos-iso-methodology.md` §"Order of work". Step 1
(`docs/gate-fod-findings.md`) made the gate a building derivation; this makes its
contents into *components*, so a toplevel can contain `df`, `useradd`, `reboot` and
`zpool` as store paths instead of hand-copied files.

Measured on `ami-0cb14e40f9355bd0c` (`i-04a21505aa38b3ef4`, m5.4xlarge, Nix 2.24.15,
`sandbox = false`, `system = x86_64-solaris`), against the step-1 proto re-fetched from
R2 — 219,678,907 B gzip, unpacking to the *original store path name* with `unix`
2,616,328 B, `genunix` 6,034,616 B and `libc.so.1` 2,013,192 B, all matching
`gate-fod-findings.md` exactly.

## 1. The headline: the proto slices, and the closure is COMPUTED

Six derivations, each built, each with a resolving deriver:

| slice | store path | size | bins | libs **computed** |
|---|---|---|---|---|
| `illumos-core-utils` | `/nix/store/i9bb35gnz7wyd9szh117si0003z20588-…` | 11,449 KB | 68 | **85** |
| `illumos-oamuser` | `/nix/store/h47sv60x7rc9iqaqymkxsyakf7dbi852-…` | 4,106 KB | 12 | **43** |
| `illumos-halt` | `/nix/store/b8ysxcfvhi71pi57w05zn5j7khi83r6h-…` | 3,787 KB | 2 | **44** |
| `illumos-smf` | `/nix/store/p6v1m44539smidn4jpha0xykpybs3lc7-…` | 8,458 KB | 7 | **56** |
| `illumos-zfs` | `/nix/store/pmfwyvjg9q2f6pl1w1vnqxj7b216v0cg-…` | 9,239 KB | 8 | **85** |
| `illumos-kernel` | `/nix/store/n8a07r4xrrmw05yg4dx70diyj38ky1y8-…` | 65,640 KB | 0 | 0 |

Total **102,679 KB = 105,143,296 B**, which is **12.9 %** of the 816,119,808 B ramdisk
ceiling. Size is not a constraint at this stage.

`illumos-kernel` has no computed closure and that is a real difference rather than a
gap: kernel objects are not userland ELF. They carry no `DT_NEEDED`, no `SONAME` and no
`RUNPATH` — module dependencies resolve through the kernel's own loader from
`depends_on`, not through `ld.so.1`. So they are copied verbatim (`cp -a`, which also
preserves the `.SUNW_ctf` sections `mdb`/`dtrace` need).

### How the closure is determined

`pkgs/illumos/mk-proto-slice.nix` takes **binaries**, not libraries. In the builder it
BFSes `elfdump -d` output, resolving each `DT_NEEDED` soname in the **ABI-matching**
directories only — 32-bit objects from `lib/`+`usr/lib/`, 64-bit from
`lib/amd64/`+`usr/lib/amd64/` — with the ELF class read from `e_ident[EI_CLASS]` rather
than guessed from the path. Any soname that resolves nowhere is a **build failure**
unless the caller declares it in `allowUnresolved`.

`elfdump`, deliberately, not `ldd`: `ldd` runs the loader against the *host's* `/lib` and
would report what the build host happens to have. `ldd` is used later, as an exec-time
check on the built slice, which answers a different question.

This is the difference from the existing `mkIllumosComponent`, whose `base-tools` caller
carries 60 sonames pasted in by hand with the comment *"Re-run that script if the tool
set changes; paste the result here."* Every image failure this campaign was one entry
missing from one such list.

**It caught three of my own errors within minutes**, none of which I would have found by
reading:

* `usr/bin/mount` does not exist in the proto (only `sbin/`, `usr/sbin/`, and the
  per-filesystem helpers under `etc/fs/<fstype>/`);
* `passmgmt` is at `usr/lib/passmgmt`, not `usr/sbin/passmgmt`;
* **`bash` is not in illumos-gate at all** — `find` over the whole proto returns nothing.
  It is an OpenIndiana *package*. `configurations/dixi.nix` had `shell = "/bin/bash"`.

## 2. ⚠️ The proto is NOT self-contained — the finding that changes the roadmap

**52 of the 260 distinct sonames the proto's own userland `DT_NEEDED`s resolve nowhere
inside the proto** (`scripts/proto-external-audit.sh`). By direct-reference count:

```
36 libdbus-1.so.3     29 libxml2.so.16    22 libglib-2.0.so.0
12 libz.so.1          10 libstdc++.so.6   10 libgcc_s.so.1
 9 libdbus-glib-1.so.2 6 libcrypto.so.1.0.0  5 libnetsnmp.so.40
```

illumos-gate does not vendor these; IPS satisfies them from separate packages at install
time. That is precisely the *"circular build-time relationships that `pkg` papers over"*
the task anticipated — except it is not circularity, it is **an unstated external
dependency set**.

The load-bearing one is **`libxml2.so.16`, and it is currently unsatisfiable**:

* the build AMI ships `libxml2.so.2` (`library/libxml2` 2.13.9);
* `pkg install library/libxml2@2.15.4` is **rejected** by
  `userland-incorporation@0.5.11-2025.0.0.31598` — the same mechanism as the gate
  prereqs in `gate-fod-findings.md` §5.3;
* the published solnix cache has libxml2 2.9.14 and 2.12.9 for x86_64-solaris — **both
  soname `.so.2`**.

The soname arithmetic is structural, not packaging drift. libxml2 2.13.0 computes
`LIBXML_VERSION_INFO` as `(major+minor):micro:minor`, giving `CURRENT=15 AGE=13`, so
libtool emits `current-age` = **`.so.2`**. 2.14.0 introduces `LIBXML_MINOR_COMPAT=14`
with `AGE = minor - minor_compat`, giving `CURRENT=16 AGE=0` and therefore **`.so.16`**.
That is a deliberate upstream compat reset, so **no 2.13.x build can ever satisfy
`.so.16`**, wherever it comes from.

> **`libxml2 >= 2.14` must exist as a real derivation before a fully self-resolving core
> userland is possible.** `docs/design-nixos-iso-methodology.md` sequences FOD → slice →
> closure-built ramdisk → `--flake` install and **mentions no userland library
> prerequisite at all**. This one was found only by measuring `DT_NEEDED` across the
> whole proto instead of assuming the proto was self-contained.

### Which binaries carry the external edge, and by what chain

Traced with `scripts/whyneeded.sh`, which prints the actual chain:

```
STACK 1 — libpool's XML dependency:
  usr/bin/id       -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
  usr/bin/ps       -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
  sbin/ifconfig    -> libdladm.so.1   -> libpool.so.1 -> libxml2.so.16
  usr/sbin/useradd -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
  usr/sbin/usermod -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
  usr/sbin/halt    -> libbe.so.1 -> libinstzones.so.1 -> libzonecfg.so.1 -> libxml2.so.16
  usr/sbin/svccfg  -> libxml2.so.16  DIRECTLY

STACK 2 — NSS/NSPR, via the name-service switch:
  usr/bin/passwd -> passwdutil.so.1 -> libsldap.so.1 -> libldap.so.5 -> libnss3.so
                    (plus libnspr4.so, libplc4.so, libssl3.so)
```

**I declared `illumos-oamuser` and `illumos-halt` closure-complete and was wrong about
both.** The gate refused to build them. The comment claiming "measured: clean" was
reasoning dressed as measurement — worth recording because it is easy to repeat.

## 3. REAL vs declared-external, per slice

This table decides what step 4 can ship.

| slice | tools that RUN with a fully store-resident closure | tools carrying an external edge |
|---|---|---|
| `illumos-core-utils` | **65 of 68** — `df`, `ls`, `cat`, `cp`, `mv`, `rm`, `ln`, `mkdir`, `chmod`, `chown`, `du`, `dd`, `sed`, `grep`, `head`, `tail`, `sort`, `tr`, `cut`, `wc`, `awk`/`nawk`, `find`, `tar`, `cpio`, `date`, `uname`, `mount`/`umount`, `sh`, `ksh93` … | `id`, `ps`, `ifconfig` (libpool→libxml2) |
| `illumos-oamuser` | `userdel`, `groupadd`, `groupmod`, `groupdel`, `pwconv`, `passmgmt`, `roleadd`/`rolemod`/`roledel` | `useradd`, `usermod` (libpool→libxml2); `passwd` (NSS/LDAP) |
| `illumos-halt` | `sbin/uadmin` — the raw syscall wrapper, **fully clean** | `halt`/`reboot`/`poweroff` (libbe→libzonecfg→libxml2), `shutdown` |
| `illumos-smf` | `svcadm`, `svcs`, `svcprop`, `svc.startd`, `svc.configd`, `init` | **`svccfg`** — needs `libxml2.so.16` directly |
| `illumos-zfs` | `zpool`, `zfs`, `zdb`, `zstreamdump`, `beadm` — **all clean** | `devfsadm`, `format` (libpool→libxml2) |
| `illumos-kernel` | `unix`, `genunix`, the driver trees (no `DT_NEEDED`) | — |

**The practical consequence is good news for step 4:** a media that boots and installs
needs `df`, `zpool`/`zfs`, `beadm` and the coreutils, and every one of those is clean.
`useradd` and `halt` work *on a host that has some libxml2* (see §5) but are not
self-contained. Only `svccfg` is hard-blocked. **The first closure-built ramdisk does
not have to wait for libxml2.**

## 4. What actually RUNS — and the three claims kept separate

A file existing, a symlink resolving, and a binary *running* are different claims;
conflating them cost this project four image bugs. `scripts/slice-exec-test.sh` reports
each separately.

```
core-utils  EXISTS 68/68   EXEC 68/68   FAILED 0
oamuser     EXISTS 12/12   EXEC 12/12   FAILED 0
halt        EXISTS  2/2    EXEC  2/2    FAILED 0
zfs         EXISTS  8/8    EXEC  8/8    FAILED 0
smf         EXISTS  7/7    EXEC  6/7    FAILED 1
   usr/sbin/svccfg: ld.so.1: svccfg: fatal: libxml2.so.16: open failed
```

That failure is the §2 prediction **observed**, and it is independent evidence the exec
test can report failure.

The three binaries the task named, doing real work out of the store:

```
$ df -n /                 →  /  : zfs
$ df -k /                 →  rpool/ROOT/7f4803ff  304360908 blocks … 2%  /
$ useradd -D              →  group=other,1  project=default,3  basedir=/home
                             skel=/etc/skel  shell=/bin/sh  inactive=0
```

**`halt`/`reboot`/`poweroff` are one inode with three names**, as `cmd/halt/Makefile`'s
`ROOTLINKS` and `halt.c`'s `argv[0]` dispatch require. The derivation *asserts* the
shared inode (192206 in this build) rather than trusting the copy, and the dispatch
proves itself:

```
reboot   -> usage: reboot [ -dlnq(p|fe:) ] [ boot args ]
halt     -> usage: halt [ -dlnqy ]
poweroff -> usage: poweroff [ -dlnqy ]
```

Different usage strings from the same inode. Image `l2` shipped **no `reboot` at all**
because its staging loop used `[ -e ] &&`, which skips silently; a derivation cannot —
a missing hardlink-group head is fatal.

## 5. ⚠️ An exec test on the build host CANNOT prove a closure is complete

The obvious negative control — delete a library from a built slice, re-run the exec test
— **cannot work on illumos**, and finding out why is worth more than the control was.

First attempt: copy the slice, delete `libcmdutils.so.1`, re-test → **zero failures**.
Not a test bug. `mk-proto-slice` bakes *absolute* `$out` RUNPATHs, so the copy resolved
its libraries out of the **original** store path. `ldd` on the sabotaged copy proved it:
byte-identical resolution to the intact slice.

Second attempt, with the copy's RUNPATH repointed at its own broken lib dirs → **still
zero failures**, and *this* is the real finding: **illumos `ld.so.1` falls back to the
host default search path (`/lib`, `/usr/lib`) once the RUNPATH is exhausted.** A library
missing from a slice is silently supplied by the build host, and the binary runs
perfectly.

So the completeness claim has to be enforced where it is actually decided — in the
derivation, at build time. `scripts/slice-closure-negative-control.sh`:

```
control 1 NEG  unresolvable soname, allowUnresolved empty  -> BUILD FAILS      PASS
control 2 POS  same slice, soname declared external        -> BUILD SUCCEEDS   PASS
control 3 NEG  bins entry absent from the proto            -> BUILD FAILS      PASS
control 4 NEG  hardlink group head absent                  -> BUILD FAILS      PASS
                                                          4 passed, 0 failed
```

Control 2 is load-bearing: without a positive control the suite could "pass" by
rejecting everything — the exact shape of the `od` zero-padding bug in
`gate-fod-findings.md` §6.3, where 4 of 5 controls passed while the *positive* one was
the broken one.

**Host-leak attribution.** `illumos-core-utils` shows 4 host-`/lib` resolutions. Traced
with `ldd -v`, every one is downstream of a declared external: `libzfs.so.1` needs
`libz.so.1`, which is not in the proto, so it comes from host `/usr/lib/64` — and
`libz` being a host object then drags host `/lib/64/libc.so.1` and `libm.so.2` with it.
*Primary* resolution for every slice binary is 100 % `/nix/store`.

## 6. The .dynstr RUNPATH ceiling is exactly 511 characters

Binary-searched with `elfedit` on five proto objects — `usr/bin/cat`, `usr/bin/ls`,
`usr/bin/ksh93`, `usr/sbin/svccfg`, `usr/lib/libpool.so.1`. All five accept 511 and
reject 512 with `elfedit: [0: .dynstr]: String table does not have room to add string`.
All five carry the same pre-existing RUNPATH (`/usr/gcc/10/lib`, 15 chars), so **the
limit is a fixed cap, not per-file slack.**

The first version of the builder named each real lib dir separately, produced 519
characters, and `elfedit` failed on 12 objects. Fixed with **one flat lib dir per ABI**
(`lib-32`, `lib-64`) holding a symlink to every library the slice resolves, its own and
its deps'. The RUNPATH is now three entries / 147 characters regardless of slice size,
so it cannot creep back over the ceiling.

**Two dirs, not one, is required rather than tidy:** `lib/libc.so.1` and
`lib/amd64/libc.so.1` share a filename, so one flat dir would have to drop an ABI
silently. `ld.so.1` skips a wrong-class object and keeps walking, so carrying both is
safe. A symlink into a dep's store path is also a real Nix reference, so the dependency
edge is recorded while costing zero RUNPATH characters.

`64/ → amd64/` normalisation is applied to every path before any `mkdir`, and the
builder asserts no directory named `64` exists in `$out` — illumos `mkdir -p` fails
rc=2 when the last component is a symlink-to-directory.

## 7. ⚠️ My exec test destroyed a build host

`scripts/slice-exec-test.sh` ran every binary in each slice with no arguments. For
`illumos-smf` that set includes `lib/svc/bin/svc.configd` — so it started a **second
repository daemon against the running system's `/etc/svc/repository.db`**, which locked
and then corrupted it:

```
svc.configd: Fatal error: /etc/svc/repository.db: db error: database is locked
Requesting System Maintenance Mode
svc.configd exited with database corrupt error after initialization of the repository
```

ssh never returned; the console was the only remaining view. This is COMMON.md's *"an
instrument that changes the system is not an observer"* in its most literal form — the
observer rebooted the observed.

The script now skips daemons and state-mutating binaries (`svc.configd`, `svc.startd`,
`init`, `reboot`/`halt`/`poweroff`/`shutdown`/`uadmin`, `zpool`, `zdb`, `devfsadm`,
`format`, the `etc/fs/*/` helpers) and reports them as **SKIP, counted separately from
EXEC** — "we did not test it" and "it works" must not merge. A slice's daemons can only
be exec-tested somewhere disposable.

All measurements above were captured before the wedge.

## 8. `dixi` is wired, and the toplevel closes over the slices

`flake.nix` gains a `dixi` entry in `solnixConfigurations` and `dixiToplevel` beside
`baseToplevel`. `nix eval .#solnixConfigurations.dixi.config.networking.hostName` →
`"dixi"`.

The toplevel instantiates to a full derivation graph:

```
/nix/store/v37c6fclr2jr8x9nr88w7k73w0b8ka68-solnix-system-dixi.drv
```

and `nix-store --query --requisites` on it contains, as real `.drv` nodes,
**`illumos-core-utils`, `illumos-oamuser`, `illumos-halt` and `illumos-zfs`** — `df`,
`useradd`/`passwd`, `reboot`/`halt`/`poweroff` and `zpool`/`zfs` are in the toplevel
closure *as derivations*, which is the target condition.

⚠️ **Honest scope.** The slices were **built for real** on illumos (§1). The toplevel was
**instantiated** on the Linux box through `lib/eval-host.nix` with a *stub* gate and a
stub `nix224`, because the real proto and the x86_64-solaris `storePath`s cannot exist
there. Both halves are demonstrated; **not in one command on one machine.** Closing that
needs an AMI whose `authorized_keys` trusts `solnix-lava2` (§10).

`illumos-smf` is deliberately **not** in `dixi`'s package list: its `svccfg` cannot run,
and adding it would put a knowingly-broken `svccfg` on `PATH` ahead of the working SMF
stack that `base-tools` already provides via `systemPath`.

## 9. Seven pre-existing bugs, each of which alone blocked EVERY toplevel

None is dixi-specific; `base` and `pgfarm` were equally broken. **No solnix toplevel has
evaluated for some time**, which no test would have caught because nothing evaluated one.

1. **`assertions`/`warnings` declared nowhere.** Defined by
   `modules/config/cosmic-desktop.nix:100` and `wireless-iwx.nix:44`. Added
   `modules/config/assertions.nix` — and *enforced* it, because a declaration alone
   would make every assertion in the tree silently inert. Negative control: a false
   assertion now aborts the toplevel with `Failed assertions:`.
2. **`modules/config/first-boot-defaults.nix:136`** set `solnix.enableStockServices`;
   the option is `solnix.defaults.enableStockServices` (`firewall.nix:63` gets it
   right). One-word typo, fatal.
3. **`pkgs/illumos/starter.nix` read the `published` column as a y/n flag.** Its real
   values are the words `published` (225 rows) and `staged` (97), plus a *system name* on
   18 shifted sparc rows. Every row was rejected, so `pkgs.solnix.starter` was `{ }`, and
   `base.nix`'s `with pkgs.solnix.starter; [ coreutils … ]` failed with
   `undefined variable 'coreutils'`. **0 packages before, 70 after.** Invisible from the
   flake side, which supplies `cached` but not `starter`.
4. ⚠️ **CORRECTED 2026-09-15: `externalLibs` was NOT stale — it was AHEAD of the base AMI.**
   `pkg update` on `ami-0cb14e40f9355bd0c` supplies every one of its twelve srcs, including
   `libxml2.so.16` (SONAME confirmed with `elfdump -d`) and the `libicuuc`/`libicudata`
   `.so.78` pair. `externalLibs` needed **no edit**, `external-libs.drv` builds, and the
   `dixi` toplevel now BUILDS (`/nix/store/rk5mgx…-solnix-system-dixi`, rc=0). Calling it
   stale pointed the next reader at the wrong file; the base AMI was the stale thing. The
   original text follows for the record.

   ~~**`externalLibs` in `pkgs/illumos/default.nix` is stale against this AMI**~~ — it names
   `libxml2.so.16` and `icu-78`; neither exists on it, so the slice fails with
   `extraFile src missing`.
5. **`configurations/dixi.nix` used `with pkgs; [ git curl openssl ]`.** The host shim has
   no top-level package attrs by design. Also **`openssl` is unavailable** — every row is
   `staged`, not `published` — so the file's "load-bearing" comment named a dependency
   that could not be satisfied. Now an explicit gap.
6. **`users.users.gburd.isNormalUser`** does not exist here (`users.nix` models the
   inverse, `isRoot`); `uid` is required for a non-root user and was absent; and
   `shell = "/bin/bash"` cannot work because bash is not in the proto.
7. **`lib/host-pkgs.nix` had no `writeTextFile`**, which `modules/config/mtu.nix:18`
   calls.

## 10. Substrate: the AMI does not trust `solnix-lava2`

`gate-fod-findings.md` §6 hazard 1 records this and notes *"(Re-seeded `authorized_keys`;
`solnix-lava2` works now)"* — but that re-seed was done on a **live instance and never
baked into the AMI**. A fresh `ami-0cb14e40f9355bd0c` rejects the key:

```
ssh -o PreferredAuthentications=publickey → Permission denied (publickey,password,…)
```

The console shows a clean boot, so the machine is fine; it is purely `authorized_keys`.
Worth noting how this *looks*: a plain `ssh` reports
`Authenticated … using "keyboard-interactive"` and then hangs, which reads as a hang
rather than an auth failure — a cousin of the mux-master trap in the same section.

**The AMI needs its `authorized_keys` fixed and re-banked**, otherwise every future run
starts by losing an instance to this.

## 11. Scope

Steps 2–3 only. **Not attempted:** `solnix-install --flake` (step 4), any image build
(step 5), and **libxml2 ≥ 2.14** (named and sized here, deliberately not built).

On the ramdisk ceiling: 816,119,808 B is the EFI loader's contiguous-below-4 GB
allocation limit measured on the X1, **not** a filesystem limit. At 105 MB of slices it
is not live. If a closure-built ramdisk ever approaches it, the answer is likely to stop
shipping a ramdisk and mount the store from disk — which is closer to what NixOS does
anyway.
