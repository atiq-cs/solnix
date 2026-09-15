# `--flake` unblocked: `pkg update` yields `libxml2.so.16`, and the dixi toplevel BUILDS

Measured on `ami-0cb14e40f9355bd0c` (`i-0cef14636a8b59fc6`, c5.4xlarge, us-east-2,
Nix 2.24.15, `sandbox = false`, `system = x86_64-solaris`). Two walls were documented
before this run — the cache gap blocking EVAL and `libxml2.so.16` blocking BUILD
(`docs/cache-completeness-findings.md` §4). This run resolves the second, reaches the
ladder rung nobody had reached, and finds a bug there.

## 1. The headline: the CHEAP option works — no libxml2 derivation is needed

`docs/proto-slice-findings.md` §2 concluded that "**`libxml2 >= 2.14` must exist as a real
derivation** before a fully self-resolving core userland is possible." **That is now
false.** IPS ships it; only the base AMI was behind.

| | before | after |
|---|---|---|
| `library/libxml2` | 2.13.9-2025.0.0.0 | **2.15.4-2026.0.0.0** |
| `/usr/lib/libxml2.so.16` | ABSENT | **1,495,332 B**, ELFCLASS32/EM_386 |
| `/usr/lib/amd64/libxml2.so.16` | ABSENT | **1,677,136 B**, ELFCLASS64/EM_AMD64 |

`pkg update` rc=0 — 365.28 MB, 24,386 items, 39,514 actions, ~9 min — created BE
`openindiana-2026:09:15`. SONAME was read with `elfdump -d` (**not** inferred from the
filename) and is `libxml2.so.16` in both ABIs.

`pkg install library/libxml2@2.15.4` **before** the update reproduces the documented
rejection exactly, and it is not binutils-specific (`gate-fod-findings.md` §5.3):

```
Reject:  pkg://openindiana.org/library/libxml2@2.15.4-2026.0.0.0
Reason:  This version is excluded by installed incorporation
         consolidation/userland/userland-incorporation@0.5.11-2025.0.0.31598
```

`library/libxml2/32` is the package that supplies the **32-bit** `.so.16`, which is the
ABI the 32-bit SMF stack needs. Both ABIs are obtainable from IPS.

### ⚠️ Read the new BE BEFORE rebooting into it

The answer was obtained with `beadm mount` on the new BE **before** any reboot. A reboot
into a fresh BE can fail, and then you have neither the answer nor the machine. Getting
the measurement first costs nothing. The live post-reboot root was then re-verified
independently — a BE that *mounts* is not a BE that *boots* with everything intact —
and the two agree. Proof the BE swap actually took: `uname -v` moved
`illumos-68259130da` → `illumos-5da1ddd7c7`.

### ⚠️ THREE of `externalLibs`' six libraries were missing, not one

The brief named only `libxml2.so.16`. Checking all twelve srcs (six libs × two ABIs)
instead of only the named symptom found two more, both fixed by the same update:

| src | before | after |
|---|---|---|
| `libxml2.so.16` (both ABIs) | ABSENT | PRESENT |
| `libicuuc.so.78` (both ABIs) | **ABSENT** | PRESENT |
| `libicudata.so.78` (both ABIs) | **ABSENT** | PRESENT |
| `libz.so.1`, `libstdc++.so.6`, `libgcc_s.so.1` | PRESENT | PRESENT |

The old AMI had **no `libicuuc.so.*` at all** (it carried icu-76 and icu-77).
`library/icu-78@78.3-2026.0.0.0` was gated by the same incorporation, and libxml2 2.15.4
`require`s it, so one `pkg update` fixes all three. Had only the named library been
checked, the build would have advanced exactly one derivation and failed again — which
reads as "the fix did not work" rather than "the fix was incomplete".

**`pkgs/illumos/default.nix`'s `externalLibs` needs no edit.** `proto-slice-findings.md`
§9 item 4 called it "stale against this AMI"; it was not stale, it was **ahead** of the
base AMI. The block's own comment — libxml2 NEEDs libz + libicuuc, libicuuc NEEDs
libicudata + libstdc++ + libgcc_s — is confirmed by `elfdump -d` on the new library:

```
NEEDED  libz.so.1      NEEDED  libicuuc.so.78      NEEDED  libm.so.2      NEEDED  libc.so.1
```

### Reproducing without a new AMI

The update is pinnable by exact FMRI:

```
pkg://openindiana.org/library/libxml2@2.15.4-2026.0.0.0:20260912T131628Z
pkg://openindiana.org/library/libxml2/32@2.15.4-2026.0.0.0:20260912T131627Z
pkg://openindiana.org/library/icu-78@78.3-2026.0.0.0:20260319T180406Z
pkg://openindiana.org/library/icu-78/32@78.3-2026.0.0.0:20260319T180400Z
```

⚠️ Not oversold: the publisher is a single **moving** hipster catalog with no snapshot
history, so those FMRIs hold only as long as hipster serves them. That is an argument for
banking a real image eventually — but see §5 on why the obvious shortcut is forbidden.

## 2. The ladder: INSTANTIATES → **BUILDS**

First time a solnix toplevel has been instantiated **and** realised on one machine.
`proto-slice-findings.md` §8 could only demonstrate the two halves on two different
boxes ("Both halves are demonstrated; **not in one command on one machine**").

| rung | status | evidence |
|---|---|---|
| instantiates | **YES** | `/nix/store/wc29cqv5v3k4203dxwsffhdvgnxm8r5v-solnix-system-dixi.drv` |
| builds | **YES** | `/nix/store/rk5mgx4qf5wadwa51z7gvrmr49d2l5z8-solnix-system-dixi`, rc=0 |
| `switch-to-configuration` runs | **YES, with a bug** | §4 |
| installs / boots | **NOT ATTEMPTED** | no disk was written; see §6 |

The wall derivation itself, which previously died with
`FATAL: extraFile src missing (/usr/lib/libxml2.so.16)`:

```
/nix/store/3hpk4sa95xarcwgvmsjb7kcvz34rh00q-external-libs   BUILT
  usr/lib/libxml2.so.16         1,495,332 B   SONAME=libxml2.so.16
  usr/lib/amd64/libxml2.so.16   1,677,136 B   SONAME=libxml2.so.16
```

All twelve objects are **real files** (`cp -aL` dereferenced the host's versioned
symlinks as intended), not dangling links to a version that was never copied.

Every gate `scripts/solnix-install` applies to a `--flake` toplevel passes on the real
artifact — and each has been absent in a real toplevel at some point in this repo:

```
activate                                       PRESENT
systemPath                                     PRESENT
bin/switch-to-configuration                    PRESENT
systemPath/platform/i86pc/kernel/amd64/unix    2,616,328 B
systemPath/kernel/amd64/genunix                6,034,616 B
```

Both kernel sizes match `gate-fod-findings.md` byte-for-byte, so the proto is the pinned
one and not a rebuild.

## 3. The EVAL wall is still there, and it is bigger than five names

Unchanged by this work, and it is why the brief's "two independent walls" framing holds.
Re-measured here, with a **positive** control because a bare 404 proves nothing — my
first negative control (a bogus hash) also returns 404:

```
7bnpc66nfnr7gvn6nfm5x42pvnzfifdv  (file)       200   <- positive control
d9zrp2hjgbdq8gv0b2gi46pdlq88qyp7  (gnugrep)    200   <- positive control
3wlwvk71i6dfwiq63kdakq02fig8m68p  (coreutils)  404   on cache.solnix.io AND s3.solnix.io
```

So the probe discriminates and the 404 is real. Eval needs the five documented
unfetchable names dropped (`coreutils`, `nvi`, `gdb`, `git`, `curl`).

### ⚠️ NEW: `which` is unusable on x86_64, and it is NOT a cache gap

`docs/cache-completeness-findings.md` §3 flags that `which` has four registry rows and
that taking the first match is a trap. The **arch** is the missing half:

| rows for `which` | |
|---|---|
| 3 × `x86_64-solaris` | `staged` |
| 1 × `sparcv9-solaris` | `published` |

`starter.nix` correctly filters on `published`, so **x86_64 gets no `which` at all** —
`pkgs.solnix.starter.which` is an undefined variable, not a 404. Because
`configurations/base.nix:44` lists `which`, **`base.nix` cannot evaluate on x86_64
either**. That is a live bug in a committed config, independent of the cache, and it
affects every configuration that imports base.nix. (`xz` is fine: its x86_64 row is
published. It was omitted from a first draft of the workaround and that omission was
wrong.)

## 4. ⚠️ `switch-to-configuration` — executed for the first time, and it has a real bug

Nobody had ever run this. It runs, and its argument guards are sound
(negative-controlled: no action → usage rc=1; nonexistent target → refuses; a real
directory with no `activate` → refuses naming the reason).

`boot` then **partially succeeds and reports success**, which is the dangerous shape:

```
registered generation 1 -> /nix/store/rk5mgx…-solnix-system-dixi
== creating boot environment solnix-1 for generation 1 ==
Created successfully / Mounted successfully on: '/a'
-- copying toplevel closure into solnix-1:/nix/store
Usage: cp [-afinpT@/] source_file target_file            <- illumos cp usage error
       ...
chmod: WARNING: can't access /a/lib/svc/method/solnix-activate
Activated successfully
== generation 1 is the boot default (BE solnix-1). Reboot to run it. ==
```

Verified by remounting the BE: the four SMF manifests **are** staged, but
`/a/lib/svc/method/solnix-activate` is **ABSENT**. So it activated a BE for next boot
whose activation method was never staged, and exited claiming success. The `|| true` on
those lines is what converts a hard failure into a silent one.

### Root cause: `cp -L` is not valid on illumos

`modules/system/activation/default.nix`, in `do_boot`, stages with `cp -L`. The source
(`$toplevel/activate`) is a symlink into the store, so dereferencing is the intent — but
illumos `cp` rejects a bare `-L`. Its own usage says `-H`/`-L`/`-P` are legal only
**with** `-r`/`-R`:

```
cp [-r|-R [-H|-L|-P]] [-afinp@/] source_dir... target
```

Reproduced by hand: `cp -L "$TL/activate" <dst>` → **rc=2**, usage text, no file created.
Controls, all measured on the node:

| form | result |
|---|---|
| `cp -L src dst` | **rc=2**, file not created |
| `cp src dst` | rc=0, 1,184 B real content — deref is the **default** for a source symlink, so `-L` was never needed |
| `cp -RL src dst` | rc=0, works (the illumos-legal spelling) |
| `/usr/gnu/bin/cp` | **does not exist** on this AMI — no GNU `cp` to fall back to |

Fix verified by hand inside the BE: plain `cp` stages both files with real content and
correct modes (`-r-xr-xr-x`, 1,184 B method; 1,899 B site profile), giving a BE with all
three halves activation needs (method + profile + 4 manifests).

`copy_path`'s `cp -R -P` in the same function is **fine** — that is the legal `-R` form.
Only the two `cp -L` lines are affected.

This is COMMON.md's "illumos is missing GNU tools and the failures are SILENT" class,
and it survived in committed code precisely because this rung had never been executed.

### `switch` and `test` were deliberately NOT run

Both call `do_activate`, which runs the target's `activate` against the **live** SMF
repository: `svccfg apply`, `svccfg import` per manifest, then
`svcadm milestone svc:/milestone/multi-user-server:default`. Running a second
repository-mutating activation against a live build host is what corrupted an SMF
repository before (`proto-slice-findings.md` §7). That needs a disposable target.

## 5. Two falsified comments in committed configs

Both were found by reading the built artifact rather than the source.

**1. `configurations/base.nix:78`** says the `enable = false` sshd example
"keeps `svcs -x` clean while still generating the manifest into the toplevel". **It
generates nothing.** `modules/system/boot/init/smf.nix:278` filters
`enabledServices = filterAttrs (_: s: s.enable) config.smf.services`, so a disabled
service produces no manifest and no method. `find` over the built toplevel for `*sshd*`
returns zero files.

Two consequences worth noting:
* the generated **site profile still lists** `network/sshd enabled='false'` (the profile
  writer at `activation/default.nix:42` iterates *all* services, not just enabled ones),
  so `svccfg apply` references a service that has no manifest;
* sshd is the *only* contract-model example, so the build-time DTD gate never validates a
  contract service at all.

**2. `configurations/dixi.nix`** excludes `illumos-smf` because `svccfg` "NEEDs
`libxml2.so.16`, which exists in no reachable build". It exists now (§1), so that
exclusion should be revisited — `svccfg` was the single hard-blocked binary in
`proto-slice-findings.md` §3.

### A near miss worth recording

`activate` runs `svcadm disable svc:/network/sshd:default`. On this node the live service
is `svc:/network/ssh:default` — a **different** FMRI — so the disable silently no-ops.
That is the only reason executing `activate` would not have cut the ssh session it was
being driven over. Checked before running anything rather than after.

## 6. Scope, and what is NOT claimed

* **INSTALLS / BOOTS: not attempted.** No disk was written, no install performed. The
  toplevel building and `switch-to-configuration boot` creating a BE are *not* the same
  claim as a machine booting into that generation.
* `switch` / `test` not executed (§4).
* The `cp -L` fix is **verified by hand**, not yet committed, and `do_boot` has not been
  re-run end to end with it applied.
* The `pkgs.bash` infinite recursion in the solaris stdenv (previous run) was **not
  encountered**: the host eval path (`lib/eval-host.nix` → `lib/host-pkgs.nix`) has no
  nixpkgs stdenv at all, which is the whole reason that shim exists. So it is not
  refuted — it simply does not arise on this path, and home-manager was not attempted.
* ⚠️ **No new AMI was banked, deliberately.** `scripts/ami-bank.sh` reads an AMI's own
  **snapshot** because capturing a booted node is, in its words, "the documented way to
  LOSE the reliable-boot property", citing a measured cold-boot DHCP regression
  (`docs/base-ami-rebuild-runbook.md:80` and `:186`: "do NOT re-bake a derivative AMI
  from a running instance"). Banking the updated state therefore requires
  stop → create-image → bank-by-id, and re-measuring cold-boot rate over ≥6 launches to
  know whether it regressed. The pinned FMRIs in §1 reproduce the state in ~9 min
  meanwhile.

## 7. Reproducing

Prereq correction that blocked this run: `scripts/slice-host-bootstrap.sh` unpacks the
banked proto with `/usr/gnu/bin/tar`, which **is not installed on the base AMI** — the
script installs only `compress/zstd` and `text/gnu-diffutils`. Measured on *both* boot
environments: `/usr/gnu/bin/tar` ABSENT, `/usr/bin/tar` present. So that stage has been
broken on any genuinely fresh AMI the whole time and only ever worked where something
else had pulled `archiver/gnu-tar` in. `pkg install archiver/gnu-tar` fixes it (rc=0,
ungated). Note also `pkg install compress/zstd` now returns **exit=4** (already-installed
no-op), which is not a failure.

The host eval needs more than the `.nix` tree: `docs/registry/*.tsv` (read by
`starter.nix` and `cached.nix` via `readFile`) and `scripts/solnix-mtu.sh` +
`scripts/solnix-install` (read by `modules/config/mtu.nix`). Omitting them yields
`opening file ... No such file or directory` at eval, naming the *consumer* rather than
the missing input.
