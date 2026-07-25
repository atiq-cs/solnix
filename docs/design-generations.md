# Design: generations ↔ ZFS boot environments (T2.5)

Status: **implemented + gate-verified on EC2** (2026-07-25). Maps roadmap
**T2.5** (map Nix generations onto ZFS boot environments; `switch-to-configuration`
activates within a BE; rollback = `beadm activate` the previous). Realises
steering pillar 5 (`.kiro/steering/product.md`) and the ZFS-root/BE section of
`.kiro/steering/illumos-domain.md`.

This is solnix's "upgradeable system" payoff: NixOS-style atomic switch +
rollback, implemented natively with illumos `beadm` boot environments rather
than a bootloader-generation list.

---

## 0. The model (steering pillar 5)

- Root FS = ZFS `rpool` (here `spool`); root datasets under `rpool/ROOT/<be>`.
- **A solnix generation = a ZFS boot environment.** `/nix/store` lives *inside*
  the BE (each BE is a self-contained root). A generation's toplevel closure is
  copied into its BE's `/nix/store`.
- **switch** (activate now): run the target toplevel's `activate` script — live
  SMF reconcile (`svccfg import` the changed manifests, `svcadm enable/disable`
  to match the new config, `svcadm milestone` to the target) — **without a
  reboot**. Also update `/run-current-system` and the generation registry.
- **boot** (activate for next boot): `beadm create` a new BE, lay the new
  generation's toplevel + closure into it, set its `/run-current-system` +
  stage its SMF manifests, `beadm activate` it. Next reboot runs the new
  generation.
- **rollback**: `beadm activate <previous-BE>`. Next reboot runs the old
  generation. The loader reads `bootfs` from the pool (set by `beadm activate`)
  and boots that dataset.

This gives atomic switch (the new BE is a full clone; a failed build never
touches the running root) and instant rollback (the old BE is untouched).

---

## 1. The two layers

### 1.1 Runtime tools (in the toplevel)

`system.build.toplevel` now carries two scripts under `bin/`
(`modules/system/activation/default.nix`):

- **`bin/switch-to-configuration`** — the NixOS `switch-to-configuration`
  analog. Actions:
  - `switch <toplevel>` — activate live (SMF reconcile) **and** create+activate
    a BE for next boot (so a reboot stays on the switched generation).
  - `test  <toplevel>` — activate live only; do **not** touch the boot default.
  - `boot  <toplevel>` — create a new BE with `<toplevel>`, activate it for next
    boot; do not change the running system.
  - `list-generations` — the generation registry + `beadm list`.
  - `<toplevel>` defaults to this script's own system (discovered from `$0`'s
    `bin/` parent, falling back to `/run-current-system`).
- **`bin/solnix-rebuild`** — the `nixos-rebuild` analog / convenience wrapper:
  `switch|boot|test [toplevel]`, plus `rollback` (`beadm activate` the previous
  BE) and `list-generations`. Defaults the toplevel to the highest registered
  generation.

make-be symlinks both into `/usr/bin` so an admin just runs `solnix-rebuild
switch <top>` / `solnix-rebuild rollback`.

**No `nix` dependency at runtime.** The scripts are pure `/sbin/sh` + `beadm` +
`cp`. The minimal proto image has no `nix` binary, so the closure copy walks
the toplevel's own store symlinks (and the BE is a ZFS clone that already holds
the running closure, so usually nothing needs copying). The generation registry
is plain symlinks under `/nix/var/nix/profiles` that the script maintains
itself (no `nix-env --profile`).

### 1.2 The generation registry

Mirrors NixOS's profile layout enough to list + roll back, without nix:

```
/nix/var/nix/profiles/
  system-1-link -> /nix/store/<hash>-solnix-system-<host>   (generation 1)
  system-2-link -> /nix/store/<hash>-solnix-system-<host>   (generation 2)
  system        -> system-2-link                            (the current gen)
  system.gen    -> "2"                                       (the number)
/run-current-system -> <toplevel of the running generation>
```

`make-be` seeds generation 1 = the image's toplevel. Each `switch`/`boot`
registers the next generation. BE names track the generation: `solnix-<N>`
(never reusing the running BE's name — `next_gen` also scans existing
`solnix-<n>` BEs so numbers never collide).

### 1.3 Nix side

`modules/system/activation/default.nix` emits both scripts (via `writeScript`)
and adds `$out/bin/{switch-to-configuration,solnix-rebuild}` to the toplevel,
plus exposes `system.build.{switchToConfiguration,solnixRebuild}`. It reuses the
existing `activate` script (svccfg import + svcadm milestone) rather than
duplicating the SMF logic — `switch`/`test` just call `<target>/activate`.

`lib/make-be.nix` stages the registry + tools into the image and (T2.5)
prepares the pool for `beadm`: gives the pool a mountpoint + seeds
`/<pool>/boot/menu.lst` (see §3 gotcha).

---

## 2. Switch / rollback recipe

On a running solnix system (tools are on `$PATH`):

```sh
# switch to a new generation now AND set it as the boot default:
solnix-rebuild switch /nix/store/<hash>-solnix-system-<host>

# activate live only (no reboot, boot default unchanged) — the safe "try it":
switch-to-configuration test /nix/store/<hash>-solnix-system-<host>

# stage a new generation for the NEXT boot only (no live change):
solnix-rebuild boot /nix/store/<hash>-solnix-system-<host>
reboot                        # comes up on the new generation

# roll back to the previous boot environment:
solnix-rebuild rollback       # beadm activate <previous BE>
reboot                        # back on the old generation

# see what's registered:
solnix-rebuild list-generations
```

Building the new toplevel (on the illumos build host, Nix 2.3.16, classic):

```sh
cd /var/tmp/solnix-repo
nix-build lib/eval-host.nix -A toplevel --no-out-link
# copy the closure to the target (nix copy, or cpio the store paths for a
# nix-less target), then run solnix-rebuild switch <that path> on the target.
```

---

## 3. Gotchas (root-caused on EC2)

1. **`beadm create` → "Missing boot menu file" / "Invalid path for menu.lst".**
   illumos `libbe` needs the pool's top-level dataset mounted and a
   `<pool-mountpoint>/boot/menu.lst` present to rewrite on create/activate. Our
   image created the pool with `mountpoint=none` (mirroring the running-root
   layout), so libbe had nowhere to find/write the menu. **Fix:** give the pool
   a mountpoint (`zfs set mountpoint=/<pool> <pool>`) and seed
   `/<pool>/boot/menu.lst`. `make-be` does this at image build; the switch
   script's `ensure_menu()` does it idempotently at runtime as a belt-and-braces.
   (The loader actually boots the dataset named by the pool's `bootfs` property,
   which `beadm activate` sets; `menu.lst` is the grub-legacy file libbe insists
   on maintaining.)

2. **illumos `ln -sfn` silently FOLLOWS an existing symlink-to-directory.**
   Unlike GNU coreutils, `ln -sfn newtarget existing_symlink_to_dir` on illumos
   returns 0 and does *nothing* (or creates *inside* the pointed-to dir). Every
   profile/`run-current-system` repoint must be `rm -f && ln -s`. Wrapped as
   `relink()` in the script; `make-be` does the explicit rm+ln too. This bit the
   first `switch` run (run-current-system + `system` profile didn't move despite
   rc=0).

3. **The minimal proto has no `readlink(1)`.** The switch script derives symlink
   targets with `ls -ld ... | sed 's/.* -> //'` (`_readlink()`), not `readlink`.
   (It also has no `pax`/`gunzip`; use `cpio` + `zcat` for `.Z`, or transfer
   store closures uncompressed.)

4. **illumos `cp` for dir trees is `cp -R -P` (not `-RP`), no trailing slash on
   the target.** `-P` preserves symlinks (store paths are symlink forests). The
   BE is a ZFS clone of the running BE, so its `/nix/store` already holds the
   running closure — the copy only fills in paths the clone is missing, so the
   copy is usually a no-op on a same-world switch.

5. **Removal-on-switch across BEs is partial (documented deferral).** `boot`
   drops stale solnix-generated manifest *files* from the new BE that the target
   no longer declares (keeping the boot-plumbing hello/netcfg). But the BE's
   cloned `repository.db` still has the removed service registered, so on first
   boot of the new BE `manifest-import` may re-online a service the target
   dropped. Fully clean removal needs the new BE's first-boot activation to
   `svccfg delete` the removed FMRIs (a diff against the previous generation) —
   deferred to a later pass. The *generation identity* is unaffected:
   `/run-current-system` is the authoritative "which generation booted" marker.

6. **Reboot on EC2.** `reboot` warns `Not all drivers have implemented
   quiesce(9E)` and falls back to a full reboot (which is what we want — the
   loader re-reads `bootfs`). The instance may get a new DHCP lease + SSH host
   key; the public IP is retained across an in-place reboot. Boots are reliable
   thanks to the pit_is_broken kernel fix baked into the non-DEBUG proto (T2.1).

---

## 4. Gate evidence (EC2, 2026-07-25)

Built two generations on the build host (Nix 2.3.16, x86_64-solaris):
- **Gen A** `g4hrlxhi…-solnix-system-solnix` — marker oneshot only.
- **Gen B** `bfjvy4m7…-solnix-system-solnix` — marker + a `solnix-switch-witness`
  oneshot (the change under test).

### GATE A — live switch (no reboot) — PASS

On `solnix-t2-SSH-PASS` (proto-root AMI, beadm present, no `/nix`):
- baseline: activate gen A → `site/solnix-marker` **online**,
  `site/solnix-switch-witness` **ABSENT**, `/run-current-system` → gen A.
- `switch-to-configuration test <genB>` → `site/solnix-switch-witness` comes
  **online live**, `site/solnix-marker` still online, `/run-current-system`
  flips to gen B, `system` profile → generation 2, **`svcs -x` empty**,
  **uptime unchanged (no reboot)**.

### GATE B — new BE + reboot-into-new-gen + rollback — PASS

On a throwaway launched from the T2.5 nixified AMI (`/nix` + full closure +
switch tools + beadm-ready pool):
- boots as gen B (`/run-current-system → bfjvy4m7…`), `svcs -x` clean, tools on
  `$PATH`, `beadm list` shows `solnix-1 NR`.
- `solnix-rebuild boot <genA>` → creates BE **`solnix-2`** with gen A, sets its
  `/run-current-system → gen A`, `beadm activate solnix-2` (→ `R`,
  `bootfs=spool/ROOT/solnix-2`, menu.lst updated).
- **reboot → comes up on gen A** (console + SSH: `/run-current-system →
  g4hrlxhi…`, `solnix-2 NR`, multi-user-server online, `svcs -x` clean).
- `solnix-rebuild rollback` → `beadm activate solnix-1` (→ `solnix-1 R`,
  `bootfs=spool/ROOT/solnix-1`).
- **reboot → back on gen B** (console + SSH: `/run-current-system → bfjvy4m7…`,
  `solnix-1 NR`, gen B's witness online, `svcs -x` clean).

`beadm` is **present** in the image (`/usr/sbin/beadm` + `/usr/lib/libbe.so.1`
from the gate proto) — no slicing needed; the only fix was the pool
mountpoint + menu.lst (gotcha #1).

Artifacts: AMI `ami-036132346cc90bed0` (solnix-t2.5-generations-final),
toplevel `83kwlmzs…-solnix-system-solnix`. Throwaway boot-test instances
terminated.
