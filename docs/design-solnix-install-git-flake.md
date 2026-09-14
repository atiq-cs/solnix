# `solnix-install --git … --flake .#dixi` — the full spec, and the one thing that blocks it

The maintainer's requested flow, verbatim in intent:

```sh
./solnix-install --git git@github.com:gburd/nix-config.git --flake .#dixi
```

1. confirm which drive to install to
2. check out the nix-config
3. **ensure the `.#dixi` profile exists**
4. ask to begin
5. build and install the entire flake
6. notice a home-manager user and offer to install it, choosing `/export/home` or `/home`
7. build/install that
8. reboot → everything works

## ⚠️ Step 3 fails today, and it is the crux

`.#dixi` does not exist in `nix-config`. Measured:

| attr | present? |
|---|---|
| `homeConfigurations."gburd@dixi"` | ✅ `flake.nix:199`, `platform = "x86_64-solaris"` |
| `nixosConfigurations.dixi` | ❌ **absent** — the set holds `floki meh santorini pgperf-arm pgperf-x86 agent-vm` |

So the **home-manager half exists and the system half does not**. `--flake .#dixi` would resolve to nothing, and
step 3's "ensure the profile exists" check would correctly refuse.

That is not a defect in the request — it is the request revealing a missing piece. There are two coherent
answers, and the choice is the maintainer's:

**(a) the system config lives in `solnix`** — `solnixConfigurations.dixi` (`configurations/dixi.nix` already
exists here, and `solnixConfigurations` is described in `flake.nix:70` as *"the `nixosConfigurations`
analog"*). Then the flow is two flakes:

```sh
solnix-install --flake github:gregburd/solnix#dixi \
               --home git@github.com:gburd/nix-config.git#gburd@dixi
```

**(b) the system config lives in `nix-config`** — add `nixosConfigurations.dixi` there beside `floki`/`meh`,
importing solnix's modules as a flake input. Then one flake does both, exactly as asked:

```sh
solnix-install --git git@github.com:gburd/nix-config.git --flake .#dixi
```

⚠️ (b) matches the request but means `nix-config` must evaluate solnix's module set for `x86_64-solaris`. That
already half-works: `mkHome` resolves `*-solaris` platforms via the solnix-pkgs fork (`lib/helpers.nix:7-12`), so
the precedent exists — but the *system* side has never been evaluated from there.

## What must be true before ANY of this runs

The flow's step 5 — *"built and installed the entire flake"* — is `nix build` of a toplevel followed by
`nix copy` of its closure. That is exactly `nixos-install`'s shape (`pkgs/by-name/ni/nixos-install/`, 345 lines):
build → copy → `switch-to-configuration boot` → interactive `passwd`.

**It cannot work until the toplevel contains a usable system.** Today `df`, `useradd`, `passwd`,
`reboot`/`halt`/`poweroff`, `zpool`/`zfs`, `svcadm`/`svccfg` and the kernel are illumos **core-OS** and are not
derivations.

| step | state |
|---|---|
| 1. `gate.nix` a building FOD | ✅ **done** — `unix` 2,616,328 B + `genunix` 6,034,616 B in a store path |
| 2. slice the proto into derivations | **in flight** |
| 3. `dixi` toplevel evaluates | in flight |
| 4. `solnix-install --flake` | **this document** |
| 5. image built from the closure | not started |

## The installer interface, once step 3 lands

```
solnix-install [--git <url> [--ref <rev>]] --flake <flakeref>#<attr>
               [--home <flakeref>#<attr>] [--home-base /home|/export/home]
               [--disk <target>] [--no-home]
```

Behaviour, in order, mirroring the request:

1. **Disk confirmation.** Enumerate `/dev/rdsk/*s0` with sizes, mark unlabelled as fine (that is the *normal*
   state for a target), name the booted-from device, and require explicit confirmation. Already implemented.
2. **Fetch.** `git clone --depth 1` the `--git` URL into a temp dir (or use a local path). ⚠️ **`git@…` needs an
   ssh key on the live media** — offer the `https://` form, since a fresh installer has no key.
3. **Verify the attr exists before doing anything destructive**:
   `nix eval <flake>#<attr>.config.system.build.toplevel.drvPath --raw`. If it fails, **stop and say which
   attrs *do* exist** rather than proceeding.
4. **Show the plan, then ask.** Disk, pool, flake, attr, home layout, console geometry — then `[y/N]`. Already
   the pattern used for the admin user.
5. **Build + copy + activate.** `nix build`, `nix copy --to /a`, then `switch-to-configuration boot` under
   chroot. Replaces the `cpio` path lists entirely.
6. **Home-manager.** After the system lands, detect `homeConfigurations` in the same or the `--home` flake, ask
   which base (`/home` default per FreeBSD's `bsdinstall`, `/export/home` for traditional Solaris), then
   `home-manager switch --flake <ref>#<attr>`.
   ⚠️ **`/home` needs autofs disabled AND the `auto_master` `/home` line commented** — a dataset alone is
   silently shadowed at boot. Verified on the maintainer's host `sun`, which runs `/home/gburd` with the autofs
   *service* disabled. Both halves already implemented.
7. **Reboot prompt.** Already implemented, after the pool export.

## Hard prerequisite that is not code

⚠️ **Network.** Steps 2 and 5 fetch from the internet. **Wifi does not work and is not close**: the Intel AX2xx
has no illumos driver, no OpenSolaris fork has one (checked `illumos-gate`, `omnios`, `joyent`, `nexenta` —
newest Intel support is the `iwn`/`iwp` 6000-series era, zero forks claim `0x2723`/`0x2725`/`0x02f0`), and the
OpenBSD `iwx` port was abandoned after measuring that it needs a BSD network-interface layer illumos never had.

**USB-Ethernet is the answer.** illumos has four USB-ethernet drivers and all are Fast Ethernet: `axf`
(ASIX AX88172/88178/88772), `udmf` (Davicom DM9601E), `upf` (Prolific), `urf` (Realtek **RTL8150**).
⚠️ **None claims RTL8153**, which is what a modern Lenovo dongle usually is — so an **ASIX AX88772**-based
adapter is the safe choice.
